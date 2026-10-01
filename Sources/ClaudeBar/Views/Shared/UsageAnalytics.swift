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
    @State private var matrix: [MatrixRow] = []
    @State private var compressed = false
    @State private var calendarMode = false
    @State private var showStatistics = false
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
    private struct MatrixRow: Identifiable {
        let name: String; let tokens: Int; let cells: [Int]
        var id: String { name }
    }
    private struct TokenPart: Identifiable {
        let name: String; let tokens: Int; let color: Color
        var id: String { name }
    }

    var body: some View {
        Group {
            if let a = analysis {
                VStack(alignment: .leading, spacing: 14) {
                    metrics(a)
                    activity(a)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            sourceComposition.frame(minWidth: 400, maxWidth: .infinity)
                            tokenComposition(a).frame(minWidth: 400, maxWidth: .infinity)
                        }
                        VStack(spacing: 14) { sourceComposition; tokenComposition(a) }
                    }
                    structure(a)
                    statisticalDetails(a)
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
                let dictionaries = UsageSource.allCases.map { source in
                    request.sources[source, default: []].reduce(into: [String: Int]()) { $0[$1.model, default: 0] += $1.totalTokens }
                }
                let matrixRows = a.models.prefix(8).map { model in
                    MatrixRow(name: model.name, tokens: model.tokens, cells: dictionaries.map { $0[model.name, default: 0] })
                }
                return (a, sourceValues, matrixRows)
            }.value
            guard !Task.isCancelled else { return }
            analysis = result.0; sourceRows = result.1; matrix = result.2
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
        metric("本地 Token", UsageStats.formatTokens(a.total), help: "本地模型记录，不包含 Cursor 官方账单")
        metric("有记录的天数", "\(a.activeDays) / \(a.daily.count)", help: "排除未来日期；已到达但无记录的日期为零")
        metric("日用量中位数", UsageStats.formatTokens(Int(a.median)), help: "日 P50：包含零记录日的线性插值中位数")
        metric("日用量 P95", UsageStats.formatTokens(Int(a.p95)), help: "包含零记录日的线性插值 95 分位数；不是预测或实测覆盖率")
        metric("缓存命中率", rateLabel(a.hitRate), help: "读取 / (输入 + 读取 + 写入)，不含输出")
    }
    private func metric(_ label: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(Theme.textPrimary)
        }.fixedSize().frame(maxWidth: .infinity, alignment: .leading).help(help)
            .accessibilityElement(children: .combine)
    }

    private func activity(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                heading("用量节奏", "chart.xyaxis.line")
                Spacer()
                Text("按\(a.grain) · \(a.buckets.count) 个周期").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                Menu {
                    Button(calendarMode ? "显示轨迹" : "显示日历") { calendarMode.toggle() }
                    if a.buckets.count > 1 {
                        Button(compressed ? "使用原值坐标" : "使用长尾坐标") { compressed.toggle() }
                    }
                } label: { Image(systemName: "slider.horizontal.3") }
                    .menuStyle(.borderlessButton).fixedSize().help("选择图表和坐标尺度").accessibilityLabel("图表选项")
            }
            if calendarMode { calendarContent(a) }
            else if a.buckets.isEmpty { emptyFigure }
            else if a.bucketMaximum == 0 {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("0").font(Theme.Font.displayMetric).foregroundColor(Theme.textPrimary)
                    caption("Token · \(a.buckets.count) 个已到达周期尚无用量记录")
                }.frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            }
            else if a.buckets.count == 1, let row = a.buckets.first { singleObservation(row, grain: a.grain) }
            else { trajectory(a) }
        }.padding(20).usageFigure()
    }

    private func singleObservation(_ row: UsageAnalysis.Bucket, grain: String) -> some View {
        HStack(spacing: 26) {
            ZStack {
                Circle().fill(UsagePlotPalette.blue.opacity(Theme.isDark ? 0.25 : 0.15))
                Circle().strokeBorder(UsagePlotPalette.blue.opacity(0.65), lineWidth: 2)
                VStack(spacing: 3) {
                    Text(grain == "日" ? UsageStats.formatter("MMM").string(from: row.date) : grain)
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    Text(UsageStats.formatter(grain == "日" ? "dd" : grain == "月" ? "MM" : "yyyy").string(from: row.date))
                        .font(.system(size: 36, weight: .medium, design: .rounded)).foregroundColor(Theme.textPrimary)
                }
            }.frame(width: 114, height: 114).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UsageStats.formatTokens(row.total)).font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit()).foregroundColor(Theme.textPrimary)
                    caption("Token")
                }
                HStack(spacing: 24) {
                    observationValue("提示侧", UsageStats.formatTokens(row.prompt))
                    observationValue("输出", UsageStats.formatTokens(row.output))
                    observationValue("缓存命中", rateLabel(row.hitRate))
                }
                caption(row.total > 0 ? "\(row.label) · 当前仅一个观测周期" : "\(row.label) 尚无用量记录")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
            .accessibilityLabel("\(row.label)，\(row.total.formatted()) Token；单个观测周期，不构造小时趋势。")
    }
    private func observationValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption(title)
            Text(value).font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit()).foregroundColor(Theme.textPrimary)
        }
    }

    private func trajectory(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(inspected(a).map { UsageStats.formatTokens($0.total) } ?? UsageStats.formatTokens(a.temporalTotal))
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()).foregroundColor(Theme.textPrimary)
                Text(inspected(a).map { $0.label } ?? "周期内日期记录合计")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                Spacer()
                Text(compressed ? "长尾坐标" : "原值坐标 · 从零开始").font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
            }
            GeometryReader { geo in
                let left: CGFloat = 70
                let height: CGFloat = 112
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
            }.frame(height: 138)
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
    private func calendarContent(_ a: UsageAnalysis) -> some View {
        VStack(spacing: 8) {
            UsageCalendarPlot(rows: a.calendarRows, maximum: a.calendarMaximum, truncated: a.daily.count > 366, reference: interval.start, onSelect: onSelectDay)
            HStack(spacing: 8) {
                Text("相对长尾强度").font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                LinearGradient(colors: UsagePlotPalette.cacheColors, startPoint: .leading, endPoint: .trailing).frame(width: 70, height: 7).clipShape(Capsule())
                Text("0 → \(UsageStats.formatTokens(a.calendarMaximum))").font(Theme.Font.microMono).foregroundColor(Theme.textSecondary)
                Spacer()
                Menu("选择日期") {
                    ForEach(a.calendarRows) { row in Button("\(row.label) · \(UsageStats.formatTokens(row.total))") { onSelectDay(row.date) } }
                }.menuStyle(.borderlessButton).fixedSize().font(Theme.Font.micro)
            }
        }
    }

    private var sourceComposition: some View {
        let total = sourceRows.reduce(0) { $0 + $1.tokens }
        let positive = sourceRows.filter { $0.tokens > 0 }
        return VStack(alignment: .leading, spacing: 14) {
            HStack { heading("来源份额", "circle.hexagongrid"); Spacer(); caption("面积 ∝ Token") }
            GeometryReader { geo in
                let weights = positive.map { sqrt(Double($0.tokens) / Double(max(1, total))) }
                let scale = min(110 / max(0.001, weights.max() ?? 1), max(1, geo.size.width - Double(max(0, positive.count - 1)) * 12) / max(1, weights.reduce(0, +)))
                HStack(alignment: .center, spacing: 12) {
                    ForEach(Array(positive.enumerated()), id: \.element.id) { index, row in
                        let diameter = scale * weights[index]
                        ZStack {
                            Circle().fill(UsagePlotPalette.source(row.source).opacity(Theme.isDark ? 0.35 : 0.21))
                            Circle().strokeBorder(UsagePlotPalette.source(row.source), lineWidth: 1.5)
                            if diameter > 50 {
                                Text(UsageAnalysis.share(row.tokens, of: total))
                                    .font(.system(size: diameter > 90 ? 21 : 15, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundColor(Theme.textPrimary)
                            }
                        }.frame(width: diameter, height: diameter)
                    }
                    if positive.isEmpty { emptyMessage("本周期暂无来源记录") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }.frame(height: 112).accessibilityHidden(true)
            VStack(spacing: 10) {
                ForEach(sourceRows) { row in compositionRow(row.source.label, tokens: row.tokens, total: total, color: UsagePlotPalette.source(row.source)) }
            }
            Spacer(minLength: 0)
            caption("来源总量 \(UsageStats.formatTokens(total)) · 不含 Cursor 官方账单")
        }.padding(20).frame(height: 294, alignment: .topLeading).usageFigure()
    }

    private func tokenComposition(_ a: UsageAnalysis) -> some View {
        let parts = [TokenPart(name: "输入", tokens: a.input, color: UsagePlotPalette.blue),
                     TokenPart(name: "缓存读取", tokens: a.hit, color: UsagePlotPalette.teal),
                     TokenPart(name: "缓存写入", tokens: a.write, color: UsagePlotPalette.purple),
                     TokenPart(name: "输出", tokens: a.output, color: UsagePlotPalette.clay)]
        return VStack(alignment: .leading, spacing: 18) {
            HStack { heading("Token 构成", "circle.circle"); Spacer(); caption("分层环图") }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) {
                    tokenRing(parts, a: a).frame(width: 148, height: 148)
                    tokenLegend(parts, a: a).frame(minWidth: 175, maxWidth: .infinity)
                }
                HStack(spacing: 12) {
                    tokenRing(parts, a: a).frame(width: 116, height: 116)
                    tokenLegend(parts, a: a).frame(maxWidth: .infinity)
                }
            }.frame(maxHeight: .infinity)
            HStack { caption("提示侧 \(UsageStats.formatTokens(a.prompt))"); Spacer(); caption("内环：提示 / 输出") }
                .help("提示侧 = 输入 + 缓存读取 + 缓存写入；命中率不包含输出。")
        }.padding(20).frame(height: 294, alignment: .topLeading).usageFigure()
    }
    private func tokenLegend(_ parts: [TokenPart], a: UsageAnalysis) -> some View {
        VStack(spacing: 16) {
            ForEach(parts) { part in compositionRow(part.name, tokens: part.tokens, total: a.total, color: part.color) }
        }
    }
    private func tokenRing(_ parts: [TokenPart], a: UsageAnalysis) -> some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2 - 2
                func ring(_ slices: [(Int, Color)], outerRadius: CGFloat, innerRadius: CGFloat) {
                    var start = -Double.pi / 2
                    for (tokens, color) in slices where tokens > 0 {
                        let end = start + Double(tokens) / Double(max(1, a.total)) * 2 * Double.pi
                        var sector = Path()
                        sector.addArc(center: center, radius: outerRadius, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
                        sector.addArc(center: center, radius: innerRadius, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
                        sector.closeSubpath()
                        context.fill(sector, with: .color(color))
                        start = end
                    }
                }
                if a.total == 0 {
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - outer * 0.85, y: center.y - outer * 0.85, width: outer * 1.7, height: outer * 1.7)), with: .color(Theme.hairline), lineWidth: outer * 0.25)
                }
                ring(parts.map { ($0.tokens, $0.color) }, outerRadius: outer, innerRadius: outer * 0.78)
                ring([(a.prompt, UsagePlotPalette.blue.opacity(0.4)), (a.output, UsagePlotPalette.clay)], outerRadius: outer * 0.67, innerRadius: outer * 0.52)

            }.accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(rateLabel(a.hitRate)).font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit()).foregroundColor(Theme.textPrimary)
                Text("命中率").font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
            }.accessibilityElement(children: .combine)
        }
    }
    private func compositionRow(_ title: String, tokens: Int, total: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(title).font(Theme.Font.caption).foregroundColor(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 4)
            Text(UsageStats.formatTokens(tokens)).font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(Theme.textPrimary).frame(minWidth: 65, alignment: .trailing)
            Text(UsageAnalysis.share(tokens, of: total)).font(Theme.Font.caption.monospacedDigit())
                .foregroundColor(Theme.textSecondary).frame(width: 48, alignment: .trailing)
        }.accessibilityElement(children: .combine)
            .help("\(title)：\(tokens.formatted()) Token，\(UsageAnalysis.share(tokens, of: total))")
    }

    private func structure(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { heading("模型与来源关系", "point.3.connected.trianglepath.dotted"); Spacer(); caption("Top \(matrix.count) / \(a.models.count) · 弦图") }
            if matrix.isEmpty { emptyMessage("本周期暂无模型记录") }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 28) {
                        relationshipPlot
                        relationshipLegend(a).frame(minWidth: 330, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        relationshipPlot.frame(maxWidth: .infinity)
                        relationshipLegend(a)
                    }
                }
            }
            HStack {
                caption("连带两端角宽 ∝ 来源 Token · 模型份额以全部模型为分母")
                Spacer()
                caption("有效模型 \(String(format: "%.1f", a.effectiveModels))")
            }.help("弦图仅连接 Top 模型实际匹配的来源记录；本地模型总量和来源记录范围可以不同。有效模型数 = 1 / 各模型份额平方和。")
        }.padding(20).usageFigure()
    }
    private var relationshipPlot: some View {
        UsageRelationshipPlot(rows: matrix.map { .init(name: $0.name, tokens: $0.tokens, cells: $0.cells) },
                              sourceLabels: UsageSource.allCases.map(\.label),
                              sourceColors: UsageSource.allCases.map { UsagePlotPalette.source($0) })
    }
    private func relationshipLegend(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(matrix.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(index + 1)").font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary).frame(width: 18, alignment: .leading)
                        Text(row.name).font(.system(size: 13, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle).foregroundColor(Theme.textPrimary)
                        Spacer(minLength: 8)
                        Text(UsageStats.formatTokens(row.tokens)).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()).foregroundColor(Theme.textPrimary)
                        caption(UsageAnalysis.share(row.tokens, of: a.total)).frame(width: 48, alignment: .trailing)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { modelSourceItems(row) }
                        VStack(alignment: .leading, spacing: 5) { modelSourceItems(row) }
                    }.padding(.leading, 27)
                }.accessibilityElement(children: .combine)
                    .help("\(row.name)：\(row.tokens.formatted()) Token；" + UsageSource.allCases.enumerated().map {
                        "\($0.element.label) \(row.cells[$0.offset].formatted())"
                    }.joined(separator: " · "))
            }
        }
    }
    @ViewBuilder private func modelSourceItems(_ row: MatrixRow) -> some View {
        ForEach(Array(UsageSource.allCases.enumerated()), id: \.element.id) { index, source in
            if row.cells[index] > 0 {
                HStack(spacing: 4) {
                    Circle().fill(UsagePlotPalette.source(source)).frame(width: 5, height: 5).accessibilityHidden(true)
                    caption("\(source.label) \(UsageStats.formatTokens(row.cells[index]))")
                }.fixedSize()
            }
        }
        if row.cells.allSatisfy({ $0 == 0 }) { caption("暂无对应来源记录") }
    }

    private func statisticalDetails(_ a: UsageAnalysis) -> some View {
        DisclosureGroup(isExpanded: $showStatistics) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    distribution(a).frame(minWidth: 300, maxWidth: .infinity)
                    concentration(a).frame(minWidth: 300, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 24) { distribution(a); concentration(a) }
            }.padding(.top, 18)
        } label: {
            HStack { heading("分布与集中度", "chart.xyaxis.line"); Spacer(); caption("观测分布 · 模型集中度") }
        }.padding(20).usageFigure()
    }
    private func distribution(_ a: UsageAnalysis) -> some View {
        UsageDistributionPlot(analysis: a)
    }
    private func concentration(_ a: UsageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("模型集中度").font(Theme.Font.chromeEmph).foregroundColor(Theme.textPrimary); Spacer(); caption("Lorenz · \(a.models.count) 个模型") }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", a.effectiveModels)).font(Theme.Font.displayMetric).foregroundColor(Theme.textPrimary)
                caption("有效模型 / \(a.models.count)")
            }
            if a.models.count < 2 {
                caption(a.models.isEmpty ? "暂无模型记录" : "只有一个模型，暂无模型间集中度差异").frame(maxWidth: .infinity, minHeight: 95, alignment: .leading)
            } else {
                Canvas { context, size in
                    let rect = CGRect(x: 32, y: 3, width: max(1, size.width - 42), height: size.height - 24)
                    let points = a.lorenz.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.maxY - $0.y * rect.height) }
                    var curve = Path(); curve.move(to: points[0])
                    for point in points.dropFirst() { curve.addLine(to: point) }
                    var area = curve
                    area.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); area.closeSubpath()
                    context.fill(area, with: .color(UsagePlotPalette.purple.opacity(Theme.isDark ? 0.3 : 0.17)))
                    var gap = curve; gap.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); gap.closeSubpath()
                    context.fill(gap, with: .color(UsagePlotPalette.clay.opacity(Theme.isDark ? 0.18 : 0.09)))
                    context.stroke(curve, with: .color(UsagePlotPalette.purple), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    var equal = Path(); equal.move(to: CGPoint(x: rect.minX, y: rect.maxY)); equal.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    context.stroke(equal, with: .color(Theme.textSecondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    for point in points {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)), with: .color(UsagePlotPalette.purple))
                    }
                    for value in [0.0, 0.5, 1.0] {
                        context.draw(Text("\(Int(value * 100))%").font(Theme.Font.micro).foregroundColor(Theme.textSecondary), at: CGPoint(x: rect.minX - 5, y: rect.maxY - value * rect.height), anchor: .trailing)
                        context.draw(Text("\(Int(value * 100))%").font(Theme.Font.micro).foregroundColor(Theme.textSecondary), at: CGPoint(x: rect.minX + value * rect.width, y: rect.maxY + 6), anchor: value == 1 ? .topTrailing : .topLeading)
                    }
                }.frame(height: 128)
                    .accessibilityLabel("Lorenz 曲线：模型按 Token 升序排列；横轴累计模型比例，纵轴累计 Token 比例，虚线为完全均衡。")
            }
            caption("累计模型份额 → 累计 Token 份额 · 虚线为均衡参考")
        }
    }
    private func rateLabel(_ rate: Double?) -> String { rate.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
    private var emptyFigure: some View { emptyMessage("本周期无已到达日期") }
    private func emptyMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "chart.xyaxis.line").font(.system(size: 26)).foregroundColor(Theme.textSecondary)
            caption(message)
        }.frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
    }
    private func caption(_ text: String) -> some View { Text(text).font(Theme.Font.caption).foregroundColor(Theme.textSecondary) }
    private func heading(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            AppGlyph(name: symbol, size: 14).foregroundColor(Theme.textSecondary).accessibilityHidden(true)
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
        }.foregroundColor(Theme.textPrimary).accessibilityAddTraits(.isHeader)
    }
}

