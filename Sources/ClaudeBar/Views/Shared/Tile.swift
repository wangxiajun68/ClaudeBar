import SwiftUI

// MARK: - Tile surface

/// The 宫格 (grid) tile surface: dense Liquid Glass over `.panelCard()`'s
/// glass — smaller radius, slightly lighter fill, optional state tint, and a
/// hover lift. Tiles are the only data surface; hairlines group grids.
struct TileModifier: ViewModifier {
    var tint: Color? = nil
    var hovered: Bool = false
    var dense: Bool = false

    func body(content: Content) -> some View {
        let radius = dense ? Theme.Radius.md : Theme.Radius.lg
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint == nil
                          ? Theme.cardSurface
                          : tint!.opacity(hovered ? 0.14 : 0.09))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(hovered ? 0.06 : 0.04), radius: hovered ? 8 : 5, y: 1)
    }
}

extension View {
    /// Apply the tile surface — the grid cell equivalent of `.panelCard()`.
    func tile(tint: Color? = nil, hovered: Bool = false, dense: Bool = false) -> some View {
        modifier(TileModifier(tint: tint, hovered: hovered, dense: dense))
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
    var pill: String? = nil
    var valueFont: SwiftUI.Font = Theme.Font.displayMetricSmall
    var dense: Bool = false
    var action: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        let content = VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 8) {
                if let icon {
                    GlyphWell(name: icon, tint: Theme.textSecondary, size: dense ? 20 : 22)
                }
                Text(label)
                    .font(Theme.Font.tileLabel)
                    .tracking(Theme.Tracking.caption)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 4)
                if let pill {
                    StatusPill(label: pill, tint: tint ?? Theme.statusSuccess)
                }
            }
            Text(value)
                .font(Theme.Font.displayMetricSmall)
                .monospacedDigit()
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(Theme.Animation.smooth, value: value)
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
        .animation(Theme.Animation.smooth, value: isHovered)
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
    @ViewBuilder let content: () -> Content

    init(_ preset: Theme.GridLayout.Preset,
         spacing: CGFloat? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        let spec = Theme.GridLayout.equalRow(preset)
        self.fixedColumns = spec.fixed
        self.minColumnWidth = spec.minWidth
        switch preset {
        case .pageMetric, .pageSession, .pageUsage, .pageProvider, .pageSetting:
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
        EqualRowGrid(spacing: spacing, minColumnWidth: minColumnWidth, fixedColumns: fixedColumns) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Packs children into equal-width columns and stretches every cell in a row
/// to that row's tallest sibling. Safe in ScrollView because the layout
/// reports a concrete height instead of proposing infinity upward.
struct EqualRowGrid: Layout {
    var spacing: CGFloat
    var minColumnWidth: CGFloat
    var fixedColumns: Int?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // SwiftUI proposes `.infinity` width whenever the parent is greedy
        // (`.frame(maxWidth: .infinity)`), and a non-finite width makes the
        // column math produce NaN/∞, which traps on `Int(...)`. Collapse
        // non-finite proposals to 0 so we lay out one column instead.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let cols = columnCount(for: width)
        let colW = columnWidth(container: width, columns: cols)
        let heights = rowHeights(subviews: subviews, columns: cols, colW: colW)
        let rows = heights.count
        let height = heights.reduce(0, +) + spacing * CGFloat(max(rows - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let container = bounds.width.isFinite ? bounds.width : 0
        let cols = columnCount(for: container)
        let colW = columnWidth(container: container, columns: cols)
        let heights = rowHeights(subviews: subviews, columns: cols, colW: colW)
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
