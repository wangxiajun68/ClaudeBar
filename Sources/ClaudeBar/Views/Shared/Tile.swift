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
        let radius = dense ? Theme.Radius.sm : Theme.Radius.md
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(tint?.opacity(hovered ? 0.18 : 0.11)
                          ?? Color.white.opacity(hovered ? 0.08 : 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.white.opacity(hovered ? 0.10 : 0.06), lineWidth: 1)
            }
            .scaleEffect(hovered && !dense ? 1.004 : 1)
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
    var valueFont: SwiftUI.Font = Theme.Font.tileValue
    var dense: Bool = false
    var action: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        let content = VStack(alignment: .leading, spacing: Theme.Space.s6) {
            Text(label)
                .font(Theme.Font.tileLabel)
                .tracking(Theme.Tracking.caption)
                .foregroundColor(tint ?? Theme.textSecondary)
            Text(value)
                .font(valueFont)
                .monospacedDigit()
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(Theme.Animation.smooth, value: value)
            // Always render the detail line so all tiles stay equal height.
            Text(detail.isEmpty ? " " : detail)
                .font(Theme.Font.tileDetail)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(dense ? Theme.Space.s12 : Theme.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile(tint: tint, hovered: isHovered, dense: dense)
        .contentShape(RoundedRectangle(cornerRadius: dense ? Theme.Radius.sm : Theme.Radius.md))
        .hoverState($isHovered)
        .animation(Theme.Animation.smooth, value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)，\(value)\(detail.isEmpty ? "" : "，\(detail)")")

        if let action {
            Button(action: action) { content }
                .buttonStyle(.pressable)
        } else {
            content
        }
    }
}

// MARK: - Tile grid

/// A grid of tiles with a themed gap — the 宫格 wrapper. Initialize from a
/// `Theme.GridLayout.Preset` or with explicit columns.
struct TileGrid<Content: View>: View {
    private let columns: [GridItem]
    private let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(_ preset: Theme.GridLayout.Preset,
         spacing: CGFloat? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.columns = Theme.GridLayout.columns(preset)
        switch preset {
        case .pageMetric, .pageSession, .pageUsage, .pageProvider:
            self.spacing = spacing ?? Theme.Space.gridGapPage
        case .popupSession, .popupProvider, .popupUsage:
            self.spacing = spacing ?? Theme.Space.gridGap
        }
        self.content = content
    }

    init(columns: [GridItem], spacing: CGFloat,
         @ViewBuilder content: @escaping () -> Content) {
        self.columns = columns
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: spacing, content: content)
    }
}
