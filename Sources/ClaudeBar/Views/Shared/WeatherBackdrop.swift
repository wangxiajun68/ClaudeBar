import SwiftUI

/// The sky behind the greeting band.
///
/// Apple Weather's scene, scaled to one short card and one draw call:
///
/// 1. A vertical sky (the palette), lighter at the top.
/// 2. A slow pool of light, so a clear sky is not a frozen poster.
/// 3. Clouds as volume — a body and a lit crown, never a stroked blob.
/// 4. Precipitation in **depth layers**. Far streaks are thin, cool, and slow;
///    near ones are short, bright, and fast. Each layer is one `Path` stroked
///    once. The previous curtain filled two rounded rects per drop (up to ~150
///    drops), which is a hatch pattern and a lot of draw calls. A layer is one
///    stroke. Splashes are a handful of ellipses where a near streak meets the
///    bottom edge.
///
/// The timeline is absolute time since the band appeared, so a frame is a
/// function of the clock. It pauses for Reduce Motion and when the surface is
/// off-screen. Still skies tick slower than rain: a drifting cloud does not
/// need 30 Hz, a shower does.
struct WeatherBackdrop: View {
    let sky: WeatherReading.Sky
    let isDay: Bool?
    /// 0…100. Widens a shower so drizzle and a downpour are different pictures.
    var intensity: Int = 40
    var astronomy: SkyAstronomy.Snapshot? = nil
    var windKph: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceIsVisible) private var surfaceVisible

    /// Seconds since the band appeared. An absolute clock jumps when the
    /// timeline resumes; this one stays continuous with the moment the card
    /// was shown.
    @State private var start = Date()
    @State private var onScreen = true

    private var night: Bool { isDay == false }

    /// Rain and thunder need a smooth curtain. Everything else is cloud drift,
    /// a breathing sun, or fog, and 12–16 Hz is enough to read as motion.
    private var frameInterval: Double {
        switch sky {
        case .drizzle, .rain, .sleet, .snow, .hail, .thunder: return 1.0 / 30
        case .fog, .partly, .cloudy: return 1.0 / 16
        case .clear: return 1.0 / 12
        }
    }

    var body: some View {
        let palette = SkyPalette(sky: sky, night: night)
        return TimelineView(.animation(minimumInterval: ProcessInfo.processInfo.isLowPowerModeEnabled ? max(frameInterval, 1.0 / 15) : frameInterval,
                                       paused: reduceMotion || !surfaceVisible || !onScreen)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSince(start)
                var c = ctx
                Self.draw(sky: sky, night: night, palette: palette,
                          intensity: intensity, astronomy: astronomy, windKph: windKph, t: reduceMotion ? 3 : t, size: size, ctx: &c)
            }
        }
        .onAppear { start = Date() }
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private static func draw(sky: WeatherReading.Sky, night: Bool, palette: SkyPalette,
                             intensity: Int, astronomy: SkyAstronomy.Snapshot?, windKph: Double, t: TimeInterval, size: CGSize,
                             ctx: inout GraphicsContext) {
        drawWind(speed: windKph, t: t, size: size, ctx: &ctx)
        drawLight(palette: palette, t: t, size: size, ctx: &ctx)
        if let astronomy { drawCelestial(astronomy, sky: sky, size: size, t: t, ctx: &ctx) }
        switch sky {
        case .clear: if astronomy == nil { drawClear(night: night, size: size, t: t, ctx: &ctx) }
        case .partly: drawPartly(night: night, celestial: astronomy == nil, size: size, t: t, ctx: &ctx)
        case .cloudy: drawCloudy(night: night, size: size, t: t, ctx: &ctx)
        case .fog: drawFog(size: size, t: t, ctx: &ctx)
        case .rain: drawRain(night: night, size: size, intensity: intensity, t: t, ctx: &ctx)
        case .snow: drawSnow(night: night, size: size, t: t, ctx: &ctx)
        case .thunder: drawThunder(size: size, intensity: intensity, t: t, ctx: &ctx)
        case .drizzle:
            drawFog(size: size, t: t, ctx: &ctx)
            stroke(streaks(count: 46, speed: 0.24, length: 0.026, angle: 0.16, seed: 224737, t: t, size: size), width: 0.6, color: .white.opacity(0.35), ctx: &ctx)
        case .sleet:
            drawRain(night: night, size: size, intensity: 20, t: t, ctx: &ctx)
            drawSnow(night: night, size: size, t: t * 1.5, ctx: &ctx)
        case .hail:
            drawThunder(size: size, intensity: intensity, t: t, ctx: &ctx)
            var pellets = Path()
            for i in 0..<36 {
                let phase = (t * 0.7 + Double(i) * 0.137).truncatingRemainder(dividingBy: 1)
                let x = Double((i * 137) % 991) / 991 * size.width
                let y = phase * size.height
                pellets.addEllipse(in: CGRect(x: x, y: y, width: 2.5, height: 3.5))
            }
            ctx.fill(pellets, with: .color(.white.opacity(0.7)))
        }
    }

    private static func drawWind(speed: Double, t: Double, size: CGSize, ctx: inout GraphicsContext) {
        guard speed > 18 else { return }
        var paths = Path()
        for i in 0..<5 {
            let phase = (t / max(3, 18 - speed * 0.2) + Double(i) * 0.23).truncatingRemainder(dividingBy: 1)
            let x = phase * (size.width + 240) - 120
            let y = size.height * (0.15 + Double(i) * 0.16)
            paths.move(to: CGPoint(x: x, y: y))
            paths.addQuadCurve(to: CGPoint(x: x + 100, y: y - 8), control: CGPoint(x: x + 50, y: y - 18))
        }
        ctx.stroke(paths, with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
    }

    /// Panorama projection: east → south → west, wrapped through north.
    /// Height is the actual horizon altitude; objects below it are hidden.
    private static func point(_ position: SkyAstronomy.Position, size: CGSize) -> CGPoint {
        CGPoint(x: (position.azimuth / 360) * size.width,
                y: size.height * (0.78 - position.altitude / 90 * 0.69))
    }

    private static func drawCelestial(_ astro: SkyAstronomy.Snapshot, sky: WeatherReading.Sky,
                                      size: CGSize, t: Double, ctx: inout GraphicsContext) {
        let clarity: Double = sky == .clear ? 1 : sky == .partly ? 0.8 : sky == .cloudy ? 0.12 : 0
        let darkness = min(1, max(0, (-astro.sun.altitude - 3) / 12))
        var stars = ctx
        stars.opacity = darkness * clarity
        for (index, star) in SkyAstronomy.stars.enumerated() {
            let position = SkyAstronomy.star(raHours: star.0, declination: star.1, in: astro)
            guard position.altitude > 0 else { continue }
            let p = point(position, size: size)
            let r = star.2
            let alpha = 0.65 + 0.35 * sin(t * 0.5 + Double(index))
            stars.fill(Path(ellipseIn: CGRect(x: p.x-r, y: p.y-r, width: r*2, height: r*2)),
                       with: .color(.white.opacity(alpha)))
            if r > 1.4 {
                var cross = Path()
                cross.move(to: CGPoint(x: p.x-4, y: p.y)); cross.addLine(to: CGPoint(x: p.x+4, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y-4)); cross.addLine(to: CGPoint(x: p.x, y: p.y+4))
                stars.stroke(cross, with: .color(.white.opacity(alpha * 0.3)), lineWidth: 0.5)
            }
        }
        // A sunset is light scattered along the horizon, not an orange sun at noon.
        if astro.twilight > 0 {
            let p = point(astro.sun, size: size)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [Color(hex: 0xF5A56B).opacity(astro.twilight * 0.42), .clear]),
                center: p, startRadius: 0, endRadius: size.width * 0.65))
        }
        var celestial = ctx
        celestial.opacity = clarity
        if astro.sun.altitude > -1 {
            drawSun(at: point(astro.sun, size: size), size: size, t: t, ctx: &celestial)
        }
        if astro.moon.altitude > 0 {
            let p = point(astro.moon, size: size), r = min(22.0, size.height * 0.065)
            celestial.opacity *= max(0.25, darkness)
            celestial.fill(Path(ellipseIn: CGRect(x: p.x-r*3, y: p.y-r*3, width: r*6, height: r*6)),
                           with: .radialGradient(Gradient(colors: [.white.opacity(0.16), .clear]), center: p, startRadius: 0, endRadius: r*3))
            // Sample the illuminated hemisphere into a single path, including waxing/waning orientation.
            var phase = Path()
            let k = cos(astro.moonPhase * 2 * .pi)
            let side = astro.moonPhase < 0.5 ? 1.0 : -1.0
            for i in 0...40 {
                let y = -r + 2*r*Double(i)/40
                let x = sqrt(max(0, r*r-y*y)) * side
                let p = CGPoint(x: p.x+x, y: p.y+y)
                if i == 0 { phase.move(to: p) } else { phase.addLine(to: p) }
            }
            for i in stride(from: 40, through: 0, by: -1) {
                let y = -r + 2*r*Double(i)/40
                let x = sqrt(max(0, r*r-y*y)) * side * k
                phase.addLine(to: CGPoint(x: p.x+x, y: p.y+y))
            }
            phase.closeSubpath()
            celestial.fill(phase, with: .color(SkyPalette.moon))
        }
    }

    /// One soft pool of the palette's highlight, travelling the width of the
    /// band. Replaces a blurred `Canvas` (a per-frame offscreen pass) with a
    /// single radial fill.
    private static func drawLight(palette: SkyPalette, t: TimeInterval, size: CGSize,
                                  ctx: inout GraphicsContext) {
        let phase = 0.5 + 0.35 * sin(t / 28)
        let center = CGPoint(x: CGFloat(phase) * size.width, y: size.height * 0.28)
        let radius = max(size.width, size.height) * 0.55
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .radialGradient(
                    Gradient(colors: [palette.highlight.opacity(0.20), palette.highlight.opacity(0)]),
                    center: center, startRadius: 0, endRadius: radius))
    }

    /// A bank of radial puffs, not a filled silhouette.
    ///
    /// A union of ellipses with a hard edge is a sticker. Real cloud in a
    /// weather scene (Apple Weather, and every serious 2D sky) is density:
    /// each lobe is a radial falloff to nothing, so the bank has no outline
    /// to catch the eye. A dark under-shape — the obvious first cut — is what
    /// made the early banks read as black potatoes on the rain sky, so the
    /// lobes carry no fill of their own and there is nothing to shadow.
    private static func cloud(_ ctx: inout GraphicsContext, at x: CGFloat, y: CGFloat,
                              scale: CGFloat, size: CGSize,
                              lit: Color) {
        let width = scale * min(size.height, 440) * 2.3
        let height = width * 0.43
        var layer = ctx
        layer.addFilter(.colorMultiply(lit))
        layer.draw(Image(decorative: SkyCloudTexture.image, scale: 1),
                   in: CGRect(x: x * size.width - width / 2, y: y * size.height - height / 2,
                              width: width, height: height))
    }

    // MARK: Clear

    private static func drawClear(night: Bool, size: CGSize, t: TimeInterval,
                                  ctx: inout GraphicsContext) {
        if night {
            for i in 0..<28 {
                let x = starX(i) * size.width
                let y = starY(i) * size.height
                let twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * (0.6 + Double(i % 5) * 0.25) + Double(i)))
                let r = 0.65 + Double((i * 37) % 5) * 0.28
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(SkyPalette.moon.opacity((0.35 + Double(i % 3) * 0.2) * twinkle)))
            }
            let c = CGPoint(x: size.width * 0.76, y: min(size.height * 0.15, 76))
            let r = min(size.height * 0.14, 56)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 2.2, y: c.y - r * 2.2,
                                            width: r * 4.4, height: r * 4.4)),
                     with: .radialGradient(Gradient(colors: [SkyPalette.moon.opacity(0.28),
                                                             SkyPalette.moon.opacity(0)]),
                                           center: c, startRadius: r * 0.2, endRadius: r * 2.2))
            ctx.drawLayer { layer in
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.55, y: c.y - r * 0.55,
                                                  width: r * 1.1, height: r * 1.1)),
                           with: .color(SkyPalette.moon))
                layer.blendMode = .destinationOut
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.55 + r * 0.34,
                                                  y: c.y - r * 0.55 - r * 0.12,
                                                  width: r * 1.05, height: r * 1.05)),
                           with: .color(.black))
            }
        } else {
            drawSun(at: CGPoint(x: size.width * 0.78, y: min(size.height * 0.13, 65)),
                    size: size, t: t, ctx: &ctx)
        }
    }

    /// A breathing disc and corona, and three diffuse light pools drifting
    /// across the card. The drift is the clear sky's motion; the breathing
    /// alone is too small to notice.
    private static func drawSun(at c: CGPoint, size: CGSize, t: TimeInterval,
                                ctx: inout GraphicsContext) {
        ctx.blendMode = .plusLighter
        // Diffuse light drifts across the card. No hard triangular rays.
        for i in 0..<3 {
            let x = c.x + CGFloat(sin(t * 0.08 + Double(i) * 2.1)) * size.width * 0.12
            let center = CGPoint(x: x, y: c.y + CGFloat(i) * 22)
            let radius = max(size.width * 0.34, size.height * 0.7)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [SkyPalette.sunCore.opacity(0.10), SkyPalette.sun.opacity(0.03), .clear]),
                center: center, startRadius: 0, endRadius: radius))
        }
        let pulse = 1 + 0.04 * sin(t / 9 * 2 * .pi)
        let r = min(size.height * 0.05, 24) * pulse
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 3.2, y: c.y - r * 3.2,
                                        width: r * 6.4, height: r * 6.4)),
                 with: .radialGradient(
                    Gradient(colors: [SkyPalette.sun.opacity(0.40),
                                      SkyPalette.sun.opacity(0.10),
                                      SkyPalette.sun.opacity(0)]),
                    center: c, startRadius: r * 0.2, endRadius: r * 3.2))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(colors: [.white, SkyPalette.sunCore]),
                                           center: c, startRadius: 0, endRadius: r))

    }

    // MARK: Partly / cloudy / fog

    private static func drawPartly(night: Bool, celestial: Bool = true, size: CGSize, t: TimeInterval,
                                   ctx: inout GraphicsContext) {
        if celestial { drawClear(night: night, size: size, t: t, ctx: &ctx) }
        let lit = Color.white.opacity(night ? 0.40 : 0.98)
        cloud(&ctx, at: drift(0.02, 0.28, t / 70), y: 0.42, scale: 0.50, size: size,
              lit: lit)
        cloud(&ctx, at: drift(0.40, 0.78, t / 52), y: 0.62, scale: 0.64, size: size,
              lit: lit)
    }

    private static func drawCloudy(night: Bool, size: CGSize, t: TimeInterval,
                                   ctx: inout GraphicsContext) {
        let lit = Color.white.opacity(night ? 0.32 : 0.88)
        cloud(&ctx, at: drift(0.02, 0.30, t / 86), y: 0.30, scale: 0.56, size: size,
              lit: lit)
        cloud(&ctx, at: drift(0.34, 0.70, t / 64), y: 0.48, scale: 0.72, size: size,
              lit: lit)
        cloud(&ctx, at: drift(0.62, 1.02, t / 50), y: 0.66, scale: 0.80, size: size,
              lit: lit)
    }

    private static func drawFog(size: CGSize, t: TimeInterval, ctx: inout GraphicsContext) {
        let band = Color.white
        for i in 0..<5 {
            let y = size.height * (0.16 + Double(i) * 0.17)
            let h = size.height * (0.14 + Double(i % 2) * 0.04)
            let phase = drift(-0.4, 0.9, t / (40 + Double(i) * 14) + Double(i) * 0.21)
            let rect = CGRect(x: phase * size.width - size.width * 0.3, y: y,
                              width: size.width * 1.6, height: h)
            let alpha = 0.10 + Double(i) * 0.035
            ctx.fill(Path(roundedRect: rect, cornerRadius: h / 2),
                     with: .linearGradient(
                        Gradient(stops: [
                            .init(color: band.opacity(0), location: 0),
                            .init(color: band.opacity(alpha), location: 0.5),
                            .init(color: band.opacity(0), location: 1)]),
                        startPoint: CGPoint(x: rect.minX, y: 0),
                        endPoint: CGPoint(x: rect.maxX, y: 0)))
        }
    }

    // MARK: Rain

    private static func drawRain(night: Bool, size: CGSize, intensity: Int,
                                 t: TimeInterval, ctx: inout GraphicsContext) {
        let lit = Color.white.opacity(night ? 0.34 : 0.55)
        cloud(&ctx, at: drift(-0.08, 0.22, t / 70), y: 0.02, scale: 0.70, size: size,
              lit: lit)
        cloud(&ctx, at: drift(0.28, 0.62, t / 54), y: 0.08, scale: 0.86, size: size,
              lit: lit)
        cloud(&ctx, at: drift(0.64, 1.04, t / 46), y: 0.00, scale: 0.64, size: size,
              lit: lit)
        rainStreaks(size: size, intensity: intensity, t: t, ctx: &ctx, splashes: true)
        ctx.fill(Path(CGRect(x: 0, y: size.height * 0.86,
                             width: size.width, height: size.height * 0.14)),
                 with: .linearGradient(
                    Gradient(colors: [Color.white.opacity(0), Color.white.opacity(0.14)]),
                    startPoint: CGPoint(x: 0, y: size.height * 0.86),
                    endPoint: CGPoint(x: 0, y: size.height)))
    }

    /// Three depths, each stroked once. `load` only changes how many streaks
    /// a layer carries, so a 10% chance and a 90% chance are different densities
    /// of the same three speeds.
    private static func rainStreaks(size: CGSize, intensity: Int, t: TimeInterval,
                                    ctx: inout GraphicsContext, splashes: Bool) {
        let load = Double(min(max(intensity, 0), 100)) / 100
        // Far: a mist of hairlines. Mid: the curtain. Near: a few drops with
        // a bright head and a tail that fades — a uniform stroke reads as a
        // pencil line, which is what the last shower looked like.
        let far = streaks(count: 48 + Int(load * 36), speed: 0.38, length: 0.012,
                          angle: 0.025, seed: 104729, t: t, size: size)
        let mid = streaks(count: 22 + Int(load * 16), speed: 0.55, length: 0.022,
                          angle: 0.05, seed: 224737, t: t, size: size)
        let near = streaks(count: 8 + Int(load * 6), speed: 0.78, length: 0.036,
                           angle: 0.075, seed: 479909, t: t, size: size)
        stroke(far, width: 0.6, color: Color(hex: 0xD5E4F5).opacity(0.28), ctx: &ctx)
        stroke(mid, width: 0.9, color: Color.white.opacity(0.42), ctx: &ctx)
        tapered(near, width: 1.15, ctx: &ctx)
        if splashes { drawSplashes(near, size: size, ctx: &ctx) }
    }

    private struct Streak {
        var start: CGPoint
        var end: CGPoint
        var travel: Double
    }

    private static func streaks(count: Int, speed: Double, length: CGFloat, angle: CGFloat,
                                seed: Int, t: TimeInterval, size: CGSize) -> [Streak] {
        var out: [Streak] = []
        out.reserveCapacity(count)
        let shear = CGFloat(sin(Double(angle)))
        let baseLength = length * size.height
        for i in 0..<count {
            let s = Double((i * seed) % 997) / 997
            let len = baseLength * CGFloat(0.65 + 0.7 * s)
            let travel = (t * speed * (0.72 + 0.56 * s) + s).truncatingRemainder(dividingBy: 1)
            let y = -len + CGFloat(travel) * (size.height + len)
            let horizontal = Double((i * 1299709 + seed * 17) % 991) / 991
            let x = CGFloat(horizontal) * size.width + y * shear * 0.40
            out.append(Streak(start: CGPoint(x: x, y: y),
                              end: CGPoint(x: x + len * shear, y: y + len),
                              travel: travel))
        }
        return out
    }

    private static func stroke(_ streaks: [Streak], width: CGFloat, color: Color,
                               ctx: inout GraphicsContext) {
        var path = Path()
        for streak in streaks {
            path.move(to: streak.start)
            path.addLine(to: streak.end)
        }
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// Foreground drops. One gradient each, capped by the caller at a handful,
    /// so the head of the drop is bright and the tail disappears. Batched
    /// strokes cannot do that falloff.
    private static func tapered(_ streaks: [Streak], width: CGFloat, ctx: inout GraphicsContext) {
        for streak in streaks {
            let dx = streak.end.x - streak.start.x
            let dy = streak.end.y - streak.start.y
            let len = hypot(dx, dy)
            guard len > 1 else { continue }
            var layer = ctx
            layer.translateBy(x: streak.start.x, y: streak.start.y)
            layer.rotate(by: .radians(atan2(dy, dx) - .pi / 2))
            let rect = CGRect(x: -width / 2, y: 0, width: width, height: len)
            layer.fill(Path(roundedRect: rect, cornerRadius: width / 2),
                       with: .linearGradient(
                        Gradient(stops: [
                            .init(color: Color.white.opacity(0), location: 0),
                            .init(color: Color.white.opacity(0.20), location: 0.35),
                            .init(color: Color.white.opacity(0.92), location: 0.78),
                            .init(color: Color.white.opacity(0), location: 1),
                        ]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: len)))
        }
    }

    /// A near streak past ~80% of its fall leaves a flat ellipse on the wet
    /// edge, widening as it fades. Same samples as the streak, so the splash
    /// sits where the line ends.
    private static func drawSplashes(_ near: [Streak], size: CGSize, ctx: inout GraphicsContext) {
        for streak in near where streak.travel > 0.78 {
            let k = (streak.travel - 0.78) / 0.22
            let alpha = sin(k * .pi)
            guard alpha > 0.05 else { continue }
            let w = size.height * (0.045 + 0.07 * CGFloat(k))
            let h = w * 0.32
            let y = min(streak.end.y, size.height * 0.94)
            ctx.fill(Path(ellipseIn: CGRect(x: streak.end.x - w / 2, y: y - h / 2,
                                            width: w, height: h)),
                     with: .color(Color.white.opacity(0.40 * alpha)))
        }
    }

    // MARK: Snow

    private static func drawSnow(night: Bool, size: CGSize, t: TimeInterval,
                                 ctx: inout GraphicsContext) {
        let lit = Color.white.opacity(night ? 0.40 : 0.95)
        cloud(&ctx, at: drift(0.04, 0.36, t / 74), y: 0.24, scale: 0.58, size: size,
              lit: lit)
        cloud(&ctx, at: drift(0.50, 0.92, t / 58), y: 0.34, scale: 0.68, size: size,
              lit: lit)
        // Three depths. Near flakes are larger and slower to sway, which reads
        // as depth of field without a blur pass.
        let depths: [(fall: Double, radius: CGFloat, alpha: Double, sway: Double)] = [
            (0.05, 0.0025, 0.45, 0.008),
            (0.09, 0.004, 0.78, 0.014),
            (0.14, 0.006, 0.95, 0.020),
        ]
        for i in 0..<36 {
            let seed = Double((i * 524287) % 1000) / 1000
            let depth = depths[i % 3]
            let x = (Double(i) + 0.37) / 36
            let y = (t * depth.fall + seed * 3.1).truncatingRemainder(dividingBy: 1)
            let sway = sin((t * 0.6 + seed * 6.2) * .pi) * depth.sway
            let r = size.height * depth.radius * (0.85 + seed * 0.3)
            let cx = CGFloat(x + sway) * size.width
            let cy = CGFloat(y) * size.height
            ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                     with: .color(Color.white.opacity(depth.alpha)))
        }
    }

    // MARK: Thunder

    private static func drawThunder(size: CGSize, intensity: Int, t: TimeInterval,
                                    ctx: inout GraphicsContext) {
        let lit = Color.white.opacity(0.16)
        cloud(&ctx, at: drift(0.00, 0.32, t / 60), y: 0.18, scale: 0.68, size: size,
              lit: lit)
        cloud(&ctx, at: drift(0.40, 0.82, t / 48), y: 0.28, scale: 0.80, size: size,
              lit: lit)
        cloud(&ctx, at: drift(0.74, 1.14, t / 42), y: 0.14, scale: 0.56, size: size,
              lit: lit)
        rainStreaks(size: size, intensity: max(intensity, 50), t: t, ctx: &ctx, splashes: true)

        // One strike per ~12 s. The flash is the first 8% of the cycle;
        // the rest is dark, so it reads as lightning and not as a pulse.
        let cycle = 12.0
        let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
        let flash = phase < 0.08 ? pow(1 - phase / 0.08, 2.4) : 0
        if flash > 0.02 {
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(SkyPalette.flash.opacity(0.55 * flash)))
        }
    }

    // MARK: Fields

    private static func drift(_ from: Double, _ to: Double, _ t: Double) -> CGFloat {
        let span = to - from
        let travel = 0.5 + 0.5 * sin(t * 2 * .pi)
        return CGFloat(from + span * travel)
    }

    private static func starX(_ i: Int) -> CGFloat {
        CGFloat(0.02 + Double((i * 73) % 100) / 100 * 0.96)
    }
    private static func starY(_ i: Int) -> CGFloat {
        CGFloat(0.05 + Double((i * 41) % 100) / 100 * 0.90)
    }
}

