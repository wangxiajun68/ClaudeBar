import SwiftUI

/// Row density for `UsageBarRow`.
enum UsageRowDensity {
    /// Menu-bar popup: tight, 44pt token column.
    case popup
    /// Usage page: full-width, fixed model column, share column.
    case page
    /// Dashboard mini: fixed model column, share before tokens, no hover.
    case mini
}

/// The single per-model usage row: model name, proportional fill bar, and
/// formatted token count (+ share on page/mini). Replaces the three former
/// copies (UsageRowView, UsageView.UsageBarRow, DashboardView.MiniUsageRow).
struct UsageBarRow: View {
    let stat: ModelUsage
    let maxTokens: Int
    var density: UsageRowDensity = .popup
    /// nil → bar fills available space (popup only).
    var barWidth: CGFloat? = nil

    @State private var isHovered = false

    private var ratio: Double { maxTokens > 0 ? Double(stat.totalTokens) / Double(maxTokens) : 0 }
    private var color: Color { Theme.barColor(for: stat.model) }

    var body: some View {
        switch density {
        case .popup: popupRow
        case .page: pageRow
        case .mini: miniRow
        }
    }

    // MARK: Popup (was UsageRowView)

    private var popupRow: some View {
        HStack(spacing: Theme.Space.s8) {
            Text(stat.model)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textPrimary.opacity(isHovered ? 0.95 : 0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            ProportionBar(ratio: ratio, color: color, height: isHovered ? 6 : 5, corner: 2)
                .frame(width: barWidth, height: 12)

            MetricText(
                value: UsageStats.formatTokens(stat.totalTokens),
                font: Theme.Font.captionMono,
                color: Theme.textPrimary.opacity(isHovered ? 0.8 : 0.6),
                width: 44
            )
        }
        .padding(.horizontal, Theme.Space.s8).padding(.vertical, 1)
        .scaleEffect(isHovered ? 1.02 : 1)
        .hoverState($isHovered)
    }

    // MARK: Page (was UsageView.UsageBarRow)

    private var pageRow: some View {
        HStack(spacing: Theme.Space.s12) {
            Text(stat.model)
                .font(Theme.Font.bodySmall)
                .foregroundColor(Theme.textPrimary.opacity(isHovered ? 1 : 0.85))
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            ProportionBar(ratio: ratio, color: color, height: 8, corner: 3)
                .frame(height: 14)
            MetricText(
                value: UsageStats.formatTokens(stat.totalTokens),
                font: Theme.Font.bodySmall,
                color: Theme.textSecondary,
                width: 64
            )
            MetricText(
                value: "\(Int(ratio * 100))%",
                font: Theme.Font.captionMono,
                color: color,
                width: 40
            )
        }
        .padding(.vertical, 3)
        .hoverState($isHovered)
    }

    // MARK: Mini (was DashboardView.MiniUsageRow)

    private var miniRow: some View {
        HStack(spacing: Theme.Space.s8) {
            Text(stat.model)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 140, alignment: .leading)
            ProportionBar(ratio: ratio, color: color, height: 6, corner: 2)
                .frame(height: 6)
            MetricText(
                value: "\(Int((ratio * 100).rounded()))%",
                font: Theme.Font.captionMono,
                color: Theme.textTertiary(),
                width: 36
            )
            MetricText(
                value: UsageStats.formatTokens(stat.totalTokens),
                font: Theme.Font.captionMono,
                color: Theme.textSecondary,
                width: 56
            )
        }
    }
}

// MARK: - Proportion bar

/// A plain proportional fill bar — track + colored fill. The one GeometryReader
/// bar implementation; every usage/context ratio bar composes this.
struct ProportionBar: View {
    let ratio: Double
    var color: Color
    var height: CGFloat = 6
    var corner: CGFloat = 2
    /// Track opacity for the unfilled portion.
    var trackOpacity: Double = 0.07

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: corner)
                    .fill(Theme.cardFill(trackOpacity))
                    .frame(height: height)
                RoundedRectangle(cornerRadius: corner)
                    .fill(color)
                    .frame(width: max(3, geo.size.width * CGFloat(min(max(ratio, 0), 1))), height: height)
            }
        }
    }
}

// MARK: - Metric text

/// Right-aligned tabular figure with numeric roll transition — the single
/// home for "a number that updates" in usage contexts.
struct MetricText: View {
    let value: String
    var font: SwiftUI.Font = Theme.Font.captionMono
    var color: Color = Theme.textSecondary
    var width: CGFloat? = nil

    var body: some View {
        Text(value)
            .font(font)
            .monospacedDigit()
            .foregroundColor(color)
            .frame(width: width, alignment: .trailing)
            .contentTransition(.numericText())
            .animation(Theme.Animation.smooth, value: value)
    }
}
