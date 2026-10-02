import SwiftUI

/// Input / cache-hit / cache-write / output as a labeled stacked track.
struct TokenMixStrip: View {
    let stats: [ModelUsage]
    /// Selects the compact drawing: 8pt bar, tight legend spacing, bare
    /// labels. The `false` arm — 10pt bar, wider legend, numbered "输入 N"
    /// labels — never ships: every call site in the app passes `true`, so do
    /// not read that arm as live behaviour.
    var compact: Bool = false
    var rolls = true

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
                HStack(spacing: 0) {
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
                .frame(width: width * CGFloat(n) / CGFloat(total))
        }
    }

    private func cap(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            RollingNumberText(compact ? label : "\(label) \(UsageStats.formatTokens(n))", rolls: rolls)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
        }
    }
}
