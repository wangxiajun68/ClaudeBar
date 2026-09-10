import SwiftUI

/// Period volume: smooth stacked gradient area — soft washes under 1.5pt
/// ridgelines instead of hard columns. Hover for a crosshair + per-day
/// breakdown.
struct UsageRiver: View {
    let days: [DayUsage]
    var height: CGFloat = 120

    @State private var hoverIndex: Int?

    private struct Band: Identifiable {
        let label: String
        let color: Color
        let values: [CGFloat]
        var id: String { label }
    }

    private var bands: [Band] {
        [
            Band(label: "输出", color: Theme.cursor,
                 values: days.map { CGFloat($0.outputTokens) }),
            Band(label: "缓存写入", color: Theme.statusWarning,
                 values: days.map { CGFloat($0.cacheCreationTokens) }),
            Band(label: "缓存命中", color: Theme.external,
                 values: days.map { CGFloat($0.cacheReadTokens) }),
            Band(label: "输入", color: Theme.claude,
                 values: days.map { CGFloat($0.inputTokens) }),
        ]
    }

    private var totals: [CGFloat] {
        days.map { CGFloat($0.totalTokens) }
    }

    private var peak: CGFloat {
        max(totals.max() ?? 1, 1)
    }

    private var hoverDay: DayUsage? {
        guard let hoverIndex, days.indices.contains(hoverIndex) else { return nil }
        return days[hoverIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                ForEach(bands.reversed()) { band in
                    legend(band.label, band.color)
                }
                Spacer()
                Text(caption)
                    .font(Theme.Font.microMono)
                    .monospacedDigit()
                    .foregroundColor(Theme.textTertiary())
                    .contentTransition(.opacity)
            }

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
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

                    if let i = hoverIndex, days.indices.contains(i) {
                        tooltip(for: i, width: geo.size.width)
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
        return "峰 \(UsageStats.formatTokens(Int(peak)))"
    }

    // MARK: - Drawing

    /// Smooth (Catmull-Rom) path through points, left → right.
    private func smoothPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard !pts.isEmpty else { return path }
        path.move(to: pts[0])
        guard pts.count > 1 else { return path }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard days.count > 1 else { return }

        // Recessive horizontal gridlines (hairline, solid) with y ticks.
        let steps = 3
        for s in 1...steps {
            let y = size.height - size.height * CGFloat(s) / CGFloat(steps)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(line, with: .color(Theme.hairline.opacity(0.5)), lineWidth: 0.5)
            let tick = Text(UsageStats.formatTokens(Int(peak * CGFloat(s) / CGFloat(steps))))
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary(0.35))
            ctx.draw(tick, at: CGPoint(x: 2, y: y - 7), anchor: .leading)
        }

        let slot = size.width / CGFloat(days.count - 1)
        let n = days.count

        // Cumulative tops per band (stacked bottom-up).
        var cumulative = [CGFloat](repeating: 0, count: n)
        for band in bands {
            let lower = cumulative
            let upper = zip(cumulative, band.values).map { $0 + $1 }
            cumulative = upper

            let upperPts = upper.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * slot,
                        y: size.height - min(v / peak, 1) * size.height)
            }
            let lowerPts = lower.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * slot,
                        y: size.height - min(v / peak, 1) * size.height)
            }

            var fill = smoothPath(upperPts)
            // Close along the lower boundary, reversed, down to the baseline.
            for p in lowerPts.reversed() { fill.addLine(to: p) }
            fill.closeSubpath()

            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [band.color.opacity(0.30), band.color.opacity(0.04)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(smoothPath(upperPts), with: .color(band.color.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }

        // Crosshair on hover.
        if let i = hoverIndex {
            let x = CGFloat(i) * slot
            var cross = Path()
            cross.move(to: CGPoint(x: x, y: 0))
            cross.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(cross, with: .color(Color.white.opacity(0.22)),
                       style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

            let topY = size.height - min(min(cumulative[i] / peak, 1), 1) * size.height
            let dot = Path(ellipseIn: CGRect(x: x - 3, y: topY - 3, width: 6, height: 6))
            ctx.fill(dot, with: .color(Theme.base0))
            ctx.stroke(dot, with: .color(.white), lineWidth: 1.2)
        }
    }

    // MARK: - Overlays

    private func tooltip(for index: Int, width: CGFloat) -> some View {
        let day = days[index]
        let rows: [(String, Int, Color)] = [
            ("输出", day.outputTokens, Theme.cursor),
            ("写入", day.cacheCreationTokens, Theme.statusWarning),
            ("命中", day.cacheReadTokens, Theme.external),
            ("输入", day.inputTokens, Theme.claude),
        ]
        let slot = width / CGFloat(max(days.count - 1, 1))
        let x = CGFloat(index) * slot
        let flip = x > width * 0.65

        return VStack(alignment: .leading, spacing: 3) {
            Text(shortDay(day.day))
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
            Text(UsageStats.formatTokens(day.totalTokens))
                .font(Theme.Font.microMono)
                .monospacedDigit()
                .foregroundColor(Theme.textPrimary)
            ForEach(rows, id: \.0) { label, value, color in
                if value > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 4, height: 4)
                        Text(label)
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.textTertiary())
                        Spacer()
                        Text(UsageStats.formatTokens(value))
                            .font(Theme.Font.microMono)
                            .monospacedDigit()
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 118)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.base1.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5))
        )
        .offset(x: flip ? x - 126 : x + 8, y: 4)
        .allowsHitTesting(false)
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
