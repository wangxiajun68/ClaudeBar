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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Theme.Font.caption).foregroundColor(Theme.Ink.error)
                    .textSelection(.enabled)
            }
            if let report {
                totals(report)
                HairlineDivider()
                if report.startedAt == nil {
                    empty.frame(maxHeight: .infinity, alignment: .topLeading)
                } else {
                    VpnTrafficTrendView(report: report, period: period)
                        .frame(maxHeight: .infinity)
                }
                footnote(report)
            } else if loading {
                ProgressView("正在读取流量历史…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        HStack(alignment: .top, spacing: 16) {
            trafficTotal("内核总流量", report.totals.core, ink: Theme.textPrimary)
            trafficTotal("代理流量", report.totals.proxied, ink: Theme.Ink.claude)
            trafficTotal("直连流量", report.totals.direct, ink: Theme.Ink.success)
        }
    }

    private func trafficTotal(_ title: String, _ traffic: VpnTrafficAmounts, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(Theme.textSecondary)
            Text(VpnFormat.bytes(traffic.total))
                .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundColor(ink).lineLimit(1).minimumScaleFactor(0.65)
            Text("↑ \(VpnFormat.bytes(traffic.upload)) · ↓ \(VpnFormat.bytes(traffic.download))")
                .font(.system(size: 11, design: .rounded)).monospacedDigit()
                .foregroundColor(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("流量历史从下一次连接采样开始").font(Theme.Font.bodySmall.weight(.medium))
            Text("连接 VPN 后会自动记录趋势与域名排行。过去的日志没有字节数据，无法补算历史流量。")
                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }.frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
    }

    private func footnote(_ report: VpnTrafficReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("历史累计 \(VpnFormat.bytes(report.lifetime.core.total)) · 未归类 \(VpnFormat.bytes(report.totals.unclassified.total))")
                .monospacedDigit()
            Text("代理与直连来自连接采样，仅统计经过内核的流量。清空日志不影响历史。")
        }.font(.system(size: 11, design: .rounded)).foregroundColor(Theme.textSecondary)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("代理与直连趋势").font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                SegmentedCapsule(items: Measure.allCases, selection: measure,
                                 title: { $0.title }, tint: Theme.Ink.claude,
                                 onSelect: { measure = $0 }).fixedSize()
                    .accessibilityLabel("图表显示的数据")
            }
            Chart {
                ForEach(report.points) { point in
                    LineMark(x: .value("时间", point.date), y: .value(measure.title, Double(measure.bytes(point.traffic.proxied))),
                             series: .value("流向", "代理"))
                        .foregroundStyle(by: .value("流向", "代理"))
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                    LineMark(x: .value("时间", point.date), y: .value(measure.title, Double(measure.bytes(point.traffic.direct))),
                             series: .value("流向", "直连"))
                        .foregroundStyle(by: .value("流向", "直连"))
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [5, 3]))
                        .interpolationMethod(.linear)
                }
                if let point = selectedPoint(report) ?? peakPoint {
                    if selectedDate != nil {
                        RuleMark(x: .value("选中时间", point.date))
                            .foregroundStyle(Theme.textSecondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    PointMark(x: .value("时间", point.date), y: .value(measure.title, Double(measure.bytes(point.traffic.proxied))))
                        .foregroundStyle(by: .value("流向", "代理")).symbolSize(36)
                    PointMark(x: .value("时间", point.date), y: .value(measure.title, Double(measure.bytes(point.traffic.direct))))
                        .foregroundStyle(by: .value("流向", "直连")).symbolSize(36)
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
            .chartYScale(domain: 0...max(1, Double(report.points.map { max(measure.bytes($0.traffic.proxied), measure.bytes($0.traffic.direct)) }.max() ?? 0) * 1.08))
            .chartForegroundStyleScale(["代理": Theme.chartBlue, "直连": Theme.chartGreen])
            .chartLegend(position: .top, alignment: .leading, spacing: 8)
            .frame(minHeight: 100, maxHeight: .infinity)
            .accessibilityLabel("\(period.title)代理与直连\(measure.title)流量，蓝色实线为代理，绿色虚线为直连，纵轴为字节，横轴为统计时段")
            inspection
        }
    }

    private var peakPoint: VpnTrafficPoint? {
        report.points.max {
            VpnFormat.saturatingAdd(measure.bytes($0.traffic.proxied), measure.bytes($0.traffic.direct))
                < VpnFormat.saturatingAdd(measure.bytes($1.traffic.proxied), measure.bytes($1.traffic.direct))
        }
    }

    private var inspection: some View {
        let point = selectedPoint(report)
        let traffic = point?.traffic ?? peakPoint?.traffic ?? .init()
        let date = point?.date ?? peakPoint?.date
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(point == nil ? "峰值时段" : "选中时段")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                Text(date.map { bucketLabel($0) } ?? "暂无采样")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text("代理 \(VpnFormat.bytes(measure.bytes(traffic.proxied))) · 直连 \(VpnFormat.bytes(measure.bytes(traffic.direct)))")
                .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(height: 40)
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
