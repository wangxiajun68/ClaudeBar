import SwiftUI

/// A raincloud pairs an explicitly estimated density with actual observations.
/// Sparse samples stay as frequency bubbles, without a fabricated smooth shape.
struct UsageDistributionPlot: View {
    let analysis: UsageAnalysis

    private var blue: Color { UsagePlotPalette.blue }
    private var teal: Color { UsagePlotPalette.teal }
    private var purple: Color { UsagePlotPalette.purple }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("周期用量分布").font(Theme.Font.labelSection).foregroundColor(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(analysis.density.isEmpty ? "真实观测 · n = \(analysis.buckets.count)" : "核密度估计 · n = \(analysis.buckets.count)")
                    .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
            }
            Canvas { context, size in
                if analysis.buckets.isEmpty {
                    context.draw(Text("本周期无已到达日期").font(Theme.Font.caption).foregroundColor(Theme.textSecondary),
                                 at: CGPoint(x: size.width / 2, y: size.height / 2))
                } else if analysis.density.isEmpty {
                    drawObservations(context: &context, size: size)
                } else {
                    drawRaincloud(context: &context, size: size)
                }
            }
            .frame(height: 118)
            .accessibilityHidden(true)
            HStack(spacing: 12) {
                readout("P50", analysis.bucketMedian, color: teal)
                readout("P25–P75", analysis.bucketQ25, suffix: "–\(UsageStats.formatTokens(Int(analysis.bucketQ75)))", color: purple)
                Spacer(minLength: 0)
            }
            Text(analysis.density.isEmpty ? sparseCaption : "点为真实周期观测 · 紫色区间为中间 50% · 密度仅描述已记录样本")
                .font(Theme.Font.micro).foregroundColor(Theme.textSecondary).lineLimit(2)
        }
        .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
        .frame(height: 190, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .help(accessibilitySummary)
    }

    private var sparseCaption: String {
        if analysis.buckets.isEmpty { return "仅统计已到达日期" }
        if analysis.distribution.count == 1 { return "所有观测值相同 · 气泡标注真实周期数" }
        return "样本不足以估计密度 · 气泡标注每个数值的真实周期数"
    }

    private var accessibilitySummary: String {
        let values = analysis.buckets.map { "\($0.label)：\($0.total.formatted()) Token" }.joined(separator: "；")
        let method = analysis.density.isEmpty ? "真实观测，无密度估计" : "零边界反射的高斯核密度估计"
        return "\(method)，\(analysis.buckets.count) 个\(analysis.grain)周期。P25 \(analysis.bucketQ25.formatted())，中位数 \(analysis.bucketMedian.formatted())，P75 \(analysis.bucketQ75.formatted()) Token。\(values)"
    }

    private func readout(_ label: String, _ value: Double, suffix: String = "", color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).foregroundColor(Theme.textSecondary)
            Text(UsageStats.formatTokens(Int(value)) + suffix).foregroundColor(Theme.textPrimary)
        }.font(Theme.Font.microMono).lineLimit(1)
    }

    private func plotX(_ value: Double, size: CGSize) -> CGFloat {
        let fraction = (value - analysis.densityLower) / max(1, analysis.densityUpper - analysis.densityLower)
        return 16 + CGFloat(min(1, max(0, fraction))) * max(1, size.width - 32)
    }

    private func drawRaincloud(context: inout GraphicsContext, size: CGSize) {
        let baseline: CGFloat = 58
        let cloudHeight: CGFloat = 48
        var cloud = Path()
        cloud.move(to: CGPoint(x: plotX(analysis.densityLower, size: size), y: baseline))
        for point in analysis.density {
            cloud.addLine(to: CGPoint(x: plotX(point.x, size: size),
                                     y: baseline - CGFloat(point.y / max(.leastNonzeroMagnitude, analysis.densityMaximum)) * cloudHeight))
        }
        cloud.addLine(to: CGPoint(x: plotX(analysis.densityUpper, size: size), y: baseline))
        cloud.closeSubpath()
        context.fill(cloud, with: .color(teal.opacity(Theme.isDark ? 0.42 : 0.24)))
        context.stroke(cloud, with: .color(teal), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))

        // Points preserve raw values on the same linear Token scale; vertical
        // lanes only separate marks and do not encode another measurement.
        for (index, bucket) in analysis.buckets.enumerated() {
            let x = plotX(Double(bucket.total), size: size)
            let y = 69 + CGFloat(index % 4) * 5
            let dot = Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
            context.fill(dot, with: .color(blue.opacity(Theme.isDark ? 0.9 : 0.7)))
        }

        let lower = plotX(analysis.bucketQ25, size: size)
        let upper = plotX(analysis.bucketQ75, size: size)
        var interval = Path()
        interval.move(to: CGPoint(x: lower, y: 94))
        interval.addLine(to: CGPoint(x: upper, y: 94))
        context.stroke(interval, with: .color(purple), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        let middle = plotX(analysis.bucketMedian, size: size)
        let median = Path(ellipseIn: CGRect(x: middle - 5, y: 89, width: 10, height: 10))
        context.fill(median, with: .color(Theme.cardSurface))
        context.stroke(median, with: .color(teal), lineWidth: 2.5)
        drawAxis(context: &context, size: size, y: 111)
    }

    private func drawObservations(context: inout GraphicsContext, size: CGSize) {
        let count = analysis.buckets.count
        var previous = 0.0
        for (index, point) in analysis.distribution.enumerated() {
            let frequency = Int(((point.y - previous) * Double(count)).rounded())
            previous = point.y
            let x = analysis.distribution.count == 1 ? size.width / 2 : plotX(point.x, size: size)
            let y: CGFloat = 48 + CGFloat(index % 2) * 13
            let radius: CGFloat = min(20, 8 + 3 * CGFloat(sqrt(Double(frequency))))
            let bubble = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            context.fill(bubble, with: .color((point.x == 0 ? blue : teal).opacity(Theme.isDark ? 0.42 : 0.24)))
            context.stroke(bubble, with: .color(point.x == 0 ? blue : teal), lineWidth: 2.5)
            context.draw(Text("\(frequency)").font(Theme.Font.microMono).foregroundColor(Theme.textPrimary),
                         at: CGPoint(x: x, y: y))
            let anchor: UnitPoint = x < 36 ? .leading : x > size.width - 36 ? .trailing : .center
            context.draw(Text(UsageStats.formatTokens(Int(point.x))).font(Theme.Font.microMono).foregroundColor(Theme.textPrimary),
                         at: CGPoint(x: x, y: 94 + CGFloat(index % 2) * 14), anchor: anchor)
        }
        if analysis.distribution.count == 1 {
            context.draw(Text("\(count) 个真实周期").font(Theme.Font.micro).foregroundColor(Theme.textSecondary),
                         at: CGPoint(x: size.width / 2, y: 12))
        }
    }

    private func drawAxis(context: inout GraphicsContext, size: CGSize, y: CGFloat) {
        for (value, anchor) in [(analysis.densityLower, UnitPoint.leading), (analysis.densityUpper, UnitPoint.trailing)] {
            context.draw(Text(UsageStats.formatTokens(Int(value))).font(Theme.Font.microMono).foregroundColor(Theme.textSecondary),
                         at: CGPoint(x: plotX(value, size: size), y: y), anchor: anchor)
        }
        context.draw(Text("Token").font(Theme.Font.micro).foregroundColor(Theme.textSecondary),
                     at: CGPoint(x: size.width / 2, y: y))
    }
}
