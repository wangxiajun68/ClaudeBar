import SwiftUI
import Charts

/// A historical surface backed by the archive, never the 2,000-row log ring.
struct VpnTrafficAnalyticsView: View {
    var isVisible = true
    private let history = VpnTrafficHistory.shared
    @State private var period: VpnTrafficPeriod = .week
    @State private var revision = 0
    @State private var report: VpnTrafficReport?
    @State private var error: String?
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var loading = true
    @State private var rankRoute: RankRoute = .all
    @State private var domainsExpanded = false

    enum RankRoute: String, CaseIterable, Identifiable {
        case all, proxied, direct
        var id: String { rawValue }
        var title: String {
            switch self { case .all: return "全部"; case .proxied: return "代理"; case .direct: return "直连" }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                controls
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.caption).foregroundColor(Theme.Ink.error)
                        .textSelection(.enabled)
                }
                if let report {
                    totals(report)
                    if report.startedAt == nil {
                        empty
                    } else {
                        VpnTrafficTrendView(report: report, period: period)
                        routeTotals(report)
                        DisclosureGroup(isExpanded: $domainsExpanded) {
                            domainRanking(report).padding(.top, 12)
                        } label: {
                            Text("域名明细 · \(report.domains.count)")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                        }.tint(Theme.Ink.claude)
                    }
                    footnote(report)
                } else if loading {
                    ProgressView("正在读取流量历史…").frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
        }
        .task(id: "\(period.rawValue)-\(revision)-\(isVisible)") {
            guard isVisible else { return }
            loading = report == nil
            let next = await history.report(period: period)
            guard !Task.isCancelled else { return }
            report = next
            error = history.storageError
            loading = false
        }
        .onReceive(history.$revision) { if isVisible { revision = $0 } }
        .onReceive(history.$storageError) { if isVisible { error = $0 } }
        .alert("清除全部流量历史？", isPresented: $confirmClear) {
            Button("清除历史", role: .destructive) {
                clearing = true
                Task { await history.clear(); clearing = false }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除所有日期的累计流量与域名排行。日志记录和域名规则会保留。")
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                Text("流量分析").font(.system(size: 20, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                periodPicker
                clearButton
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("流量分析").font(.system(size: 20, weight: .semibold, design: .rounded)); Spacer(); clearButton }
                periodPicker
            }
        }
    }

    private var periodPicker: some View {
        SegmentedCapsule(items: VpnTrafficPeriod.allCases, selection: period,
                         title: { $0.title }, tint: Theme.Ink.claude,
                         onSelect: { period = $0 })
            .fixedSize().accessibilityLabel("统计时段")
    }

    private var clearButton: some View {
        Button { confirmClear = true } label: {
            AppGlyph(name: "trash", size: 14).frame(width: 30, height: 32)
        }
        .buttonStyle(.plain).foregroundColor(Theme.textSecondary)
        .accessibilityLabel("清除全部流量历史").help("清除全部流量历史，与清空日志独立")
        .disabled(clearing)
    }

