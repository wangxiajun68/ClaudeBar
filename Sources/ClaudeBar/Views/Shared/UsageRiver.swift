import SwiftUI

/// Horizontal token mix for the period — same four hues, flat, 4pt track.
struct CacheAnatomyBar: View {
    let stats: [ModelUsage]

    /// One pass over the model list, shared by the track, the four caps and
    /// the hit rate. As computed properties these were five `reduce`s, with
    /// `total` read again per slice and `hitRate` itself reading three of them
    /// — roughly fifteen walks per body pass, on a view that renders for every
    /// user with a cache hit.
    private struct Totals {
        var input = 0
        var hit = 0
        var write = 0
        var output = 0
        var sum: Int { max(input + hit + write + output, 1) }
        var hitRate: Int {
            let prompt = input + hit + write
            guard prompt > 0 else { return 0 }
            return Int((Double(hit) / Double(prompt) * 100).rounded())
        }
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
        return VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(alignment: .firstTextBaseline) {
                Text("提示缓存")
                    .font(Theme.Font.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                RollingNumberText("命中 \(t.hitRate)%")
                    .font(Theme.Font.microMono)
                    .monospacedDigit()
                    .foregroundColor(Theme.Ink.success)
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    slice(t.input, geo.size.width, Theme.claude, total: t.sum)
                    slice(t.hit, geo.size.width, Theme.external, total: t.sum)
                    slice(t.write, geo.size.width, Theme.statusWarning, total: t.sum)
                    slice(t.output, geo.size.width, Theme.cursor, total: t.sum)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
            .frame(height: 4)
            .background(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.cardFill(0.06))
            )
            HStack(spacing: 14) {
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
            color.opacity(0.88)
                .frame(width: max(2, width * CGFloat(n) / CGFloat(total)))
        }
    }

    private func cap(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color.opacity(0.9))
                .frame(width: 6, height: 6)
            RollingNumberText("\(label) \(UsageStats.formatTokens(n))")
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary(0.55))
        }
    }
}
