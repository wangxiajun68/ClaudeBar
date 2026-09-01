import SwiftUI

/// Period ribbon: each day is a vertical stack of fresh input / cache hit /
/// cache write / output. Reads as a film-strip of the selected window — not
/// a conventional bar chart. A single Canvas so month views stay cheap.
struct UsageRiver: View {
    let days: [DayUsage]
    var height: CGFloat = 88

    private var peak: Int {
        max(days.map(\.totalTokens).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 12) {
                legend("输入", Theme.claude)
                legend("缓存命中", Theme.external)
                legend("缓存写入", Theme.statusWarning)
                legend("输出", Theme.cursor)
                Spacer()
            }
            Canvas { ctx, size in
                guard !days.isEmpty else { return }
                let gap: CGFloat = days.count > 20 ? 1 : 2
                let slot = size.width / CGFloat(days.count)
                let barW = max(1, slot - gap)
                for (i, day) in days.enumerated() {
                    let x = CGFloat(i) * slot
                    var y = size.height
                    func band(_ n: Int, _ color: Color) {
                        guard n > 0 else { return }
                        let h = size.height * CGFloat(n) / CGFloat(peak)
                        let rect = CGRect(x: x, y: y - h, width: barW, height: max(h, 0.5))
                        ctx.fill(Path(roundedRect: rect, cornerRadius: min(2, barW / 2)),
                                 with: .color(color))
                        y -= h
                    }
                    band(day.outputTokens, Theme.cursor)
                    band(day.cacheCreationTokens, Theme.statusWarning)
                    band(day.cacheReadTokens, Theme.external)
                    band(day.inputTokens, Theme.claude)
                }
            }
            .frame(height: height)
            if let first = days.first, let last = days.last {
                HStack {
                    Text(shortDay(first.day))
                    Spacer()
                    Text(shortDay(last.day))
                }
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
            }
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }
    }

    private func shortDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return "\(parts[1])/\(parts[2])"
    }
}

/// Horizontal stacked anatomy of one period: fresh / hit / write / output.
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
                Text("命中率 \(hitRate)%")
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.external)
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    slice(input, geo.size.width, Theme.claude)
                    slice(hit, geo.size.width, Theme.external)
                    slice(write, geo.size.width, Theme.statusWarning)
                    slice(output, geo.size.width, Theme.cursor)
                }
            }
            .frame(height: 10)
            HStack(spacing: 12) {
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
            color.frame(width: max(2, width * CGFloat(n) / CGFloat(total)))
        }
    }

    private func cap(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(label) \(UsageStats.formatTokens(n))")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
        }
    }
}
