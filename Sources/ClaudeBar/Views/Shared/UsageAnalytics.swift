import SwiftUI
import Charts

/// Compact linked exploratory figures; summaries and curves are cached off-main.
struct UsageAnalyticsSection: View {
    let days: [DayUsage]
    let stats: [ModelUsage]
    let sources: [UsageSource: [ModelUsage]]
    let period: UsagePeriod
    let interval: DateInterval
    var onSelectDay: (Date) -> Void
    @State private var analysis: UsageAnalysis?
    @State private var sourceRows: [SourceValue] = []
    @State private var matrix: [MatrixRow] = []
    @State private var matrixMaximum = 1
    @State private var compressed = true
    @State private var calendarMode = false
    @State private var selectedDate: Date?
    @State private var distributionX: Double?

    private struct Request: Equatable {
        let days: [DayUsage]; let stats: [ModelUsage]
        let sources: [UsageSource: [ModelUsage]]
        let period: UsagePeriod; let interval: DateInterval
    }
    private struct SourceValue: Identifiable {
        let source: UsageSource; let tokens: Int
        var id: UsageSource { source }
    }
    private struct MatrixRow: Identifiable {
        let name: String; let tokens: Int; let cells: [Int]
        var id: String { name }
    }
    var body: some View {
        Group {
            if let a = analysis {
                VStack(alignment: .leading, spacing: 10) {
                    metrics(a)
                    activity(a)
                    structure(a)
                }
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 100) }
        }
        .task(id: Request(days: days, stats: stats, sources: sources, period: period, interval: interval)) {
            let request = Request(days: days, stats: stats, sources: sources, period: period, interval: interval)
            let result = await Task.detached(priority: .userInitiated) {
                let a = UsageAnalysis(days: request.days, stats: request.stats, period: request.period, interval: request.interval)
                let sourceValues = UsageSource.allCases.map { source in
                    SourceValue(source: source, tokens: request.sources[source, default: []].reduce(0) { $0 + $1.totalTokens })
                }
                let dictionaries = UsageSource.allCases.map { source in
                    request.sources[source, default: []].reduce(into: [String: Int]()) { $0[$1.model, default: 0] += $1.totalTokens }
                }
                let matrixRows = a.models.prefix(8).map { model in
                    MatrixRow(name: model.name, tokens: model.tokens, cells: dictionaries.map { $0[model.name, default: 0] })
                }
                return (a, sourceValues, matrixRows, max(1, matrixRows.flatMap(\.cells).max() ?? 0))
            }.value
            guard !Task.isCancelled else { return }
            analysis = result.0; sourceRows = result.1; matrix = result.2; matrixMaximum = result.3
            selectedDate = nil; distributionX = nil
        }
    }
    private func metrics(_ a: UsageAnalysis) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) { metricItems(a) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) { metricItems(a) }
        }.padding(.horizontal, 14).padding(.vertical, 10).usageFigure()
    }
    @ViewBuilder private func metricItems(_ a: UsageAnalysis) -> some View {
        metric("Token", UsageStats.formatTokens(a.total), help: "本地记录，不包含 Cursor 官方账单")
        metric("记录日", "\(a.activeDays)/\(a.daily.count)", help: "排除未来日期；已到达但无记录的日期为零")
        metric("日 P50", UsageStats.formatTokens(Int(a.median)), help: "包含零记录日的线性插值中位数")
        metric("日 P95", UsageStats.formatTokens(Int(a.p95)), help: "包含零记录日的线性插值95分位数；不是实测覆盖率")
        metric("缓存命中", a.hitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—", help: "读取 / (输入 + 读取 + 写入)，不含输出")
    }
    private func metric(_ label: String, _ value: String, help: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundColor(Theme.textPrimary)
        }.fixedSize().frame(maxWidth: .infinity, alignment: .leading).help(help)
    }
    private func activity(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                heading("活动剖面", "waveform.path")
                Text("按\(a.grain)").font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                SegmentedCapsule(items: [false, true], selection: calendarMode, title: { $0 ? "日历" : "轨迹" }, onSelect: { calendarMode = $0 })
                    .accessibilityLabel("活动图展示方式")
                Spacer()
                if !calendarMode {
                    SegmentedCapsule(items: [false, true], selection: compressed, title: { $0 ? "长尾" : "原值" }, onSelect: { compressed = $0 })
                        .help("长尾轴 = asinh(Token / c)，c 为正值中位数；保留零值，刻度仍显示原始 Token。")
                        .accessibilityLabel("Token 坐标尺度")
                }
            }
            if calendarMode { calendarContent(a) }
            else if a.buckets.isEmpty { emptyFigure }
            else {
                ViewThatFits(in: .horizontal) {
                    GeometryReader { geo in
                        HStack(alignment: .top, spacing: 16) {
                            trajectory(a).frame(width: (geo.size.width - 16) * 0.64)
                            distribution(a).frame(maxWidth: .infinity)
                        }
                    }.frame(minWidth: 700).frame(height: 200)
                    VStack(spacing: 16) { trajectory(a); distribution(a) }
                }
                HStack(spacing: 8) {
                    Text("缓存 0%").font(Theme.Font.micro)
                    LinearGradient(colors: [PlotInk.blue, PlotInk.teal], startPoint: .leading, endPoint: .trailing).frame(width: 64, height: 5)
                    Text("100%").font(Theme.Font.micro)
                    Spacer()
                    Text(detail(a)).font(Theme.Font.captionMono).lineLimit(1).textSelection(.enabled)
                }.foregroundColor(Theme.textSecondary)
            }
        }.padding(14).usageFigure()
    }
    private func trajectory(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("用量轨迹").font(Theme.Font.labelSection).foregroundColor(Theme.textPrimary)
                Spacer()
                Text("峰值 \(UsageStats.formatTokens(a.bucketMaximum)) · \(compressed ? "长尾轴" : "线性轴")").font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
            }
            Chart {
                ForEach(a.buckets) { row in
                    AreaMark(x: .value("日期", row.date), y: .value("Token", coordinate(Double(row.total), a)))
                        .foregroundStyle(LinearGradient(colors: [PlotInk.blue.opacity(0.24), PlotInk.blue.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("日期", row.date), y: .value("Token", coordinate(Double(row.total), a)))
                        .foregroundStyle(PlotInk.blue).lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                    PointMark(x: .value("日期", row.date), y: .value("Token", coordinate(Double(row.total), a)))
                        .foregroundStyle(cacheColor(row)).symbolSize(row.total > 0 ? 24 : 12)
                        .accessibilityLabel(Text("\(UsageStats.formatter("yyyy-M-d").string(from: row.date))，\(row.total.formatted()) Token"))
                }
                RuleMark(y: .value("中位数", coordinate(a.bucketMedian, a)))
                    .foregroundStyle(Theme.textSecondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("P50 \(UsageStats.formatTokens(Int(a.bucketMedian)))").font(Theme.Font.microMono).foregroundColor(Theme.textSecondary)
                    }
                if let row = inspected(a) {
                    RuleMark(x: .value("选中日期", row.date)).foregroundStyle(Theme.textSecondary.opacity(0.35))
                    PointMark(x: .value("日期", row.date), y: .value("Token", coordinate(Double(row.total), a)))
                        .symbol { Circle().strokeBorder(Theme.textPrimary, lineWidth: 1.5).frame(width: 11, height: 11) }
                }
            }
            .chartXScale(domain: dateDomain(a))
            .chartYScale(domain: 0...upper(a))
            .chartXAxis { AxisMarks(values: axisDates(a)) { _ in
                AxisValueLabel(format: a.grain == "年" ? .dateTime.year() : a.grain == "月" ? .dateTime.year().month() : .dateTime.month().day())
            } }
            .chartYAxis { AxisMarks(position: .leading, values: ticks(a)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Theme.hairline)
                AxisValueLabel { if let n = value.as(Double.self) { Text(tokenLabel(n, a)).font(Theme.Font.micro) } }
            } }
            .chartXSelection(value: $selectedDate)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            if let frame = proxy.plotFrame { selectedDate = proxy.value(atX: point.x - geo[frame].origin.x, as: Date.self); distributionX = nil }
                        case .ended: selectedDate = nil
                        }
                    }
                }
            }
            .frame(height: 174)
            .accessibilityLabel("日期与 Token 的活动轨迹；颜色为提示侧缓存命中率。连线连接统计周期，不表示小时采样。")
        }
    }
    private func distribution(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("用量分布 · ECDF").font(Theme.Font.labelSection).foregroundColor(Theme.textPrimary)
                Spacer()
                Text("≤ Token").font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
            }
            Chart {
                AreaMark(x: .value("Token", 0.0), y: .value("比例", 0.0))
                    .foregroundStyle(PlotInk.teal.opacity(0.10)).interpolationMethod(.stepEnd)
                LineMark(x: .value("Token", 0.0), y: .value("比例", 0.0))
                    .foregroundStyle(PlotInk.teal).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.stepEnd)
                ForEach([50.0, 95.0], id: \.self) { level in
                    RuleMark(y: .value("累计比例", level))
                        .foregroundStyle(PlotInk.teal.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("\(Int(level))%").font(Theme.Font.microMono).foregroundColor(Theme.textSecondary)
                        }
                }
                ForEach(a.distribution) { point in
                    AreaMark(x: .value("Token", coordinate(point.x, a)), y: .value("比例", point.y * 100))
                        .foregroundStyle(PlotInk.teal.opacity(0.10)).interpolationMethod(.stepEnd)
                    LineMark(x: .value("Token", coordinate(point.x, a)), y: .value("比例", point.y * 100))
                        .foregroundStyle(PlotInk.teal).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.stepEnd)
                }
                if let row = inspected(a) {
                    RuleMark(x: .value("选中 Token", coordinate(Double(row.total), a)))
                        .foregroundStyle(PlotInk.teal).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .chartXScale(domain: 0...upper(a)).chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: ticks(a, count: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel { if let n = value.as(Double.self) { Text(tokenLabel(n, a)).font(Theme.Font.micro) } }
            } }
            .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel { if let n = value.as(Int.self) { Text("\(n)%").font(Theme.Font.micro) } }
            } }
            .chartXSelection(value: $distributionX)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            if let frame = proxy.plotFrame { distributionX = proxy.value(atX: point.x - geo[frame].origin.x, as: Double.self); selectedDate = nil }
                        case .ended: distributionX = nil
                        }
                    }
                }
            }
            .frame(height: 174)
            .accessibilityLabel("经验累积分布。纵轴是总量小于等于横轴 Token 的周期比例，包含零记录周期。")
        }
    }
    private func coordinate(_ value: Double, _ a: UsageAnalysis) -> Double { compressed ? asinh(value / a.tokenScale) : value }
    private func upper(_ a: UsageAnalysis) -> Double { max(1, coordinate(Double(a.bucketMaximum), a) * 1.07) }
    private func ticks(_ a: UsageAnalysis, count: Int = 4) -> [Double] { (0..<count).map { upper(a) * Double($0) / Double(count - 1) } }
    private func tokenLabel(_ value: Double, _ a: UsageAnalysis) -> String {
        UsageStats.formatTokens(Int(max(0, compressed ? sinh(value) * a.tokenScale : value)))
    }
    private func cacheColor(_ row: UsageAnalysis.Bucket) -> Color {
        guard let rate = row.hitRate else { return Theme.textSecondary.opacity(0.65) }
        return PlotInk.cache(rate)
    }
    private func inspected(_ a: UsageAnalysis) -> UsageAnalysis.Bucket? {
        if let distributionX { return a.buckets.min { abs(coordinate(Double($0.total), a) - distributionX) < abs(coordinate(Double($1.total), a) - distributionX) } }
        guard let selectedDate else { return nil }
        return a.buckets.first { $0.date <= selectedDate && selectedDate < $0.end }
    }
    private func detail(_ a: UsageAnalysis) -> String {
        guard let row = inspected(a) else { return "\(a.buckets.count) 个周期 · 悬停联动 · 中位数虚线" }
        let date = UsageStats.formatter(a.grain == "年" ? "yyyy" : a.grain == "月" ? "yyyy-M" : "M/d").string(from: row.date)
        let percentile = a.distribution.last { $0.x <= Double(row.total) }?.y ?? 0
        return "\(date) · \(row.total.formatted()) Token · 命中 \(UsageAnalysis.share(row.hit, of: row.prompt)) · 累积 \(Int((percentile * 100).rounded()))%"
    }
    private func dateDomain(_ a: UsageAnalysis) -> ClosedRange<Date> {
        let start = a.buckets.first?.date ?? interval.start
        let end = a.buckets.last?.date ?? start
        let padding = max(86400, (a.buckets.first?.end ?? start).timeIntervalSince(start)) * 0.3
        return start.addingTimeInterval(-padding)...end.addingTimeInterval(padding)
    }
    private func axisDates(_ a: UsageAnalysis) -> [Date] {
        let stride = max(1, Int(ceil(Double(a.buckets.count) / 6)))
        return a.buckets.enumerated().filter { $0.offset % stride == 0 || $0.offset == a.buckets.count - 1 }.map { $0.element.date }
    }
    private func calendarContent(_ a: UsageAnalysis) -> some View {
        VStack(spacing: 5) {
            UsageCalendarPlot(rows: a.calendarRows, maximum: a.calendarMaximum, truncated: a.daily.count > 366, reference: interval.start, onSelect: onSelectDay).frame(height: 174)
            HStack(spacing: 8) {
                Text("0 为灰色 · 正值对数色阶").font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                LinearGradient(colors: PlotInk.viridis, startPoint: .leading, endPoint: .trailing).frame(width: 72, height: 5)
                Text(UsageStats.formatTokens(a.calendarMaximum)).font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                Spacer()
                Menu {
                    ForEach(a.calendarRows) { row in
                        Button("\(UsageStats.formatter("yyyy-M-d").string(from: row.date)) · \(UsageStats.formatTokens(row.total))") { onSelectDay(row.date) }
                    }
                } label: { Label("选择日期", systemImage: "cursorarrow.click") }
                .menuStyle(.borderlessButton).fixedSize().font(Theme.Font.micro)
            }
        }
    }
    private func structure(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                heading("来源 × 模型", "square.grid.3x3")
                Text("Top \(matrix.count)").font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                Spacer()
                Text("首位 \(UsageAnalysis.share(a.models.first?.tokens ?? 0, of: a.total)) · 有效模型 \(String(format: "%.1f", a.effectiveModels))/\(a.models.count)")
                    .font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary)
                    .help("有效模型数 = 1 / Σ(模型 Token 占比²)。所有模型权重相同时等于模型数；由少数模型主导时更小。")
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    matrixView(a).frame(minWidth: 480, maxWidth: .infinity)
                    concentration(a).frame(width: 240)
                }
                VStack(spacing: 16) { matrixView(a); concentration(a) }
            }
        }.padding(14).usageFigure()
    }
    private func matrixView(_ a: UsageAnalysis) -> some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("模型 / Token").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(sourceRows) { source in
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Circle().fill(PlotInk.source(source.source)).frame(width: 5, height: 5)
                            Text(source.source.label).lineLimit(1)
                        }
                        Text(UsageStats.formatTokens(source.tokens)).font(Theme.Font.captionMono).foregroundColor(Theme.textPrimary)
                    }.frame(minWidth: 70, maxWidth: .infinity)
                }
                Text("占比").frame(width: 48, alignment: .trailing)
            }.font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
            ForEach(matrix) { row in
                GridRow {
                    Text(row.name).font(Theme.Font.captionMono).lineLimit(1).frame(minWidth: 145, maxWidth: .infinity, alignment: .leading).help(row.name)
                    ForEach(0..<3, id: \.self) { index in matrixCell(row.cells[index], source: UsageSource.allCases[index]) }
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(UsageAnalysis.share(row.tokens, of: a.total)).font(Theme.Font.captionMono)
                        GeometryReader { geo in
                            Rectangle().fill(Theme.bgOverlay)
                            Rectangle().fill(PlotInk.blue).frame(width: geo.size.width * min(1, Double(row.tokens) / Double(max(1, a.total))))
                        }.frame(height: 3)
                    }.frame(width: 48, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
            GridRow {
                Text("单元格条长 / 共同线性尺度").gridCellColumns(3).frame(maxWidth: .infinity, alignment: .leading)
                Text("最大 " + UsageStats.formatTokens(matrixMaximum)).gridCellColumns(2).frame(maxWidth: .infinity, alignment: .trailing)
            }.font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
        }.foregroundColor(Theme.textPrimary)
        .help("单元格为来源与模型的实际 Token 总量；条形长度按全矩阵最大值线性缩放，颜色区分来源。微小份额仍显示实际数值，不放大条形。")
    }
    private func matrixCell(_ value: Int, source: UsageSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value > 0 ? UsageStats.formatTokens(value) : "—")
                .font(Theme.Font.captionMono).foregroundColor(value > 0 ? Theme.textPrimary : Theme.textSecondary)
            GeometryReader { geo in
                Rectangle().fill(Theme.bgOverlay.opacity(0.65))
                Rectangle().fill(PlotInk.source(source))
                    .frame(width: geo.size.width * Double(max(0, value)) / Double(matrixMaximum))
            }.frame(height: 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 4))
        .help("\(value.formatted()) Token")
        .accessibilityLabel("\(value.formatted()) Token")
    }
    private func concentration(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text("模型集中度 · Lorenz").font(Theme.Font.labelSection).foregroundColor(Theme.textPrimary); Spacer() }
            if a.models.count < 2 {
                Text(a.models.isEmpty ? "暂无模型" : "只有 1 个模型").font(Theme.Font.caption).foregroundColor(Theme.textSecondary).frame(maxWidth: .infinity, minHeight: 135)
            } else {
                Chart {
                    ForEach(a.lorenz) { row in
                        AreaMark(x: .value("模型比例", row.x * 100), yStart: .value("Token 累计", row.y * 100), yEnd: .value("均衡", row.x * 100))
                            .foregroundStyle(PlotInk.blue.opacity(0.10))
                        LineMark(x: .value("模型比例", row.x * 100), y: .value("Token 累计", row.y * 100))
                            .foregroundStyle(PlotInk.blue).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    LineMark(x: .value("模型比例", 0.0), y: .value("均衡", 0.0), series: .value("参考", "均衡"))
                        .foregroundStyle(Theme.textSecondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    LineMark(x: .value("模型比例", 100.0), y: .value("均衡", 100.0), series: .value("参考", "均衡"))
                        .foregroundStyle(Theme.textSecondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }
                .chartXScale(domain: 0...100).chartYScale(domain: 0...100)
                .chartXAxis { AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { if let n = value.as(Int.self) { Text("\(n)%").font(Theme.Font.micro) } }
                } }
                .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { if let n = value.as(Int.self) { Text("\(n)%").font(Theme.Font.micro) } }
                } }
                .frame(height: 135)
                .accessibilityLabel("Lorenz 曲线，模型按 Token 从少到多排序。横轴模型累计比例，纵轴 Token 累计比例；虚线为完全均衡。")
            }
            Text("横轴 模型累计 · 纵轴 Token 累计").font(Theme.Font.micro).foregroundColor(Theme.textSecondary).lineLimit(2)
        }
    }
    private var emptyFigure: some View { Text("本周期无已到达日期").font(Theme.Font.caption).foregroundColor(Theme.textSecondary).frame(maxWidth: .infinity, minHeight: 100) }
    private func heading(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 6) { AppGlyph(name: symbol, size: 14).foregroundColor(Theme.Ink.claude); Text(title).font(Theme.Font.body) }.foregroundColor(Theme.textPrimary)
    }
}

