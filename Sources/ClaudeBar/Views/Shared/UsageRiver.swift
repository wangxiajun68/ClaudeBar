import SwiftUI

/// Period volume: flat stacked columns, no tracks, no candy gradients.
/// Hover a day for its date and tokens.
struct UsageRiver: View {
    let days: [DayUsage]
    var height: CGFloat = 120

    @State private var hoverIndex: Int?

    private var peak: Int {
        max(days.map(\.totalTokens).max() ?? 1, 1)
    }

    private var hoverDay: DayUsage? {
        guard let hoverIndex, days.indices.contains(hoverIndex) else { return nil }
        return days[hoverIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                legend("输入", Theme.claude)
                legend("缓存命中", Theme.external)
                legend("缓存写入", Theme.statusWarning)
                legend("输出", Theme.cursor)
                Spacer()
                Text(caption)
                    .font(Theme.Font.microMono)
                    .monospacedDigit()
                    .foregroundColor(Theme.textTertiary())
                    .contentTransition(.opacity)
            }

            GeometryReader { geo in
                Canvas { ctx, size in
                    draw(ctx: ctx, size: size)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let i = Int(loc.x / geo.size.width * CGFloat(max(days.count, 1)))
                        hoverIndex = min(max(i, 0), max(days.count - 1, 0))
                    case .ended:
                        hoverIndex = nil
                    }
                }
            }
            .frame(height: height)

            if let first = days.first, let last = days.last {
                HStack {
                    Text(shortDay(first.day))
                    if days.count >= 5 {
                        Spacer()
                        Text(shortDay(days[days.count / 2].day))
                    }
                    Spacer()
                    Text(shortDay(last.day))
                }
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
            }
        }
    }

    private var caption: String {
        if let d = hoverDay {
            return "\(shortDay(d.day))  \(UsageStats.formatTokens(d.totalTokens))"
        }
        return "峰 \(UsageStats.formatTokens(peak))"
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !days.isEmpty else { return }
        let n = CGFloat(days.count)
        let gap: CGFloat = days.count > 24 ? 1 : (days.count > 10 ? 2 : 3)
        let slot = size.width / n
        let barW = max(2, slot - gap)
        let radius = min(2, barW / 2)

        var base = Path()
        base.move(to: CGPoint(x: 0, y: size.height - 0.5))
        base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        ctx.stroke(base, with: .color(Theme.hairline.opacity(0.55)), lineWidth: 0.5)

        for (i, day) in days.enumerated() {
            let x = CGFloat(i) * slot + gap / 2
            let highlighted = hoverIndex == i
            let stackH = max(
                day.totalTokens > 0 ? 2 : 0,
                size.height * CGFloat(day.totalTokens) / CGFloat(peak))
            guard stackH > 0 else { continue }

            if highlighted {
                let wash = CGRect(x: x - 1, y: 0, width: barW + 2, height: size.height)
                ctx.fill(Path(wash), with: .color(Color.white.opacity(0.04)))
            }

            let column = CGRect(x: x, y: size.height - stackH, width: barW, height: stackH)
            var col = ctx
            col.clip(to: Path(roundedRect: column, cornerRadius: radius, style: .continuous))

            var y = size.height
            let bands: [(Int, Color)] = [
                (day.outputTokens, Theme.cursor),
                (day.cacheCreationTokens, Theme.statusWarning),
                (day.cacheReadTokens, Theme.external),
                (day.inputTokens, Theme.claude),
            ]
            for (tokens, color) in bands {
                guard tokens > 0 else { continue }
                let h = max(1, size.height * CGFloat(tokens) / CGFloat(peak))
                let rect = CGRect(x: x, y: y - h, width: barW, height: h)
                col.fill(Path(rect), with: .color(color.opacity(highlighted ? 0.95 : 0.82)))
                y -= h
            }
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color.opacity(0.9))
                .frame(width: 6, height: 6)
            Text(label)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary(0.55))
        }
    }

    private func shortDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return "\(parts[1])/\(parts[2])"
    }
}

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
                    .foregroundColor(Theme.external)
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
