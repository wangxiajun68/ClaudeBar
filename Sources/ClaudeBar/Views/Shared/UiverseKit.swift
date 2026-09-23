import SwiftUI

// Native translations of the Uiverse.io widgets the product actually uses.
// Motion is gated: TimelineView only ticks on hover, press, or VPN starting.
// Ice canvas stays ice — the dark sparkle pill is the one ink contrast CTA.

// MARK: - Sparkle CTA (MuhammadHasann)

/// Dark capsule with inset highlight, purple/red `--active` glow, rotating
/// border sweep, and a three-point sparkle. Used as VPN 启动 / 停止.
struct SparkleCta: View {
    let title: String
    var spinning: Bool = false
    var kind: Kind = .go
    var action: () -> Void

    enum Kind { case go, stop }

    @State private var hover = false

    private var active: Bool { hover || spinning }

    private var glow: Color {
        kind == .stop ? Theme.statusError : Color(hue: 0.72, saturation: 0.90, brightness: 0.58)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SparkleMark(active: hover || spinning)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: active
                                ? [Color.white, Color.white.opacity(0.55)]
                                : [Color.white, Color.white.opacity(0.92)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    Capsule().fill(Color(hex: 0x1F1F1F))
                    Capsule()
                        .fill(
                            RadialGradient(
                                colors: overlayColors,
                                center: UnitPoint(x: 0.5, y: 0.92),
                                startRadius: 2,
                                endRadius: 36
                            )
                        )
                        .opacity(active ? 1 : 0)
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.55),
                                    Color.black.opacity(0.45)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    SweepRing(active: active)
                }
            }
            .overlay {
                Capsule()
                    .stroke(glow.opacity(active ? 0.72 : 0), lineWidth: 6)
                    .blur(radius: 5)
                    .opacity(active ? 1 : 0)
            }
            .shadow(color: Color.black.opacity(active ? 0.04 : 0.22), radius: active ? 2 : 8, y: active ? 0 : 4)
            .scaleEffect(active ? 1.06 : 1)
            .animation(.easeInOut(duration: 0.28), value: active)
        }
        .buttonStyle(SparklePressStyle())
        .fixedSize()
        .onHover { hovering in
            if hover != hovering { hover = hovering }
        }
        .help(title)
    }

    private var overlayColors: [Color] {
        switch kind {
        case .go:
            return [
                Color(hue: 0.74, saturation: 0.42, brightness: 0.82),
                Color(hue: 0.72, saturation: 0.90, brightness: 0.58).opacity(0.82)
            ]
        case .stop:
            return [
                Color(hex: 0xFF8A80),
                Color(hex: 0xC41E3A).opacity(0.88)
            ]
        }
    }
}

/// Press collapses the hover scale back to 1, matching `:active { scale(1) }`.
private struct SparklePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SparkleMark: View {
    var active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 20.0 : 30, paused: !active)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.5) / 1.5
            ZStack {
                spark(scaleAt(phase, peak: 0.17))
                    .frame(width: 10, height: 10)
                spark(scaleAt(phase, peak: 0.49))
                    .frame(width: 6, height: 6)
                    .offset(x: 5, y: -4)
                spark(scaleAt(phase, peak: 0.83))
                    .frame(width: 5, height: 5)
                    .offset(x: -4, y: 5)
            }
            .foregroundColor(.white)
        }
    }

    private func spark(_ scale: CGFloat) -> some View {
        Image(systemName: "sparkle")
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
    }

    private func scaleAt(_ phase: Double, peak: Double) -> CGFloat {
        abs(phase - peak) < 0.08 ? 1.22 : 1
    }
}