/// Fixed categorical colors; sequential viridis is reserved for ordered values.
private enum PlotInk {
    static let blue = Color(red: 0.16, green: 0.43, blue: 0.72)
    static let teal = Color(red: 0.10, green: 0.60, blue: 0.53)
    static let orange = Color(red: 0.88, green: 0.48, blue: 0.14)
    // Viridis by N. J. Smith, S. van der Walt and E. Firing (CC0),
    // sampled uniformly at 64 positions using Matplotlib. See ASSET-LICENSES.md.
    static let viridisRGB: [(Double, Double, Double)] = [
        (0.267004, 0.004874, 0.329415),
        (0.272594, 0.025563, 0.353093),
        (0.277018, 0.050344, 0.375715),
        (0.280267, 0.073417, 0.397163),
        (0.282327, 0.094955, 0.417331),
        (0.283197, 0.115680, 0.436115),
        (0.282884, 0.135920, 0.453427),
        (0.281412, 0.155834, 0.469201),
        (0.278826, 0.175490, 0.483397),
        (0.275191, 0.194905, 0.496005),
        (0.270595, 0.214069, 0.507052),
        (0.265145, 0.232956, 0.516599),
        (0.258965, 0.251537, 0.524736),
        (0.252194, 0.269783, 0.531579),
        (0.244972, 0.287675, 0.537260),
        (0.237441, 0.305202, 0.541921),
        (0.227802, 0.326594, 0.546532),
        (0.220057, 0.343307, 0.549413),
        (0.212395, 0.359683, 0.551710),
        (0.204903, 0.375746, 0.553533),
        (0.197636, 0.391528, 0.554969),
        (0.190631, 0.407061, 0.556089),
        (0.183898, 0.422383, 0.556944),
        (0.177423, 0.437527, 0.557565),
        (0.171176, 0.452530, 0.557965),
        (0.165117, 0.467423, 0.558141),
        (0.159194, 0.482237, 0.558073),
        (0.153364, 0.497000, 0.557724),
        (0.147607, 0.511733, 0.557049),
        (0.141935, 0.526453, 0.555991),
        (0.136408, 0.541173, 0.554483),
        (0.131172, 0.555899, 0.552459),
        (0.125394, 0.574318, 0.549086),
        (0.121831, 0.589055, 0.545623),
        (0.119738, 0.603785, 0.541400),
        (0.119699, 0.618490, 0.536347),
        (0.122312, 0.633153, 0.530398),
        (0.128087, 0.647749, 0.523491),
        (0.137339, 0.662252, 0.515571),
        (0.150148, 0.676631, 0.506589),
        (0.166383, 0.690856, 0.496502),
        (0.185783, 0.704891, 0.485273),
        (0.208030, 0.718701, 0.472873),
        (0.232815, 0.732247, 0.459277),
        (0.259857, 0.745492, 0.444467),
        (0.288921, 0.758394, 0.428426),
        (0.319809, 0.770914, 0.411152),
        (0.352360, 0.783011, 0.392636),
        (0.395174, 0.797475, 0.367757),
        (0.430983, 0.808473, 0.346476),
        (0.468053, 0.818921, 0.323998),
        (0.506271, 0.828786, 0.300362),
        (0.545524, 0.838039, 0.275626),
        (0.585678, 0.846661, 0.249897),
        (0.626579, 0.854645, 0.223353),
        (0.668054, 0.861999, 0.196293),
        (0.709898, 0.868751, 0.169257),
        (0.751884, 0.874951, 0.143228),
        (0.793760, 0.880678, 0.120005),
        (0.835270, 0.886029, 0.102646),
        (0.876168, 0.891125, 0.095250),
        (0.916242, 0.896091, 0.100717),
        (0.955300, 0.901065, 0.118128),
        (0.993248, 0.906157, 0.143936),
    ]
    static let viridis = viridisRGB.map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    static func cache(_ rate: Double) -> Color {
        let t = min(1, max(0, rate))
        return Color(red: 0.16 - 0.06 * t, green: 0.43 + 0.17 * t, blue: 0.72 - 0.19 * t)
    }
    static func source(_ source: UsageSource) -> Color {
        switch source { case .claude: return blue; case .codex: return orange; case .thirdParty: return teal }
    }
}

