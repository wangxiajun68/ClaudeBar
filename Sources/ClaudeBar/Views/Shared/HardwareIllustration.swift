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

    /// Lucide's own grid. The outline is authored in these units.
    static let grid = LucideHardwareGeometry.grid

    var body: some View {
        let level = Self.clamp(load)
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: !Self.animates(level,
                                                       reduceMotion: reduceMotion,
                                                       visible: surfaceVisible))) { timeline in
            Canvas { ctx, size in
                var c = ctx
                // Two stacked lanes, and the split is the design:
                //
                //   ┌──────────────────────────┐
                //   │   Lucide's icon, 24pt    │  ← which part is this
                //   ├──────────────────────────┤
                //   │   ▮▮▮▮▮▮▮▮▮▮▮▮  (a row)  │  ← how busy is it
                //   └──────────────────────────┘
                //
                // The first attempt squeezed the reading *inside* the artwork and
                // the two fought each other: bars crossed the GPU's port circles
                // and the DIMM's chip windows. Giving the reading its own lane
                // keeps the icon legible as an icon and the reading legible as a
                // reading — neither has to compromise for the other.
                let laneH = max(13, size.height * 0.22)
                let iconH = size.height - laneH - 7
                let side = min(size.width, iconH)
                let s = side / Self.grid
                let iconRect = CGRect(x: (size.width - Self.grid * s) / 2,
                                      y: 0,
                                      width: Self.grid * s, height: Self.grid * s)
                let lane = CGRect(x: (size.width - Self.grid * s) / 2,
                                  y: iconRect.maxY + 7,
                                  width: Self.grid * s, height: laneH)

                // 1. The icon: Lucide's own stroke spec (2pt, round joins).
                var icon = c
                icon.translateBy(x: iconRect.minX, y: iconRect.minY)
                icon.scaleBy(x: s, y: s)
                let outline = LucideHardwareGeometry.path(for: Self.outline(for: kind))
                icon.fill(outline, with: .color(tint.opacity(0.09)))
                icon.stroke(outline, with: .color(tint),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                // 2. The reading, in its own lane.
                let t = Self.phase(level: level, at: timeline.date)
                Self.drawReading(kind: kind, level: level, cells: cells, wells: wells,
                                 t: t, tint: tint, lane: lane, ctx: &c)
            }
        }
        .accessibilityHidden(true)
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

    /// 0…1 for one sweep. Rate ∝ the reading, derived from absolute time so a
    /// load change speeds the sweep up rather than restarting it.
    static func phase(level: Double, at date: Date) -> Double {
        let secs = date.timeIntervalSinceReferenceDate * (0.35 + clamp(level) * 1.35)
        return secs.truncatingRemainder(dividingBy: 1)
    }

    /// Where each icon keeps the space that is legitimately a "gauge": inside the
    /// die (CPU), inside the shroud (GPU), inside the modules (内存/硬盘). These
    /// rects are in Lucide's own 24pt space and were chosen to sit inside the
    /// stroked outline rather than crossing it.
    /// The reading, laid out in a lane under the icon.
    ///
    /// One bar per unit — one per logical core for the CPU, one per graphics
    /// sub-unit for the GPU, one per area for 内存 / 硬盘 — each filled from its
    /// own baseline by its own value. The bars are separated enough to be
    /// *countable*: "twelve cores, six of them busy" has to be readable off the
    /// mark, which is the only reason to draw twelve of anything.
    private static func drawReading(kind: Kind, level: Double, cells: [Double],
                                    wells: [Double], t: Double, tint: Color,
                                    lane: CGRect, ctx: inout GraphicsContext) {
        let values: [Double]
        switch kind {
        case .cpu, .gpu: values = cells.isEmpty ? [level] : cells.map(clamp)
        case .memory, .disk: values = (wells.isEmpty ? [level] : wells).map(clamp)
        }

        // The lane's own track, so the bars read as a gauge on a rail rather
        // than as loose marks under a picture.
        ctx.fill(Path(roundedRect: lane, cornerRadius: lane.height * 0.28),
                 with: .color(tint.opacity(0.12)))

        let count = max(1, values.count)
        let gap: CGFloat = count > 10 ? 1.0 : (count > 6 ? 1.4 : 2.2)
        let barW = (lane.width - gap * CGFloat(count - 1)) / CGFloat(count)
        guard barW > 0.3 else { return }
        for (index, value) in values.enumerated() {
            let rect = CGRect(x: lane.minX + CGFloat(index) * (barW + gap), y: lane.minY,
                              width: barW, height: lane.height)
            let busy = value > 0.04
            // Bars grow from the lane's baseline: height ∝ the reading, so the
            // shape of the row *is* the shape of the load.
            let h = busy ? max(lane.height * 0.34, lane.height * CGFloat(value)) : lane.height * 0.34
            let bar = CGRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h)
            let radius = min(lane.height * 0.30, barW * 0.42)
            ctx.fill(Path(roundedRect: bar, cornerRadius: radius),
                     with: .color(busy ? tint.opacity(0.50 + value * 0.50)
                                       : tint.opacity(0.24)))
            if busy { sweep(bar, t, tint, &ctx, opacity: 0.5, corner: radius) }
        }
    }

    /// The light sweep: an angled highlight crossing `r`, clipped to it.
    private static func sweep(_ r: CGRect, _ t: Double, _ tint: Color,
                              _ ctx: inout GraphicsContext,
                              opacity: Double, corner: CGFloat) {
        var layer = ctx
        layer.clip(to: Path(roundedRect: r, cornerRadius: corner))
        let travel = r.width + r.height
        let head = r.minX - r.height + travel * CGFloat(t)
        let w = max(r.height, 1.2) * 1.1
        layer.fill(Path(r.insetBy(dx: -1, dy: -1)),
                   with: .linearGradient(
                    Gradient(stops: [
                        .init(color: tint.opacity(0), location: 0),
                        .init(color: tint.opacity(opacity), location: 0.5),
                        .init(color: tint.opacity(0), location: 1)]),
                    startPoint: CGPoint(x: head - w, y: r.minY),
                    endPoint: CGPoint(x: head + w, y: r.maxY)))
    }
}
