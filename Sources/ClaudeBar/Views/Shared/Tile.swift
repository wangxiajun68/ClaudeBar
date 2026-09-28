import SwiftUI

// MARK: - Tile surface

/// The 宫格 (grid) tile surface — the one card behind every data grid in the
/// app (dashboard KPIs, sessions, usage, providers, connectors).
///
/// One shape language, four parts, all of them already drawn by the reference
/// Uiverse pieces (see `UiverseSurfaces.swift`):
///
/// 1. a `cardSurface` base, so a tile is opaque in both themes;
/// 2. an optional **accent wash** — the tile's own hue at 5–17 % — which is
///    what the weather card's saturated gradient does for its white frame ring;
/// 3. an optional **depth lens** off the top trailing corner, receding past the
///    edge (`DepthLens`, one `Canvas`);
/// 4. the **inner frame ring** inside the card's own edge, and a hairline that
///    lights up as the accent on hover.
///
/// Cost, because this hangs off grids of up to 200 cards: the lens is one
/// `Canvas` drawing three stroked circles — fewer layers than the three
/// separate `Circle` views it replaces, and the same count as the single
/// stroked circle each of these cards drew before. Nothing here animates on a
/// timer; the only motion is the hover lift, which is a pointer state change.
struct TileModifier: ViewModifier {
    var tint: Color? = nil
    var hovered: Bool = false
    var dense: Bool = false
    var lens: DepthLensSpec? = nil
    var framed: Bool = true
    var wash: Double? = nil
    /// Whether the card rises 2pt under the pointer. See `TileSurface.lift`.
    var lift: Bool = true
    /// A ground **view** drawn over the opaque base fill, under the accent
    /// wash. See `TileSurface.ground` — only the weather band passes one.
    var ground: AnyView? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        TileSurface(tint: tint, hovered: hovered, dense: dense, lens: lens,
                    framed: framed, wash: wash, lift: lift, ground: ground,
                    reduceMotion: reduceMotion) {
            content
        }
    }
}

/// The surface itself, split out of the modifier so it can be reused by
/// `.hoverTile()` (which owns its own hover flag) without the two modifiers
/// chaining into each other — a modifier calling another modifier's extension
/// on `Content` does not type-check.
struct TileSurface<Content: View>: View {
    var tint: Color?
    var hovered: Bool
    var dense: Bool
    var lens: DepthLensSpec?
    var framed: Bool
    /// Base accent wash at rest, overridden when a surface needs its own
    /// strength. The default (5.5 % light / 11 % dark) is tuned for a dense
    /// grid of small tiles; a page-scale band carries a heavier one so its
    /// white inner frame ring actually reads (`PageHeaderCard`).
    var wash: Double?
    /// Whether the card rises 2pt under the pointer. **Off for a page band.**
    ///
    /// The lift moves the card's own frame, and the hover region travels with
    /// it, so a pointer resting within 2pt of the card's bottom edge gets
    /// carried out of the card by the lift, re-enters when it drops back, and
    /// oscillates — a visible shiver at pointer-update frequency. On a grid
    /// tile the pointer almost never sits on that 2pt strip, and "the card I am
    /// about to click answers by lifting" is the affordance; on a *page band*,
    /// which is full-width and whose buttons and figures sit in its lower half,
    /// it is easy to hit and the lift means nothing (there is one band per page,
    /// not a field of them to scan). `PageHeaderCard` passes `false`, so the
    /// band answers the pointer with its edge and wash instead.
    /// A ground **view** drawn over the opaque base fill and under the accent
    /// wash. `nil` — every card in the app but one.
    ///
    /// The weather band passes its sky here: it is the one surface whose *ground*
    /// carries a reading (which sky, and whether the sun is up), and painting
    /// that as an accent wash over white would have made it a tint of a white
    /// card rather than a sky. Everything else about the surface — the depth
    /// lens, the inner frame ring, the hover edge, the Core Animation layer
    /// shadow — is unchanged, so the weather band is still the same object as
    /// every other card.
    ///
    /// **A view, not a `ShapeStyle`.** The obvious spelling is
    /// `base: AnyShapeStyle?` fed to `.fill(_:)`, and it silently draws nothing:
    /// a custom `ShapeStyle` whose `resolve(in:)` returns a `View` satisfies the
    /// compiler but renders as a no-op fill, so the card falls back to
    /// `Theme.cardSurface` and every figure on it lands on white. Measured —
    /// `RoundedRectangle.fill(<view-backed style>)` leaves the pixels untouched
    /// while `.fill(LinearGradient(...))` paints — which is why the ground is a
    /// view stacked in the background, and why the base stays an opaque
    /// `Color` fill under it.
    var ground: AnyView?
    var lift: Bool
    var reduceMotion: Bool
    let content: Content

