import SwiftUI

/// Horizontal token mix for the period — same four hues, flat, 4pt track.
struct CacheAnatomyBar: View {
    let stats: [ModelUsage]

    private var input: Int { stats.reduce(0) { $0 + $1.inputTokens } }
    private var hit: Int { stats.reduce(0) { $0 + $1.cacheReadTokens } }
    private var write: Int { stats.reduce(0) { $0 + $1.cacheCreationTokens } }
    private var output: Int { stats.reduce(0) { $0 + $1.outputTokens } }
    private var total: Int { max(input + hit + write + output, 1) }
    private var hitRate: Int {
        let prompt = input + hit + write
        guard prompt > 0 else { return 0 }
        return Int((Double(hit) / Double(prompt) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(alignment: .firstTextBaseline) {
                Text("提示缓存")
                    .font(Theme.Font.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("命中 \(hitRate)%")
                    .font(Theme.Font.microMono)
                    .monospacedDigit()
                    .foregroundColor(Theme.Ink.success)
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    slice(input, geo.size.width, Theme.claude)
                    slice(hit, geo.size.width, Theme.external)
                    slice(write, geo.size.width, Theme.statusWarning)
                    slice(output, geo.size.width, Theme.cursor)
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
                cap("输入", input, Theme.claude)
                cap("命中", hit, Theme.external)
                cap("写入", write, Theme.statusWarning)
                cap("输出", output, Theme.cursor)
            }
        }
    }

    @ViewBuilder
    private func slice(_ n: Int, _ width: CGFloat, _ color: Color) -> some View {
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
            Text("\(label) \(UsageStats.formatTokens(n))")
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary(0.55))
        }
    }
}