extension View {
    func usageFigure() -> some View {
        self.background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline))
    }
}

private struct UsageCalendarPlot: View {
    let rows: [UsageAnalysis.Bucket]
    let maximum: Int
    let truncated: Bool
    let reference: Date
    let onSelect: (Date) -> Void
    @State private var hover: Date?
    private let calendar = Calendar.current

    var body: some View {
        let shown = rows
        let isMonth = rows.count <= 31
        let start = shown.first?.date ?? calendar.startOfDay(for: reference)
        let maxValue = max(1, maximum)
        let lookup = Dictionary(uniqueKeysWithValues: shown.map { ($0.date, $0.total) })
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let leading = (calendar.component(.weekday, from: start) + 5) % 7
                let columns = isMonth ? 7 : max(1, Int(ceil(Double(shown.count + leading) / 7)))
                let lineCount = isMonth ? max(1, Int(ceil(Double(shown.count + leading) / 7))) : 7
                let cell = max(1, min(isMonth ? 34.0 : 14.0, (geo.size.width - 30) / CGFloat(columns) - 3, (geo.size.height - 24) / CGFloat(lineCount) - 3))
                let gap: CGFloat = 3
                let baseX: CGFloat = isMonth ? max(0, (geo.size.width - CGFloat(columns) * (cell + gap)) / 2) : 30
                let baseY: CGFloat = isMonth ? 20 : 24
                Canvas { context, _ in
                    let labels = ["一", "二", "三", "四", "五", "六", "日"]
                    for index in 0..<7 {
                        let point = isMonth ? CGPoint(x: baseX + CGFloat(index) * (cell + gap) + cell / 2, y: 8)
                            : CGPoint(x: 10, y: baseY + CGFloat(index) * (cell + gap) + cell / 2)
                        context.draw(Text(labels[index]).font(.system(size: 9)).foregroundColor(Theme.textSecondary), at: point)
                    }
                    for (index, row) in shown.enumerated() {
                        let offset = index + leading
                        let col = isMonth ? offset % 7 : offset / 7
                        let line = isMonth ? offset / 7 : offset % 7
                        let rect = CGRect(x: baseX + CGFloat(col) * (cell + gap), y: baseY + CGFloat(line) * (cell + gap), width: cell, height: cell)
                        let path = Path(roundedRect: rect, cornerRadius: 2)
                        context.fill(path, with: .color(fill(row.total, max: maxValue)))
                        if hover == row.date { context.stroke(path, with: .color(Theme.textPrimary), lineWidth: 1) }
                        if isMonth {
                            context.draw(Text("\(calendar.component(.day, from: row.date))")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(row.total > 0 ? (log1p(Double(row.total)) / log1p(Double(maxValue)) < 0.55 ? .white : Color(white: 0.08)) : Theme.textSecondary),
                                         at: CGPoint(x: rect.midX, y: rect.midY))
                        } else if calendar.component(.day, from: row.date) == 1 {
                            context.draw(Text("\(calendar.component(.month, from: row.date))月").font(.system(size: 9)).foregroundColor(Theme.textSecondary),
                                         at: CGPoint(x: rect.midX, y: 8))
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hover = date(at: point, shown: shown, leading: leading, isMonth: isMonth, cell: cell, gap: gap, x: baseX, y: baseY)
                    case .ended: hover = nil
                    }
                }
                .onTapGesture { point in
                    if let date = date(at: point, shown: shown, leading: leading, isMonth: isMonth, cell: cell, gap: gap, x: baseX, y: baseY) { onSelect(date) }
                }
            }
            Text(hover.map { "\(UsageStats.formatter("M月d日").string(from: $0)) · \((lookup[$0] ?? 0).formatted()) Token" }
                 ?? (truncated ? "展示最近 366 天 · 零记录日期为灰色" : "日期按周排列 · 零记录日期为灰色"))
                .font(Theme.Font.micro).foregroundColor(Theme.textSecondary).frame(height: 16)
        }
        .accessibilityChildren {
            ForEach(shown) { row in
                Button("\(UsageStats.formatter("yyyy年M月d日").string(from: row.date))，\(row.total.formatted()) Token") { onSelect(row.date) }
            }
        }
        .accessibilityLabel("日历分布，\(shown.count) 个日期，峰值 \(maxValue) Token；点击日期可下钻。")
    }
    private func date(at point: CGPoint, shown: [UsageAnalysis.Bucket], leading: Int, isMonth: Bool,
                      cell: CGFloat, gap: CGFloat, x: CGFloat, y: CGFloat) -> Date? {
        guard point.x >= x, point.y >= y, cell > 0 else { return nil }
        let col = Int((point.x - x) / (cell + gap)), line = Int((point.y - y) / (cell + gap))
        guard (isMonth ? col < 7 : line < 7) else { return nil }
        let index = (isMonth ? line * 7 + col : col * 7 + line) - leading
        return shown.indices.contains(index) ? shown[index].date : nil
    }
    private func fill(_ value: Int, max maximum: Int) -> Color {
        guard value > 0 else { return Theme.bgSecondary }
        let intensity = log1p(Double(value)) / log1p(Double(maximum))
        let index = min(PlotInk.viridis.count - 1, Int(intensity * Double(PlotInk.viridis.count - 1)))
        return PlotInk.viridis[index]
    }
}
