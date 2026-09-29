import AppKit
import SwiftUI

/// The live hardware marks on the 概览 resource strip.
///
/// **The outline is Lucide's, not this file's.** `LucideHardwareGeometry` holds
/// the four icons converted straight from Lucide's own SVGs (`cpu`, `gpu`,
/// `memory-stick`, `hard-drive`), so the marks are drawn to a real icon system's
/// spec — one 24pt grid, one stroke weight, round caps and joins — instead of
/// being silhouettes invented here. An earlier version hand-authored its shapes
/// on a Canvas; the result was recognisable-ish and plainly amateur, because
/// inventing curve geometry by eye does not produce designed curves.
///
/// What this file adds on top of the icon is the **reading**, which is the whole
/// reason the mark exists:
///
/// - the outline is stroked in the tile's hue, and
/// - a *live layer* sits inside it: one bar per logical core (CPU), per graphics
///   sub-unit (GPU) or per area (内存 / 硬盘), each filled by its own reading,
///   plus a light sweep that crosses the mark at a rate proportional to the
///   tile's own figure.
///
/// So the shape says *which part it is* and the interior says *how busy it is* —
/// two jobs, drawn by two different means. Below ~4 % the sweep stops: an idle
/// machine must not animate chrome. Reduce Motion and an off-screen surface stop
/// it too.
struct HardwareIllustration: View {
    enum Kind { case cpu, gpu, memory, disk }

