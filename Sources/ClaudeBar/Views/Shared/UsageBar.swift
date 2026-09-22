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
    /// Where this model's tokens came from, in display order. Non-empty makes
    /// the tile open a ring popover on click; empty leaves it inert.
    var sourceSlices: [SourceRing.Slice] = []

    @State private var isHovered = false
    @State private var showSourceRing = false

    private var ratio: Double { maxTokens > 0 ? Double(stat.totalTokens) / Double(maxTokens) : 0 }
    private var color: Color { Theme.barColor(for: stat.model) }

    private var hasCache: Bool {
        stat.cacheReadTokens > 0 || stat.cacheCreationTokens > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: Theme.Space.s6) {
                Circle()
                    .fill(color)
                    .frame(width: dense ? 6 : 8, height: dense ? 6 : 8)
                Text(stat.model)
                    .font(dense ? Theme.Font.rowTitle : Theme.Font.bodySmall)
                    .foregroundColor(Theme.textPrimary.opacity(isHovered ? 1 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                StatusPill(label: "\(Int((ratio * 100).rounded()))%",
                           tint: color,
                           ink: Theme.barInk(for: stat.model))
                if !sourceSlices.isEmpty {
                    Image(systemName: "chart.pie")
                        .font(Theme.Font.tileDetail)
                        .foregroundColor(Theme.textTertiary(isHovered ? 0.9 : 0.4))
                }
            }
            UsageStackBar(stat: stat, height: dense ? 7 : 10)
            HStack(alignment: .firstTextBaseline) {
                Text(UsageStats.formatTokens(stat.totalTokens))
                    .font(dense ? Theme.Font.tileValueSmall : Theme.Font.displayMetricSmall)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: stat.totalTokens)
                Spacer(minLength: 8)
                if hasCache {
                    StatusPill(
                        label: "缓存 \(stat.cacheHitPercent)%",
                        tint: stat.cacheHitPercent >= 50 ? Theme.statusSuccess : color,
                        ink: stat.cacheHitPercent >= 50 ? Theme.Ink.success : Theme.barInk(for: stat.model)
                    )
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(hovered: isHovered, dense: dense)
        .hoverState($isHovered)
        .animation(Theme.Animation.smooth, value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture { if !sourceSlices.isEmpty { showSourceRing = true } }
        .popover(isPresented: $showSourceRing, arrowEdge: .bottom) {
            sourceRingPopover
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hasCache
            ? "\(stat.model)，\(UsageStats.formatTokens(stat.totalTokens)) tokens，缓存命中 \(stat.cacheHitPercent)%"
            : "\(stat.model)，\(UsageStats.formatTokens(stat.totalTokens)) Token")
    }

    /// Where this model's tokens came from. Opens on click — the ring is the
    /// only place the CC / Codex / 第三方 split is legible per model.
    private var sourceRingPopover: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(stat.model)
                .font(Theme.Font.rowTitle)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(alignment: .center, spacing: Theme.Space.s16) {
                SourceRing(slices: sourceSlices,
                           centerValue: UsageStats.formatTokens(stat.totalTokens),
                           centerCaption: "总用量")
                SourceRingLegend(slices: sourceSlices)
                    .frame(width: 168)
            }
            Text(detailLine)
                .font(Theme.Font.tileDetail)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
        }
        .padding(Theme.Space.s12)
        .frame(width: 330)
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

/// Stacked token anatomy for one model, same palette as UsageRiver.
struct UsageStackBar: View {
    let stat: ModelUsage
    var height: CGFloat = 8

    private var parts: [(Int, Color)] {
        [
            (stat.inputTokens, Theme.claude),
            (stat.cacheReadTokens, Theme.external),
            (stat.cacheCreationTokens, Theme.statusWarning),
            (stat.outputTokens, Theme.cursor),
        ]
    }

    private var total: Int {
        max(parts.reduce(0) { $0 + $1.0 }, 1)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if part.0 > 0 {
                        part.1.opacity(0.88)
                            .frame(width: max(2, geo.size.width * CGFloat(part.0) / CGFloat(total)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(Theme.cardFill(0.07))
        )
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
