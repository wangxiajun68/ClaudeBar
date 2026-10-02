import Foundation
import simd

/// One moment of one sky, reduced to the numbers the atmosphere shader draws.
///
/// Pure value code (Foundation + simd): the renderer, the preview probe and the
/// regression tests all build the same scene from the same inputs.
///
/// Colour is a function of **solar altitude**, not the wall clock, so a July
/// 19:30 in Guangzhou and a December 17:10 in Harbin both read as "sunset".
/// Weather is a transform over the clear-sky keyframes rather than a second
/// hand-picked table: `stop = exposure × mix(clear, mix(nightTint, dayTint,
/// dayness), amount)`. The horizon stop takes less of the tint than the zenith,
/// which is why an overcast sunrise still shows a warm seam.
struct SkyScene: Equatable {
    enum Weather: String {
        case clear, cloudy, overcast, lightRain, heavyRain, thunder, snow, fog
    }

    /// The eight parts of a solar day. Rising and setting halves are distinct
    /// because a morning and an afternoon at the same altitude are not the
    /// same colour.
    enum Band {
        case night, dawn, sunrise, morning, noon, afternoon, sunset, dusk
    }

    var weather: Weather
    var band: Band
    var zenith: SIMD3<Float>
    var mid: SIMD3<Float>
    var horizon: SIMD3<Float>
    var glow: SIMD3<Float>
    var glowStrength: Float
    /// Positions are in sky-band units: x 0…1 across, y 0…1 down the sky band.
    var sunUV: SIMD2<Float>
    var sunRadius: Float
    var sunVisibility: Float
    var sunColor: SIMD3<Float>
    var sunAltitude: Float
    var moonUV: SIMD2<Float>
    var moonRadius: Float
    var moonVisibility: Float
    var moonPhase: Float
    var starVisibility: Float
    /// Catalogue stars above the horizon: (u, v, radius pt, seed).
    var stars: [SIMD4<Float>]
    var starDrift: Float
    var cloudCover: Float
    var cloudDarkness: Float
    var windSpeed: Float
    var windAngle: Float
    var rain: Float
    var snow: Float
    var fog: Float
    var thunder: Float
    var hail: Bool
    var glassDrops: Float
    var rimStrength: Float
    var textGlow: Float
    var nightness: Float

    static let horizonLine: Float = 0.80
    static let fieldOfView: Double = 220
    /// Horizon to zenith spans 72 % of the band, so a body overhead still
    /// clears the top edge by its own radius.
    static let altitudeSpan: Double = 0.72

