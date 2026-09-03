import SwiftUI

// MARK: - Usage model tile

/// One per-model usage tile: model name + share %, proportional bar, token
/// total, and a micro breakdown line. Used on the usage page and, in the
/// dense variant, in the popup's 2-col grid.
struct UsageModelTile: View {
    let stat: ModelUsage
    let maxTokens: Int
    /// Popup density: smaller fonts, tighter padding.
    var dense: Bool = false

    @State private var isHovered = false

    private var ratio: Double { maxTokens > 0 ? Double(stat.totalTokens) / Double(maxTokens) : 0 }
    private var color: Color { Theme.barColor(for: stat.model) }

    private var hasCache: Bool {
        stat.cacheReadTokens > 0 || stat.cacheCreationTokens > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            HStack(spacing: Theme.Space.s6) {
                Circle()
                    .fill(color)
                    .frame(width: dense ? 5 : 6, height: dense ? 5 : 6)
                Text(stat.model)
                    .font(dense ? Theme.Font.rowTitle : Theme.Font.bodySmall)
                    .foregroundColor(Theme.textPrimary.opacity(isHovered ? 1 : 0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(Theme.Font.captionMono)
                    .foregroundColor(color)
            }
            ProportionBar(ratio: ratio, color: color, height: dense ? 5 : 7, corner: dense ? 2 : 3)
            HStack(alignment: .firstTextBaseline) {
                Text(UsageStats.formatTokens(stat.totalTokens))
                    .font(dense ? Theme.Font.tileMicroValue : Theme.Font.tileValueSmall)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: stat.totalTokens)
                Spacer(minLength: 8)
                if hasCache {
                    Text("缓存命中 \(stat.cacheHitPercent)%")
                        .font(dense ? Theme.Font.tileDetail : Theme.Font.captionMono)
                        .monospacedDigit()
                        .foregroundColor(color)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Text(detailLine)
                .font(Theme.Font.tileDetail)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(dense ? Theme.Space.s8 : Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile(hovered: isHovered, dense: dense)
        .hoverState($isHovered)
        .animation(Theme.Animation.smooth, value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hasCache
            ? "\(stat.model)，\(UsageStats.formatTokens(stat.totalTokens)) tokens，缓存命中 \(stat.cacheHitPercent)%"
            : "\(stat.model)，\(UsageStats.formatTokens(stat.totalTokens)) Token")
    }

    private var detailLine: String {
        var parts = [
            "\(stat.calls) 次",
            "输入 \(UsageStats.formatTokens(stat.inputTokens))",
            "输出 \(UsageStats.formatTokens(stat.outputTokens))",
        ]
        if hasCache {
            parts.append("命中 \(UsageStats.formatTokens(stat.cacheReadTokens))")
            if stat.cacheCreationTokens > 0 {
                parts.append("写入 \(UsageStats.formatTokens(stat.cacheCreationTokens))")
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Proportion bar

/// A plain proportional fill bar: track + colored fill. The shared
/// GeometryReader bar behind usage and context ratio displays.
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

/// Right-aligned tabular figure with numeric roll transition, for values
/// that update in place.
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
