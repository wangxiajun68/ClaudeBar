import SwiftUI

/// The sky behind the greeting band.
///
/// Apple Weather's scene, scaled to one short card and one draw call:
///
/// 1. A vertical sky (the palette), lighter at the top.
/// 2. A slow pool of light, so a clear sky is not a frozen poster.
/// 3. Clouds as volume — a shadow, a body, a lit crown — never a stroked blob.
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceIsVisible) private var surfaceVisible

    /// Seconds since the band appeared. An absolute clock jumps when the
    /// timeline resumes; this one stays continuous with the moment the card
    /// was shown.
    @State private var start = Date()

    private var night: Bool { isDay == false }

    /// Rain and thunder need a smooth curtain. Everything else is cloud drift,
    /// a breathing sun, or fog, and 12–16 Hz is enough to read as motion.
    private var frameInterval: Double {
        switch sky {
        case .rain, .snow, .thunder: return 1.0 / 30
        case .fog, .partly, .cloudy: return 1.0 / 16
        case .clear: return 1.0 / 12
        }
    }

    var body: some View {
        let palette = SkyPalette(sky: sky, night: night)
        return TimelineView(.animation(minimumInterval: frameInterval,
                                       paused: reduceMotion || !surfaceVisible)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSince(start)
                var c = ctx
                Self.draw(sky: sky, night: night, palette: palette,
                          intensity: intensity, t: t, size: size, ctx: &c)
            }
        }
        .onAppear { start = Date() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private static func draw(sky: WeatherReading.Sky, night: Bool, palette: SkyPalette,
                             intensity: Int, t: TimeInterval, size: CGSize,
                             ctx: inout GraphicsContext) {
        drawLight(palette: palette, t: t, size: size, ctx: &ctx)
        switch sky {
        case .clear: drawClear(night: night, size: size, t: t, ctx: &ctx)
        case .partly: drawPartly(night: night, size: size, t: t, ctx: &ctx)
        case .cloudy: drawCloudy(night: night, size: size, t: t, ctx: &ctx)
        case .fog: drawFog(size: size, t: t, ctx: &ctx)
        case .rain: drawRain(night: night, size: size, intensity: intensity, t: t, ctx: &ctx)
        case .snow: drawSnow(night: night, size: size, t: t, ctx: &ctx)
        case .thunder: drawThunder(size: size, intensity: intensity, t: t, ctx: &ctx)
        }
    }

    /// One soft pool of the palette's highlight, travelling the width of the
    /// band. Replaces a blurred `Canvas` (a per-frame offscreen pass) with a
    /// single radial fill.
    private static func drawLight(palette: SkyPalette, t: TimeInterval, size: CGSize,
                                  ctx: inout GraphicsContext) {
        let phase = (t / 22).truncatingRemainder(dividingBy: 1)
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
    /// to catch the eye. `shadow` is unused — a dark under-shape is what made
    /// the last banks read as black potatoes on the rain sky.
    private static func cloud(_ ctx: inout GraphicsContext, at x: CGFloat, y: CGFloat,
                              scale: CGFloat, size: CGSize,
                              body: Color, shadow: Color, lit: Color) {
        _ = shadow
        let cx = x * size.width
        let cy = y * size.height
        let s = scale * size.height
        let lobes: [(CGFloat, CGFloat, CGFloat)] = [
            (-0.70, 0.12, 0.28), (-0.36, -0.02, 0.36), (0.00, -0.16, 0.44),
            (0.38, -0.04, 0.34), (0.72, 0.12, 0.26), (-0.10, 0.16, 0.30),
        ]
        for (dx, dy, r) in lobes {
            let rr = r * s
            let rect = CGRect(x: cx + dx * s - rr, y: cy + dy * s - rr * 0.72,
                              width: rr * 2, height: rr * 1.44)
            let center = CGPoint(x: rect.midX, y: rect.midY - rr * 0.12)
            ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [lit, body, body.opacity(0)]),
                center: center, startRadius: rr * 0.04, endRadius: rr))
        }
    }

    // MARK: Clear

    private static func drawClear(night: Bool, size: CGSize, t: TimeInterval,
                                  ctx: inout GraphicsContext) {
        if night {
            for i in 0..<28 {
                let x = starX(i) * size.width
                let y = starY(i) * size.height
                let twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * (0.6 + Double(i % 5) * 0.25) + Double(i)))
                let r = size.height * (0.008 + Double((i * 37) % 5) * 0.004)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(SkyPalette.moon.opacity((0.35 + Double(i % 3) * 0.2) * twinkle)))
            }
            let c = CGPoint(x: size.width * 0.62, y: size.height * 0.30)
            let r = size.height * 0.42
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
            drawSun(at: CGPoint(x: size.width * 0.60, y: size.height * 0.30),
                    size: size, t: t, ctx: &ctx)
        }
    }

    /// A disc, a corona, and ten rays that turn once every ~25 s. The rays are
    /// the clear sky's motion; the disc breathing is too small to notice alone.
    private static func drawSun(at c: CGPoint, size: CGSize, t: TimeInterval,
                                ctx: inout GraphicsContext) {
        let spin = t * 0.25
        for i in 0..<10 {
            var ray = ctx
            ray.translateBy(x: c.x, y: c.y)
            ray.rotate(by: .radians(spin + Double(i) * .pi / 5))
            let tall = i.isMultiple(of: 2)
            let len = size.height * (tall ? 0.95 : 0.68)
            let w = max(1.4, size.height * 0.012)
            let rect = CGRect(x: -w / 2, y: -len, width: w, height: len * 0.55)
            ray.fill(Path(roundedRect: rect, cornerRadius: w / 2),
                     with: .linearGradient(
                        Gradient(colors: [SkyPalette.sun.opacity(0),
                                          SkyPalette.sun.opacity(tall ? 0.32 : 0.16)]),
                        startPoint: CGPoint(x: 0, y: -len),
                        endPoint: CGPoint(x: 0, y: -len * 0.2)))
        }
        let pulse = 1 + 0.04 * sin(t / 9 * 2 * .pi)
        let r = size.height * 0.30 * pulse
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 3.2, y: c.y - r * 3.2,
                                        width: r * 6.4, height: r * 6.4)),
                 with: .radialGradient(
                    Gradient(colors: [SkyPalette.sun.opacity(0.40),
                                      SkyPalette.sun.opacity(0.10),
                                      SkyPalette.sun.opacity(0)]),
                    center: c, startRadius: r * 0.2, endRadius: r * 3.2))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                 with: .color(SkyPalette.sun))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.62, y: c.y - r * 0.62,
                                        width: r * 1.24, height: r * 1.24)),
                 with: .color(SkyPalette.sunCore))
    }

    // MARK: Partly / cloudy / fog

    private static func drawPartly(night: Bool, size: CGSize, t: TimeInterval,
                                   ctx: inout GraphicsContext) {
        drawClear(night: night, size: size, t: t, ctx: &ctx)
        let body = Color.white.opacity(night ? 0.22 : 0.82)
        let shadow = Color.black.opacity(night ? 0.30 : 0.16)
        let lit = Color.white.opacity(night ? 0.40 : 0.98)
        cloud(&ctx, at: drift(0.02, 0.28, t / 70), y: 0.42, scale: 0.50, size: size,
              body: body, shadow: shadow, lit: lit)
        cloud(&ctx, at: drift(0.40, 0.78, t / 52), y: 0.62, scale: 0.64, size: size,
              body: body, shadow: shadow, lit: lit)
    }

    private static func drawCloudy(night: Bool, size: CGSize, t: TimeInterval,
                                   ctx: inout GraphicsContext) {
        let body = Color.white.opacity(night ? 0.16 : 0.55)
        let shadow = Color.black.opacity(night ? 0.28 : 0.14)
        let lit = Color.white.opacity(night ? 0.32 : 0.88)
        cloud(&ctx, at: drift(0.02, 0.30, t / 86), y: 0.30, scale: 0.56, size: size,
              body: body, shadow: shadow, lit: lit)
        cloud(&ctx, at: drift(0.34, 0.70, t / 64), y: 0.48, scale: 0.72, size: size,
              body: body, shadow: shadow, lit: lit)
        cloud(&ctx, at: drift(0.62, 1.02, t / 50), y: 0.66, scale: 0.80, size: size,
              body: body, shadow: shadow, lit: lit)
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
        let body = Color.white.opacity(night ? 0.16 : 0.28)
        let lit = Color.white.opacity(night ? 0.34 : 0.55)
        let shadow = Color.clear
        cloud(&ctx, at: drift(-0.08, 0.22, t / 70), y: 0.02, scale: 0.70, size: size,
              body: body, shadow: shadow, lit: lit)
        cloud(&ctx, at: drift(0.28, 0.62, t / 54), y: 0.08, scale: 0.86, size: size,
              body: body, shadow: shadow, lit: lit)
        cloud(&ctx, at: drift(0.64, 1.04, t / 46), y: 0.00, scale: 0.64, size: size,
              body: body, shadow: shadow, lit: lit)
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
        let far = streaks(count: 48 + Int(load * 36), speed: 0.38, length: 0.18,
                          angle: 0.08, seed: 104729, t: t, size: size)
        let mid = streaks(count: 22 + Int(load * 16), speed: 0.55, length: 0.36,
                          angle: 0.14, seed: 224737, t: t, size: size)
        let near = streaks(count: 8 + Int(load * 6), speed: 0.78, length: 0.52,
                           angle: 0.20, seed: 479909, t: t, size: size)
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
        let len = length * size.height
        for i in 0..<count {
            let s = Double((i * seed) % 997) / 997
            let travel = (t * speed + s).truncatingRemainder(dividingBy: 1)
            let y = -len + CGFloat(travel) * (size.height + len)
            let x = CGFloat(0.02 + s * 0.98) * size.width + y * shear * 0.40
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
        let body = Color.white.opacity(night ? 0.18 : 0.62)
        let lit = Color.white.opacity(night ? 0.40 : 0.95)
        let shadow = Color.black.opacity(night ? 0.25 : 0.10)
        cloud(&ctx, at: drift(0.04, 0.36, t / 74), y: 0.24, scale: 0.58, size: size,
              body: body, shadow: shadow, lit: lit)
        cloud(&ctx, at: drift(0.50, 0.92, t / 58), y: 0.34, scale: 0.68, size: size,
              body: body, shadow: shadow, lit: lit)
        // Three depths. Near flakes are larger and slower to sway, which reads
        // as depth of field without a blur pass.
        let depths: [(fall: Double, radius: CGFloat, alpha: Double, sway: Double)] = [
            (0.10, 0.010, 0.45, 0.008),
            (0.16, 0.018, 0.78, 0.014),
            (0.24, 0.030, 0.95, 0.020),
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
        let body = SkyPalette.stormCloud.opacity(0.55)
        let lit = Color.white.opacity(0.16)
        let shadow = Color.black.opacity(0.35)
        cloud(&ctx, at: drift(0.00, 0.32, t / 60), y: 0.18, scale: 0.68, size: size,
              body: body, shadow: shadow, lit: lit)
        cloud(&ctx, at: drift(0.40, 0.82, t / 48), y: 0.28, scale: 0.80, size: size,
              body: body, shadow: shadow, lit: lit)
        cloud(&ctx, at: drift(0.74, 1.14, t / 42), y: 0.14, scale: 0.56, size: size,
              body: body, shadow: shadow, lit: lit)
        rainStreaks(size: size, intensity: max(intensity, 50), t: t, ctx: &ctx, splashes: true)

        // One strike per ~4.5 s. The spike is the first tenth of the cycle;
        // the rest is dark, so it reads as lightning and not as a pulse.
        let cycle = 4.5
        let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
        let flash = phase < 0.08 ? pow(1 - phase / 0.08, 2.4) : 0
        if flash > 0.02 {
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(SkyPalette.flash.opacity(0.55 * flash)))
        }
        var bolt = ctx
        bolt.translateBy(x: size.width * 0.58, y: size.height * 0.12)
        let s = size.height * 0.70
        let path = Path { p in
            p.move(to: CGPoint(x: 0.08 * s, y: 0))
            p.addLine(to: CGPoint(x: -0.08 * s, y: 0.38 * s))
            p.addLine(to: CGPoint(x: 0.10 * s, y: 0.40 * s))
            p.addLine(to: CGPoint(x: -0.06 * s, y: 0.78 * s))
            p.addLine(to: CGPoint(x: 0.12 * s, y: 0.80 * s))
            p.addLine(to: CGPoint(x: -0.04 * s, y: 1.20 * s))
        }
        bolt.stroke(path, with: .color(SkyPalette.bolt.opacity(0.25 + 0.55 * flash)),
                    style: StrokeStyle(lineWidth: max(3, size.height * 0.09),
                                       lineCap: .round, lineJoin: .round))
        bolt.stroke(path, with: .color(SkyPalette.flash.opacity(0.55 + 0.45 * flash)),
                    style: StrokeStyle(lineWidth: max(1.2, size.height * 0.018),
                                       lineCap: .round, lineJoin: .round))
    }

    // MARK: Fields

    private static func drift(_ from: Double, _ to: Double, _ t: Double) -> CGFloat {
        let span = to - from
        let travel = (t.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
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
/// No reading yet is the other case. `neutral` is the ice canvas, dark type,
/// and it claims no weather.
struct SkyPalette {
    var top: Color
    var bottom: Color
    var ink: Color
    var inkSoft: Color
    var accent: Color
    /// Dark type on a light ground. The ice fallback only — every real sky is
    /// a dark ground with light type.
    var isLightGround: Bool
    /// The pool of light that travels the band, and the sheen on HELLO.
    var highlight: Color

    init(top: Color, bottom: Color, ink: Color, inkSoft: Color, accent: Color,
         isLightGround: Bool, highlight: Color) {
        self.top = top
        self.bottom = bottom
        self.ink = ink
        self.inkSoft = inkSoft
        self.accent = accent
        self.isLightGround = isLightGround
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
                          isLightGround: false, highlight: Color(hex: 0xD5E2FF))
            } else {
                self.init(top: Color(hex: 0x1860B0), bottom: Color(hex: 0x0C3C86),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xFFE3A3),
                          isLightGround: false, highlight: Color(hex: 0xFFF6D8))
            }
        case .partly:
            if night {
                self.init(top: Color(hex: 0x141B38), bottom: Color(hex: 0x243056),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xC9D6FF),
                          isLightGround: false, highlight: Color(hex: 0xC5D4F8))
            } else {
                self.init(top: Color(hex: 0x1E5EA8), bottom: Color(hex: 0x123E78),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xFFE3A3),
                          isLightGround: false, highlight: Color(hex: 0xFFF4D4))
            }
        case .cloudy:
            if night {
                self.init(top: Color(hex: 0x1A2233), bottom: Color(hex: 0x2A3548),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xD5DEEA),
                          isLightGround: false, highlight: Color(hex: 0xC5D0DE))
            } else {
                self.init(top: Color(hex: 0x3E5168), bottom: Color(hex: 0x243444),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xE7EEF6),
                          isLightGround: false, highlight: Color(hex: 0xF4F7FB))
            }
        case .fog:
            if night {
                self.init(top: Color(hex: 0x222833), bottom: Color(hex: 0x343C48),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xE4E8EE),
                          isLightGround: false, highlight: Color(hex: 0xF2F4F7))
            } else {
                self.init(top: Color(hex: 0x546274), bottom: Color(hex: 0x323C4A),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xF2F5F8),
                          isLightGround: false, highlight: Color(hex: 0xFFFFFF))
            }
        case .rain:
            if night {
                self.init(top: Color(hex: 0x152033), bottom: Color(hex: 0x101820),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xB9D7FF),
                          isLightGround: false, highlight: Color(hex: 0xD6E6FF))
            } else {
                self.init(top: Color(hex: 0x2C4E74), bottom: Color(hex: 0x163044),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xD6E8FF),
                          isLightGround: false, highlight: Color(hex: 0xEAF3FF))
            }
        case .snow:
            if night {
                self.init(top: Color(hex: 0x1A2436), bottom: Color(hex: 0x2A384C),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xE7F1FF),
                          isLightGround: false, highlight: Color(hex: 0xF7FBFF))
            } else {
                self.init(top: Color(hex: 0x4E6278), bottom: Color(hex: 0x2C3E52),
                          ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xF4FBFF),
                          isLightGround: false, highlight: Color(hex: 0xFFFFFF))
            }
        case .thunder:
            self.init(top: Color(hex: 0x12161F), bottom: Color(hex: 0x243044),
                      ink: ink, inkSoft: inkSoft, accent: Color(hex: 0xFFD772),
                      isLightGround: false, highlight: Color(hex: 0xFFC24D))
        }
    }

    /// No reading: the page's own ice, dark type. It must not announce a sky.
    static var neutral: SkyPalette {
        SkyPalette(top: Color(hex: 0xE7EEF6), bottom: Color(hex: 0xD5DEEA),
                   ink: Color(hex: 0x1B2331), inkSoft: Color(hex: 0x5A6675),
                   accent: Color(hex: 0x1D4FB8), isLightGround: true,
                   highlight: Color(hex: 0xFFFFFF))
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    var shadowTint: Color { top }

    static let sun = Color(hex: 0xFFC24D)
    static let sunCore = Color(hex: 0xFFE9A8)
    static let moon = Color(hex: 0xF4F7FF)
    static let stormCloud = Color(hex: 0x2A3344)
    static let flash = Color(hex: 0xF7FBFF)
    static let bolt = Color(hex: 0xFFF2B0)
}