    /// Explicit init: the memberwise one would take `content` as a plain
    /// function, so every call site would have to spell out
    /// `content: { … }` instead of trailing-closure syntax.
    init(tint: Color? = nil, hovered: Bool, dense: Bool = false,
         lens: DepthLensSpec? = nil, framed: Bool = true,
         wash: Double? = nil, lift: Bool = true, ground: AnyView? = nil,
         reduceMotion: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.hovered = hovered
        self.dense = dense
        self.lens = lens
        self.framed = framed
        self.wash = wash
        self.lift = lift
        self.ground = ground
        self.reduceMotion = reduceMotion
        self.content = content()
    }

    /// The wash actually painted: the surface's own strength when it asked for
    /// one, otherwise the grid default, deepened on hover in both cases.
    private var restWash: Double {
        let base = wash ?? (Theme.isDark ? 0.11 : 0.055)
        return hovered ? base * 1.7 : base
    }

    var body: some View {
        let radius = dense ? Theme.Radius.md : Theme.Radius.lg
        // A tile with no accent hue still needs an interactive edge; the app's
        // blue is the one every page already uses for "this is a control".
        let accent = tint ?? Theme.Ink.claude
        content
            .background {
                ZStack(alignment: lens?.align ?? .topTrailing) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Theme.cardSurface)
                    // The card's own ground, over the opaque base and under the
                    // accent wash — so a ground that forgets a pixel still lands
                    // on a real surface rather than on nothing.
                    if let ground {
                        ground
                            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    }
                    if tint != nil {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(accent.opacity(restWash))
                    }
                    if let lens {
                        DepthLens(spec: lens, engaged: hovered)
                            // Pushed past the aligned edge so the rings leave the
                            // card instead of sitting in it — the reference
                            // card's circles are cropped by its own bounds the
                            // same way. `LensPlacement` keeps the direction tied
                            // to the alignment, and honours an exact offset when
                            // the card knows where its mark actually is.
                            .offset(LensPlacement.offset(lens))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                // The card's drop shadow is **owned by a layer, not the view
                // graph.** `.shadow(...)` looks like the same thing and is not:
                // SwiftUI evaluates it as a filter inside the display-list pass,
                // so it re-runs for every cycle the card's subtree is visited,
                // and it makes the subtree a compositing unit. A `CALayer` with a
                // `shadowPath` is rasterised once by the render server and costs
                // the view graph nothing.
                //
                // Measured (idle dashboard, frames per 6 s, SCStream paints):
                // with the SwiftUI shadow **380**; with `.shadow` removed
                // entirely **734**; with this layer-based shadow, *enabled*
                // **742**. So the frames come back and the shadow stays — the
                // shadow was never free, it was the most expensive single thing
                // on the page, and it was hiding behind a component the eye reads
                // as decoration. Same method as `DecorativeMotion`: if it is a
                // drawing rather than state, the render server should own it.
                .background {
                    LayerShadow(radius: hovered ? 9 : 5,
                                y: hovered ? 4 : 1,
                                opacity: hovered ? 0.07 : 0.04,
                                cornerRadius: radius,
                                surface: Theme.cardSurface)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(hovered ? accent.opacity(0.34) : Theme.hairline,
                                  lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if framed {
                    // On a tinted tile the ring is the lit white edge of the
                    // reference card; on a plain one it is an engraved hairline
                    // (white over white would be nothing).
                    InnerFrameRing(inset: dense ? 2.5 : 3, radius: radius,
                                   tint: tint == nil ? Theme.innerFrameMuted : Theme.innerFrame)
                }
            }
            // The hit shape is pinned to the *unlifted* frame and applied
            // before the lift, so the pointer region never travels with the
            // 2pt rise. Without this, the region is whatever the offset leaves
            // behind: a pointer on the card's bottom edge rides the card out of
            // itself and back, once per frame.
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .offset(y: lift && hovered && !reduceMotion ? -2 : 0)
    }
}

/// A drop shadow drawn by Core Animation instead of by SwiftUI's view graph.
///
/// See the call site in `TileSurface.body` for the numbers. The layer's
/// `shadowPath` is what makes it cheap: Core Animation skips deriving the
/// shadow's silhouette from the layer's contents (which for an opaque fill with
/// a corner radius means an offscreen mask) and rasterises the rounded rect
/// directly, once, on the render server.
struct LayerShadow: NSViewRepresentable {
    var radius: CGFloat
    var y: CGFloat
    var opacity: Double
    var cornerRadius: CGFloat
    /// Painted behind the shape so the layer has something to *be*; the card's
    /// own fill covers it. Without it the layer is transparent and the shadow
    /// has no silhouette to come from.
    var surface: Color
    /// Shadow hue. Every card surface wants a black drop shadow, but the
    /// instrument buttons pair one with a **tinted** one underneath
    /// (`tint.opacity(0.18)`), and that pair is what makes a filled plate read
    /// as lit from above. Passing the hue in keeps that effect on the same
    /// rasterisation path instead of leaving it in the view graph.
    var color: Color = .black
    /// The second, fuller shadow's radius/offset — the reference's `:before`
    /// layer sitting under the `:after` one.
    var underRadius: CGFloat = 0
    var underY: CGFloat = 0
    var underOpacity: Double = 0
    var underColor: Color = .black

    func makeNSView(context: Context) -> ShadowHostView { ShadowHostView() }

    func updateNSView(_ view: ShadowHostView, context: Context) {
        view.apply(radius: radius, y: y, opacity: opacity,
                   cornerRadius: cornerRadius, surface: NSColor(surface),
                   color: NSColor(color),
                   underRadius: underRadius, underY: underY,
                   underOpacity: underOpacity, underColor: NSColor(underColor))
    }

    static func dismantleNSView(_ view: ShadowHostView, coordinator: ()) { view.clear() }
}

final class ShadowHostView: NSView {
    /// Flipped, so the layer's frame is the AppKit frame and the shadow's `y`
    /// offset means what the SwiftUI modifier's `y:` meant (downward).
    override var isFlipped: Bool { true }
    /// Decoration: it must never take a pointer or a hit test away from the card
    /// it sits behind.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private let box = CALayer()
    /// The fuller shadow underneath. A layer can only carry one shadow, and the
    /// button's gloss wants two, so the lower one is a sibling layer.
    private let under = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        box.masksToBounds = false
        under.masksToBounds = false
        layer?.addSublayer(under)
        layer?.addSublayer(box)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(radius: CGFloat, y: CGFloat, opacity: Double,
               cornerRadius: CGFloat, surface: NSColor, color: NSColor,
               underRadius: CGFloat, underY: CGFloat,
               underOpacity: Double, underColor: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil)
        let specs = [(box, radius, y, opacity, color),
                     (under, underRadius, underY, underOpacity, underColor)]
        for (layer, r, dy, o, hue) in specs {
            layer.frame = bounds
            layer.cornerRadius = cornerRadius
            // The explicit `shadowPath` *is* the silhouette, so the layer
            // itself may stay transparent — which is what a button wants, since
            // its own `plateFill` already draws the capsule and a second
            // painted one would show at the antialiased edge. Card call sites
            // pass their fill anyway; it is harmless there and helps when the
            // path is briefly stale during a resize.
            layer.backgroundColor = surface.cgColor
            layer.shadowPath = path
            layer.shadowColor = hue.cgColor
            layer.shadowOpacity = Float(o)
            layer.shadowRadius = r
            // The layer tree's y grows downward in a flipped host, so a positive
            // `y` means "below the card", matching the modifier it replaces.
            layer.shadowOffset = CGSize(width: 0, height: dy)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let path = CGPath(roundedRect: bounds, cornerWidth: box.cornerRadius,
                          cornerHeight: box.cornerRadius, transform: nil)
        for layer in [box, under] {
            layer.frame = bounds
            layer.shadowPath = path
        }
    }

    func clear() { box.shadowOpacity = 0; under.shadowOpacity = 0 }
}

extension View {
    /// Apply the tile surface — the grid cell equivalent of `.panelCard()`.
    ///
    /// `tint` is the tile's accent: it drives the corner lens, the wash and the
    /// hover edge. `lens` is opt-in because a 40pt metric tile has no corner to
    /// spare, and because on some tiles the corner is already occupied (a
    /// session tile's agent cluster) — rings there would run under content
    /// instead of behind a header. The rings carry no glyph of their own: a
    /// card's mark belongs in its header, where it is legible and where it can
    /// keep its own accessible name, so the lens is hue and depth only.
    func tile(tint: Color? = nil, hovered: Bool = false, dense: Bool = false,
              lens: DepthLensSpec? = nil, framed: Bool = true,
              wash: Double? = nil, lift: Bool = true,
              ground: AnyView? = nil) -> some View {
        modifier(TileModifier(tint: tint, hovered: hovered, dense: dense,
                              lens: lens, framed: framed, wash: wash, lift: lift,
                              ground: ground))
    }
}

// MARK: - Tile grid

/// A grid of tiles with a themed gap — the 宫格 wrapper. Initialized from a
/// `Theme.GridLayout.Preset`. Row cells share the tallest sibling's height so
/// modules don't sit 一大一小.
struct TileGrid<Content: View>: View {
    private let fixedColumns: Int?
    private let minColumnWidth: CGFloat
    private let spacing: CGFloat
    private var virtualized = false
    @ViewBuilder let content: () -> Content

    init(_ preset: Theme.GridLayout.Preset,
         spacing: CGFloat? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        let spec = Theme.GridLayout.equalRow(preset)
        self.fixedColumns = spec.fixed
        self.minColumnWidth = spec.minWidth
        switch preset {
        case .pageSession, .pageUsage: self.virtualized = true
        default: break
        }
        switch preset {
        case .pageMetric, .pageSession, .pageUsage, .pageProvider, .pageSetting, .pageSettingDense:
            self.spacing = spacing ?? Theme.Space.gridGapPage
        case .popupSession, .popupProvider, .popupUsage:
            self.spacing = spacing ?? Theme.Space.gridGap
        }
        self.content = content
    }

    var body: some View {
        Group {
            if virtualized {
                LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                    content()
                }
            } else {
                EqualRowGrid(spacing: spacing, minColumnWidth: minColumnWidth, fixedColumns: fixedColumns) {
                    content()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columns: [GridItem] {
        if let fixedColumns {
            return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: max(1, fixedColumns))
        }
        return [GridItem(.adaptive(minimum: max(1, minColumnWidth)), spacing: spacing, alignment: .top)]
    }
}

/// Packs children into equal-width columns and stretches every cell in a row
/// to that row's tallest sibling. Safe in ScrollView because the layout
/// reports a concrete height instead of proposing infinity upward.
struct EqualRowGrid: Layout {
    var spacing: CGFloat
    var minColumnWidth: CGFloat
    var fixedColumns: Int?

    /// Why the row heights are cached at all: SwiftUI asks `sizeThatFits` for
    /// the container's own height *and* then `placeSubviews` for where every
    /// cell goes, and it re-asks on any parent change (a scroll pass, a hover
    /// on one cell, an unrelated publish). Without the cache each of those
    /// passes calls `sizeThatFits` on every child, so a 200-card grid measures
    /// 200 text layouts twice per pass.
    ///
    /// Keyed on what the row heights actually depend on. It used to carry the
    /// raw proposed width, but `sizeThatFits` collapses a non-finite proposal
    /// to 0 while `placeSubviews` uses `bounds.width` — the *same* layout pass
    /// therefore produced two different keys, so every child was measured
    /// twice per pass for every greedy (`.frame(maxWidth: .infinity)`) parent,
    /// which is the documented common case.
    struct MeasurementKey: Hashable {
        /// Non-finite proposals collapse to 0, matching `sizeThatFits`.
        let proposalWidth: CGFloat
        let colW: CGFloat
        let columns: Int
        let spacing: CGFloat
    }

    // Reuse each proposal's row heights during placement.
    struct Cache {
        var measurements: [MeasurementKey: [CGFloat]] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    /// Reuse each proposal's row heights during placement.
    ///
    /// **The cache is cleared on every content change, and that is load-bearing.**
    /// The key is `(columns, colW, proposalWidth, spacing)` — it describes the
    /// *packing*, not the cells — so a cell whose own height changes (a caption
    /// wrapping to a second line, a tile swapping its body) would otherwise keep
    /// the row height measured for its old content and the grid would not grow or
    /// shrink. `updateCache` is the only signal SwiftUI gives for that, so
    /// clearing here is the contract, and `Tests/ui-regressions.py` asserts it
    /// (`Cache must invalidate when content changes`).
    ///
    /// A 2026-09-26 pass tried removing the clear to stop the re-measure a 2.5 s
    /// session poll triggers. The test caught it, and the measurement does not
    /// support the trade anyway: a 1 ms `sample` of a dashboard dwell puts
    /// `EqualRowGrid.placeSubviews` at ~0.25 ms per second of wall clock — the
    /// clear is cheap, and the re-measure it triggers is the work that keeps the
    /// tiles the right height.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.measurements.removeAll(keepingCapacity: true)
    }

    /// Row heights for a proposed container width. The cache key is built from
    /// the *collapsed* width and its derived column geometry, so the measure
    /// pass (`sizeThatFits`) and the place pass (`placeSubviews`) — which
    /// arrive with `∞` and with the resolved width respectively — hit the same
    /// entry instead of re-measuring every child.
    private func heights(container: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGFloat] {
        // A non-finite width makes the column math produce NaN/∞, which traps
        // on `Int(...)`. Collapse it to 0 so we lay out one column instead.
        let width = container.isFinite ? container : 0
        let cols = columnCount(for: width)
        let colW = columnWidth(container: width, columns: cols)
        let key = MeasurementKey(proposalWidth: width, colW: colW, columns: cols, spacing: spacing)
        if let heights = cache.measurements[key] { return heights }
        let result = rowHeights(subviews: subviews, columns: cols, colW: colW)
        // Live resize can propose hundreds of widths without changing the
        // children. Bound retained measurements while preserving reuse for
        // the usual measure/place proposal pair.
        if cache.measurements.count >= 8 { cache.measurements.removeAll(keepingCapacity: true) }
        cache.measurements[key] = result
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        // SwiftUI proposes `.infinity` width whenever the parent is greedy
        // (`.frame(maxWidth: .infinity)`); `heights` collapses that for us.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let heights = heights(container: width, subviews: subviews, cache: &cache)
        let rows = heights.count
        let height = heights.reduce(0, +) + spacing * CGFloat(max(rows - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let container = bounds.width.isFinite ? bounds.width : 0
        let cols = columnCount(for: container)
        let colW = columnWidth(container: container, columns: cols)
        let heights = heights(container: container, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for col in 0..<cols {
                let i = row * cols + col
                guard i < subviews.count else { break }
                let x = bounds.minX + CGFloat(col) * (colW + spacing)
                subviews[i].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: colW, height: height)
                )
            }
            y += height + spacing
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        if let fixedColumns { return max(1, fixedColumns) }
        let pitch = minColumnWidth + spacing
        guard pitch > 0, width > 0 else { return 1 }
        return max(1, Int(floor((width + spacing) / pitch)))
    }

    private func columnWidth(container: CGFloat, columns: Int) -> CGFloat {
        let gaps = spacing * CGFloat(max(columns - 1, 0))
        guard container > 0 else { return 0 }
        return max(0, (container - gaps) / CGFloat(max(columns, 1)))
    }

    /// A child that reports a non-finite height (an unbounded Text, a nested
    /// layout that itself got an ∞ proposal) would propagate NaN into the row
    /// total and onward into the parent's height. Clamp to 0.
    private func finite(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }

    private func rowHeights(subviews: Subviews, columns: Int, colW: CGFloat) -> [CGFloat] {
        guard !subviews.isEmpty else { return [] }
        let rows = (subviews.count + columns - 1) / columns
        return (0..<rows).map { row in
            var h: CGFloat = 0
            for col in 0..<columns {
                let i = row * columns + col
                guard i < subviews.count else { break }
                h = max(h, finite(subviews[i].sizeThatFits(ProposedViewSize(width: colW, height: nil)).height))
            }
            return h
        }
    }
}