/// Plot roles have authored light/dark values; sequential ramps encode ordered data.
enum UsagePlotPalette {
    static var blue: Color { Color(hex: Theme.isDark ? 0x91B5DA : 0x5F8FBC) }
    static var clay: Color { Color(hex: Theme.isDark ? 0xEAA084 : 0xD97757) }
    static var teal: Color { Color(hex: Theme.isDark ? 0x6DCFC7 : 0x278F89) }
    static var orange: Color { Color(hex: Theme.isDark ? 0xE8BD78 : 0xBB8840) }
    static var purple: Color { Color(hex: Theme.isDark ? 0xC2AAE4 : 0x9673BC) }
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
    // The purple → blue → teal portion avoids the calendar's yellow end.
    // Both the legend and observations use the same 48 ordered samples.
    private static let cacheLight = Array(viridis.prefix(48))
    private static let cacheDark = viridisRGB.prefix(48).map { rgb in
        Color(red: rgb.0 * 0.72 + 0.28, green: rgb.1 * 0.72 + 0.28, blue: rgb.2 * 0.72 + 0.28)
    }
    static var cacheColors: [Color] { Theme.isDark ? cacheDark : cacheLight }
    static func cache(_ rate: Double) -> Color {
        cacheColors[min(47, max(0, Int(rate * 47)))]
    }
    static func source(_ source: UsageSource) -> Color {
        switch source { case .claude: return clay; case .codex: return blue; case .thirdParty: return teal }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let calendar = Calendar.current

    private var leading: Int {
        (calendar.component(.weekday, from: rows.first?.date ?? reference) + 5) % 7
    }
    private var weeks: [[UsageAnalysis.Bucket?]] {
        guard !rows.isEmpty else { return [] }
        let slots: [UsageAnalysis.Bucket?] = Array(repeating: nil, count: leading) + rows.map { Optional($0) }
        return stride(from: 0, to: slots.count, by: 7).map { start in
            let slice = Array(slots[start..<min(start + 7, slots.count)])
            return slice + Array(repeating: nil, count: 7 - slice.count)
        }
    }
    private var showsMonth: Bool {
        guard let first = rows.first, let last = rows.last else { return false }
        return !calendar.isDate(first.date, equalTo: last.date, toGranularity: .month)
    }
    var body: some View {
        let total = rows.reduce(0) { $0 + $1.total }
        let active = rows.filter { $0.total > 0 }.count
        let peak = rows.max { $0.total < $1.total }
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    calendarReadout("活跃", "\(active)/\(rows.count) 天", ink: UsagePlotPalette.teal)
                    calendarReadout("日均", UsageStats.formatTokens(rows.isEmpty ? 0 : total / rows.count), ink: UsagePlotPalette.blue)
                    calendarReadout("峰值", peak.map { "\($0.label) · \(UsageStats.formatTokens($0.total))" } ?? "—", ink: UsagePlotPalette.purple)
                    Spacer(minLength: 0)
                    Text(truncated ? "最近 366 天" : "\(rows.first?.label ?? "—")—\(rows.last?.label ?? "—")")
                        .font(Theme.Font.microMono).foregroundColor(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    calendarReadout("活跃", "\(active)/\(rows.count) 天", ink: UsagePlotPalette.teal)
                    calendarReadout("日均", UsageStats.formatTokens(rows.isEmpty ? 0 : total / rows.count), ink: UsagePlotPalette.blue)
                    calendarReadout("峰值", peak.map { "\($0.label) · \(UsageStats.formatTokens($0.total))" } ?? "—", ink: UsagePlotPalette.purple)
                }
            }
            if rows.isEmpty {
                Text("本周期无已到达日期").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            } else if rows.count <= 31 {
                monthGrid
            } else {
                annualBand
            }
            Text(hover.flatMap { date in rows.first { $0.date == date } }.map {
                "\(UsageStats.formatter("M月d日").string(from: $0.date)) · \($0.total.formatted()) Token · 命中 \($0.hitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")"
            } ?? (truncated ? "展示最近 366 天 · 点击日期下钻" : "点击日期下钻 · 周合计仅含所选范围内的日期"))
                .font(Theme.Font.microMono).foregroundColor(Theme.textSecondary).lineLimit(1).frame(height: 16, alignment: .leading)
        }
        .accessibilityLabel("日历分布，\(rows.count) 个日期，峰值 \(maximum) Token；点击日期可下钻。")
    }
    private func calendarReadout(_ title: String, _ value: String, ink: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(ink).frame(width: 5, height: 5)
            Text(title).foregroundColor(Theme.textSecondary)
            Text(value).foregroundColor(Theme.textPrimary).monospacedDigit()
        }.font(Theme.Font.caption).fixedSize()
    }
    private var monthGrid: some View {
        let grouped = weeks
        let totals = grouped.map { $0.compactMap { $0 }.reduce(0) { $0 + $1.total } }
        return Grid(horizontalSpacing: 5, verticalSpacing: 5) {
            GridRow {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                    Text(day).font(Theme.Font.microMedium).foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 7)
                }
                Text("周合计").font(Theme.Font.microMedium).foregroundColor(Theme.textSecondary)
                    .frame(width: 60, alignment: .trailing)
            }
            ForEach(grouped.indices, id: \.self) { week in
                GridRow {
                    ForEach(0..<7, id: \.self) { day in
                        if let row = grouped[week][day] { dateCell(row) }
                        else {
                            RoundedRectangle(cornerRadius: 5).fill(Theme.bgSecondary.opacity(0.55))
                                .frame(minWidth: 30, maxWidth: .infinity).frame(height: 38)
                                .accessibilityHidden(true)
                        }
                    }
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(UsageStats.formatTokens(totals[week])).font(Theme.Font.microMono).foregroundColor(Theme.textPrimary)
                    }.frame(width: 60).padding(.leading, 5)
                    .help("本行范围内合计 \(totals[week].formatted()) Token")
                }
            }
        }
    }
    private func dateCell(_ row: UsageAnalysis.Bucket) -> some View {
        let selected = hover == row.date
        let color = strengthColor(row.total)
        return Button { onSelect(row.date) } label: {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 3) {
                        Text(showsMonth ? row.label : "\(calendar.component(.day, from: row.date))")
                            .font(Theme.Font.microMedium).foregroundColor(Theme.textSecondary)
                        Spacer(minLength: 0)
                        Text(UsageStats.formatTokens(row.total)).font(Theme.Font.microMono).foregroundColor(Theme.textPrimary)
                    }
                    Text(showsMonth ? row.label : "\(calendar.component(.day, from: row.date))")
                        .font(Theme.Font.microMedium).foregroundColor(Theme.textPrimary)
                }
            }
            .padding(.horizontal, 7).frame(minWidth: 30, maxWidth: .infinity).frame(height: 38)
            .background(row.total > 0 ? color.opacity(Theme.isDark ? 0.18 : 0.10) : Theme.bgSecondary,
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? UsagePlotPalette.blue : color.opacity(row.total > 0 ? 0.20 : 0.0), lineWidth: selected ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { hover = hovering ? row.date : nil }
        }
        .help("\(UsageStats.formatter("M月d日").string(from: row.date)) · \(row.total.formatted()) Token")
        .accessibilityLabel("\(UsageStats.formatter("yyyy年M月d日").string(from: row.date))，\(row.total.formatted()) Token")
    }
    private var annualBand: some View {
        let columns = max(1, Int(ceil(Double(rows.count + leading) / 7)))
        return ViewThatFits(in: .horizontal) {
            bandPlot(detailed: true).frame(minWidth: CGFloat(columns) * 64 + 24)
            bandPlot(detailed: false)
        }
    }
    private func bandPlot(detailed: Bool) -> some View {
        let columns = max(1, Int(ceil(Double(rows.count + leading) / 7)))
        return GeometryReader { geo in
            let gap: CGFloat = 3
            let cellWidth = max(1, (geo.size.width - 24 - CGFloat(columns - 1) * gap) / CGFloat(columns))
            let cellHeight: CGFloat = detailed ? 28 : 12
            let baseX: CGFloat = 24
            let baseY: CGFloat = 20
            Canvas { context, _ in
                for (index, day) in ["一", "二", "三", "四", "五", "六", "日"].enumerated() {
                    context.draw(Text(day).font(Theme.Font.micro).foregroundColor(Theme.textSecondary),
                                 at: CGPoint(x: 8, y: baseY + CGFloat(index) * (cellHeight + gap) + cellHeight / 2))
                }
                var lastLabelX: CGFloat = -100
                for (index, row) in rows.enumerated() {
                    let slot = index + leading
                    let rect = CGRect(x: baseX + CGFloat(slot / 7) * (cellWidth + gap),
                                      y: baseY + CGFloat(slot % 7) * (cellHeight + gap), width: cellWidth, height: cellHeight)
                    let path = Path(roundedRect: rect, cornerRadius: 2)
                    let color = strengthColor(row.total)
                    context.fill(path, with: .color(row.total > 0 ? (detailed ? color.opacity(Theme.isDark ? 0.22 : 0.12) : color) : Theme.bgOverlay.opacity(0.55)))
                    if detailed {
                        context.draw(Text(row.label).font(Theme.Font.micro).foregroundColor(Theme.textSecondary),
                                     at: CGPoint(x: rect.minX + 5, y: rect.minY + 7), anchor: .leading)
                        context.draw(Text(UsageStats.formatTokens(row.total)).font(Theme.Font.microMono).foregroundColor(Theme.textPrimary),
                                     at: CGPoint(x: rect.maxX - 5, y: rect.minY + 18), anchor: .trailing)
                    }
                    if hover == row.date { context.stroke(path, with: .color(Theme.textPrimary), lineWidth: 1.5) }
                    if (index == 0 || calendar.component(.day, from: row.date) == 1) && rect.minX - lastLabelX >= 35 {
                        context.draw(Text(UsageStats.formatter("M月").string(from: row.date)).font(Theme.Font.micro).foregroundColor(Theme.textSecondary),
                                     at: CGPoint(x: rect.midX, y: 7))
                        lastLabelX = rect.minX
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = bandDate(at: point, columns: columns, width: cellWidth, height: cellHeight, gap: gap, x: baseX, y: baseY)
                case .ended: hover = nil
                }
            }
            .onTapGesture { point in
                if let date = bandDate(at: point, columns: columns, width: cellWidth, height: cellHeight, gap: gap, x: baseX, y: baseY) { onSelect(date) }
            }
            .accessibilityChildren {
                ForEach(rows) { row in
                    Button("\(UsageStats.formatter("yyyy年M月d日").string(from: row.date))，\(row.total.formatted()) Token") { onSelect(row.date) }
                }
            }
        }.frame(height: detailed ? 238 : 122)
    }
    private func bandDate(at point: CGPoint, columns: Int, width: CGFloat, height: CGFloat,
                          gap: CGFloat, x: CGFloat, y: CGFloat) -> Date? {
        guard point.x >= x, point.y >= y else { return nil }
        let localX = point.x - x, localY = point.y - y
        let col = Int(localX / (width + gap)), line = Int(localY / (height + gap))
        guard col < columns, line < 7,
              localX - CGFloat(col) * (width + gap) < width,
              localY - CGFloat(line) * (height + gap) < height else { return nil }
        let index = col * 7 + line - leading
        return rows.indices.contains(index) ? rows[index].date : nil
    }
    private func strengthColor(_ value: Int) -> Color {
        guard value > 0 else { return Theme.bgOverlay }
        // Relative long-tail scale with a 1/99-peak pivot; avoids collapsing
        // nearly every nonzero day into yellow at real-world billion-token scales.
        let strength = log1p(99 * Double(value) / Double(max(1, maximum))) / log(100)
        return UsagePlotPalette.cacheColors[min(47, max(0, Int(strength * 47)))]
    }
}