/// Rotating white bar clipped to the capsule stroke — `dots_border`.
private struct SweepRing: View {
    var active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 20.0 : 30, paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let deg = active ? (t.truncatingRemainder(dividingBy: 2) / 2) * 360 : 0
            Canvas { ctx, size in
                let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                ctx.translateBy(x: mid.x, y: mid.y)
                ctx.rotate(by: .degrees(deg))
                let bar = CGRect(x: 0, y: -10, width: max(size.width, size.height), height: 20)
                ctx.fill(
                    Path(bar),
                    with: .linearGradient(
                        Gradient(colors: [.clear, .white, .clear]),
                        startPoint: CGPoint(x: 0, y: -10),
                        endPoint: CGPoint(x: 0, y: 10)
                    )
                )
            }
            .mask {
                Capsule().stroke(lineWidth: 2).padding(-1)
            }
            .opacity(active ? 1 : 0)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Orbit loader (circular inset-shadow spinner + stars)

/// Starting-state ring. Stars and rotation only while `spinning`.
struct OrbitLoader: View {
    var size: CGFloat = 44
    var caption: String = "…"
    var spinning: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: spinning ? 1.0 / 20.0 : 30, paused: !spinning)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let deg = spinning ? (t.truncatingRemainder(dividingBy: 2) / 2) * 360 + 90 : 90
            ZStack {
                if size >= 36 {
                    ForEach(0..<5, id: \.self) { i in
                        star(i, t: t)
                    }
                }
                Circle()
                    .fill(Theme.chartPurple.opacity(0.10))
                    .shadow(color: Color.white.opacity(0.35), radius: size * 0.18)
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                Color.white.opacity(0.90),
                                Color.white.opacity(0.08),
                                Theme.chartPurple.opacity(0.45),
                                Color.white.opacity(0.90)
                            ],
                            center: .center
                        ),
                        lineWidth: max(3, size * 0.09)
                    )
                    .rotationEffect(.degrees(deg))
                if !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: max(9, size * 0.24), weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel(caption.isEmpty ? "启动中" : caption)
    }

    private func star(_ i: Int, t: TimeInterval) -> some View {
        let phase = t + Double(i) * 0.18
        let pulse = 0.18 + 0.14 * (0.5 + 0.5 * sin(phase * .pi))
        let angles: [Double] = [70, 28, 130, 210, 320]
        let radii: [CGFloat] = [0.62, 0.58, 0.70, 0.64, 0.60]
        let rad = angles[i] * .pi / 180
        let r = size * radii[i]
        return Circle()
            .fill(Color.white.opacity(pulse))
            .frame(width: 3.5, height: 3.5)
            .blur(radius: pulse > 0.26 ? 0.4 : 1.6)
            .offset(x: CGFloat(cos(rad)) * r, y: CGFloat(sin(rad)) * r)
    }
}

// MARK: - Aurora sparkline (Monthly Balance)

struct AuroraSparkline: View {
    let values: [Double]
    var tint: Color = Theme.chartGreen
    var live: Bool = false

    /// A `live` sparkline pulses its head dot at 12 Hz. `live` is a caller
    /// decision (VPN running, stream in flight) but on its own it is not
    /// enough: the schedule has to stop when nothing is on screen, or an
    /// always-resident menu-bar app keeps animating a window nobody can see.
    @State private var uiIsLive = UIWakePolicy.hasVisibleWindow

    private var pulsing: Bool { live && uiIsLive }

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack(alignment: .topLeading) {
                fillPath(pts, height: geo.size.height)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.22), tint.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                strokePath(pts)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    if pulsing {
                        TimelineView(.animation(minimumInterval: 1.0 / 12.0,
                                                paused: !pulsing)) { timeline in
                            let p = 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 2.4)
                            Circle()
                                .fill(tint.opacity(0.14 + 0.16 * p))
                                .frame(width: 10 + 8 * p, height: 10 + 8 * p)
                                .position(last)
                        }
                    }
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                        .shadow(color: tint.opacity(0.55), radius: 5)
                        .position(last)
                }
            }
        }
        .onReceive(UIWakePolicy.changes) { _ in
            uiIsLive = UIWakePolicy.hasVisibleWindow
        }
        .accessibilityHidden(true)
    }

    /// CSS-like cubic: low start, mid dip, rise, settle.
    static func accentCurve(peak: Double, count: Int = 18) -> [Double] {
        let p = min(max(peak, 0.08), 1)
        return (0..<count).map { i in
            let t = Double(i) / Double(max(count - 1, 1))
            let wave = 0.42 + 0.58 * sin((t * 1.15 + 0.12) * .pi)
            return max(0.06, p * wave)
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let raw = values.isEmpty ? Self.accentCurve(peak: 0.35) : values
        let maxV = max(raw.max() ?? 1, 0.0001)
        let n = raw.count
        guard n > 0, size.width > 1 else { return [] }
        return raw.enumerated().map { i, v in
            let x = CGFloat(i) / CGFloat(max(n - 1, 1)) * size.width
            let y = size.height - CGFloat(v / maxV) * (size.height * 0.86) - 3
            return CGPoint(x: x, y: y)
        }
    }

    private func strokePath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }

    private func fillPath(_ pts: [CGPoint], height: CGFloat) -> Path {
        var p = strokePath(pts)
        guard let last = pts.last, let first = pts.first else { return p }
        p.addLine(to: CGPoint(x: last.x, y: height))
        p.addLine(to: CGPoint(x: first.x, y: height))
        p.closeSubpath()
        return p
    }
}