    private func totals(_ report: VpnTrafficReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(period.title) · 内核总流量").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(Theme.textSecondary)
                    Text(VpnFormat.bytes(report.totals.core.total))
                        .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("历史累计").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(Theme.textSecondary)
                    Text(VpnFormat.bytes(report.lifetime.core.total)).font(Theme.Font.body.weight(.semibold)).monospacedDigit()
                    if let date = report.startedAt {
                        Text("自 \(date.formatted(.dateTime.year().month().day()))")
                            .font(.system(size: 12, design: .rounded)).foregroundColor(Theme.textSecondary)
                    }
                }
            }
            HStack(spacing: 24) {
                metric("上传", value: report.totals.core.upload, symbol: "arrow.up")
                metric("下载", value: report.totals.core.download, symbol: "arrow.down")
            }
            HairlineDivider()
        }
    }

    private func metric(_ label: String, value: Int64, symbol: String) -> some View {
        HStack(spacing: 6) {
            AppGlyph(name: symbol, size: 12).foregroundColor(Theme.textSecondary)
            Text(label).foregroundColor(Theme.textSecondary)
            Text(VpnFormat.bytes(value)).font(Theme.Font.captionMono).monospacedDigit()
        }.font(.system(size: 13, weight: .medium, design: .rounded))
    }

    private func routeTotals(_ report: VpnTrafficReport) -> some View {
        HStack(alignment: .top, spacing: 20) {
            routeTotal("代理采样", report.totals.proxied.total)
            routeTotal("直连采样", report.totals.direct.total)
            routeTotal("未归类", report.totals.unclassified.total)
        }
        .padding(.top, 4)
    }

    private func routeTotal(_ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
            Text(VpnFormat.bytes(bytes))
                .font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func domainRanking(_ report: VpnTrafficReport) -> some View {
        let domains: [VpnTrafficDomain]
        let count: Int
        switch rankRoute {
        case .all: domains = Array(report.domains.prefix(20)); count = report.domains.count
        case .proxied: domains = report.proxyRanking; count = report.proxyDomainCount
        case .direct: domains = report.directRanking; count = report.directDomainCount
        }
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("域名流量排行").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("\(count) 个域名").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    Spacer(minLength: 8)
                    rankPicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("域名流量排行 · \(count) 个域名").font(.system(size: 18, weight: .semibold, design: .rounded))
                    rankPicker
                }
            }
            HStack {
                Text("域名").frame(maxWidth: .infinity, alignment: .leading)
                Text("代理").frame(width: 78, alignment: .trailing)
                Text("直连").frame(width: 78, alignment: .trailing)
                Text("合计").frame(width: 82, alignment: .trailing)
            }.font(.system(size: 12, design: .rounded)).foregroundColor(Theme.textSecondary)
            if domains.isEmpty {
                Text("此时段尚无域名流量采样").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    .padding(.vertical, 16)
            }
            ForEach(Array(domains.prefix(20).enumerated()), id: \.element.id) { index, domain in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(.system(size: 12, design: .rounded).monospacedDigit()).foregroundColor(Theme.textSecondary).frame(width: 20, alignment: .leading)
                        Text(domain.host).font(Theme.Font.captionMono)
                            .lineLimit(1).truncationMode(.middle).help(domain.host)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(VpnFormat.bytes(domain.traffic.proxied.total)).foregroundColor(Theme.Ink.claude).frame(width: 78, alignment: .trailing)
                        Text(VpnFormat.bytes(domain.traffic.direct.total)).foregroundColor(Theme.Ink.success).frame(width: 78, alignment: .trailing)
                        Text(VpnFormat.bytes(domain.total)).frame(width: 82, alignment: .trailing)
                    }
                    .font(Theme.Font.captionMono).monospacedDigit().frame(height: 40)
                    .textSelection(.enabled)
                    HairlineDivider()
                }
            }
            Text("显示流量最高的 20 个域名 · 历史累计保留全部域名，不受日志条数限制")
                .font(.system(size: 12, design: .rounded)).foregroundColor(Theme.textSecondary)
        }
    }

    private var rankPicker: some View {
        SegmentedCapsule(items: RankRoute.allCases, selection: rankRoute,
                         title: { $0.title }, tint: Theme.Ink.claude,
                         onSelect: { rankRoute = $0 }).fixedSize()
            .accessibilityLabel("域名排行流向")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("流量历史从下一次连接采样开始").font(Theme.Font.bodySmall.weight(.medium))
            Text("连接 VPN 后会自动记录趋势与域名排行。过去的日志没有字节数据，无法补算历史流量。")
                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }.frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
    }

    private func footnote(_ report: VpnTrafficReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("每个点表示该时段的传输量，上传与下载相加为总量；代理与直连来自连接采样。")
            Text("仅统计经过内核的流量。清空日志不影响累计历史。")
            if let date = report.updatedAt { Text("最近记录 \(date.formatted(.dateTime.month().day().hour().minute()))") }
        }.font(.system(size: 12, design: .rounded)).foregroundColor(Theme.textSecondary)
    }
}

private func chartBytes(_ value: Double) -> String {
    VpnFormat.bytes(value >= Double(Int64.max) ? .max : Int64(max(0, value)))
}

/// Selection belongs to this chart, never the archive page or its ranking.
private struct VpnTrafficTrendView: View {
    let report: VpnTrafficReport
    let period: VpnTrafficPeriod
    @State private var selectedDate: Date?
    @State private var measure: Measure = .total