/// The sky's colours, and the inks that sit on them.
///
/// A reading paints an **immersive** sky: saturated, darker toward the bottom,
/// light type. That is the Weather app's contract — the card is a window, and
/// white type is what stays legible on every condition. The lightest stop of
/// each sky is held dark enough that the soft ink still clears 4.5:1.
///
/// **What is actually read is `highlight`** — a soft pool of light travelling
/// the band (`drawLight`). The other fields are the palette's own record of a
/// sky and are written by every case below but read by nothing since the Metal
/// atmosphere took over the band; they are kept because the Canvas fallback
/// still draws from this table and the values are the reference for it. (The
/// earlier `neutral` palette, its `gradient`, and the `isLightGround` flag went
/// with that rework: no reading means `WeatherBackdrop` is not mounted at all.)
struct SkyPalette {
    var top: Color
    var bottom: Color
    var ink: Color
    var inkSoft: Color
    var accent: Color
    /// The pool of light that travels the band, and the sheen on HELLO.
    var highlight: Color

    init(top: Color, bottom: Color, ink: Color, inkSoft: Color, accent: Color,
         highlight: Color) {
        self.top = top
        self.bottom = bottom
        self.ink = ink
        self.inkSoft = inkSoft
        self.accent = accent
        self.highlight = highlight
    }

