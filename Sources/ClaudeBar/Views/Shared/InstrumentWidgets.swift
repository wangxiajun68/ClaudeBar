import SwiftUI

/// Two compact rotors. Each click toggles that fan between max RPM and auto.
struct CompactFanPair: View {
    let fans: [FanInfo]
    var onToggle: (FanInfo) -> Void = { _ in }

    private var shown: [FanInfo] {
        fans.isEmpty ? [] : Array(fans.prefix(2))
    }

    var body: some View {
        HStack(spacing: 6) {
            if shown.isEmpty {
                SoftRotor(rpm: 0, maxRPM: 1, tint: Theme.statusIdle, forced: false, size: 44)
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, fan in
                    Button {
                        onToggle(fan)
                    } label: {
                        VStack(spacing: 2) {
                            SoftRotor(
                                rpm: fan.rpm,
                                maxRPM: fan.maxRPM,
                                tint: bladeTint(fan),
                                forced: !fan.mode.isAutomatic,
                                size: 42
                            )
                            Text(shortName(fan, index: index))
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundColor(fan.mode.isAutomatic ? Theme.textTertiary() : bladeTint(fan))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(help(fan))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortName(_ fan: FanInfo, index: Int) -> String {
        let raw = fan.name.trimmingCharacters(in: .whitespaces)
        if raw.localizedCaseInsensitiveContains("left") || raw.contains("左") { return "左" }
        if raw.localizedCaseInsensitiveContains("right") || raw.contains("右") { return "右" }
        return index == 0 ? "左" : "右"
    }

    private func help(_ fan: FanInfo) -> String {
        if fan.mode.isAutomatic {
            return "\(fan.name) 自动 \(fan.rpm) rpm · 点击拉到最大"
        }
        return "\(fan.name) 手动 \(fan.rpm) / \(fan.maxRPM) rpm · 点击恢复自动"
    }

    private func bladeTint(_ fan: FanInfo) -> Color {
        if !fan.mode.isAutomatic { return Theme.chartAmber }
        let load = Double(fan.rpm) / Double(max(fan.maxRPM, 1))
        if load > 0.88 { return Theme.statusError }
        if load > 0.65 { return Theme.chartAmber }
        return Theme.claude
    }
}

/// Open three-blade rotor whose spin tracks RPM (12°/s at the floor, 58°/s
/// at rated max — about 30 s … 6 s per turn).
///
/// The blades are a Core Animation layer with one endless rotation, so the
/// spin is interpolated by the render server at the display's refresh rate
/// and costs the app no per-frame work — the previous 20 Hz Canvas timeline
/// re-ran layout on the main thread for every tick and still looked choppy.
/// RPM changes retime the layer in place (`RotorLayerView.setSpeed`), so the
/// blades never snap back to rest.
struct SoftRotor: View {
    var rpm: Int
    var maxRPM: Int
    var tint: Color
    var forced: Bool
    var size: CGFloat = 48

    @State private var mounted = false
    @Environment(\.surfaceIsVisible) private var windowVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spinning: Bool { mounted && windowVisible && rpm >= 80 && !reduceMotion }

    private var degreesPerSecond: Double {
        guard spinning else { return 0 }
        let load = min(1, Double(rpm) / Double(max(maxRPM, 1)))
        return 12 + load * 46
    }

    var body: some View {
        ZStack {
            if forced {
                Circle()
                    .stroke(tint.opacity(0.25), lineWidth: 1)
                    .frame(width: size * 0.92, height: size * 0.92)
            }
            RotorLayer(tint: NSColor(tint), degreesPerSecond: degreesPerSecond)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear { mounted = true }
        .onDisappear { mounted = false }
        .accessibilityHidden(true)
    }
}

private struct RotorLayer: NSViewRepresentable {
    let tint: NSColor
    let degreesPerSecond: Double

    func makeNSView(context: Context) -> RotorLayerView { RotorLayerView() }

    func updateNSView(_ view: RotorLayerView, context: Context) {
        view.apply(tint: tint, degreesPerSecond: degreesPerSecond)
    }
}

final class RotorLayerView: NSView {
    private let rotor = CALayer()
    private let blades = CAShapeLayer()
    private let hub = CAShapeLayer()
    private var pathSide: CGFloat = 0
    private static let spinKey = "spin"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        rotor.speed = 0
        rotor.addSublayer(blades)
        rotor.addSublayer(hub)
        layer?.addSublayer(rotor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotor.bounds = CGRect(origin: .zero, size: bounds.size)
        rotor.position = CGPoint(x: bounds.midX, y: bounds.midY)
        blades.frame = rotor.bounds
        hub.frame = rotor.bounds
        let side = min(bounds.width, bounds.height)
        if side != pathSide, side > 0 {
            pathSide = side
            rebuildPaths(side: side)
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [rotor, blades, hub].forEach { $0.contentsScale = scale }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ensureAnimation()
    }

    func apply(tint: NSColor, degreesPerSecond: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blades.fillColor = tint.withAlphaComponent(0.85).cgColor
        hub.fillColor = tint.cgColor
        CATransaction.commit()
        ensureAnimation()
        setSpeed(Float(degreesPerSecond / 360))
    }

    private func rebuildPaths(side: CGFloat) {
        let center = CGAffineTransform(translationX: side / 2, y: side / 2)
        let blade = RotorBlade().path(in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
        let rotorPath = CGMutablePath()
        for index in 0..<3 {
            let angle = (18 + Double(index) * 120) * .pi / 180
            let transform = CGAffineTransform(rotationAngle: angle).concatenating(center)
            rotorPath.addPath(blade.cgPath, transform: transform)
        }
        blades.path = rotorPath
        let hubRadius = side * 0.045
        hub.path = CGPath(ellipseIn: CGRect(x: side / 2 - hubRadius, y: side / 2 - hubRadius,
                                            width: hubRadius * 2, height: hubRadius * 2), transform: nil)
    }

    /// One turn per second of layer time; `speed` scales it to the RPM.
    private func ensureAnimation() {
        guard rotor.animation(forKey: Self.spinKey) == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 1
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        rotor.add(spin, forKey: Self.spinKey)
    }

    /// Retimes the layer without a jump: freeze the current local time into
    /// `timeOffset`, restart the clock now, then apply the new rate.
    private func setSpeed(_ speed: Float) {
        guard rotor.speed != speed else { return }
        let now = CACurrentMediaTime()
        let local = rotor.convertTime(now, from: nil)
        rotor.timeOffset = local
        rotor.beginTime = now
        rotor.speed = speed
    }
}
