#!/usr/bin/env python3
"""Production greeting geometry and ink selection. No app, preferences or GPU."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

def declaration(path, anchor):
    raw = (root / path).read_text()
    start = raw.index(anchor)
    index = raw.index('{', start) + 1
    depth = 1
    while depth:
        depth += (raw[index] == '{') - (raw[index] == '}')
        index += 1
    return raw[start:index] + '\n'

source = 'import AppKit\nimport SwiftUI\n'
source += declaration('Sources/ClaudeBar/Utils/WeatherFetcher.swift', 'struct WeatherReading: Equatable {')
source += declaration('Sources/ClaudeBar/Utils/WeatherForecastFetcher.swift', 'struct WeatherDay: Equatable, Identifiable {')
source += (root / 'Sources/ClaudeBar/Utils/SkyAstronomy.swift').read_text()
for name in ['SkyScene', 'GreetingScript', 'AtmosphereShader', 'AtmosphereRenderer']:
    source += '\n' + (root / f'Sources/ClaudeBar/Views/Shared/Atmosphere/{name}.swift').read_text()
source += '\nenum SolarTimesFixture {\n' + declaration('Sources/ClaudeBar/Views/Shared/GreetingInstruments.swift', '    static func times(on date: Date,') + '}\n'
source += r'''
@main struct Regression {
    @MainActor static func main() {
        GreetingScript.resourceRoot = URL(fileURLWithPath: CommandLine.arguments[1])
        func require(_ condition: Bool, _ message: String = "Regression failed") {
            guard condition else { print("FAIL: " + message); exit(1) }
        }
        let solarISO = ISO8601DateFormatter()
        func date(_ value: String) -> Date { solarISO.date(from: value)! }
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let today = date("2026-09-30T04:00:00Z")
        let events = SkyAstronomy.solarEvents(on: today, latitude: 23.13, longitude: 113.26, zone: zone)
        require(events.sunrise != nil && events.sunset != nil, "Guangzhou crossings missing")
        for crossing in [events.sunrise!, events.sunset!] {
            let height = SkyAstronomy.snapshot(date: crossing, latitude: 23.13, longitude: 113.26).sun.altitude
            require(abs(height + 0.833) < 0.005, "Solar horizon crossing")
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let riseHour = cal.component(.hour, from: events.sunrise!)
        let setHour = cal.component(.hour, from: events.sunset!)
        require(riseHour == 6 && setHour == 18, "Guangzhou local-time plausibility")
        let summer = SkyAstronomy.solarEvents(on: date("2026-06-21T04:00:00Z"), latitude: 23.13, longitude: 113.26, zone: zone)
        let winter = SkyAstronomy.solarEvents(on: date("2026-12-21T04:00:00Z"), latitude: 23.13, longitude: 113.26, zone: zone)
        require(summer.sunset!.timeIntervalSince(summer.sunrise!) > winter.sunset!.timeIntervalSince(winter.sunrise!) + 7200,
                "Solar events must vary by season")
        let western = SkyAstronomy.solarEvents(on: today, latitude: 23.13, longitude: 103.26, zone: zone)
        require(western.sunrise!.timeIntervalSince(events.sunrise!) > 2300, "Longitude must affect clocks")
        let oslo = TimeZone(identifier: "Europe/Oslo")!
        for day in ["2026-06-21T12:00:00Z", "2026-12-21T12:00:00Z"] {
            let polar = SkyAstronomy.solarEvents(on: date(day), latitude: 69.65, longitude: 18.96, zone: oslo)
            require(polar.sunrise == nil && polar.sunset == nil, "Polar day/night must not invent events")
        }
        let invalid = SkyAstronomy.solarEvents(on: today, latitude: .nan, longitude: 113, zone: zone)
        require(invalid.sunrise == nil && invalid.sunset == nil, "Invalid coordinates")
        let ny = TimeZone(identifier: "America/New_York")!
        cal.timeZone = ny
        for (value, duration) in [("2026-03-08T12:00:00Z", 23.0), ("2026-11-01T12:00:00Z", 25.0)] {
            let instant = date(value)
            let bounds = cal.dateInterval(of: .day, for: instant)!
            require(bounds.duration == duration * 3600, "DST fixture")
            let result = SkyAstronomy.solarEvents(on: instant, latitude: 40.71, longitude: -74.01, zone: ny)
            require(bounds.contains(result.sunrise!) && bounds.contains(result.sunset!), "DST local civil day")
        }
        var reading = WeatherReading(place: "广州", temperatureC: 30, feelsLikeC: 31, conditionCode: 113,
            conditionText: "晴", highC: 32, lowC: 25, humidity: 60, windKph: 10, windDirection: "东",
            sunrise: "06:18 AM", sunset: "06:17 PM", rainChance: 0, observedAt: today)
        let missing = SolarTimesFixture.times(on: today, reading: nil, zone: zone)
        require(missing.rise == nil && missing.set == nil, "Missing reading must not become 06–18")
        let parsed = SolarTimesFixture.times(on: today, reading: reading, zone: zone)
        cal.timeZone = zone
        require(cal.component(.minute, from: parsed.rise!) == 18 && cal.component(.hour, from: parsed.set!) == 18,
                "12-hour source parsing")
        let tomorrow = today.addingTimeInterval(86400)
        let stale = SolarTimesFixture.times(on: tomorrow, reading: reading, zone: zone)
        require(stale.rise == nil && stale.set == nil, "Current clocks must not be reused tomorrow")
        reading.sunrise = "99:70"; reading.sunset = "garbage 18:00"
        let malformed = SolarTimesFixture.times(on: today, reading: reading, zone: zone)
        require(malformed.rise == nil && malformed.set == nil, "Malformed clocks must not be clamped")
        reading.latitude = 23.13; reading.longitude = 113.26
        let computed = SolarTimesFixture.times(on: today, reading: reading, zone: zone)
        require(computed.rise == events.sunrise && computed.set == events.sunset, "Coordinate fallback/cache")
        let computedTomorrow = SolarTimesFixture.times(on: tomorrow, reading: reading, zone: zone)
        require(computedTomorrow.rise != nil && cal.isDate(computedTomorrow.rise!, inSameDayAs: tomorrow), "Selected date fallback")
        let forecastRise = date("2026-09-29T22:19:00Z"), forecastSet = date("2026-09-30T10:16:00Z")
        reading.forecast = [WeatherDay(date: today, code: 113, high: 32, low: 25, rainChance: 0, wind: 10,
                                      sunrise: forecastRise, sunset: forecastSet)]
        let authoritative = SolarTimesFixture.times(on: today, reading: reading, zone: zone)
        require(authoritative.rise == forecastRise && authoritative.set == forecastSet, "Forecast precedence")
        var count = 0
        for width: CGFloat in [620, 900, 1100, 1400] {
            let sky = min(430, max(330, width * 0.38)).rounded()
            let margin: CGFloat = width >= 900 ? 32 : 24
            let top = margin - 8 + 88 + 6, bottom = sky - 100
            for face in GreetingTypeface.allCases {
                for phrase in ["good morning,", "good afternoon,", "good evening,", "happy new year,"] {
                    for name in ["wangxiajun", "Xiajun Wang", "王夏军", "Alexandra Montgomery-Williams", ""] {
                        let layout = GreetingTypesetter.layout(phrase, name: name, typeface: face,
                            cardWidth: width, skyHeight: sky, margin: margin, topClear: top, bottomClear: bottom)
                        let label = "\(width) \(face) \(phrase) \(name)"
                        require(layout.name == name, "Authored name case: \(label)")
                        require(layout.nameSize >= 18, "Name size: \(label)")
                        require(layout.phraseFrame.minX >= margin - 2 && layout.phraseFrame.maxX <= width - margin + 2,
                                     "Phrase horizontal bounds: \(label) \(layout)")
                        require(layout.phraseFrame.minY >= top - 2 && layout.phraseFrame.maxY <= bottom + 2,
                                     "Phrase instrument overlap: \(label) \(layout)")
                        if !name.isEmpty {
                            require(layout.nameFrame.minX >= margin - 2 && layout.nameFrame.maxX <= width - margin + 2,
                                         "Name horizontal bounds: \(label) \(layout)")
                            require(layout.nameFrame.minY >= top - 2 && layout.nameFrame.maxY <= bottom + 2,
                                         "Name instrument overlap: \(label) \(layout)")
                            if !layout.nameInline {
                                require(layout.nameFrame.minY > layout.phraseFrame.maxY,
                                             "Name/greeting overlap: \(label)")
                            }
                        }
                        require(layout == GreetingTypesetter.layout(phrase, name: name, typeface: face,
                            cardWidth: width, skyHeight: sky, margin: margin, topClear: top, bottomClear: bottom), "Cache mismatch")
                        count += 1
                    }
                }
            }
        }
        let iso = ISO8601DateFormatter()
        for sky: WeatherReading.Sky in [.clear, .partly, .cloudy, .rain, .drizzle, .thunder, .snow, .fog] {
            let day = SkyScene.make(sky: sky, rainChance: 90, windKph: 12, windDirection: "东南",
                astronomy: SkyAstronomy.snapshot(date: iso.date(from: "2026-09-28T04:30:00Z")!, latitude: 23.13, longitude: 113.26))
            let night = SkyScene.make(sky: sky, rainChance: 90, windKph: 12, windDirection: "东南",
                astronomy: SkyAstronomy.snapshot(date: iso.date(from: "2026-09-27T16:30:00Z")!, latitude: 23.13, longitude: 113.26))
            require(!night.prefersDarkInk, "Night needs light ink: \(sky)")
            if [.clear, .partly, .snow, .fog].contains(sky) { require(day.prefersDarkInk, "Pale day needs dark ink: \(sky)") }
        }
        var localSky = SkyScene.make(sky: .clear, rainChance: 0, windKph: 0, windDirection: "",
            astronomy: SkyAstronomy.snapshot(date: today, latitude: 23.13, longitude: 113.26))
        localSky.glowStrength = 0; localSky.fog = 0
        let positions: [SIMD2<Float>] = [SIMD2(0.12, 0.12), SIMD2(0.85, 0.16), SIMD2(0.18, 0.90), SIMD2(0.85, 0.86)]
        for value: Float in [0.02, 0.95] {
            localSky.zenith = SIMD3(repeating: value)
            localSky.mid = SIMD3(repeating: value)
            localSky.horizon = SIMD3(repeating: value)
            for position in positions {
                require(localSky.prefersDarkInk(at: position, aspect: 2.6) == (value > 0.5),
                        "Every instrument must adapt to its background")
            }
        }
        localSky.zenith = SIMD3(repeating: 0.02)
        localSky.mid = SIMD3(repeating: 0.1)
        require(!localSky.prefersDarkInk(at: positions[0], aspect: 2.6), "Dark zenith needs white clock")
        require(localSky.prefersDarkInk(at: positions[3], aspect: 2.6), "Pale horizon needs navy forecast independently")
        for value: Float in stride(from: 0, through: 1, by: 0.05) {
            localSky.zenith = SIMD3(repeating: value)
            localSky.mid = localSky.zenith; localSky.horizon = localSky.zenith
            let dark = localSky.prefersDarkInk(at: positions[0], aspect: 2.6)
            func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let background = linear(value)
            let navy = 0.2126 * linear(20 / 255) + 0.7152 * linear(30 / 255) + 0.0722 * linear(51 / 255)
            let ratio = dark ? (background + 0.05) / (navy + 0.05) : 1.05 / (background + 0.05)
            let alternative = dark ? 1.05 / (background + 0.05) : (background + 0.05) / (navy + 0.05)
            require(ratio >= alternative, "Instrument must select the ink with higher contrast")
        }
        let layout = GreetingTypesetter.layout("good morning,", name: "wangxiajun", cardWidth: 1100, skyHeight: 418, margin: 32)
        let texture = GreetingTypesetter.rasterize(layout, scale: 2)!
        require(texture.texels.count == texture.width * texture.height * 2)
        require(texture.texels.enumerated().contains { $0.offset % 2 == 0 && $0.element > 0 })
        print("PASS: \(count) greeting/name layouts, original casing, readable name size, instrument clearance, cache and texture; day/night ink; dated solar events, source precedence, polar/DST and missing data")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-greeting-layout-') as tmp:
    path = Path(tmp) / 'Regression.swift'
    path.write_text(source)
    binary = Path(tmp) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(root / 'Sources/Fonts')], check=True)