    init(sky: WeatherReading.Sky, night: Bool) {
        let ink = Color(hex: 0xF7FAFF)
        let inkSoft = Color(hex: 0xE4EEF8)
        switch sky {
        case .clear:
            if night {
                self.init(top: Color(hex: 0x101735), bottom: Color(hex: 0x1C2A58),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xC9D6FF),
                          highlight: Color(hex: 0xD5E2FF))
            } else {
                self.init(top: Color(hex: 0x2869BA), bottom: Color(hex: 0x83B9E8),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xFFE3A3),
                          highlight: Color(hex: 0xFFF6D8))
            }
        case .partly:
            if night {
                self.init(top: Color(hex: 0x141B38), bottom: Color(hex: 0x243056),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xC9D6FF),
                          highlight: Color(hex: 0xC5D4F8))
            } else {
                self.init(top: Color(hex: 0x326CA9), bottom: Color(hex: 0x8AB3D4),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xFFE3A3),
                          highlight: Color(hex: 0xFFF4D4))
            }
        case .cloudy:
            if night {
                self.init(top: Color(hex: 0x1A2233), bottom: Color(hex: 0x2A3548),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xD5DEEA),
                          highlight: Color(hex: 0xC5D0DE))
            } else {
                self.init(top: Color(hex: 0x3E5168), bottom: Color(hex: 0x243444),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xE7EEF6),
                          highlight: Color(hex: 0xF4F7FB))
            }
        case .fog:
            if night {
                self.init(top: Color(hex: 0x222833), bottom: Color(hex: 0x343C48),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xE4E8EE),
                          highlight: Color(hex: 0xF2F4F7))
            } else {
                self.init(top: Color(hex: 0x546274), bottom: Color(hex: 0x323C4A),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xF2F5F8),
                          highlight: Color(hex: 0xFFFFFF))
            }
        case .rain, .drizzle, .sleet:
            if night {
                self.init(top: Color(hex: 0x152033), bottom: Color(hex: 0x101820),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xB9D7FF),
                          highlight: Color(hex: 0xD6E6FF))
            } else {
                self.init(top: Color(hex: 0x2C4E74), bottom: Color(hex: 0x163044),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xD6E8FF),
                          highlight: Color(hex: 0xEAF3FF))
            }
        case .snow:
            if night {
                self.init(top: Color(hex: 0x1A2436), bottom: Color(hex: 0x2A384C),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xE7F1FF),
                          highlight: Color(hex: 0xF7FBFF))
            } else {
                self.init(top: Color(hex: 0x4E6278), bottom: Color(hex: 0x2C3E52),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xF4FBFF),
                          highlight: Color(hex: 0xFFFFFF))
            }
        case .thunder, .hail:
            self.init(top: Color(hex: 0x12161F), bottom: Color(hex: 0x243044),
                      ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xFFD772),
                      highlight: Color(hex: 0xFFC24D))
        }
    }

    static let sun = Color(hex: 0xFFC24D)
    static let sunCore = Color(hex: 0xFFE9A8)
    static let moon = Color(hex: 0xF4F7FF)
    static let flash = Color(hex: 0xF7FBFF)
}

