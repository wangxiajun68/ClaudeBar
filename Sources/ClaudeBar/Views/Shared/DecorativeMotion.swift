import AppKit
import SwiftUI

/// Repeating decoration is interpolated by the render server. No timer,
/// TimelineView, per-frame path construction, or SwiftUI layout is involved.
struct DecorativeMotion: NSViewRepresentable {
    enum Kind { case sparkles, sweep, orbit, pulse, scan, conveyor, arc }
    let kind: Kind
    var tint: Color = .white
    var active: Bool
    /// Stroke width for `kind == .arc`; ignored by the others. `nil` means a
    /// default proportional to the view's size.
    var lineWidth: CGFloat?

    func makeNSView(context: Context) -> MotionLayerView { MotionLayerView() }
    func updateNSView(_ view: MotionLayerView, context: Context) {
        view.apply(kind: kind, tint: NSColor(tint), active: active, lineWidth: lineWidth)
    }
    static func dismantleNSView(_ view: MotionLayerView, coordinator: ()) { view.stop() }
}

final class MotionLayerView: NSView {
    private var kind: DecorativeMotion.Kind = .sparkles
    private var tint = NSColor.white
    private var active = false
    private var lineWidth: CGFloat?
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

    func apply(kind: DecorativeMotion.Kind, tint: NSColor, active: Bool, lineWidth: CGFloat? = nil) {
        let rebuild = self.kind != kind || self.tint != tint || self.lineWidth != lineWidth
        self.kind = kind
        self.tint = tint
        self.active = active
        self.lineWidth = lineWidth
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
        case .conveyor:
            // The belt card's travelling ticks. One gradient carrying a whole
            // run of ticks slides by exactly one tick pitch per cycle, so the
            // pattern is continuous at the loop point — a single moving band
            // would read as a scan line, not a belt.
            //
            // The travel is `transform.translation.x`, not `position.x`:
            // `position` *is* how a layer's frame is placed, so animating it
            // would yank the belt off the strip on the first frame.
            let pitch = max(14, h * 0.9)
            let ticks = max(3, Int(ceil(w / pitch)) + 3)
            let span = CGFloat(ticks) * pitch
            let belt = CAGradientLayer()
            belt.startPoint = CGPoint(x: 0, y: 0.5)
            belt.endPoint = CGPoint(x: 1, y: 0.5)
            // `locations` are fractions of the layer's *own* width, so the layer
            // must be exactly `ticks` pitches wide for one 4-stop group to span
            // exactly one pitch. It is anchored one pitch left of the strip and
            // travelled by exactly `pitch`: at that point the pattern has moved
            // onto itself, so the loop point is invisible, and the extra two
            // ticks keep the strip covered for the whole cycle.
            // (A frame of `span * 2` with a travel of `pitch` shifted the
            // pattern by half a group, which reads as a hitch every 1.1 s.)
            belt.frame = CGRect(x: -pitch, y: 0, width: span, height: h)
            let stops = ticks * 4
            belt.locations = (0...stops).map { NSNumber(value: Double($0) / Double(stops)) }
            belt.colors = (0...stops).map { index in
                let phase = index % 4
                let alpha: CGFloat = phase == 1 ? 0.85 : (phase == 2 ? 0.35 : 0)
                return tint.withAlphaComponent(alpha).cgColor
            }
            layer.addSublayer(belt)
            let travel = CABasicAnimation(keyPath: "transform.translation.x")
            travel.fromValue = 0
            travel.toValue = pitch
            travel.duration = 1.1
            travel.repeatCount = .infinity
            travel.timingFunction = CAMediaTimingFunction(name: .linear)
            tracks.append((belt, travel))
        case .arc:
            // `IslandOrbit`: a 100° gradient-tailed arc, one turn per 1.1 s.
            //
            // Ported from SwiftUI (`.trim` + `.stroke(AngularGradient)` +
            // `.rotationEffect` under a `repeatForever`). That version kept an
            // animated transaction in flight for as long as the island drew a
            // busy badge, and while a transaction is in flight *every* display
            // cycle re-runs the whole hosting view's layout — the island's
            // panel is the full expanded box even when collapsed, so each one
            // laid out 640 × 386. Swapping the two builds under the same
            // launcher and sampling them alternately puts the share of
            // main-thread samples inside `NSHostingView.layout()` at a median
            // 48.8 % for the old arc and 31.9 % for this one, disjoint ranges,
            // with the transaction count falling from ≈420 to ≈285. See
            // `docs/technical/17-ui-audit-backlog.md` §7.
            //
            // Composition, from the inside out: a conic gradient carries the
            // fade, a shape trims it to the arc's 100°, and the whole thing
            // spins.
            //
            // Two conventions have to line up to reproduce the original, and
            // each was measured rather than assumed. The harness renders the
            // layers through `bitmapImageRepForCachingDisplay` and reads the
            // alpha back out at one-degree steps along the stroke's centreline,
            // so these are numbers, not impressions:
            //
            //  * The conic's `locations` are fractions of the **whole turn**,
            //    not of the trimmed arc. So the ramp has to *stop* at `sweep`:
            //    `[clear, tint]` at `[0, sweep]` fades steadily across the arc,
            //    matching the original's `AngularGradient(endAngle: 100°)`. An
            //    earlier three-stop version — `[0, .9·sweep, sweep]` — held full
            //    tint across most of the arc and then dropped off a cliff, so the
            //    port read as a heavy ring segment rather than a tail.
            //  * The trim path must start where the conic's phase 0 is, or the
            //    taper falls outside the trimmed span and the whole arc lights up
            //    flat. An earlier version used `CGPath(ellipseIn:)` with
            //    `strokeStart`/`strokeEnd`, whose start point is a quarter turn
            //    away from the phase — enough to trigger exactly that failure.
            //    Here `startAngle: -.pi / 2` with `clockwise: false` is the
            //    combination that lines up; sweeping the offset in quarter turns
            //    and scoring each against the original gives a mean |Δalpha| of
            //    2.50/255 for this one against 29–38/255 for the others, whose
            //    bands balloon from 56° wide to 92–107° (the flat-lighting
            //    signature).
            //
            // What is left is a constant quarter turn between where this arc
            // sits and where the original sits. Chasing it is not worthwhile: a
            // conic is periodic, so re-anchoring phase 0 also slides the ramp,
            // and the one attempt to do both regressed to the flat case above.
            // The arc never stops rotating and its head bears no fixed relation
            // to the badge, so a viewer has nothing to compare the phase against.
            //
            // At the best alignment the profiles match to 2.50/255 mean: both
            // fade 0 → full tint over ~100°, 54–56° of them above half brightness.
            // Rotation direction was checked the same way, by sampling the head
            // at two known times: +16° here against +14° on the original over
            // the same interval — both clockwise on screen.
            let width = lineWidth ?? max(1.5, w * 0.075)
            let sweep: CGFloat = 0.28
            let ring = CAGradientLayer()
            ring.frame = bounds
            ring.type = .conic
            ring.startPoint = CGPoint(x: 0.5, y: 0.5)
            ring.endPoint = CGPoint(x: 0.5, y: 0)
            ring.colors = [tint.withAlphaComponent(0).cgColor, tint.cgColor]
            ring.locations = [0, NSNumber(value: Double(sweep))]
            let tail = CAShapeLayer()
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: w / 2, y: h / 2),
                        radius: max(0, (min(w, h) - width) / 2),
                        startAngle: -.pi / 2,
                        endAngle: -.pi / 2 + .pi * 2 * sweep,
                        clockwise: false)
            tail.path = path
            tail.fillColor = nil
            tail.strokeColor = NSColor.white.cgColor
            tail.lineWidth = width
            tail.lineCap = .round
            tail.contentsScale = window?.backingScaleFactor ?? 2
            ring.mask = tail
            layer.addSublayer(ring)
            tracks.append((ring, motion("transform.rotation.z", from: 0, to: .pi * 2, duration: 1.1)))
        }
    }
}
