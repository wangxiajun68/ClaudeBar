import SwiftUI

/// The weather band's sky: the palette it is painted from, the ground the whole
/// card sits on, and the motion that runs across all of it.
///
/// **One surface, not three panels.** The band is made of three readings —
/// weather, clock, greeting — and the temptation is to draw three blocks on one
/// card. That is what the first cut did, and it read as exactly that: three
/// modules with a seam between them. So the sky is not a panel *inside* the
/// band, it **is** the band: one continuous gradient the full width of the card,
/// with the weather's own motion running across the whole of it, behind all
/// three readings. Nothing on the card draws its own background.
///
/// **Why this is allowed to move.** The app's rule (DESIGN.md, "Motion /
/// performance") is that nothing repeats a SwiftUI animation and nothing runs
/// per frame off-screen. This follows the machine-mark discipline exactly: a
/// `TimelineView(.animation)` paused by the same three-way gate (`surfaceIsVisible`
/// · Reduce Motion · whether this sky has anything to say), drawing one `Canvas`
/// per frame, every phase derived from **absolute time** so the picture is a
/// continuous function of the clock rather than a loop that snaps when a state
/// change interrupts it. A *still* sky (clear, partly, cloudy, fog) pauses the
/// timeline outright: it is a state, drawn once, and half the code below is the
/// `static` drawing functions that make that possible.
struct WeatherBackdrop: View {
    let sky: WeatherReading.Sky
    let isDay: Bool?
    /// 0…100. Widens the rain / snow shower, so a drizzle and a downpour are
    /// different pictures rather than the same picture at a different label.
    var intensity: Int = 40

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceIsVisible) private var surfaceVisible

    /// Seconds since the band appeared. Every phase comes from this rather than
    /// from `timeline.date`: an absolute clock's phase depends on the instant
    /// the app launched, and it jumps whenever the timeline resumes after a
    /// pause, landing the rain mid-flight.
    @State private var start = Date()

    private var night: Bool { isDay == false }

    /// Whether this sky has anything to animate. Clear / partly / cloudy / fog
    /// are states.
    static func animates(_ sky: WeatherReading.Sky) -> Bool {
        switch sky {
        case .rain, .snow, .thunder: return true
        case .clear, .partly, .cloudy, .fog: return false
        }
    }

    var body: some View {
        let palette = SkyPalette(sky: sky, night: night)
        return TimelineView(.animation(minimumInterval: 1.0 / 30,
                                       paused: !Self.animates(sky) || reduceMotion || !surfaceVisible)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSince(start)
                var c = ctx
                // The band is wide and short (roughly 1000 × 130), so the sky is
                // drawn in *its own* aspect rather than in the 1×1 unit space a
                // square panel used: clouds and drops keep their proportions and
                // the horizon stays where the gradient puts it.
                Self.draw(sky: sky, night: night, palette: palette,
                          intensity: intensity, t: t, size: size, ctx: &c)
            }
        }
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private static func draw(sky: WeatherReading.Sky, night: Bool, palette: SkyPalette,
                             intensity: Int, t: TimeInterval, size: CGSize,
                             ctx: inout GraphicsContext) {
        switch sky {
        case .clear: drawClear(night: night, size: size, t: t, ctx: &ctx)
        case .partly: drawPartly(night: night, size: size, t: t, ctx: &ctx)
        case .cloudy: drawCloudy(night: night, size: size, t: t, ctx: &ctx)
        case .fog: drawFog(night: night, size: size, t: t, ctx: &ctx)
        case .rain: drawRain(night: night, size: size, intensity: intensity, t: t, ctx: &ctx)
        case .snow: drawSnow(night: night, size: size, t: t, ctx: &ctx)
        case .thunder: drawThunder(night: night, size: size, t: t, ctx: &ctx)
        }
    }

    /// Cloud, as a fraction of the band's **height** so the bank keeps its
    /// proportions on a band that is eight times wider than it is tall. Returns
    /// the path so the same shape can be filled twice (a soft under-shadow, then
    /// the lit body).
    private static func cloudPath(at x: CGFloat, y: CGFloat, scale: CGFloat,
                                  in size: CGSize) -> Path {
        let unit = size.height
        var path = Path()
        let cx = x * size.width
        let cy = y * unit
        let s = scale * unit
        // Three lobes over a base, in units of the cloud's own scale.
        for (dx, dy, r) in [(-0.52, 0.06, 0.30), (0.0, -0.16, 0.40), (0.52, 0.05, 0.29)] {
            path.addEllipse(in: CGRect(x: cx + dx * s - r * s, y: cy + dy * s - r * s,
                                       width: r * 2 * s, height: r * 2 * s))
        }
        path.addRoundedRect(in: CGRect(x: cx - 0.80 * s, y: cy - 0.03 * s,
                                       width: 1.60 * s, height: 0.34 * s),
                            cornerSize: CGSize(width: 0.17 * s, height: 0.17 * s))
        return path
    }

    /// One cloud bank: a soft shadow under a lit body, drawn from the same path.
    private static func cloud(_ ctx: inout GraphicsContext, at x: CGFloat, y: CGFloat,
                              scale: CGFloat, size: CGSize,
                              light: Color, dark: Color) {
        let path = cloudPath(at: x, y: y, scale: scale, in: size)
        var layer = ctx
        layer.translateBy(x: 0, y: size.height * 0.035)
        layer.fill(path, with: .color(dark.opacity(0.35)))
        ctx.fill(path, with: .linearGradient(
            Gradient(colors: [light, dark]),
            startPoint: CGPoint(x: 0, y: y * size.height - size.height * 0.55),
            endPoint: CGPoint(x: 0, y: y * size.height + size.height * 0.35)))
    }

    // MARK: Clear

    private static func drawClear(night: Bool, size: CGSize, t: TimeInterval,
                                  ctx: inout GraphicsContext) {
        if night {
            // A fixed pseudo-random star field: a band that re-rolls its
            // constellations once a second is a screensaver, not a sky.
            for i in 0..<26 {
                let x = starX(i) * size.width
                let y = starY(i) * size.height
                let r = size.height * (0.010 + Double((i * 37) % 5) * 0.004)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(SkyPalette.moon.opacity(0.30 + Double(i % 3) * 0.20)))
            }
            let r = size.height * 0.62
            let c = CGPoint(x: size.width * 0.86, y: size.height * 0.30)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.6, y: c.y - r * 1.6,
                                            width: r * 3.2, height: r * 3.2)),
                     with: .radialGradient(Gradient(colors: [SkyPalette.moon.opacity(0.22),
                                                             SkyPalette.moon.opacity(0)]),
                                           center: c, startRadius: r * 0.2, endRadius: r * 1.6))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.5, y: c.y - r * 0.5,
                                            width: r, height: r)),
                     with: .color(SkyPalette.moon.opacity(0.95)))
            // The bite that makes it a crescent rather than a dot.
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.5 + r * 0.30, y: c.y - r * 0.5 - r * 0.16,
                                            width: r, height: r)),
                     with: .color(SkyPalette.nightTop))
        } else {
            // The sun keeps its corona, and the corona *breathes*: the band's
            // one motion on an otherwise still sky, slow enough (11 s) to read
            // as light rather than as animation.
            let c = CGPoint(x: size.width * 0.87, y: size.height * 0.34)
            let pulse = 1 + 0.06 * sin(t / 11 * 2 * .pi)
            let r = size.height * 0.46 * pulse
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 3.1, y: c.y - r * 3.1,
                                            width: r * 6.2, height: r * 6.2)),
                     with: .radialGradient(
                        Gradient(colors: [SkyPalette.sun.opacity(0.34),
                                          SkyPalette.sun.opacity(0.10),
                                          SkyPalette.sun.opacity(0)]),
                        center: c, startRadius: r * 0.2, endRadius: r * 3.1))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .color(SkyPalette.sun))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.64, y: c.y - r * 0.64,
                                            width: r * 1.28, height: r * 1.28)),
                     with: .color(SkyPalette.sunCore))
        }
    }

    // MARK: Partly

    private static func drawPartly(night: Bool, size: CGSize, t: TimeInterval,
                                   ctx: inout GraphicsContext) {
        drawClear(night: night, size: size, t: t, ctx: &ctx)
        cloud(&ctx, at: drift(0.02, 0.30, t / 64), y: 0.60, scale: 0.46, size: size,
              light: SkyPalette.cloudLight.opacity(night ? 0.30 : 0.88),
              dark: SkyPalette.cloudDark.opacity(night ? 0.22 : 0.34))
        cloud(&ctx, at: drift(0.42, 0.78, t / 46), y: 0.74, scale: 0.62, size: size,
              light: SkyPalette.cloudLight.opacity(night ? 0.34 : 0.96),
              dark: SkyPalette.cloudDark.opacity(night ? 0.26 : 0.40))
    }

    // MARK: Cloudy

    private static func drawCloudy(night: Bool, size: CGSize, t: TimeInterval,
                                   ctx: inout GraphicsContext) {
        let light = SkyPalette.cloudLight.opacity(night ? 0.26 : 0.80)
        let dark = SkyPalette.cloudDark.opacity(night ? 0.28 : 0.46)
        cloud(&ctx, at: drift(0.04, 0.34, t / 82), y: 0.34, scale: 0.52, size: size,
              light: light, dark: dark)
        cloud(&ctx, at: drift(0.38, 0.72, t / 62), y: 0.50, scale: 0.68, size: size,
              light: light, dark: dark)
        cloud(&ctx, at: drift(0.66, 1.06, t / 48), y: 0.72, scale: 0.80, size: size,
              light: light, dark: dark)
    }

    // MARK: Fog

    private static func drawFog(night: Bool, size: CGSize, t: TimeInterval,
                                ctx: inout GraphicsContext) {
        let band = SkyPalette.cloudLight.opacity(night ? 0.16 : 0.46)
        for i in 0..<4 {
            let y = size.height * (0.22 + Double(i) * 0.20)
            let h = size.height * 0.16
            let phase = drift(-0.5, 1.0, t / (34 + Double(i) * 12) + Double(i) * 0.23)
            let rect = CGRect(x: phase * size.width - size.width * 0.4, y: y,
                              width: size.width * 1.8, height: h)
            let path = Path(roundedRect: rect, cornerRadius: h / 2)
            ctx.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: band.opacity(0), location: 0),
                    .init(color: band, location: 0.5),
                    .init(color: band.opacity(0), location: 1)]),
                startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
        }
    }

    // MARK: Rain

    private static func drawRain(night: Bool, size: CGSize, intensity: Int,
                                 t: TimeInterval, ctx: inout GraphicsContext) {
        cloud(&ctx, at: drift(0.00, 0.34, t / 54), y: 0.22, scale: 0.60, size: size,
              light: SkyPalette.cloudLight.opacity(night ? 0.24 : 0.66),
              dark: SkyPalette.cloudDark.opacity(night ? 0.30 : 0.56))
        cloud(&ctx, at: drift(0.44, 0.82, t / 44), y: 0.30, scale: 0.72, size: size,
              light: SkyPalette.cloudLight.opacity(night ? 0.20 : 0.56),
              dark: SkyPalette.cloudDark.opacity(night ? 0.26 : 0.50))
        cloud(&ctx, at: drift(0.80, 1.18, t / 38), y: 0.18, scale: 0.52, size: size,
              light: SkyPalette.cloudLight.opacity(night ? 0.16 : 0.48),
              dark: SkyPalette.cloudDark.opacity(night ? 0.22 : 0.44))

        // The shower runs over the whole band, corner to corner — the band's
        // reading, not a panel's. Count and speed follow the rain chance.
        let load = Double(min(max(intensity, 0), 100)) / 100
        let count = 26 + Int((load * 46).rounded())
        let speed = 0.55 + load * 1.15
        let drop = SkyPalette.raindrop
        for i in 0..<count {
            let seed = Double((i * 7919) % 1000) / 1000
            let x = (Double(i) + 0.5) / Double(count) * 1.04
            let len = size.height * (0.20 + load * 0.30 + seed * 0.10)
            let travel = (t * speed + seed * 5).truncatingRemainder(dividingBy: 1)
            let y = -len + travel * (size.height + len)
            var layer = ctx
            layer.translateBy(x: CGFloat(x) * size.width + y * 0.10, y: y)
            layer.rotate(by: .radians(0.22))
            let thickness = max(1, size.height * 0.010)
            layer.fill(Path(CGRect(x: 0, y: 0, width: thickness, height: len)),
                       with: .color(drop.opacity(night ? 0.38 : 0.46)))
        }
        // A wet horizon: light pooling along the bottom edge.
        ctx.fill(Path(CGRect(x: 0, y: size.height * 0.88,
                             width: size.width, height: size.height * 0.12)),
                 with: .linearGradient(
                    Gradient(colors: [drop.opacity(0), drop.opacity(night ? 0.14 : 0.18)]),
                    startPoint: CGPoint(x: 0, y: size.height * 0.88),
                    endPoint: CGPoint(x: 0, y: size.height)))
    }

    // MARK: Snow

    private static func drawSnow(night: Bool, size: CGSize, t: TimeInterval,
                                 ctx: inout GraphicsContext) {
        cloud(&ctx, at: drift(0.04, 0.40, t / 70), y: 0.24, scale: 0.58, size: size,
              light: SkyPalette.cloudLight.opacity(night ? 0.26 : 0.72),
              dark: SkyPalette.cloudDark.opacity(night ? 0.24 : 0.44))
        cloud(&ctx, at: drift(0.56, 0.96, t / 56), y: 0.32, scale: 0.66, size: size,
              light: SkyPalette.cloudLight.opacity(night ? 0.22 : 0.64),
              dark: SkyPalette.cloudDark.opacity(night ? 0.20 : 0.40))
        for i in 0..<34 {
            let seed = Double((i * 524287) % 1000) / 1000
            let fall = 0.22 + seed * 0.20
            let x = (Double(i) + 0.5) / 34 * 1.02
            let y = (t * fall + seed * 3.4).truncatingRemainder(dividingBy: 1)
            let sway = sin((t * 0.7 + seed * 6.2) * .pi) * 0.012
            let r = size.height * (0.014 + seed * 0.016)
            let cx = CGFloat(x + sway) * size.width
            let cy = CGFloat(y) * size.height
            ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                     with: .color(SkyPalette.cloudLight.opacity(night ? 0.72 : 0.92)))
        }
    }

    // MARK: Thunder

    private static func drawThunder(night: Bool, size: CGSize, t: TimeInterval,
                                    ctx: inout GraphicsContext) {
        cloud(&ctx, at: drift(0.02, 0.36, t / 60), y: 0.18, scale: 0.66, size: size,
              light: SkyPalette.cloudLight.opacity(0.16), dark: SkyPalette.stormCloud.opacity(0.86))
        cloud(&ctx, at: drift(0.46, 0.86, t / 50), y: 0.26, scale: 0.76, size: size,
              light: SkyPalette.cloudLight.opacity(0.13), dark: SkyPalette.stormCloud.opacity(0.90))
        cloud(&ctx, at: drift(0.78, 1.18, t / 42), y: 0.14, scale: 0.58, size: size,
              light: SkyPalette.cloudLight.opacity(0.11), dark: SkyPalette.stormCloud.opacity(0.84))

        // One strike per ~4 s: a spike near the start of the cycle carries the
        // flash and the rest of the cycle is dark. A bolt that pulsed evenly
        // would read as a heartbeat rather than as lightning.
        let cycle = 4.0
        let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
        let flash = phase < 0.09 ? pow(1 - phase / 0.09, 2.2) : 0
        if flash > 0.01 {
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(SkyPalette.flash.opacity(0.30 * flash)))
        }
        var bolt = ctx
        let bx = size.width * 0.72
        let by = size.height * 0.16
        let s = size.height * 0.62
        bolt.translateBy(x: bx, y: by)
        let path = Path { p in
            p.move(to: CGPoint(x: 0.10 * s, y: 0))
            p.addLine(to: CGPoint(x: -0.06 * s, y: 0.42 * s))
            p.addLine(to: CGPoint(x: 0.09 * s, y: 0.42 * s))
            p.addLine(to: CGPoint(x: -0.10 * s, y: 0.94 * s))
            p.addLine(to: CGPoint(x: 0.04 * s, y: 0.94 * s))
            p.addLine(to: CGPoint(x: -0.14 * s, y: 1.52 * s))
        }
        bolt.stroke(path, with: .color(SkyPalette.bolt.opacity(0.35 + 0.65 * flash)),
                    style: StrokeStyle(lineWidth: max(2, size.height * 0.055),
                                       lineCap: .round, lineJoin: .round))
        bolt.stroke(path, with: .color(SkyPalette.flash.opacity(0.30 + 0.70 * flash)),
                    style: StrokeStyle(lineWidth: max(1, size.height * 0.022),
                                       lineCap: .round, lineJoin: .round))
    }

    // MARK: Deterministic fields

    /// A value that wraps a travelling coordinate into a band with a margin, so
    /// an object leaves one side and re-enters the other with no visible jump.
    /// The margin is the object's own half-width, so it is *completely* off the
    /// band at the seam.
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

