import SwiftUI

/// Compact CC / Codex / 第三方 share — three vertical meters, not a VPN gauge.
struct SourceTriad: View {
    let totals: [(source: UsageSource, tokens: Int)]

    private var peak: Int { max(totals.map(\.tokens).max() ?? 1, 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(totals, id: \.source) { row in
                let h = CGFloat(row.tokens) / CGFloat(peak)
                VStack(spacing: 4) {
                    RollingNumberText(UsageStats.formatTokens(row.tokens))
                        .font(Theme.Font.microMono)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(row.source.color.opacity(row.tokens > 0 ? 0.9 : 0.18))
                        .frame(height: max(6, 52 * h))
                    Text(row.source.shortLabel)
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 86)
        .accessibilityLabel("来源用量")
    }
}

/// Input / cache-hit / cache-write / output as a labeled stacked track.
struct TokenMixStrip: View {
    let stats: [ModelUsage]
    var compact: Bool = false

    /// The four sums, computed in one pass.
    ///
    /// They were four computed properties, each a full `reduce` over `stats`;
    /// `total` was a fifth, and `slice(_:_:_:)` read it again per slice — so
    /// one body pass walked the model list nine times.
    private struct Totals {
        var input = 0
        var hit = 0
        var write = 0
        var output = 0
        var sum: Int { max(input + hit + write + output, 1) }
    }

    private static func totals(_ stats: [ModelUsage]) -> Totals {
        var out = Totals()
        for stat in stats {
            out.input += stat.inputTokens
            out.hit += stat.cacheReadTokens
            out.write += stat.cacheCreationTokens
            out.output += stat.outputTokens
        }
        return out
    }

    var body: some View {
        let t = Self.totals(stats)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    slice(t.input, geo.size.width, Theme.claude, total: t.sum)
                    slice(t.hit, geo.size.width, Theme.external, total: t.sum)
                    slice(t.write, geo.size.width, Theme.statusWarning, total: t.sum)
                    slice(t.output, geo.size.width, Theme.cursor, total: t.sum)
                }
                .clipShape(Capsule())
            }
            .frame(height: compact ? 8 : 10)
            .background(Capsule().fill(Theme.cardFill(0.08)))
            HStack(spacing: compact ? 8 : 12) {
                cap("输入", t.input, Theme.claude)
                cap("命中", t.hit, Theme.external)
                cap("写入", t.write, Theme.statusWarning)
                cap("输出", t.output, Theme.cursor)
            }
        }
    }

    @ViewBuilder
    private func slice(_ n: Int, _ width: CGFloat, _ color: Color, total: Int) -> some View {
        if n > 0 {
            color.opacity(0.9)
                .frame(width: max(2, width * CGFloat(n) / CGFloat(total)))
        }
    }

    private func cap(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            RollingNumberText(compact ? label : "\(label) \(UsageStats.formatTokens(n))")
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
        }
    }
}

/// Daily token sparkline from real `DayUsage` rows — not a decorative curve.
struct UsageDaySpark: View {
    let days: [DayUsage]
    var tint: Color = Theme.chartPurple

    var body: some View {
        AuroraSparkline(
            values: days.map { Double($0.totalTokens) },
            tint: tint,
            live: false
        )
        .frame(height: 44)
        .accessibilityLabel("每日 Token")
    }
}