    /// Relative luminance of an sRGB colour: decode to linear light, then the
    /// Rec. 709 weights. The ink comparisons beside it are ratios of this, so
    /// both callers have to agree on where the crossover lies.
    static func luminance(_ c: SIMD3<Float>) -> Float {
        func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.x) + 0.7152 * linear(c.y) + 0.0722 * linear(c.z)
    }

    /// Relative luminance of the sky behind the greeting (the band between the
    /// mid and horizon stops, where the glyphs sit).
    var greetingGroundLuminance: Float {
        Self.luminance(simd_mix(mid, horizon, SIMD3(repeating: 0.3)))
    }

    /// Choose the greeting's ink at the light/dark contrast crossover, before
    /// white lettering disappears into a daytime sky.
    var prefersDarkInk: Bool { greetingGroundLuminance > 0.18 }

    /// Stable local sky estimate for instrument ink. Match the shader's sky
    /// gradient and broad scattering/fog; exclude moving stars, raindrops and
    /// lightning so small highlights do not make the labels flicker.
    func instrumentGround(at uv: SIMD2<Float>, aspect: Float) -> SIMD3<Float> {
        let t = min(1, max(0, uv.y / (Self.horizonLine + 0.06)))
        var c = t < 0.55
            ? simd_mix(zenith, mid, SIMD3(repeating: t / 0.55))
            : simd_mix(mid, horizon, SIMD3(repeating: (t - 0.55) / 0.45))
        let distance = (uv - SIMD2(sunUV.x, Self.horizonLine + 0.02)) * SIMD2(aspect * 0.42, 2.1)
        c += glow * glowStrength * exp(-simd_dot(distance, distance) * 1.6)
        let depth = Self.smooth(0.05, Self.horizonLine + 0.05, uv.y)
        let fogColor = simd_mix(horizon, SIMD3<Float>(0.86, 0.88, 0.9) * (1 - 0.7 * nightness), SIMD3(repeating: 0.35))
        c = simd_mix(c, fogColor, SIMD3(repeating: min(0.92, fog * (0.25 + 0.75 * depth) * 0.72)))
        return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    /// Compare the two actual inks in linear sRGB, rather than choosing by
    /// clock time or appearance. Top and horizon instruments can differ.
    func prefersDarkInk(at uv: SIMD2<Float>, aspect: Float) -> Bool {
        let background = Self.luminance(instrumentGround(at: uv, aspect: aspect))
        let navy = Self.luminance(SIMD3<Float>(20, 30, 51) / 255)
        return (background + 0.05) / (navy + 0.05) > 1.05 / (background + 0.05)
    }

    // MARK: - Construction

    static func make(sky: WeatherReading.Sky?, rainChance: Int, windKph: Double, windDirection: String,
                     astronomy: SkyAstronomy.Snapshot) -> SkyScene {
        let weather = weather(for: sky, rainChance: rainChance)
        let sunAlt = astronomy.sun.altitude
        let rising = isRising(azimuth: astronomy.sun.azimuth)
        let south = astronomy.latitude >= 0
        let center = south ? 180.0 : 0.0

        let keyframes = rising ? risingKeys : settingKeys
        let (clear, dayness) = interpolate(keyframes, altitude: sunAlt)
        let look = looks[weather]!
        func tint(_ stop: SIMD3<Float>, _ index: Int) -> SIMD3<Float> {
            guard let day = look.dayTint, let night = look.nightTint else { return stop * look.exposure }
            let target = simd_mix(night, day, SIMD3(repeating: dayness))
            return simd_mix(stop, target, SIMD3(repeating: look.amount[index])) * look.exposure
        }
        let zenith = tint(clear[0], 0), mid = tint(clear[1], 1), horizon = tint(clear[2], 2)

        // The snapshot already derives this from the same altitude; keeping one
        // expression means the renderer and the twilight tint cannot drift.
        let twilight = Float(astronomy.twilight)
        let nightness = smooth(2, -12, Float(sunAlt))
        let clarity = look.clarity

        let sunUV = project(astronomy.sun, center: center)
        let moonUV = project(astronomy.moon, center: center)
        let moonAlt = Float(astronomy.moon.altitude)
        let lowSun = smooth(15, 0, Float(sunAlt))
        let lowMoon = smooth(15, 0, moonAlt)

        var stars: [SIMD4<Float>] = []
        for (index, star) in SkyAstronomy.stars.enumerated() {
            let position = SkyAstronomy.star(raHours: star.0, declination: star.1, in: astronomy)
            guard position.altitude > 2 else { continue }
            let uv = project(position, center: center)
            guard uv.x > -0.05, uv.x < 1.05 else { continue }
            stars.append(SIMD4(uv.x, uv.y, Float(star.2), Float(index) * 0.618))
        }

        let rain: Float, snow: Float, fog: Float, thunder: Float, drops: Float
        let chance = Float(max(0, min(100, rainChance))) / 100
        switch weather {
        case .clear: (rain, snow, fog, thunder, drops) = (0, 0, 0, 0, 0)
        case .cloudy: (rain, snow, fog, thunder, drops) = (0, 0, 0, 0, 0)
        case .overcast: (rain, snow, fog, thunder, drops) = (0, 0, 0.12, 0, 0)
        case .lightRain:
            let drizzle = sky == .drizzle
            rain = drizzle ? 0.22 : 0.38 + chance * 0.18
            snow = sky == .sleet ? 0.45 : 0
            (fog, thunder, drops) = (0.28, 0, drizzle ? 0.3 : 0.55)
        case .heavyRain: (rain, snow, fog, thunder, drops) = (0.78 + chance * 0.22, 0, 0.42, 0, 1)
        case .thunder: (rain, snow, fog, thunder, drops) = (0.96, 0, 0.3, 1, 1)
        case .snow: (rain, snow, fog, thunder, drops) = (0, 0.85, 0.3, 0, 0)
        case .fog: (rain, snow, fog, thunder, drops) = (0, 0, 1, 0, 0)
        }

        let windSign: Float = windDirection.hasPrefix("东") ? -1 : 1
        let slant = min(18, Float(windKph) * 0.6) * .pi / 180 * windSign
        let sunVisibility = smooth(-3, 0.5, Float(sunAlt)) * clarity
        let moonVisibility = smooth(-1, 3, moonAlt) * clarity * (0.35 + 0.65 * nightness)

        return SkyScene(
            weather: weather,
            band: band(altitude: sunAlt, rising: rising),
            zenith: zenith, mid: mid, horizon: horizon,
            glow: simd_mix(horizon, SIMD3(repeating: 1), SIMD3(repeating: 0.12)),
            glowStrength: look.glow * (0.6 + 0.8 * twilight),
            sunUV: sunUV, sunRadius: 19 * (1 + 0.35 * lowSun),
            sunVisibility: sunVisibility,
            sunColor: sunColor(altitude: Float(sunAlt)),
            sunAltitude: Float(sunAlt),
            moonUV: moonUV, moonRadius: 15 * (1 + 0.3 * lowMoon),
            moonVisibility: moonVisibility,
            moonPhase: Float(astronomy.moonPhase),
            starVisibility: smooth(-5, -15, Float(sunAlt)) * look.starClarity,
            stars: stars,
            starDrift: Float(astronomy.sidereal.truncatingRemainder(dividingBy: 2 * .pi) / (2 * .pi)),
            cloudCover: look.cover, cloudDarkness: look.darkness,
            windSpeed: 6 + min(40, Float(windKph)) * 0.6,
            windAngle: slant,
            rain: rain, snow: snow, fog: fog, thunder: thunder,
            hail: sky == .hail,
            glassDrops: drops,
            rimStrength: max(sunVisibility * (0.55 + 0.45 * lowSun), moonVisibility * 0.55),
            textGlow: look.glow * (0.5 + 0.9 * twilight),
            nightness: nightness)
    }

    /// 天气渲染关掉时天空按这个天气画：一片按太阳高度角连续插值的晴空。
    ///
    /// 不是把整片天抹平——时段的调色、日月、星与云量都还在，所以卡片仍随一天
    /// 呼吸，只是不再有雨雪、雾、闪电和玻璃上那层水。这就是设置里「天气渲染」
    /// 关掉后的天空：一张贴图，不是一段天气。
    static var pinned: SkyScene {
        var scene = make(sky: .clear, rainChance: 0, windKph: 6, windDirection: "",
                         astronomy: placeholderAstronomy)
        // 星点是从真实坐标与星历投影出来的；关掉天气之后那串坐标既不是所在也
        // 不是此刻，就不该再指，所以贴图版把这一层收掉（日月仍在，它们只跟
        // 太阳高度角走）。
        scene.stars = []
        scene.starVisibility = 0
        return scene
    }

    private static var placeholderAstronomy: SkyAstronomy.Snapshot {
        SkyAstronomy.snapshot(date: Date(timeIntervalSinceReferenceDate: 0), latitude: 30, longitude: 0)
    }

    /// Without coordinates the sky is still drawn: longitude from the time
    /// zone's offset, a mid latitude, and the same ephemeris. It is an
    /// illustration of *about now*, which beats a grey card.
    static func estimatedAstronomy(date: Date, timezone: TimeZone) -> SkyAstronomy.Snapshot {
        let longitude = Double(timezone.secondsFromGMT(for: date)) / 3600 * 15
        return SkyAstronomy.snapshot(date: date, latitude: 30, longitude: longitude)
    }

    static func weather(for sky: WeatherReading.Sky?, rainChance: Int) -> Weather {
        switch sky {
        case .none, .clear: return .clear
        case .partly: return .cloudy
        case .cloudy: return .overcast
        case .fog: return .fog
        case .drizzle, .sleet: return .lightRain
        case .rain: return rainChance >= 60 ? .heavyRain : .lightRain
        case .snow: return .snow
        case .thunder, .hail: return .thunder
        }
    }

    // MARK: - Projection

    /// A 220° window centred on the equator-facing horizon. East is on the left
    /// in the north, on the right in the south, as it is to someone looking up.
    static func project(_ position: SkyAstronomy.Position, center: Double) -> SIMD2<Float> {
        var diff = (position.azimuth - center).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        let x = 0.5 + diff / fieldOfView
        let y = Double(horizonLine) - position.altitude / 90 * altitudeSpan
        return SIMD2(Float(x), Float(y))
    }

    /// Before local solar noon the sun is in the eastern half of the sky in
    /// both hemispheres (azimuth 0°–180°, measured from north through east).
    static func isRising(azimuth: Double) -> Bool {
        azimuth > 0 && azimuth < 180
    }

    static func band(altitude: Double, rising: Bool) -> Band {
        switch altitude {
        case ..<(-18): return .night
        case ..<(-4): return rising ? .dawn : .dusk
        case ..<8: return rising ? .sunrise : .sunset
        case ..<35: return rising ? .morning : .afternoon
        default: return .noon
        }
    }

    // MARK: - Tables

    struct Look {
        var dayTint: SIMD3<Float>?
        var nightTint: SIMD3<Float>?
        var amount: [Float]
        var exposure: Float
        var cover: Float
        var darkness: Float
        var clarity: Float
        var starClarity: Float
        var glow: Float
    }

    static let looks: [Weather: Look] = [
        .clear: Look(dayTint: nil, nightTint: nil, amount: [0, 0, 0], exposure: 1.00,
                     cover: 0.10, darkness: 0.08, clarity: 1, starClarity: 1, glow: 0.35),
        .cloudy: Look(dayTint: rgb(0xA9B9CC), nightTint: rgb(0x1E2738), amount: [0.22, 0.26, 0.18], exposure: 0.98,
                      cover: 0.46, darkness: 0.22, clarity: 1, starClarity: 0.65, glow: 0.24),
        .overcast: Look(dayTint: rgb(0x8C99A8), nightTint: rgb(0x1A2029), amount: [0.66, 0.70, 0.58], exposure: 0.92,
                        cover: 0.88, darkness: 0.42, clarity: 0.28, starClarity: 0.05, glow: 0.10),
        .lightRain: Look(dayTint: rgb(0x61758A), nightTint: rgb(0x131B26), amount: [0.66, 0.72, 0.62], exposure: 0.86,
                         cover: 0.92, darkness: 0.55, clarity: 0.12, starClarity: 0, glow: 0.08),
        .heavyRain: Look(dayTint: rgb(0x415166), nightTint: rgb(0x0C121A), amount: [0.78, 0.82, 0.74], exposure: 0.74,
                         cover: 0.97, darkness: 0.70, clarity: 0.05, starClarity: 0, glow: 0.06),
        .thunder: Look(dayTint: rgb(0x2E3350), nightTint: rgb(0x0A0C18), amount: [0.84, 0.84, 0.72], exposure: 0.66,
                       cover: 1.0, darkness: 0.82, clarity: 0.03, starClarity: 0, glow: 0.06),
        .snow: Look(dayTint: rgb(0xC7D2E0), nightTint: rgb(0x26303F), amount: [0.62, 0.66, 0.60], exposure: 1.04,
                    cover: 0.86, darkness: 0.26, clarity: 0.22, starClarity: 0, glow: 0.12),
        .fog: Look(dayTint: rgb(0xC3C9D0), nightTint: rgb(0x2E343C), amount: [0.76, 0.84, 0.88], exposure: 1.00,
                   cover: 0.40, darkness: 0.15, clarity: 0.40, starClarity: 0.1, glow: 0.10),
    ]

    typealias Key = (altitude: Double, stops: [SIMD3<Float>], dayness: Float)

    static let clearBands: [Band: [SIMD3<Float>]] = [
        .night: [rgb(0x050A1C), rgb(0x0B1634), rgb(0x17264C)],
        .dawn: [rgb(0x0E1C4A), rgb(0x34427F), rgb(0x8A77A8)],
        .sunrise: [rgb(0x27427F), rgb(0x9A86B4), rgb(0xFFB48A)],
        .morning: [rgb(0x2A6FD1), rgb(0x63A5EA), rgb(0xC4E3FA)],
        .noon: [rgb(0x1D62D8), rgb(0x4E9CF2), rgb(0xAAD8FF)],
        .afternoon: [rgb(0x2C66C2), rgb(0x72A8DE), rgb(0xEFDFC4)],
        .sunset: [rgb(0x2B3A7A), rgb(0xC4668A), rgb(0xFF9656)],
        .dusk: [rgb(0x141A46), rgb(0x3E3070), rgb(0xA6566E)],
    ]

    static let risingKeys: [Key] = [
        (-18, clearBands[.night]!, 0), (-11, clearBands[.dawn]!, 0.2), (2, clearBands[.sunrise]!, 0.55),
        (20, clearBands[.morning]!, 1), (42, clearBands[.noon]!, 1),
    ]
    static let settingKeys: [Key] = [
        (-18, clearBands[.night]!, 0), (-11, clearBands[.dusk]!, 0.2), (2, clearBands[.sunset]!, 0.55),
        (20, clearBands[.afternoon]!, 1), (42, clearBands[.noon]!, 1),
    ]

    static func interpolate(_ keys: [Key], altitude: Double) -> ([SIMD3<Float>], Float) {
        guard altitude > keys[0].altitude else { return (keys[0].stops, keys[0].dayness) }
        for (a, b) in zip(keys, keys.dropFirst()) where altitude <= b.altitude {
            let t = Float((altitude - a.altitude) / (b.altitude - a.altitude))
            let e = t * t * (3 - 2 * t)
            let stops = (0..<3).map { simd_mix(a.stops[$0], b.stops[$0], SIMD3(repeating: e)) }
            return (stops, a.dayness + (b.dayness - a.dayness) * e)
        }
        return (keys.last!.stops, keys.last!.dayness)
    }

    static func sunColor(altitude: Float) -> SIMD3<Float> {
        let keys: [(Float, SIMD3<Float>)] = [(-2, rgb(0xF37A5C)), (0, rgb(0xFF8A4C)), (5, rgb(0xFFB86B)),
                                             (15, rgb(0xFFE3A8)), (40, rgb(0xFFF6E0))]
        guard altitude > keys[0].0 else { return keys[0].1 }
        for (a, b) in zip(keys, keys.dropFirst()) where altitude <= b.0 {
            return simd_mix(a.1, b.1, SIMD3(repeating: (altitude - a.0) / (b.0 - a.0)))
        }
        return keys.last!.1
    }

    static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255)
    }

    static func smooth(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

extension SkyScene {
    /// `a` → `b` at `t` (0…1), for the renderer's weather cross-fade. Every
    /// continuous field is interpolated; the discrete ones (weather, band,
    /// hail, the star catalogue) are `b`'s, since their visible effect is
    /// already carried by an interpolated amount (`starVisibility`, `rain`…).
    static func mix(_ a: SkyScene, _ b: SkyScene, _ t: Float) -> SkyScene {
        func m(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        func m(_ x: SIMD2<Float>, _ y: SIMD2<Float>) -> SIMD2<Float> { x + (y - x) * t }
        func m(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> { x + (y - x) * t }
        var s = b
        s.zenith = m(a.zenith, b.zenith)
        s.mid = m(a.mid, b.mid)
        s.horizon = m(a.horizon, b.horizon)
        s.glow = m(a.glow, b.glow)
        s.glowStrength = m(a.glowStrength, b.glowStrength)
        s.sunUV = m(a.sunUV, b.sunUV)
        s.sunRadius = m(a.sunRadius, b.sunRadius)
        s.sunVisibility = m(a.sunVisibility, b.sunVisibility)
        s.sunColor = m(a.sunColor, b.sunColor)
        s.sunAltitude = m(a.sunAltitude, b.sunAltitude)
        s.moonUV = m(a.moonUV, b.moonUV)
        s.moonRadius = m(a.moonRadius, b.moonRadius)
        s.moonVisibility = m(a.moonVisibility, b.moonVisibility)
        s.starVisibility = m(a.starVisibility, b.starVisibility)
        s.cloudCover = m(a.cloudCover, b.cloudCover)
        s.cloudDarkness = m(a.cloudDarkness, b.cloudDarkness)
        s.windSpeed = m(a.windSpeed, b.windSpeed)
        // The short way round, so a north wind turning north-west does not
        // sweep the clouds through south.
        var turn = b.windAngle - a.windAngle
        turn = atan2(sin(turn), cos(turn))
        s.windAngle = a.windAngle + turn * t
        s.rain = m(a.rain, b.rain)
        s.snow = m(a.snow, b.snow)
        s.fog = m(a.fog, b.fog)
        s.thunder = m(a.thunder, b.thunder)
        s.glassDrops = m(a.glassDrops, b.glassDrops)
        s.rimStrength = m(a.rimStrength, b.rimStrength)
        s.textGlow = m(a.textGlow, b.textGlow)
        s.nightness = m(a.nightness, b.nightness)
        return s
    }
}
