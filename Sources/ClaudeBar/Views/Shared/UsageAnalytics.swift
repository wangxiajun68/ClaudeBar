import SwiftUI

/// Native usage report: substantial marks, exact proportions, one aligned grid.
/// Temporal records, local model totals and source totals keep their own scope.
struct UsageAnalyticsSection: View {
    let days: [DayUsage]
    let stats: [ModelUsage]
    let sources: [UsageSource: [ModelUsage]]
    let period: UsagePeriod
    let interval: DateInterval
    var onSelectMonth: ((Date) -> Void)? = nil
    var onSelectDay: (Date) -> Void
    @State private var analysis: UsageAnalysis?
    @State private var sourceRows: [SourceValue] = []
    @State private var renderedRequest: Request?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        // Measure both panels at their column width, then
                        // propose the taller height to each card's surface.
                        EqualRowGrid(spacing: 14, minColumnWidth: 380, fixedColumns: 2) {
                            activityCard(a)
                            structureCard(a)
                        }.frame(minWidth: 774)
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
            // Swap the analysis and its chart inputs together, only after the
            // cancellable computation completes. The previous report stays drawn.
            withAnimation(reduceMotion ? nil : Theme.Animation.smooth) {
                renderedRequest = request
                analysis = result.0
                sourceRows = result.1
            }
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
                .contentTransition(.numericText())
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
                heading("用量热力图", "square.grid.3x3.fill")
                Spacer()
                caption("按日 · \(a.activeDays) 天有记录")
            }
            UsageHeatmap(days: renderedRequest?.days ?? days,
                         period: renderedRequest?.period ?? period,
                         reference: renderedRequest?.interval.start ?? interval.start,
                         onSelectDay: onSelectDay, onSelectMonth: onSelectMonth)
            HStack(spacing: 6) {
                caption("少")
                ForEach([0.16, 0.4, 0.7, 1.0], id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 2).fill(Theme.chartPurple.opacity(opacity))
                        .frame(width: 10, height: 10)
                }
                caption("多")
                Spacer()
                caption("悬停查看 · 点击下钻")
            }
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
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).usageFigure()
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
                                .contentTransition(.numericText())
                        }
                        Spacer(minLength: 4)
                        Text(UsageAnalysis.share(part.tokens, of: a.total)).font(Theme.Font.microMono)
                            .foregroundColor(part.tokens > 0 ? part.color : Theme.textTertiary()).fixedSize()
                            .contentTransition(.numericText())
                    }
                    .padding(9)
                    .background(Theme.cardFill(0.025), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .combine)
                    .help("\(part.name)：\(part.tokens.formatted()) Token，占全部 Token 的 \(UsageAnalysis.share(part.tokens, of: a.total))")
                }
            }
            caption("本地记录 · 各分段按真实 Token 比例绘制")
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).usageFigure()
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

/// Exact proportions: zero values occupy no width, including tiny
/// nonzero shares. Labels carry the small values instead of inflating marks.
private struct UsageCompositionBar: View, Animatable {
    var values: [Double]
    let colors: [Color]

    // Four Token components, interpolated as normalized shares. Only this
    // small Canvas redraws during the transition, not the report calculations.
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get {
            let total = values.reduce(0, +)
            let shares = (0..<4).map { index in
                total > 0 && index < values.count ? values[index] / total : 0
            }
            return .init(.init(shares[0], shares[1]), .init(shares[2], shares[3]))
        }
        set {
            values = [newValue.first.first, newValue.first.second,
                      newValue.second.first, newValue.second.second]
        }
    }

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