/// A small density field with a sun-facing second sample for self-shadow.
/// Generated once, then composited by Canvas; no noise evaluation per frame.
private enum SkyCloudTexture {
    static let image: CGImage = {
        let width = 384, height = 168
        func hash(_ x: Double, _ y: Double) -> Double {
            let n = sin(x * 127.1 + y * 311.7) * 43758.5453
            return n - floor(n)
        }
        func noise(_ x: Double, _ y: Double) -> Double {
            let ix = floor(x), iy = floor(y)
            let fx = x - ix, fy = y - iy
            let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
            let a = hash(ix, iy) * (1-u) + hash(ix+1, iy) * u
            let b = hash(ix, iy+1) * (1-u) + hash(ix+1, iy+1) * u
            return a * (1-v) + b * v
        }
        func field(_ x: Double, _ y: Double) -> Double {
            var amplitude = 0.5, value = 0.0, x = x, y = y
            for _ in 0..<5 {
                value += noise(x, y) * amplitude
                x = x * 2.02 + 17.3; y = y * 2.02 + 17.3; amplitude *= 0.5
            }
            return value
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width), v = Double(y) / Double(height)
                let envelope = max(0, 1 - pow((u - 0.5) * 2, 2)) * max(0, 1 - pow((v - 0.5) * 2, 2))
                let d = field(u * 5, v * 3)
                let density = max(0, min(1, (d * envelope - 0.18) * 4))
                let alpha = density * density * (3 - 2 * density)
                let lighting = max(0, min(1, 0.64 + (d - field(u * 5 - 0.09, v * 3 - 0.13)) * 4))
                let i = (y * width + x) * 4
                bytes[i] = UInt8((0.52 + lighting * 0.48) * alpha * 255)
                bytes[i+1] = UInt8((0.63 + lighting * 0.37) * alpha * 255)
                bytes[i+2] = UInt8((0.78 + lighting * 0.22) * alpha * 255)
                bytes[i+3] = UInt8(alpha * 255)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }()
}
