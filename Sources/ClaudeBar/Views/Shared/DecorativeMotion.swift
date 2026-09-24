import AppKit
import SwiftUI

/// Repeating decoration is interpolated by the render server. No timer,
/// TimelineView, per-frame path construction, or SwiftUI layout is involved.
struct DecorativeMotion: NSViewRepresentable {
    enum Kind { case sparkles, sweep, orbit, pulse, scan }
    let kind: Kind
    var tint: Color = .white
    var active: Bool

    func makeNSView(context: Context) -> MotionLayerView { MotionLayerView() }
    func updateNSView(_ view: MotionLayerView, context: Context) {
        view.apply(kind: kind, tint: NSColor(tint), active: active)
    }
    static func dismantleNSView(_ view: MotionLayerView, coordinator: ()) { view.stop() }
}

final class MotionLayerView: NSView {
    private var kind: DecorativeMotion.Kind = .sparkles
    private var tint = NSColor.white
    private var active = false
    private var lastSize: CGSize = .zero
    private var tracks: [(CALayer, CAAnimation)] = []
    private var running = false
    private var observer: NSObjectProtocol?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func apply(kind: DecorativeMotion.Kind, tint: NSColor, active: Bool) {
        let rebuild = self.kind != kind || self.tint != tint
        self.kind = kind
        self.tint = tint
        self.active = active
        if rebuild || lastSize != bounds.size { rebuildLayers() }
        updatePlayback()
    }
    override func layout() {
        super.layout()
        if lastSize != bounds.size { rebuildLayers(); updatePlayback() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let window {
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.updatePlayback() }
        }
        updatePlayback()
    }
    func stop() {
        for (target, _) in tracks { target.removeAllAnimations() }
        running = false
    }
    private func updatePlayback() {
        let shouldRun = active && window?.occlusionState.contains(.visible) == true
        guard shouldRun != running else { return }
        stop()
        guard shouldRun else { return }
        for (target, animation) in tracks { target.add(animation, forKey: "decoration") }
        running = true
    }
    private func motion(_ key: String, from: Double, to: Double,
                        duration: Double, autoreverses: Bool = false) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = autoreverses
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: autoreverses ? .easeInEaseOut : .linear)
        return animation
    }
    private func shape(path: CGPath, color: NSColor) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.path = path
        shape.fillColor = color.cgColor
        shape.contentsScale = window?.backingScaleFactor ?? 2
        return shape
    }
    private func rebuildLayers() {
        stop()
        tracks.removeAll()
        lastSize = bounds.size
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.sublayers = []
        guard bounds.width > 0, bounds.height > 0 else { return }
        let w = bounds.width, h = bounds.height
        switch kind {
        case .sparkles:
            for (index, spec) in [(8.0, 8.0, 10.0), (13.0, 4.0, 6.0), (4.0, 13.0, 5.0)].enumerated() {
                let radius = spec.2 / 2
                let path = CGMutablePath()
                for vertex in 0..<8 {
                    let angle = Double(vertex) * .pi / 4
                    let r = vertex.isMultiple(of: 2) ? radius : radius * 0.27
                    let point = CGPoint(x: sin(angle) * r, y: cos(angle) * r)
                    if vertex == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                let star = shape(path: path, color: tint)
                star.position = CGPoint(x: spec.0, y: spec.1)
                layer.addSublayer(star)
                let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
                pulse.values = [1, 1, 1.22, 1, 1]
                let peak = [0.17, 0.49, 0.83][index]
                pulse.keyTimes = [0, NSNumber(value: peak - 0.08), NSNumber(value: peak), NSNumber(value: peak + 0.08), 1]
                pulse.duration = 1.5
                pulse.repeatCount = .infinity
                tracks.append((star, pulse))
            }
        case .sweep:
            let container = CALayer()
            container.frame = bounds
            let mask = CAShapeLayer()
            mask.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = 2
            container.mask = mask
            layer.addSublayer(container)
            let rotor = CALayer()
            rotor.position = CGPoint(x: w / 2, y: h / 2)
            let bar = CAGradientLayer()
            bar.frame = CGRect(x: 0, y: -10, width: max(w, h), height: 20)
            bar.colors = [NSColor.clear.cgColor, tint.cgColor, NSColor.clear.cgColor]
            rotor.addSublayer(bar)
            container.addSublayer(rotor)
            tracks.append((rotor, motion("transform.rotation.z", from: 0, to: .pi * 2, duration: 2)))
        case .orbit:
            let ring = CAGradientLayer()
            ring.frame = bounds
            ring.type = .conic
            ring.startPoint = CGPoint(x: 0.5, y: 0.5)
            ring.endPoint = CGPoint(x: 0.5, y: 0)
            ring.colors = [NSColor.white.withAlphaComponent(0.9).cgColor,
                           NSColor.white.withAlphaComponent(0.08).cgColor,
                           tint.withAlphaComponent(0.45).cgColor,
                           NSColor.white.withAlphaComponent(0.9).cgColor]
            let width = max(3, w * 0.09)
            let mask = CAShapeLayer()
            mask.path = CGPath(ellipseIn: bounds.insetBy(dx: width / 2, dy: width / 2), transform: nil)
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = width
            ring.mask = mask
            layer.addSublayer(ring)
            tracks.append((ring, motion("transform.rotation.z", from: .pi / 2, to: .pi * 2.5, duration: 2)))
            if w >= 36 {
                for (index, angle) in [70.0, 28, 130, 210, 320].enumerated() {
                    let radius = w * [0.62, 0.58, 0.70, 0.64, 0.60][index]
                    let star = shape(path: CGPath(ellipseIn: CGRect(x: -1.75, y: -1.75, width: 3.5, height: 3.5), transform: nil), color: .white)
                    star.position = CGPoint(x: w / 2 + cos(angle * .pi / 180) * radius,
                                            y: h / 2 + sin(angle * .pi / 180) * radius)
                    star.opacity = 0.25
                    layer.addSublayer(star)
                    let pulse = motion("opacity", from: 0.18, to: 0.32, duration: 1, autoreverses: true)
                    pulse.timeOffset = Double(index) * 0.18
                    tracks.append((star, pulse))
                }
            }
        case .pulse:
            let dot = shape(path: CGPath(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), transform: nil), color: tint)
            dot.position = CGPoint(x: w / 2, y: h / 2)
            dot.opacity = 0.22
            layer.addSublayer(dot)
            let group = CAAnimationGroup()
            group.animations = [motion("transform.scale", from: 10.0 / 18, to: 1, duration: 1.3, autoreverses: true),
                                motion("opacity", from: 0.14, to: 0.30, duration: 1.3, autoreverses: true)]
            group.duration = 2.6
            group.repeatCount = .infinity
            tracks.append((dot, group))
        case .scan:
            let line = CAGradientLayer()
            line.frame = bounds
            line.cornerRadius = w / 2
            line.colors = [NSColor.clear.cgColor, tint.cgColor, NSColor.clear.cgColor]
            line.opacity = 0.85
            layer.addSublayer(line)
            tracks.append((line, motion("transform.translation.x", from: -24, to: 24, duration: 1.6)))
        }
    }
}
