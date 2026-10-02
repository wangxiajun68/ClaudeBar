import SwiftUI

/// Native usage report: substantial marks, exact proportions, one aligned grid.
/// Temporal records, local model totals and source totals keep their own scope.
struct UsageAnalyticsSection: View {
    let days: [DayUsage]
    let stats: [ModelUsage]
    let sources: [UsageSource: [ModelUsage]]
    let period: UsagePeriod
    let interval: DateInterval
    var onSelectDay: (Date) -> Void
    @State private var analysis: UsageAnalysis?
    @State private var sourceRows: [SourceValue] = []
    @State private var compressed = false
    @State private var selectedDate: Date?

    private struct Request: Equatable {
        let days: [DayUsage]; let stats: [ModelUsage]
        let sources: [UsageSource: [ModelUsage]]
        let period: UsagePeriod; let interval: DateInterval
    }
    private struct SourceValue: Identifiable {
        let source: UsageSource; let tokens: Int
        var id: UsageSource { source }
    }
    private struct TokenPart: Identifiable {
        let name: String; let tokens: Int; let color: Color; let symbol: String
        var id: String { name }
    }

    var body: some View {
        Group {
            if let a = analysis {
                VStack(alignment: .leading, spacing: 14) {
                    metrics(a)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            activityCard(a).frame(minWidth: 380, idealWidth: 380, maxWidth: .infinity)
                            structureCard(a).frame(minWidth: 380, idealWidth: 380, maxWidth: .infinity)
                        }
                        VStack(spacing: 14) { activityCard(a); structureCard(a) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView("整理本周期用量…").frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .task(id: Request(days: days, stats: stats, sources: sources, period: period, interval: interval)) {
            let request = Request(days: days, stats: stats, sources: sources, period: period, interval: interval)
            let result = await Task.detached(priority: .userInitiated) {
                let a = UsageAnalysis(days: request.days, stats: request.stats, period: request.period, interval: request.interval)
                let sourceValues = UsageSource.allCases.map { source in
                    SourceValue(source: source, tokens: request.sources[source, default: []].reduce(0) { $0 + $1.totalTokens })
                }
                return (a, sourceValues)
            }.value
            guard !Task.isCancelled else { return }
            analysis = result.0; sourceRows = result.1
            selectedDate = nil
        }
    }

    private func metrics(_ a: UsageAnalysis) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) { metricItems(a) }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 18) { metricItems(a) }
        }.padding(20).usageFigure()
    }
    @ViewBuilder private func metricItems(_ a: UsageAnalysis) -> some View {
        metric("本地 Token", UsageStats.formatTokens(a.total), symbol: "chart.bar.fill", color: UsagePlotPalette.blue,
               note: "本地合计 · 按\(a.grain)记录", help: "本地模型记录，不包含 Cursor 官方账单") {
            UsageMiniBars(values: a.buckets.map { Double($0.total) }, color: UsagePlotPalette.blue)
        }
        metric("有记录的天数", "\(a.activeDays) / \(a.daily.count)", symbol: "calendar", color: UsagePlotPalette.teal,
               note: "已到达日期 · 包含零记录日", help: "排除未来日期；已到达但无记录的日期为零") {
            metricTrack(a.daily.isEmpty ? 0 : Double(a.activeDays) / Double(a.daily.count), color: UsagePlotPalette.teal)
        }
        metric("日用量中位数", UsageStats.formatTokens(Int(a.median)), symbol: "chart.bar.xaxis", color: UsagePlotPalette.purple,
               note: "P50 · 相对于日峰值", help: "日 P50：包含零记录日的线性插值中位数") {
            quantileTrack(a.median, maximum: a.daily.map(\.total).max() ?? 0, color: UsagePlotPalette.purple, hasDates: !a.daily.isEmpty)
        }
        metric("日用量 P95", UsageStats.formatTokens(Int(a.p95)), symbol: "chart.line.uptrend.xyaxis", color: UsagePlotPalette.orange,
               note: "P95 · 相对于日峰值", help: "包含零记录日的线性插值 95 分位数；不是预测或实测覆盖率") {
            quantileTrack(a.p95, maximum: a.daily.map(\.total).max() ?? 0, color: UsagePlotPalette.orange, hasDates: !a.daily.isEmpty)
        }
        metric("缓存命中率", rateLabel(a.hitRate), symbol: "arrow.triangle.2.circlepath", color: UsagePlotPalette.teal,
               note: "缓存读取 / 全部输入", help: "读取 / (输入 + 读取 + 写入)，不含输出") {
            metricTrack(a.hitRate ?? 0, color: UsagePlotPalette.teal)
        }
    }
    private func metric<Graphic: View>(_ label: String, _ value: String, symbol: String, color: Color,
                                       note: String, help: String, @ViewBuilder graphic: () -> Graphic) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color).frame(width: 26, height: 26)
                    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                Text(label).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(Theme.textPrimary).fixedSize(horizontal: true, vertical: false)
            graphic().frame(height: 18).accessibilityHidden(true)
            Text(note).font(Theme.Font.micro).foregroundColor(Theme.textSecondary).lineLimit(1)
        }.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading).help(help)
            .accessibilityElement(children: .combine)
    }
    private func metricTrack(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.10))
                Capsule().fill(color.gradient).frame(width: geo.size.width * min(1, max(0, fraction)))
            }.frame(height: 5).frame(maxHeight: .infinity)
        }
    }

    private func quantileTrack(_ value: Double, maximum: Int, color: Color, hasDates: Bool) -> some View {
        Canvas { context, size in
            let y = size.height / 2
            var axis = Path()
            axis.move(to: CGPoint(x: 4, y: y)); axis.addLine(to: CGPoint(x: size.width - 4, y: y))
            context.stroke(axis, with: .color(color.opacity(0.18)), lineWidth: 2)
            for x in [4.0, size.width - 4] {
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: y - 3)); tick.addLine(to: CGPoint(x: x, y: y + 3))
                context.stroke(tick, with: .color(color.opacity(0.4)), lineWidth: 1)
            }
            guard hasDates else { return }
            let x = 4 + (size.width - 8) * min(1, max(0, value / Double(max(1, maximum))))
            context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(color))
        }
    }

    private func activityCard(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading(a.buckets.count > 1 ? "用量趋势" : "来源份额", a.buckets.count > 1 ? "chart.xyaxis.line" : "square.grid.2x2")
                Spacer()
                caption(a.buckets.count > 1 ? "按\(a.grain) · \(a.buckets.count) 个周期" : "本地记录")
                if a.buckets.count > 1 {
                    Button { compressed.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.plain).help(compressed ? "使用原值坐标" : "使用长尾坐标")
                        .accessibilityLabel("切换坐标尺度")
                }
            }
            if a.buckets.count > 1 {
                trajectory(a)
                HStack(spacing: 16) {
                    ForEach(sourceRows) { row in
                        HStack(spacing: 5) {
                            ProductBrandMark(brand: row.source.brandMark).frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                            Circle().fill(UsageReportPalette.source(row.source)).frame(width: 5, height: 5)
                            Text(row.source.shortLabel)
                            Text(UsageAnalysis.share(row.tokens, of: sourceRows.reduce(0) { $0 + $1.tokens }))
                                .monospacedDigit()
                        }.font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                    }
                }
            } else {
                sourceComposition
                caption(a.buckets.isEmpty ? "本周期无已到达日期" : "来源占比不含 Cursor 官方账单")
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading).usageFigure()
    }

    private func structureCard(_ a: UsageAnalysis) -> some View {
        let parts = [TokenPart(name: "输入", tokens: a.input, color: UsageReportPalette.indigo, symbol: "arrow.down.left"),
                     TokenPart(name: "缓存读取", tokens: a.hit, color: UsageReportPalette.teal, symbol: "arrow.triangle.2.circlepath"),
                     TokenPart(name: "缓存写入", tokens: a.write, color: UsageReportPalette.amber, symbol: "square.and.arrow.down"),
                     TokenPart(name: "输出", tokens: a.output, color: UsageReportPalette.violet, symbol: "arrow.up.right")]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading("Token 构成", "chart.bar.xaxis")
                Spacer()
                Label("命中 \(rateLabel(a.hitRate))", systemImage: "memorychip")
                    .font(Theme.Font.microMedium).foregroundColor(UsageReportPalette.teal)
                    .help("缓存读取 / 全部输入 Token；输出不计入分母")
            }
            UsageCompositionBar(values: parts.map { Double($0.tokens) }, colors: parts.map(\.color))
                .frame(height: 12).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                ForEach(parts) { part in
                    HStack(spacing: 8) {
                        Image(systemName: part.symbol).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(part.color).frame(width: 26, height: 26)
                            .background(part.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(part.name).font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                            Text(UsageStats.formatTokens(part.tokens)).font(Theme.Font.chromeEmph.monospacedDigit())
                                .foregroundColor(Theme.textPrimary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(UsageAnalysis.share(part.tokens, of: a.total)).font(Theme.Font.microMono)
                            .foregroundColor(part.tokens > 0 ? part.color : Theme.textTertiary()).fixedSize()
                    }
                    .padding(9)
                    .background(Theme.cardFill(0.025), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .combine)
                    .help("\(part.name)：\(part.tokens.formatted()) Token，占全部 Token 的 \(UsageAnalysis.share(part.tokens, of: a.total))")
                }
            }
            caption("本地记录 · 各分段按真实 Token 比例绘制")
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading).usageFigure()
    }

    private func trajectory(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let left: CGFloat = 70
                let height: CGFloat = 82
                let width = max(1, geo.size.width - left)
                let column = width / Double(a.buckets.count)
                Canvas { context, _ in
                    for value in ticks(a) {
                        let y = height * (1 - value / upper(a))
                        var guide = Path()
                        guide.move(to: CGPoint(x: left - 4, y: y))
                        guide.addLine(to: CGPoint(x: left, y: y))
                        context.stroke(guide, with: .color(Theme.textSecondary), lineWidth: 1)
                        context.draw(Text(tokenLabel(value, a)).font(Theme.Font.micro).foregroundColor(Theme.textSecondary),
                                     at: CGPoint(x: left - 8, y: y), anchor: .trailing)
                    }
                    var axes = Path()
                    axes.move(to: CGPoint(x: left, y: 0)); axes.addLine(to: CGPoint(x: left, y: height))
                    axes.addLine(to: CGPoint(x: geo.size.width, y: height))
                    context.stroke(axes, with: .color(Theme.hairline), lineWidth: 1)
                    let points = a.buckets.enumerated().map { index, row in
                        CGPoint(x: left + column * (Double(index) + 0.5), y: height * (1 - coordinate(Double(row.total), a) / upper(a)))
                    }
                    if let first = points.first, let last = points.last {
                        var line = Path(); line.move(to: first)
                        for point in points.dropFirst() { line.addLine(to: point) }
                        var area = line
                        area.addLine(to: CGPoint(x: last.x, y: height))
                        area.addLine(to: CGPoint(x: first.x, y: height)); area.closeSubpath()
                        context.fill(area, with: .linearGradient(Gradient(colors: [UsagePlotPalette.blue.opacity(0.36), UsagePlotPalette.blue.opacity(0.06)]),
                                     startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: height)))
                        context.stroke(line, with: .color(UsagePlotPalette.blue), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        for (index, point) in points.enumerated() {
                            let row = a.buckets[index]
                            let radius: CGFloat = row.date == selectedDate || row.total == a.bucketMaximum ? 5 : 3.5
                            let color = row.total == a.bucketMaximum ? UsagePlotPalette.clay : UsagePlotPalette.blue
                            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                        }
                    }
                    for index in axisIndices(a) {
                        let anchor: UnitPoint = index == 0 ? .topLeading : index == a.buckets.count - 1 ? .topTrailing : .top
                        let x = index == 0 ? left : index == a.buckets.count - 1 ? geo.size.width : left + column * (Double(index) + 0.5)
                        context.draw(Text(UsageStats.formatter(a.grain == "年" ? "yyyy" : a.grain == "月" ? "yyyy/M" : "M/d").string(from: a.buckets[index].date)).font(Theme.Font.micro).foregroundColor(Theme.textSecondary),
                                     at: CGPoint(x: x, y: height + 8), anchor: anchor)
                    }
                }.accessibilityHidden(true)
                HStack(spacing: 0) {
                    ForEach(a.buckets) { row in
                        Button {
                            selectedDate = row.date
                            if a.grain == "日" { onSelectDay(row.date) }
                        } label: { Color.clear.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(row.label)，\(row.total.formatted()) Token，缓存命中 \(rateLabel(row.hitRate))")
                            .help("\(row.label) · \(row.total.formatted()) Token")
                    }
                }.padding(.leading, left).frame(height: height)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let x = point.x - left
                        guard x >= 0, x < width, point.y >= 0, point.y <= height else { selectedDate = nil; return }
                        let index = Int(x / column)
                        selectedDate = a.buckets.indices.contains(index) ? a.buckets[index].date : nil
                    case .ended: selectedDate = nil
                    }
                }
            }.frame(height: 108)
            HStack {
                Text(inspected(a).map { "\($0.total.formatted()) Token · 缓存命中 \(rateLabel($0.hitRate))" } ?? "峰值 \(UsageStats.formatTokens(a.bucketMaximum)) · \(a.buckets.count) 个观测周期")
                Spacer()
                Text(a.grain == "日" ? "悬停查看 · 点击日期下钻" : "悬停查看周期用量")
            }.font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
        }
    }
    private func coordinate(_ value: Double, _ a: UsageAnalysis) -> Double { compressed ? asinh(value / a.tokenScale) : value }
    private func upper(_ a: UsageAnalysis) -> Double { max(1, coordinate(Double(a.bucketMaximum), a) * 1.15) }
    private func ticks(_ a: UsageAnalysis) -> [Double] { [0, upper(a) / 2, upper(a)] }
    private func tokenLabel(_ value: Double, _ a: UsageAnalysis) -> String {
        UsageStats.formatTokens(Int(max(0, compressed ? sinh(value) * a.tokenScale : value)))
    }
    private func inspected(_ a: UsageAnalysis) -> UsageAnalysis.Bucket? {
        guard let selectedDate else { return nil }
        return a.buckets.first { $0.date == selectedDate }
    }
    private func axisIndices(_ a: UsageAnalysis) -> [Int] {
        let stride = max(1, Int(ceil(Double(a.buckets.count) / 8)))
        return a.buckets.indices.filter { $0 % stride == 0 || $0 == a.buckets.count - 1 }
    }
    private var sourceComposition: some View {
        let total = sourceRows.reduce(0) { $0 + $1.tokens }
        return VStack(alignment: .leading, spacing: 12) {
            UsageCompositionBar(values: sourceRows.map { Double($0.tokens) },
                                colors: sourceRows.map { UsageReportPalette.source($0.source) })
                .frame(height: 12).accessibilityHidden(true)
            HStack(alignment: .top, spacing: 8) {
                ForEach(sourceRows) { row in
                    let color = UsageReportPalette.source(row.source)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ProductBrandMark(brand: row.source.brandMark).frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                            Text(row.source.label).font(Theme.Font.microMedium)
                                .foregroundColor(Theme.textSecondary).lineLimit(1)
                        }
                        Text(UsageAnalysis.share(row.tokens, of: total))
                            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundColor(row.tokens > 0 ? color : Theme.textTertiary())
                            .lineLimit(1)
                        Text(UsageStats.formatTokens(row.tokens) + " Token")
                            .font(Theme.Font.microMono).foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(color.opacity(row.tokens > 0 ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        Capsule().fill(color.opacity(row.tokens > 0 ? 0.8 : 0.2))
                            .frame(width: 20, height: 2).padding(.leading, 10)
                    }
                    .accessibilityElement(children: .combine)
                    .help("\(row.source.label)：\(row.tokens.formatted()) Token，\(UsageAnalysis.share(row.tokens, of: total))")
                }
            }
        }.help("来源总量 \(total.formatted()) Token，不含 Cursor 官方账单")
    }

    private func rateLabel(_ rate: Double?) -> String { rate.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
    private func caption(_ text: String) -> some View { Text(text).font(Theme.Font.caption).foregroundColor(Theme.textSecondary) }
    private func heading(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            AppGlyph(name: symbol, size: 14).foregroundColor(Theme.textSecondary).accessibilityHidden(true)
            Text(title).font(Theme.Font.chromeEmph)
        }.foregroundColor(Theme.textPrimary).accessibilityAddTraits(.isHeader)
    }
}

