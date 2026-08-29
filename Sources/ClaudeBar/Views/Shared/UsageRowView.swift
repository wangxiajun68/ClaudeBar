import SwiftUI

/// A single per-model usage bar row: model name, a proportional fill bar, and
/// the formatted token count. Extracted from `MenuBarView.usageRow` and shared
/// between the menu-bar popup and the main-window Usage page.
struct UsageRowView: View {
    let stat: ModelUsage
    let maxTokens: Int
    var barWidth: CGFloat? = 70   // nil → fill available space
    @State private var isHovered = false

    var body: some View {
        let ratio = maxTokens > 0 ? CGFloat(stat.totalTokens) / CGFloat(maxTokens) : 0
        HStack(spacing: 8) {
            Text(stat.model)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textPrimary.opacity(isHovered ? 0.95 : 0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.cardFill(0.08))
                        .frame(height: isHovered ? 6 : 5)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.barColor(for: stat.model))
                        .frame(width: max(3, geo.size.width * ratio), height: isHovered ? 6 : 5)
                        .opacity(isHovered ? 1 : 0.9)
                }
            }
            .frame(width: barWidth, height: 12)

            // Fixed trailing column: right-aligned tabular digits so token
            // counts of different lengths align vertically across rows.
            Text(UsageStats.formatTokens(stat.totalTokens))
                .font(Theme.Font.captionMono)
                .monospacedDigit()
                .foregroundColor(Theme.textPrimary.opacity(isHovered ? 0.8 : 0.6))
                .frame(width: 44, alignment: .trailing)
                .contentTransition(.numericText())
                .animation(Theme.Animation.smooth, value: stat.totalTokens)
        }
        .padding(.horizontal, 8).padding(.vertical, 1)
        .scaleEffect(isHovered ? 1.02 : 1)
        .hoverState($isHovered)
    }
}