    enum Measure: String, CaseIterable, Identifiable {
        case total, download, upload
        var id: String { rawValue }
        var title: String {
            switch self { case .total: return "总量"; case .download: return "下载"; case .upload: return "上传" }
        }
        func bytes(_ value: VpnTrafficAmounts) -> Int64 {
            switch self { case .total: return value.total; case .download: return value.download; case .upload: return value.upload }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("流量趋势").font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                SegmentedCapsule(items: Measure.allCases, selection: measure,
                                 title: { $0.title }, tint: Theme.Ink.claude,
                                 onSelect: { measure = $0 }).fixedSize()
                    .accessibilityLabel("图表显示的数据")
            }
            Chart {
                ForEach(report.points) { point in
                    AreaMark(x: .value("时间", point.date), y: .value(measure.title, Double(measure.bytes(point.traffic.core))))
                        .foregroundStyle(LinearGradient(colors: [Theme.chartBlue.opacity(0.34), Theme.chartBlue.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.linear)
                    LineMark(x: .value("时间", point.date), y: .value(measure.title, Double(measure.bytes(point.traffic.core))))
                        .foregroundStyle(Theme.chartBlue)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                }
                if let point = selectedPoint(report) ?? report.points.max(by: { measure.bytes($0.traffic.core) < measure.bytes($1.traffic.core) }) {
                    if selectedDate != nil {
                        RuleMark(x: .value("选中时间", point.date))
                            .foregroundStyle(Theme.textSecondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    PointMark(x: .value("时间", point.date), y: .value(measure.title, Double(measure.bytes(point.traffic.core))))
                        .foregroundStyle(Theme.Ink.claude).symbolSize(48)
                }
            }
            .chartXSelection(value: selection)
            .onChange(of: period) { _, _ in selectedDate = nil }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                if let frame = proxy.plotFrame {
                                    let bounds = geometry[frame]
                                    selection.wrappedValue = bounds.contains(location)
                                        ? proxy.value(atX: location.x - bounds.minX, as: Date.self) : nil
                                }
                            case .ended: selectedDate = nil
                            }
                        }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) { Text(chartBytes(bytes)).font(.system(size: 12, design: .rounded).monospacedDigit()).lineLimit(1).frame(width: 76, alignment: .trailing) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: period == .today ? .dateTime.hour() : period == .all ? .dateTime.year().month() : .dateTime.month().day())
                        .font(.system(size: 12, design: .rounded))
                }
            }
            .chartXScale(domain: trendDomain(report))
            .chartYScale(domain: 0...max(1, Double(report.points.map { measure.bytes($0.traffic.core) }.max() ?? 0) * 1.08))
            .chartLegend(.hidden)
            .frame(height: 248)
            .accessibilityLabel("\(period.title)\(measure.title)流量，纵轴为字节，横轴为统计时段")
            inspection
        }
    }

    private var inspection: some View {
        let point = selectedPoint(report)
        let peak = report.points.max { measure.bytes($0.traffic.core) < measure.bytes($1.traffic.core) }
        let traffic = point?.traffic.core ?? peak?.traffic.core ?? .init()
        let date = point?.date ?? peak?.date
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(point == nil ? "峰值时段" : "选中时段")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                Text(date.map { bucketLabel($0) } ?? "暂无采样")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(VpnFormat.bytes(measure.bytes(traffic)))
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("上传 \(VpnFormat.bytes(traffic.upload)) · 下载 \(VpnFormat.bytes(traffic.download))")
                    .font(.system(size: 12, design: .rounded)).monospacedDigit()
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .frame(height: 52)
    }

    private func bucketLabel(_ date: Date) -> String {
        if period == .today { return date.formatted(.dateTime.month().day().hour()) }
        let monthly = period == .all && report.points.count > 1
            && report.points[1].date.timeIntervalSince(report.points[0].date) > 2 * 86400
        return date.formatted(monthly ? .dateTime.year().month() : .dateTime.month().day())
    }

    private func trendDomain(_ report: VpnTrafficReport) -> ClosedRange<Date> {
        let start = report.points.first?.date ?? Date()
        let end = max(start.addingTimeInterval(3600), report.points.last?.date ?? start)
        return start...end
    }

    private func selectedPoint(_ report: VpnTrafficReport) -> VpnTrafficPoint? {
        guard let selectedDate else { return nil }
        return VpnTrafficSelection.nearest(to: selectedDate, in: report.points)
    }

    private var selection: Binding<Date?> {
        Binding(get: { selectedDate }, set: { date in
            let next = date.flatMap { VpnTrafficSelection.nearest(to: $0, in: report.points)?.date }
            if selectedDate != next { selectedDate = next }
        })
    }
}
