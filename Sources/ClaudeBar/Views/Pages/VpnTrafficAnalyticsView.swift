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
    @State private var selectedDate: Date?
    @State private var selectedHour: Double?
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var loading = true
    @State private var rankRoute: RankRoute = .all

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
                        trend(report)
                        routeComparison(report)
                        hourlyActivity(report)
                        domainRanking(report)
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
        .onChange(of: period) { _, _ in selectedDate = nil; selectedHour = nil }
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
                Text("历史流量").font(Theme.Font.body.weight(.semibold))
                Spacer(minLength: 0)
                periodPicker
                clearButton
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("历史流量").font(Theme.Font.body.weight(.semibold)); Spacer(); clearButton }
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
                    Text("\(period.title) · 内核总流量").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    Text(VpnFormat.bytes(report.totals.core.total))
                        .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("历史累计").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    Text(VpnFormat.bytes(report.lifetime.core.total)).font(Theme.Font.body.weight(.semibold)).monospacedDigit()
                    if let date = report.startedAt {
                        Text("自 \(date.formatted(.dateTime.year().month().day()))")
                            .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
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
        }.font(Theme.Font.caption)
    }

    private func trend(_ report: VpnTrafficReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("流量趋势").font(Theme.Font.bodySmall.weight(.semibold))
                Spacer(minLength: 4)
                if let point = selectedPoint(report) {
                    Text("\(point.date.formatted(period == .today ? .dateTime.hour().minute() : .dateTime.month().day())) · \(VpnFormat.bytes(point.traffic.core.total))")
                        .font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary)
                } else {
                    Text("峰值 " + VpnFormat.bytes(report.peak?.traffic.core.total ?? 0))
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
            }
            Chart {
                ForEach(report.points) { point in
                    AreaMark(x: .value("时间", point.date), y: .value("总量", Double(point.traffic.core.total)))
                        .foregroundStyle(LinearGradient(colors: [Theme.Ink.claude.opacity(0.1), Theme.Ink.claude.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("时间", point.date), y: .value("字节", Double(point.traffic.core.total)), series: .value("流向", "总流量"))
                        .foregroundStyle(Theme.textPrimary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
                    LineMark(x: .value("时间", point.date), y: .value("字节", Double(point.traffic.proxied.total)), series: .value("流向", "代理"))
                        .foregroundStyle(Theme.Ink.claude).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                    LineMark(x: .value("时间", point.date), y: .value("字节", Double(point.traffic.direct.total)), series: .value("流向", "直连"))
                        .foregroundStyle(Theme.Ink.success).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
                }
                if let point = selectedPoint(report) {
                    RuleMark(x: .value("选中时间", point.date))
                        .foregroundStyle(Theme.textSecondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("时间", point.date), y: .value("总量", Double(point.traffic.core.total)))
                        .foregroundStyle(Theme.textPrimary).symbolSize(32)
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                if let frame = proxy.plotFrame {
                                    let bounds = geometry[frame]
                                    selectedDate = bounds.contains(location)
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
                        if let bytes = value.as(Double.self) { Text(chartBytes(bytes)).font(Theme.Font.microMono).frame(width: 58, alignment: .trailing) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: period == .today ? .dateTime.hour() : .dateTime.month().day())
                        .font(Theme.Font.micro)
                }
            }
            .chartXScale(domain: trendDomain(report))
            .frame(height: 200)
            .accessibilityLabel("\(period.title)流量趋势：总流量、代理采样和直连采样")
            HStack(spacing: 18) {
                legend("总流量", Theme.textPrimary.opacity(0.7))
                legend("代理", Theme.Ink.claude)
                legend("直连", Theme.Ink.success)
                Spacer(minLength: 0)
            }
            if let point = selectedPoint(report) {
                HStack(spacing: 16) {
                    metric("代理", value: point.traffic.proxied.total, symbol: "arrow.triangle.branch")
                    metric("直连", value: point.traffic.direct.total, symbol: "arrow.right")
                }
            }
        }
    }

    private func trendDomain(_ report: VpnTrafficReport) -> ClosedRange<Date> {
        let start = report.points.first?.date ?? Date()
        let end = max(start.addingTimeInterval(3600), report.points.last?.date ?? start)
        return start...end
    }

    private func selectedPoint(_ report: VpnTrafficReport) -> VpnTrafficPoint? {
        guard let selectedDate else { return nil }
        return report.points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private func chartBytes(_ value: Double) -> String {
        VpnFormat.bytes(value >= Double(Int64.max) ? .max : Int64(max(0, value)))
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 16, height: 3)
            Text(title).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }
    }

    private func routeComparison(_ report: VpnTrafficReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HairlineDivider()
            HStack {
                Text("流向与上传下载").font(Theme.Font.bodySmall.weight(.semibold))
                Spacer()
                Text("连接采样").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            let lanes: [(String, VpnTrafficAmounts, Color)] = [
                ("代理", report.totals.proxied, Theme.Ink.claude),
                ("直连", report.totals.direct, Theme.Ink.success)
            ]
            let denominator = max(1, Double(report.totals.proxied.total) + Double(report.totals.direct.total))
            HStack(spacing: 24) {
                ForEach(lanes, id: \.0) { lane in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(lane.0).foregroundColor(lane.2).font(Theme.Font.bodySmall.weight(.semibold))
                            Spacer(minLength: 0)
                            Text(lane.1.total == 0 ? "0%" : String(format: "%.1f%%", Double(lane.1.total) / denominator * 100))
                                .font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary)
                        }
                        Text(VpnFormat.bytes(lane.1.total)).font(Theme.Font.body.weight(.medium)).monospacedDigit()
                        Text("↑ \(VpnFormat.bytes(lane.1.upload))   ↓ \(VpnFormat.bytes(lane.1.download))")
                            .font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary).monospacedDigit()
                        Text(lane.0 == "代理" ? "本机 → 代理节点 → 目标" : "本机 → 目标")
                            .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.Ink.claude)
                        .frame(width: max(0, geometry.size.width - 2) * Double(report.totals.proxied.total) / denominator)
                    Rectangle().fill(Theme.Ink.success)
                }
                .background(Theme.bgSecondary)
                .clipShape(Capsule())
            }.frame(height: 6).accessibilityHidden(true)
            Chart {
                ForEach(lanes, id: \.0) { lane in
                    BarMark(x: .value("上传", Double(lane.1.upload)), y: .value("流向", lane.0))
                        .foregroundStyle(lane.2.opacity(0.35)).position(by: .value("方向", "上传"))
                        .cornerRadius(3)
                    BarMark(x: .value("下载", Double(lane.1.download)), y: .value("流向", lane.0))
                        .foregroundStyle(lane.2).position(by: .value("方向", "下载"))
                        .cornerRadius(3)
                }
            }
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in AxisValueLabel().font(Theme.Font.caption) }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.6))
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) { Text(chartBytes(bytes)).font(Theme.Font.microMono) }
                    }
                }
            }
            .frame(height: 106)
            HStack(spacing: 16) {
                legend("上传 · 浅色", Theme.textSecondary.opacity(0.4))
                legend("下载 · 实色", Theme.textSecondary)
                Spacer(minLength: 0)
            }
            Text("未归类差额 \(VpnFormat.bytes(report.totals.unclassified.total)) · 占比只比较代理与直连采样；短连接可能只计入内核总量。")
                .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
        }
    }

    private func hourlyActivity(_ report: VpnTrafficReport) -> some View {
        let hours = (0..<24).map { hour in
            (hour: hour, bytes: report.activity.filter { $0.hour == hour }.reduce(Int64(0)) { VpnFormat.saturatingAdd($0, $1.bytes) })
        }
        let dayCount = Set(report.activity.map(\.day)).count
        return VStack(alignment: .leading, spacing: 14) {
            HairlineDivider()
            HStack {
                Text("日内流量").font(Theme.Font.bodySmall.weight(.semibold))
                Spacer()
                if let selectedHour, let value = hours.first(where: { abs(Double($0.hour) - selectedHour) < 0.5 }) {
                    Text("\(String(format: "%02d", value.hour)):00 · \(VpnFormat.bytes(value.bytes))")
                        .font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary)
                } else {
                    Text("时段内最近 \(dayCount) 天 · 按小时合计")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
            }
            Chart {
                ForEach(hours, id: \.hour) { hour in
                    RectangleMark(xStart: .value("起始小时", Double(hour.hour) - 0.3),
                                  xEnd: .value("结束小时", Double(hour.hour) + 0.3),
                                  yStart: .value("基线", 0.0), yEnd: .value("字节", Double(hour.bytes)))
                        .foregroundStyle(Theme.Ink.claude.opacity(selectedHour == nil || abs((selectedHour ?? 0) - Double(hour.hour)) < 0.5 ? 0.75 : 0.2))
                        .cornerRadius(3)
                }
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXSelection(value: $selectedHour)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.6))
                    AxisValueLabel { if let bytes = value.as(Double.self) { Text(chartBytes(bytes)).font(Theme.Font.microMono) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0) 时").font(Theme.Font.micro) }
                }
            }
            .frame(height: 126)
            .help("按本地小时合并所选时段最近七天的内核流量。选择柱形可读取准确数值。")
        }
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
            HairlineDivider()
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("域名流量排行").font(Theme.Font.bodySmall.weight(.semibold))
                    Text("\(count) 个域名").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    Spacer(minLength: 8)
                    rankPicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("域名流量排行 · \(count) 个域名").font(Theme.Font.bodySmall.weight(.semibold))
                    rankPicker
                }
            }
            HStack {
                Text("域名").frame(maxWidth: .infinity, alignment: .leading)
                Text("代理").frame(width: 78, alignment: .trailing)
                Text("直连").frame(width: 78, alignment: .trailing)
                Text("合计").frame(width: 82, alignment: .trailing)
            }.font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
            if domains.isEmpty {
                Text("此时段尚无域名流量采样").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    .padding(.vertical, 16)
            }
            ForEach(Array(domains.prefix(20).enumerated()), id: \.element.id) { index, domain in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(Theme.Font.microMono).foregroundColor(Theme.textSecondary).frame(width: 20, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(domain.host).font(Theme.Font.captionMono).lineLimit(1).truncationMode(.middle).help(domain.host)
                            GeometryReader { geometry in
                                let maximum = max(1, Double(domains.first.map(volume) ?? 1))
                                HStack(spacing: 0) {
                                    Rectangle().fill(Theme.Ink.claude)
                                        .frame(width: geometry.size.width * Double(rankRoute == .direct ? 0 : domain.traffic.proxied.total) / maximum)
                                    Rectangle().fill(Theme.Ink.success)
                                        .frame(width: geometry.size.width * Double(rankRoute == .proxied ? 0 : domain.traffic.direct.total) / maximum)
                                }.clipShape(Capsule())
                            }.frame(height: 3).accessibilityHidden(true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(VpnFormat.bytes(domain.traffic.proxied.total)).foregroundColor(Theme.Ink.claude).frame(width: 78, alignment: .trailing)
                        Text(VpnFormat.bytes(domain.traffic.direct.total)).foregroundColor(Theme.Ink.success).frame(width: 78, alignment: .trailing)
                        Text(VpnFormat.bytes(domain.total)).frame(width: 82, alignment: .trailing)
                    }
                    .font(Theme.Font.captionMono).monospacedDigit().frame(height: 52)
                    .textSelection(.enabled)
                    HairlineDivider()
                }
            }
            Text("显示流量最高的 20 个域名 · 历史累计保留全部域名，不受日志条数限制")
                .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
        }
    }

    private var rankPicker: some View {
        SegmentedCapsule(items: RankRoute.allCases, selection: rankRoute,
                         title: { $0.title }, tint: Theme.Ink.claude,
                         onSelect: { rankRoute = $0 }).fixedSize()
            .accessibilityLabel("域名排行流向")
    }

    private func volume(_ domain: VpnTrafficDomain) -> Int64 {
        switch rankRoute {
        case .all: return domain.total
        case .proxied: return domain.traffic.proxied.total
        case .direct: return domain.traffic.direct.total
        }
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
            Text("总流量包含经内核的所有连接；代理、直连与域名排行来自连接采样。绕过内核的系统流量不在统计范围内。")
            Text("按小时保留最近 31 天，按日保留全部历史；清空日志不会清除这里的累计数据。")
            if let date = report.updatedAt { Text("最近记录 \(date.formatted(.dateTime.month().day().hour().minute()))") }
        }.font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
    }
}
