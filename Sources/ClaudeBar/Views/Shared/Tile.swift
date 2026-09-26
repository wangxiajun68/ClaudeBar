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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        TileSurface(tint: tint, hovered: hovered, dense: dense, lens: lens,
                    framed: framed, wash: wash, lift: lift,
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
    var lift: Bool
    var reduceMotion: Bool
    let content: Content

    /// Explicit init: the memberwise one would take `content` as a plain
    /// function, so every call site would have to spell out
    /// `content: { … }` instead of trailing-closure syntax.
    init(tint: Color? = nil, hovered: Bool, dense: Bool = false,
         lens: DepthLensSpec? = nil, framed: Bool = true,
         wash: Double? = nil, lift: Bool = true, reduceMotion: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.hovered = hovered
        self.dense = dense
        self.lens = lens
        self.framed = framed
        self.wash = wash
        self.lift = lift
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
                .shadow(color: .black.opacity(hovered ? 0.07 : 0.04),
                        radius: hovered ? 9 : 5, y: hovered ? 4 : 1)
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
              wash: Double? = nil, lift: Bool = true) -> some View {
        modifier(TileModifier(tint: tint, hovered: hovered, dense: dense,
                              lens: lens, framed: framed, wash: wash, lift: lift))
    }
}

// MARK: - Metric tile

/// Label / value / detail metric tile — the one primitive behind Dashboard
/// stats and other headline numbers. The detail line is always rendered
/// (space-reserved when empty) so tiles in a row stay equal height.
struct MetricTile: View {
    let label: String
    let value: String
    var detail: String = ""
    var tint: Color? = nil
    var icon: String? = nil
    var instrumentIcon: InstrumentGlyph.Kind? = nil
    var pill: String? = nil
    /// Readable counterpart of `tint` for the pill text; see `StatusPill`.
    var pillInk: Color? = nil
    var valueFont: SwiftUI.Font = Theme.Font.displayMetricSmall
    var dense: Bool = false
    var quotaWindows: [CodexQuotaWindow] = []
    var action: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        let content = VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 8) {
                if let instrumentIcon {
                    InstrumentBadge(kind: instrumentIcon, size: dense ? 22 : 26,
                                    tint: tint ?? Theme.Ink.claude, engaged: isHovered)
                } else if let icon {
                    GlyphWell(name: icon, tint: tint ?? Theme.Ink.claude, size: dense ? 20 : 22, engaged: isHovered)
                }
                Text(label)
                    .font(Theme.Font.tileLabel)
                    .tracking(Theme.Tracking.caption)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 4)
                if let pill {
                    StatusPill(label: pill,
                               tint: tint ?? Theme.statusSuccess,
                               ink: pillInk ?? (tint == nil ? Theme.Ink.success : tint))
                }
            }
            if quotaWindows.isEmpty {
                RollingNumberText(value)
                    .font(Theme.Font.displayMetricSmall)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.5)
                    // No implicit `.animation(value: value)`: `value` is a live
                    // readout, and a value-keyed transaction would stay in
                    // flight on every poll. `.numericText` carries the roll.
            } else {
                CodexQuotaGauges(windows: quotaWindows, compact: false)
            }
            Text(detail.isEmpty ? " " : detail)
                .font(Theme.Font.tileDetail)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(dense ? Theme.Space.s12 : Theme.Space.s16)
        .frame(maxWidth: .infinity, minHeight: dense ? 96 : 112, maxHeight: .infinity, alignment: .topLeading)
        .tile(hovered: isHovered, dense: dense)
        .contentShape(RoundedRectangle(cornerRadius: dense ? Theme.Radius.md : Theme.Radius.lg, style: .continuous))
        .hoverState($isHovered)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)，\(value)\(detail.isEmpty ? "" : "，\(detail)")")

        if let action {
            Button(action: action) { content }
                .buttonStyle(.pressable)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            content
        }
    }
}

// MARK: - Tile grid

/// A grid of tiles with a themed gap — the 宫格 wrapper. Initialize from a
/// `Theme.GridLayout.Preset` or with explicit columns. Row cells share the
/// tallest sibling's height so modules don't sit 一大一小.
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

    init(columns: [GridItem], spacing: CGFloat,
         @ViewBuilder content: @escaping () -> Content) {
        self.fixedColumns = max(columns.count, 1)
        self.minColumnWidth = 0
        self.spacing = spacing
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

    // Reuse each proposal's row heights during placement. SwiftUI clears
    // this cache through updateCache when a cell's content changes.
    struct Cache {
        var measurements: [MeasurementKey: [CGFloat]] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

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