    let kind: Kind
    /// 0…1, the tile's own reading. Drives the sweep.
    let load: Double
    let tint: Color
    /// Per-unit readings: one per logical core (CPU) or per graphics sub-unit
    /// (GPU). Empty means "no breakdown published" — the interior then falls back
    /// to a single bar at `load` rather than inventing units it cannot measure.
    var cells: [Double] = []
    /// 0…1 per area, for 内存 / 硬盘. Empty falls back to `load`.
    var wells: [Double] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceIsVisible) private var surfaceVisible
    /// The mark fixture renders with `ImageRenderer`, which snapshots an
    /// `NSViewRepresentable` over the canvas and replaces the bars. The live
    /// app leaves this at its default.
    @Environment(\.rendersHardwareSweep) private var rendersSweep

    /// Lucide's own grid. The outline is authored in these units.
    static let grid = LucideHardwareGeometry.grid

    var body: some View {
        let level = Self.clamp(load)
        let moving = Self.animates(level, reduceMotion: reduceMotion, visible: surfaceVisible)
        // The icon and the bars are a reading: they change when the sampler
        // does, about once a second. The highlight used to be redrawn from a
        // display-linked clock wrapped around this canvas, and that clock lays
        // the whole window out on every refresh — measured at roughly ten
        // points of a core for a clock whose content was a filled rectangle.
        // The highlight is the same drawing, moved by Core Animation
        // (`ReadingSweep`) instead.
        Canvas { ctx, size in
            let placed = Self.placement(in: size)
            var icon = ctx
            icon.translateBy(x: placed.icon.minX, y: placed.icon.minY)
            icon.scaleBy(x: placed.scale, y: placed.scale)
            // The path itself is cached per kind — see
            // `LucideHardwareGeometry.path(for:)`. It is a constant drawing.
            let outline = LucideHardwareGeometry.path(for: Self.outline(for: kind))
            icon.fill(outline, with: .color(tint.opacity(0.09)))
            icon.stroke(outline, with: .color(tint),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            Self.drawReading(kind: kind, level: level, cells: cells, wells: wells,
                             tint: tint, lane: placed.lane, ctx: &ctx)
        }
        // A 1 Hz reading must not open an animation transaction. Bar height
        // would otherwise interpolate, and an in-flight transaction lays the
        // hosting view out on every display cycle. The sweep is not in this
        // transaction: it is a layer, and `transaction` cannot freeze it.
        .transaction { $0.animation = nil }
        .overlay {
            if rendersSweep {
                ReadingSweep(kind: kind, level: level, cells: cells, wells: wells,
                             tint: tint, active: moving)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }

    /// Icon on top, reading lane beneath. One function, so the canvas and the
    /// sweep layer clip to the same bars.
    ///
    /// Two stacked lanes, and the split is the design:
    ///
    ///   ┌──────────────────────────┐
    ///   │   Lucide's icon, 24pt    │  ← which part is this
    ///   ├──────────────────────────┤
    ///   │   ▮▮▮▮▮▮▮▮▮▮▮▮  (a row)  │  ← how busy is it
    ///   └──────────────────────────┘
    ///
    /// The first attempt squeezed the reading *inside* the artwork and the two
    /// fought each other: bars crossed the GPU's port circles and the DIMM's
    /// chip windows. The lane is sized from the icon, not from the box: at
    /// 130pt the old `height * 0.22` gave the icon a hair under half the slot
    /// and the bars a lane thicker than the gap between two DIMM pads. Tying
    /// the lane to the *icon's* side keeps the mark the same drawing at every
    /// size the app hands it. The clamp keeps a short popover mark from paying
    /// 20pt of its height for a lane.
    static func placement(in size: CGSize) -> (icon: CGRect, lane: CGRect, scale: CGFloat) {
        let laneH = min(max(12, size.height * 0.17), max(12, size.height * 0.26))
        let iconH = size.height - laneH - 7
        let side = min(size.width, iconH)
        let scale = side / grid
        let icon = CGRect(x: (size.width - grid * scale) / 2, y: 0,
                          width: grid * scale, height: grid * scale)
        let lane = CGRect(x: icon.minX, y: icon.maxY + 7, width: icon.width, height: laneH)
        return (icon, lane, scale)
    }

    /// The one place the app decides which *other* kind of glyph stands in for a
    /// machine mark.
    ///
    /// `InstrumentGlyph` owns one symbol table (`InstrumentGlyph.kind(for:)`);
    /// it is what the navigation, the tiles and every popover name their marks
    /// with. It has no case for the Lucide hardware marks because they are a
    /// different drawing on a different grid — but a surface that wants to
    /// *show* a machine reading and already holds an `InstrumentGlyph.Kind`
    /// should not have to grow a second switch to find its way here. Hence this
    /// bridge, which is the whole of the mapping.
    ///
    /// Only the four marks that exist on both sides are here. There is
    /// deliberately no case for `.fan`: a fan is a rotor whose speed is a
    /// reading in its own right (`LucideRotor`), and drawing it as a static
    /// outline with a bar under it would be the one place the app states a fan's
    /// speed twice.
    static func mark(for kind: InstrumentGlyph.Kind) -> Kind? {
        switch kind {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory: return .memory
        case .disk: return .disk
        default: return nil
        }
    }

    static func outline(for kind: Kind) -> LucideHardwareGeometry.Kind {
        switch kind {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory: return .memory
        case .disk: return .disk
        }
    }

    // MARK: - Reading

    static func clamp(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }

    /// Below 4 % the mark is still.
    static func animates(_ level: Double, reduceMotion: Bool, visible: Bool) -> Bool {
        visible && !reduceMotion && clamp(level) >= 0.04
    }

    /// One bar of the reading lane. `busy` is what receives a sweep.
    struct LaneBar: Equatable {
        var rect: CGRect
        var radius: CGFloat
        var busy: Bool
    }

    /// The bars under `lane`, in core / sub-unit / area order.
    static func laneBars(kind: Kind, level: Double, cells: [Double], wells: [Double],
                         lane: CGRect) -> [LaneBar] {
        let values = readings(kind: kind, level: level, cells: cells, wells: wells)
        let count = max(1, values.count)
        let gap: CGFloat = count > 10 ? 1.0 : (count > 6 ? 1.4 : 2.2)
        let barW = (lane.width - gap * CGFloat(count - 1)) / CGFloat(count)
        guard barW > 0.3 else { return [] }
        return values.enumerated().map { index, value in
            let column = CGRect(x: lane.minX + CGFloat(index) * (barW + gap), y: lane.minY,
                                width: barW, height: lane.height)
            let busy = value > 0.04
            let h = busy ? max(lane.height * 0.34, lane.height * CGFloat(value)) : lane.height * 0.34
            let bar = CGRect(x: column.minX, y: column.maxY - h, width: column.width, height: h)
            return LaneBar(rect: bar, radius: min(lane.height * 0.30, barW * 0.42), busy: busy)
        }
    }

    /// Cycles per second of the highlight. The old canvas used
    /// `time * (0.35 + level * 1.35)` modulo one; this is that coefficient.
    static func sweepRate(level: Double) -> Double {
        0.35 + clamp(level) * 1.35
    }

    private static func readings(kind: Kind, level: Double, cells: [Double], wells: [Double]) -> [Double] {
        let source: [Double]
        switch kind {
        case .cpu, .gpu: source = cells.isEmpty ? [level] : cells
        case .memory, .disk: source = wells.isEmpty ? [level] : wells
        }
        var values = source
        for index in values.indices { values[index] = clamp(values[index]) }
        return values
    }

    /// The reading, laid out in a lane under the icon.
    ///
    /// One bar per unit — one per logical core for the CPU, one per graphics
    /// sub-unit for the GPU, one per area for 内存 / 硬盘 — each filled from its
    /// own baseline by its own value. The bars are separated enough to be
    /// *countable*: "twelve cores, six of them busy" has to be readable off the
    /// mark, which is the only reason to draw twelve of anything. The travelling
    /// highlight is not drawn here; `ReadingSweep` owns it.
    private static func drawReading(kind: Kind, level: Double, cells: [Double],
                                    wells: [Double], tint: Color,
                                    lane: CGRect, ctx: inout GraphicsContext) {
        let values = readings(kind: kind, level: level, cells: cells, wells: wells)
        // The lane's own track, so the bars read as a gauge on a rail rather
        // than as loose marks under a picture.
        ctx.fill(Path(roundedRect: lane, cornerRadius: lane.height * 0.28),
                 with: .color(tint.opacity(0.12)))

        for (bar, value) in zip(laneBars(kind: kind, level: level, cells: cells, wells: wells, lane: lane), values) {
            ctx.fill(Path(roundedRect: bar.rect, cornerRadius: bar.radius),
                     with: .color(bar.busy ? tint.opacity(0.50 + value * 0.50)
                                           : tint.opacity(0.24)))
        }
    }
}

private struct HardwareSweepKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Off only for the raster fixture. See `HardwareIllustration`.
    var rendersHardwareSweep: Bool {
        get { self[HardwareSweepKey.self] }
        set { self[HardwareSweepKey.self] = newValue }
    }
}

// MARK: - Sweep

/// The angled highlight that used to be stroked inside the 30 Hz canvas.
///
/// One gradient per busy bar, clipped to that bar, translated by a repeating
/// linear animation. `speed` is `HardwareIllustration.sweepRate` (cycles per
/// second of a one-second animation), retimed with `timeOffset` the way
/// `LucideRotor` retimes a blade, so a new reading does not jump the highlight
/// back to the start. Below the idle threshold, under Reduce Motion, or while
/// the surface or the window is hidden, `speed` is 0 and the highlight is not
/// drawn. Nothing here invalidates SwiftUI.
private struct ReadingSweep: NSViewRepresentable {
    var kind: HardwareIllustration.Kind
    var level: Double
    var cells: [Double]
    var wells: [Double]
    var tint: Color
    var active: Bool

    func makeNSView(context: Context) -> ReadingSweepView { ReadingSweepView() }

    func updateNSView(_ view: ReadingSweepView, context: Context) {
        view.kind = kind
        view.level = level
        view.cells = cells
        view.wells = wells
        view.tint = NSColor(tint)
        view.active = active
        view.sync()
    }
}

final class ReadingSweepView: NSView {
    var kind: HardwareIllustration.Kind = .cpu
    var level: Double = 0
    var cells: [Double] = []
    var wells: [Double] = []
    var tint = NSColor.white
    var active = false

    private struct TintKey: Equatable {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
        var a: CGFloat
    }

    private var bars: [HardwareIllustration.LaneBar] = []
    private var paintedTint: TintKey?
    private var sheens: [CALayer] = []
    private var speed: Float = -1
    private var running = false
    private var observer: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // No layer until the view is in a window. `ImageRenderer` (the mark
        // regression) snapshots an `NSViewRepresentable` that already owns a
        // layer, and that snapshot replaces the canvas. The bars are what the
        // fixture measures; the highlight does not exist off-screen.
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func layout() {
        super.layout()
        sync()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let window {
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.sync() }
        }
        sync()
    }

    func sync() {
        guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
        if layer == nil {
            wantsLayer = true
            let host = CALayer()
            host.masksToBounds = false
            // The view is flipped. A layer-hosting view does not inherit that,
            // and the bar frames are in the canvas's top-left coordinates.
            host.isGeometryFlipped = true
            layer = host
        }
        let placed = HardwareIllustration.placement(in: bounds.size)
        let next = HardwareIllustration.laneBars(kind: kind, level: level, cells: cells,
                                                 wells: wells, lane: placed.lane)
        let resolved = Self.components(tint)
        let tintChanged = paintedTint != resolved
        // A new reading changes bar heights, so the layers are rebuilt. The
        // phase is taken first: otherwise every sample would snap the
        // highlight back to the leading edge.
        let carried = running ? capturePhase() : 0
        let wasRunning = running
        if next != bars || tintChanged || sheens.count != next.filter(\.busy).count {
            bars = next
            paintedTint = resolved
            rebuild(next)
        }
        let visible = window?.occlusionState.contains(.visible) == true
        let shouldRun = active && visible
        let rate = shouldRun ? Float(HardwareIllustration.sweepRate(level: level)) : 0
        if shouldRun != running {
            running = shouldRun
            // Coming back from a pause starts at the leading edge. A rebuild
            // while the sweep was already running keeps the phase it had.
            if shouldRun { restart(rate: rate, phase: wasRunning ? carried : 0) }
            else { setSpeed(0, hide: true) }
        } else if shouldRun {
            setSpeed(rate, hide: false)
        }
    }

    private func capturePhase() -> Double {
        guard let sheen = sheens.first else { return 0 }
        let local = sheen.convertTime(CACurrentMediaTime(), from: nil)
        var phase = local.truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        return phase
    }

    private func rebuild(_ bars: [HardwareIllustration.LaneBar]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheens.forEach { $0.removeFromSuperlayer() }
        sheens.removeAll()
        let peak = tint.withAlphaComponent(0.5)
        let clear = peak.withAlphaComponent(0)
        for bar in bars where bar.busy {
            let clip = CALayer()
            clip.frame = bar.rect
            clip.cornerRadius = bar.radius
            clip.masksToBounds = true
            let band = max(bar.rect.height, 1.2) * 1.1
            let sheen = CAGradientLayer()
            sheen.frame = CGRect(x: 0, y: 0, width: band * 2, height: bar.rect.height)
            sheen.colors = [clear.cgColor, peak.cgColor, clear.cgColor]
            sheen.locations = [0, 0.5, 1]
            // Top-left to bottom-right: the canvas gradient ran from
            // `(head - w, minY)` to `(head + w, maxY)`.
            sheen.startPoint = CGPoint(x: 0, y: 0)
            sheen.endPoint = CGPoint(x: 1, y: 1)
            sheen.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            // Centre sits one bar-height off the leading edge at t = 0, and on
            // the trailing edge at t = 1. Travel is `width + height`, the same
            // span the canvas used (`r.width + r.height`).
            sheen.opacity = 0
            sheen.position = CGPoint(x: -bar.rect.height, y: bar.rect.height / 2)
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = -bar.rect.height
            move.toValue = bar.rect.width
            move.duration = 1
            move.repeatCount = .infinity
            move.timingFunction = CAMediaTimingFunction(name: .linear)
            move.isRemovedOnCompletion = false
            sheen.speed = 0
            sheen.add(move, forKey: "sweep")
            clip.addSublayer(sheen)
            layer?.addSublayer(clip)
            sheens.append(sheen)
        }
        CATransaction.commit()
        speed = -1
        running = false
    }

    /// `phase` is 0…1 through one pass. Zero after a pause; the value captured
    /// before a rebuild when the sweep was already moving.
    private func restart(rate: Float, phase: Double) {
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sheen in sheens {
            sheen.opacity = 1
            sheen.timeOffset = phase
            sheen.beginTime = now
            sheen.speed = rate
        }
        CATransaction.commit()
        speed = rate
    }

    private static func components(_ color: NSColor) -> TintKey {
        guard let resolved = color.usingColorSpace(.sRGB) else { return TintKey(r: 0, g: 0, b: 0, a: 1) }
        return TintKey(r: resolved.redComponent, g: resolved.greenComponent,
                       b: resolved.blueComponent, a: resolved.alphaComponent)
    }

    /// Retimed in place. Freezing local time into `timeOffset` is what keeps
    /// the highlight from jumping when the sampler publishes a new rate.
    private func setSpeed(_ rate: Float, hide: Bool) {
        let hidden = sheens.first.map { $0.opacity == 0 } ?? hide
        guard rate != speed || hide != hidden else { return }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sheen in sheens {
            if !hide, rate != speed {
                let local = sheen.convertTime(now, from: nil)
                sheen.timeOffset = local
                sheen.beginTime = now
            }
            sheen.speed = rate
            sheen.opacity = hide ? 0 : 1
        }
        CATransaction.commit()
        speed = rate
    }
}
