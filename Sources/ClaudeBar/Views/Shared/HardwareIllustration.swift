import SwiftUI

/// Vector hardware silhouettes drawn on a shared 100×76 grid.
///
/// The mark is *live*: every element carries a real reading rather than being a
/// decoration in a measurement's costume. What each shape is wired to:
///
/// - **CPU** — one cell per logical core, lit by that core's own busy fraction
///   (`ProcessSampler.HostStats.coreLoad`). A 12-core machine draws twelve
///   cells and no others; with no per-core baseline yet (the sampler's first
///   tick) the cells fall back to the aggregate so the mark never claims cores
///   it cannot see.
/// - **GPU** — one cell per sub-unit, lit by its own 0…100 reading
///   (`HostStats.gpuRenderers`). One unit per cell, so a three-unit GPU is
///   three cells; a driver that publishes none keeps the one honest aggregate.
/// - **内存 / 硬盘** — the same live idiom, split the other way: the mark's
///   wells are the *categories* the reading is made of (`memoryActive` /
///   `memoryWired` / `memoryCompressed`; `磁盘`'s used / free), each filled to
///   its own share of the total.
///
/// Load remains the fallback in every case, so a caller that has only one
/// number (a tooltip, a preview, a platform without the breakdown) still gets a
/// coherent picture instead of an empty one.
struct HardwareIllustration: View {
    enum Kind { case cpu, gpu, memory }
    let kind: Kind
    let load: Double
    let tint: Color
    /// The same reading `load` came from, as cells. Empty means "no per-cell
    /// breakdown available" — the caller passes `coreLoad` / `gpuRenderers` /
    /// `memoryParts` when it has them and nothing when it does not.
    var cells: [Double] = []
    /// 0…1 per well, for `内存` / `硬盘`, whose shape is fixed and whose
    /// reading is a set of category fills rather than a variable cell count.
    var wells: [Double] = []
    /// The terms the wells are in, formatted by the caller (it already owns the
    /// byte formatter). Passed as strings so this view never re-derives a
    /// label its owner printed differently.
    var wellCaptions: [String] = []

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 100, size.height / 76)
            context.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 76 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let level = Self.clamp(load)
            let lit = Self.litCells(reported: cells, fallback: level)
            func line(_ points: [CGPoint], color: Color, width: CGFloat = 1.5) {
                guard let first = points.first else { return }
                var path = Path(); path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            func plate(_ rect: CGRect, radius: CGFloat, opacity: Double) {
                let path = Path(roundedRect: rect, cornerRadius: radius)
                context.fill(path, with: .linearGradient(Gradient(colors: [tint.opacity(opacity), tint.opacity(opacity * 0.25)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                context.stroke(path, with: .color(tint.opacity(0.65)), lineWidth: 1.2)
            }

            switch kind {
            case .cpu:
                // Four-sided leads, stacked package and a luminous die. The die
                // is the core grid; its illumination is the only thing that
                // carries the load, and it carries it per core.
                for index in 0..<6 {
                    let p = CGFloat(30 + index * 8)
                    line([CGPoint(x: p, y: 6), CGPoint(x: p, y: 14)], color: tint.opacity(0.55), width: 2.5)
                    line([CGPoint(x: p, y: 62), CGPoint(x: p, y: 70)], color: tint.opacity(0.55), width: 2.5)
                    let y = CGFloat(18 + index * 8)
                    line([CGPoint(x: 16, y: y), CGPoint(x: 24, y: y)], color: tint.opacity(0.55), width: 2.5)
                    line([CGPoint(x: 76, y: y), CGPoint(x: 84, y: y)], color: tint.opacity(0.55), width: 2.5)
                }
                plate(CGRect(x: 24, y: 14, width: 52, height: 50), radius: 10, opacity: 0.2)
                plate(CGRect(x: 29, y: 18, width: 42, height: 40), radius: 7, opacity: 0.16)
                // Flat die surface under the core grid: the cells are opaque and
                // drawn on top, so the plate behind them must be a solid colour
                // rather than a gradient that varies cell to cell.
                context.fill(Path(roundedRect: CGRect(x: 34, y: 19, width: 32, height: 26), cornerRadius: 5),
                             with: .color(Theme.cardSurface))
                Self.drawCoreGrid(cells: lit, fallback: level, tint: tint, in: &context)
                context.draw(Text("CPU").font(.system(size: 7, weight: .heavy, design: .rounded)).foregroundColor(tint), at: CGPoint(x: 50, y: 60))
            case .gpu:
                // The card's own board, drawn to the same 100×76 grid the CPU
                // and memory use — not the 24-point Lucide glyph scaled up,
                // which left the card as a different drawing in a different
                // weight from its two neighbours. The sub-unit cells are this
                // drawing's version of the CPU die grid.
                Self.drawGPU(cells: lit, fallback: level, tint: tint, in: &context)
            case .memory:
                // Horizontal memory module, keyed edge connector and two IC
                // packages. The right-hand package is the pressure bar; the
                // left is the module's own identity mark.
                plate(CGRect(x: 9, y: 19, width: 82, height: 38), radius: 6, opacity: 0.15)
                let loaded = wells.isEmpty ? [level] : wells.map(Self.clamp)
                let active = loaded.first ?? level
                for x in [CGFloat(22), 53] {
                    // The package body is an opaque socket; the fill inside it is
                    // the reading, so the two ICs are two measurements rather
                    // than two copies of the same wash.
                    let body = Path(roundedRect: CGRect(x: x, y: 27, width: 25, height: 21), cornerRadius: 3)
                    context.fill(body, with: .color(tint.opacity(0.14)))
                    context.stroke(body, with: .color(tint.opacity(0.65)), lineWidth: 1.1)
                    let inner = CGRect(x: x + 3, y: 44 - 14 * active, width: 19, height: 14 * active)
                    if inner.height > 0.3 {
                        context.fill(Path(roundedRect: inner, cornerRadius: 1.5),
                                     with: .color(tint.opacity(0.42 + active * 0.45)))
                    }
                    for offset in [CGFloat(5), 12, 19] {
                        line([CGPoint(x: x + offset, y: 24), CGPoint(x: x + offset, y: 27)], color: tint.opacity(0.6), width: 1)
                    }
                }
                // The pressure bar: one segment per category, each filled to
                // its own share, so the bar is a sum of readings rather than a
                // second copy of the percentage printed above the mark.
                let bar = CGRect(x: 16, y: 50, width: 68, height: 4)
                context.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(tint.opacity(0.16)))
                var cursor = bar.minX
                for (index, share) in loaded.enumerated() {
                    let width = bar.width * CGFloat(share) / CGFloat(max(1, loaded.count))
                    guard width > 0.2 else { continue }
                    let segment = CGRect(x: cursor, y: bar.minY, width: width, height: bar.height)
                    context.fill(Path(roundedRect: segment, cornerRadius: 1),
                                 with: .color(tint.opacity(index == 0 ? 1 : (0.72 - Double(index) * 0.12))))
                    cursor += width
                }
                for x in [CGFloat(14), 84] {
                    context.stroke(Path(ellipseIn: CGRect(x: x, y: 23, width: 3, height: 3)), with: .color(tint.opacity(0.6)), lineWidth: 1)
                }
                // No caption inside the mark, deliberately.
                //
                // `内存` / `硬盘` already print their own byte line under the
                // drawing ("已使用 375.3 GB / 460.4 GB"), and at 7pt inside a
                // 100pt grid a second copy of the same figure did not fit: the
                // text overran the module it was labelling. The bar carries the
                // same information as a proportion, which is what a caption
                // could not do at this size.
                _ = wellCaptions
            }
        }.accessibilityHidden(true)
    }

    // MARK: - Readings

    static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    /// The caller's own per-cell readings, clamped. An empty result is
    /// meaningful: it means "no breakdown", and every shape has a fallback for
    /// it rather than inventing cells it cannot measure.
    private static func litCells(reported: [Double], fallback: Double) -> [Double] {
        _ = fallback
        guard !reported.isEmpty else { return [] }
        return reported.map(clamp)
    }

    // MARK: - CPU die

    /// One cell per logical core in a near-square grid inside the die.
    ///
    /// The die rect is 30×28. `columns` is chosen so the grid stays roughly
    /// square for any core count Apple ships (8, 10, 12, 14, 16, 20, 24) rather
    /// than always 3 — three columns for 12 cores would draw four rows 4.4pt
    /// tall, which is not a cell, it is a line.
    private static func drawCoreGrid(cells: [Double], fallback: Double, tint: Color, in context: inout GraphicsContext) {
        let die = CGRect(x: 36, y: 20, width: 28, height: 24)
        guard !cells.isEmpty else {
            // No per-core reading: the die is a single plate at the aggregate,
            // which is what this mark drew before it had cores.
            context.fill(Path(roundedRect: die.insetBy(dx: 3, dy: 3), cornerRadius: 4),
                         with: .color(tint.opacity(0.18 + fallback * 0.5)))
            return
        }
        let count = cells.count
        let columns = max(1, Int((Double(count)).squareRoot().rounded()))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let gap: CGFloat = 1.2
        let cellW = (die.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellH = (die.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        guard cellW > 0.6, cellH > 0.6 else { return }
        for index in 0..<count {
            let column = index % columns
            let row = index / columns
            // The last row is centred when it is short, so a 10-core die does
            // not read as a 12-core one with two cores missing from a corner.
            let inRow = min(columns, count - row * columns)
            let rowWidth = CGFloat(inRow) * cellW + gap * CGFloat(inRow - 1)
            let x = die.minX + (die.width - rowWidth) / 2 + CGFloat(column) * (cellW + gap)
            let y = die.minY + CGFloat(row) * (cellH + gap)
            let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
            let path = Path(roundedRect: rect, cornerRadius: min(1.5, cellW * 0.3))
            // The cell is *opaque*, and that is the whole point: it sits on the
            // die's gradient plate, and a translucent lit fill over a
            // translucent idle fill over that plate left the two readings
            // 6/255 apart — i.e. invisible. An idle core paints the surface
            // colour (so the cell reads as a dark socket at rest) and a busy
            // core paints the ink at full strength, which is the same contrast
            // the pill and the hero figure use.
            let lit = cells[index]
            let busy = lit > 0.04
            // Below 4 % a core is idle, and an idle core must not glow: the
            // floor is what keeps a quiet machine reading as quiet.
            //
            // The two fills are opaque and *far* apart (≈95 vs ≈235 of 255 at
            // the 112×80 tile size). An earlier version stacked two translucent
            // greens on the die's gradient plate and the lit and idle readings
            // came out 6/255 apart — a mark that measured nothing. A busy core
            // is ink; an idle core is a pale socket that still reads as a core,
            // so twelve cores are countable whether or not the machine is busy.
            let fill: Color = busy
                ? tint.opacity(0.30 + lit * 0.70)
                : tint.opacity(0.16)
            context.fill(path, with: .color(fill))
            if busy {
                context.stroke(path, with: .color(tint.opacity(0.9)), lineWidth: 0.5)
            }
        }
    }

    // MARK: - GPU board

    /// The graphics card at the grid's own weight: a board, a bracket, two
    /// sub-unit cells and the fan slot, with each cell lit by its own reading.
    private static func drawGPU(cells: [Double], fallback: Double, tint: Color, in context: inout GraphicsContext) {
        let board = CGRect(x: 8, y: 18, width: 84, height: 40)
        let body = Path(roundedRect: board, cornerRadius: 5)
        context.fill(body, with: .linearGradient(Gradient(colors: [tint.opacity(0.06), tint.opacity(0.2)]),
                                                 startPoint: board.origin, endPoint: CGPoint(x: board.maxX, y: board.maxY)))
        context.stroke(body, with: .color(tint), lineWidth: 1.6)

        // Mounting bracket, left edge, with the two tabs the CPU mark also uses.
        var bracket = Path()
        bracket.move(to: CGPoint(x: 8, y: 64)); bracket.addLine(to: CGPoint(x: 8, y: 12))
        bracket.move(to: CGPoint(x: 8, y: 24)); bracket.addLine(to: CGPoint(x: 14, y: 24))
        bracket.move(to: CGPoint(x: 8, y: 52)); bracket.addLine(to: CGPoint(x: 14, y: 52))
        context.stroke(bracket, with: .color(tint.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

        // The fan slot: a rotor silhouette at the right end, always turning in
        // the strip, still here — this mark states, the strip moves.
        let hub = CGPoint(x: 72, y: 38)
        context.fill(Path(ellipseIn: CGRect(x: hub.x - 14, y: hub.y - 14, width: 28, height: 28)),
                     with: .color(tint.opacity(0.08)))
        var rotor = Path()
        for index in 0..<3 {
            let angle = Double(index) * 120 - 90
            rotor.move(to: hub)
            rotor.addArc(center: hub, radius: 13,
                         startAngle: .degrees(angle - 26), endAngle: .degrees(angle + 26), clockwise: false)
            rotor.closeSubpath()
        }
        context.fill(rotor, with: .color(tint.opacity(0.22)))
        context.fill(Path(ellipseIn: CGRect(x: hub.x - 3, y: hub.y - 3, width: 6, height: 6)), with: .color(tint))

        // One cell per published sub-unit, lit by its own 0…100 reading. With
        // no reading the slot keeps a single plate at the aggregate.
        let slot = CGRect(x: 18, y: 24, width: 38, height: 28)
        guard !cells.isEmpty else {
            // No published sub-units: one opaque plate at the aggregate, the
            // same weight as the CPU die's fallback. A 20 % wash here sat within
            // 4/255 of the board it was drawn on, i.e. it was not a mark at all.
            let plate = Path(roundedRect: slot.insetBy(dx: 6, dy: 6), cornerRadius: 4)
            context.fill(plate, with: .color(tint.opacity(0.30 + fallback * 0.55)))
            return
        }
        let gap: CGFloat = 2.5
        let width = (slot.width - gap * CGFloat(cells.count - 1)) / CGFloat(cells.count)
        for (index, reading) in cells.enumerated() {
            let rect = CGRect(x: slot.minX + CGFloat(index) * (width + gap), y: slot.minY, width: width, height: slot.height)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            // Same pair as the CPU cells: an opaque socket, then an ink column
            // filled from the bottom by that sub-unit's *own* reading — so the
            // three units of a GPU are three independent bars, not one bar
            // repeated three times.
            context.fill(path, with: .color(tint.opacity(0.16)))
            context.stroke(path, with: .color(tint.opacity(0.55)), lineWidth: 0.8)
            if reading > 0.04 {
                let height = (rect.height - 3) * CGFloat(reading)
                let column = CGRect(x: rect.minX + 1.5, y: rect.maxY - 1.5 - height,
                                    width: rect.width - 3, height: height)
                context.fill(Path(roundedRect: column, cornerRadius: 1.5), with: .color(tint.opacity(0.9)))
            }
        }
    }
}