// MARK: - Source stack (Damn good card overlapping circles)

struct SourceStack: View {
    let slices: [SourceRing.Slice]
    var scan: Bool = false

    private var ranked: [SourceRing.Slice] {
        slices.filter { $0.value > 0 }.sorted { $0.value > $1.value }
    }

    var body: some View {
        let items = Array(ranked.prefix(3))
        let sizes: [CGFloat] = items.count == 1 ? [28] : (items.count == 2 ? [24, 32] : [20, 26, 34])
        ZStack {
            HStack(spacing: -10) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, slice in
                    let s = sizes[min(i, sizes.count - 1)]
                    ZStack {
                        Circle().fill(Theme.base2)
                        Circle().fill(slice.color.opacity(0.16))
                        Text(glyph(slice.label))
                            .font(.system(size: s * 0.32, weight: .bold, design: .rounded))
                            .foregroundColor(slice.color)
                    }
                    .frame(width: s, height: s)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.75), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 6, y: 3)
                    .zIndex(Double(items.count - i))
                    .help("\(slice.label) \(UsageStats.formatTokens(slice.value))")
                }
            }
            if scan, !items.isEmpty {
                ScanLine(active: scan)
                    .frame(width: 1, height: 36)
            }
        }
        .frame(height: 36)
    }

    private func glyph(_ label: String) -> String {
        if label.contains("Claude") { return "C" }
        if label.lowercased().contains("codex") { return "X" }
        return "3"
    }
}

private struct ScanLine: View {
    /// Same contract as the other gated schedules in this file: the parent
    /// stops rendering the line when it is not scanning, and `active` keeps
    /// the schedule itself paused so an in-flight hover-out cannot leave a
    /// 20 Hz display link behind.
    var active: Bool

    var body: some View {
        // 20 Hz while the card is hovered. Every other 20 Hz schedule in this
        // kit carries `paused:`, and this one is worse than they are: it has
        // no stop condition at all, so leaving the pointer on a usage card
        // pinned a display link for as long as the app ran.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.6) / 1.6
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.clear, Theme.external, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .offset(x: CGFloat(t - 0.5) * 48)
                .opacity(0.85)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Folder peek (byllzz files, no 3D)

/// Colored sheets that peek above a card on hover — the folder's fanned
/// files without preserve-3d.
struct FolderPeek: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) {
                ZStack {
                    sheet(Color(hex: 0xA18CD1), y: active ? -8 : 2, rot: 6, inset: 18)
                    sheet(Color(hex: 0x4FACFE), y: active ? -5 : 2, rot: -5, inset: 12)
                    sheet(Color(hex: 0xFFC371), y: active ? -3 : 2, rot: 3, inset: 8)
                }
                .opacity(active ? 0.70 : 0)
                .animation(Theme.Animation.smooth, value: active)
                .allowsHitTesting(false)
            }
    }

    private func sheet(_ color: Color, y: CGFloat, rot: Double, inset: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color)
            .frame(height: 16)
            .padding(.horizontal, inset)
            .offset(y: y)
            .rotationEffect(.degrees(rot))
    }
}

extension View {
    func folderPeek(_ active: Bool) -> some View {
        modifier(FolderPeek(active: active))
    }
}