/// Exact proportions: zero values occupy no arc or width, including tiny
/// nonzero shares. Labels carry the small values instead of inflating marks.
private struct UsageCompositionBar: View {
    let values: [Double]
    let colors: [Color]
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.cardFill(0.06)))
            let total = values.reduce(0, +)
            guard total > 0 else { return }
            var x = 0.0
            for index in values.indices where values[index] > 0 {
                let width = size.width * values[index] / total
                let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(rect), with: .color(colors[index]))
                x += width
            }
        }.clipShape(Capsule())
    }
}

private struct UsageMiniBars: View {
    let values: [Double]
    let color: Color
    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let maximum = max(1, values.max() ?? 0)
            let step = size.width / Double(values.count)
            for index in values.indices {
                let height = size.height * values[index] / maximum
                let rect = CGRect(x: Double(index) * step, y: size.height - max(1, height),
                                  width: min(8, step * 0.72), height: max(1, height))
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(values[index] > 0 ? 0.8 : 0.12)))
            }
        }
    }
}

/// The two overview charts share a restrained categorical palette. Keep
/// these roles separate from the sequential scales used by detailed plots.
private enum UsageReportPalette {
    static var indigo: Color { Color(hex: Theme.isDark ? 0x969EFF : 0x5865DC) }
    static var teal: Color { Color(hex: Theme.isDark ? 0x66D3C2 : 0x229B87) }
    static var amber: Color { Color(hex: Theme.isDark ? 0xE8C78B : 0xBD914B) }
    static var violet: Color { Color(hex: Theme.isDark ? 0xC2A9F1 : 0x9472CC) }
    static var slate: Color { Color(hex: Theme.isDark ? 0xA0AFC6 : 0x8492AA) }
    static func source(_ source: UsageSource) -> Color {
        switch source { case .claude: return indigo; case .codex: return teal; case .thirdParty: return slate }
    }
}

/// Plot roles have authored light/dark values.
enum UsagePlotPalette {
    static var blue: Color { Color(hex: Theme.isDark ? 0x91B5DA : 0x5F8FBC) }
    static var clay: Color { Color(hex: Theme.isDark ? 0xEAA084 : 0xD97757) }
    static var teal: Color { Color(hex: Theme.isDark ? 0x6DCFC7 : 0x278F89) }
    static var orange: Color { Color(hex: Theme.isDark ? 0xE8BD78 : 0xBB8840) }
    static var purple: Color { Color(hex: Theme.isDark ? 0xC2AAE4 : 0x9673BC) }
}

extension View {
    func usageFigure() -> some View {
        self.background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline))
    }
}