/// What the band paints itself from, and what it paints its **text** in.
///
/// The second half is the part that has to exist: a card whose ground is the sky
/// cannot use `Theme.textPrimary`, because a night sky and an ice sheet take
/// opposite inks. Every palette therefore carries its own text inks, chosen to
/// clear the app's 4.5:1 floor against *its own* top and bottom stops — the same
/// discipline `Theme.Ink` documents for the light canvas.
///
/// The day palettes are deliberately close to the ice canvas they sit on: a
/// clear day is the ice sheet warmed a few degrees, not a poster. The night and
/// thunder palettes are the honest exception, because "it is dark outside" is
/// information the card is allowed to carry.
struct SkyPalette {
    var top: Color
    var bottom: Color
    /// Primary text on this ground.
    var ink: Color
    /// Captions and secondary figures.
    var inkSoft: Color
    /// The accent used for the clock's weekday, the greeting and the day's
    /// high/low — a hue that reads on both stops.
    var accent: Color
    /// Whether this ground wants dark text (true) or light text (false). Used
    /// for the hairline and the inner frame ring, which are white over a tinted
    /// ground and black over a bright one.
    var isLightGround: Bool

    init(sky: WeatherReading.Sky, night: Bool) {
        switch sky {
        case .clear:
            if night {
                top = Color(hex: 0x141A31); bottom = Color(hex: 0x28305A)
                ink = Color(hex: 0xF2F5FF); inkSoft = Color(hex: 0xB9C2DE)
                accent = Color(hex: 0x9FB6FF); isLightGround = false
            } else {
                top = Color(hex: 0xEAF3FF); bottom = Color(hex: 0xD6E8FF)
                ink = Color(hex: 0x17233A); inkSoft = Color(hex: 0x54627C)
                accent = Color(hex: 0x1D4FB8); isLightGround = true
            }
        case .partly:
            if night {
                top = Color(hex: 0x171D33); bottom = Color(hex: 0x2C3459)
                ink = Color(hex: 0xF1F4FF); inkSoft = Color(hex: 0xB6BFDA)
                accent = Color(hex: 0x9FB6FF); isLightGround = false
            } else {
                top = Color(hex: 0xE7F1FF); bottom = Color(hex: 0xD3E4F8)
                ink = Color(hex: 0x1A2438); inkSoft = Color(hex: 0x596781)
                accent = Color(hex: 0x1D4FB8); isLightGround = true
            }
        case .cloudy, .fog:
            if night {
                top = Color(hex: 0x1C2233); bottom = Color(hex: 0x2A3348)
                ink = Color(hex: 0xEFF3FA); inkSoft = Color(hex: 0xB3BCCD)
                accent = Color(hex: 0x9FB6FF); isLightGround = false
            } else {
                top = Color(hex: 0xE7ECF2); bottom = Color(hex: 0xD6DEE9)
                ink = Color(hex: 0x1B2331); inkSoft = Color(hex: 0x5A6675)
                accent = Color(hex: 0x1D4FB8); isLightGround = true
            }
        case .rain, .snow:
            if night {
                top = Color(hex: 0x1B2334); bottom = Color(hex: 0x2B3A52)
                ink = Color(hex: 0xEEF4FF); inkSoft = Color(hex: 0xB4C1D6)
                accent = Color(hex: 0x8FB4E8); isLightGround = false
            } else {
                top = Color(hex: 0xDCE6F1); bottom = Color(hex: 0xC8D6E6)
                ink = Color(hex: 0x18222F); inkSoft = Color(hex: 0x52617A)
                accent = Color(hex: 0x1B4AA8); isLightGround = true
            }
        case .thunder:
            // A storm is its own palette in either light: it is the one sky that
            // genuinely is dark at noon, and painting it pale would cost the
            // card the only thing that reads as a storm.
            top = Color(hex: 0x141A28); bottom = Color(hex: 0x2A3446)
            ink = Color(hex: 0xF2F6FF); inkSoft = Color(hex: 0xB8C2D4)
            accent = Color(hex: 0xFFD772); isLightGround = false
        }
    }

    /// No reading yet: the same bench the rest of the app sits on. The band then
    /// paints the ice canvas's own step, so "we have no weather" costs nothing
    /// and claims nothing.
    static var neutral: SkyPalette { SkyPalette(sky: .cloudy, night: false) }

    /// The ground, top → bottom.
    var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A palette's darkest stop, for the layer shadow's hue.
    var shadowTint: Color { top }

    // Shared ornament hues, so a palette never invents a new sun.
    static let sun = Color(hex: 0xFFC24D)
    static let sunCore = Color(hex: 0xFFE9A8)
    static let moon = Color(hex: 0xE8EDFF)
    static let cloudLight = Color(hex: 0xFFFFFF)
    static let cloudDark = Color(hex: 0x9DAEC6)
    static let stormCloud = Color(hex: 0x3A4459)
    static let raindrop = Color(hex: 0x86B8F5)
    static let flash = Color(hex: 0xF3F7FF)
    static let bolt = Color(hex: 0xFFF2B0)
    static let nightTop = Color(hex: 0x141A31)
}
