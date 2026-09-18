import SwiftUI

/// Desktop usage tile: model name, totals, tap to expand a source ring
/// (Claude Code / Codex / 第三方).
struct UsageModelCard: View {
    let stat: ModelUsage
    let slices: [SourceRing.Slice]
    var share: Double
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        Button {
            withAnimation(Theme.Animation.smooth) { open.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 6) {
                    Text(stat.model)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if !slices.isEmpty {
                        SourceStack(slices: slices, scan: hovered)
                    }
                    Text("\(stat.calls) 次")
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                }
                Text(UsageStats.formatTokens(stat.totalTokens))
                    .font(Theme.Font.displayMetricSmall)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                AuroraSparkline(
                    values: AuroraSparkline.accentCurve(peak: min(max(share, 0.08), 1)),
                    tint: Theme.chartPurple,
                    live: hovered
                )
                .frame(height: 28)
                if open {
                    HStack(alignment: .center, spacing: 12) {
                        SourceRing(
                            slices: slices,
                            size: 88,
                            thickness: 11,
                            centerValue: UsageStats.formatTokens(stat.totalTokens),
                            centerCaption: "来源"
                        )
                        SourceRingLegend(slices: slices)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tile(hovered: hovered)
            .folderPeek(hovered)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverState($hovered)
        .help(open ? "收起来源" : "查看 Claude Code / Codex / 第三方用量")
    }
}
