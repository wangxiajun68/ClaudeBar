import Charts
import SwiftUI

// MARK: - History

private struct AnalysisDay: Identifiable {
    let date: Date
    let models: [ModelUsage]
    var claude = 0
    var codex = 0
    var thirdParty = 0
    var id: Date { date }
    var tokens: Int { models.reduce(0) { $0 + $1.totalTokens } }
    var calls: Int { models.reduce(0) { $0 + $1.calls } }
    var sourceTotal: Int { claude + codex + thirdParty }
    var cost: ModelPricing.Estimate { ModelPricing.estimate(models) }
}

private struct AnalysisHistory {
    var current: [AnalysisDay] = []
    var previous: [AnalysisDay] = []
    var currentModels: [ModelUsage] { ModelUsage.merged(current.flatMap(\.models)) }
    var previousModels: [ModelUsage] { ModelUsage.merged(previous.flatMap(\.models)) }
    var total: Int { current.reduce(0) { $0 + $1.tokens } }
    var priorTotal: Int { previous.reduce(0) { $0 + $1.tokens } }
    var calls: Int { current.reduce(0) { $0 + $1.calls } }
    var priorCalls: Int { previous.reduce(0) { $0 + $1.calls } }
    var claude: Int { current.reduce(0) { $0 + $1.claude } }
    var codex: Int { current.reduce(0) { $0 + $1.codex } }
    var thirdParty: Int { current.reduce(0) { $0 + $1.thirdParty } }
    var priorClaude: Int { previous.reduce(0) { $0 + $1.claude } }
    var priorCodex: Int { previous.reduce(0) { $0 + $1.codex } }

    static func load(days: Int, now: Date) -> Self {
        let cal = Calendar.current
        let end = cal.startOfDay(for: now)
        guard let start = cal.date(byAdding: .day, value: -2 * days, to: end) else { return Self() }
        let interval = DateInterval(start: start, end: end)
        let models = UsageIndex.fetchDailyModels(in: interval)
        let sourced = UsageIndex.fetchDailyBySource(in: interval)
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = cal.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        func map(_ source: UsageSource) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: (sourced[source] ?? []).map { ($0.day, $0.totalTokens) })
        }
        let claude = map(.claude), codex = map(.codex), third = map(.thirdParty)
        let series = (0..<(2 * days)).compactMap { offset -> AnalysisDay? in
            guard let date = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = formatter.string(from: date)
            return AnalysisDay(date: date, models: models[key] ?? [],
                               claude: claude[key] ?? 0, codex: codex[key] ?? 0, thirdParty: third[key] ?? 0)
        }
        return Self(current: Array(series.suffix(days)), previous: Array(series.prefix(days)))
    }
}

private enum AnalysisSource: String, CaseIterable, Identifiable {
    case claude, codex, thirdParty
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .thirdParty: return "第三方"
        }
    }
    var color: Color {
        switch self {
        case .claude: return Theme.claude
        case .codex: return Theme.codex
        case .thirdParty: return Theme.cursor
        }
    }
    func value(_ day: AnalysisDay) -> Int {
        switch self {
        case .claude: return day.claude
        case .codex: return day.codex
        case .thirdParty: return day.thirdParty
        }
    }
}

// MARK: - View

struct DashboardAnalysisView: View {
    let refreshStats: [ModelUsage]
    let refreshDays: [DayUsage]
    @State private var horizon = 28
    @State private var history = AnalysisHistory()
    @State private var loading = true
    /// Totals only. Comparing the full usage arrays restarted the SQLite load
    /// on every store publish, even when the chart's inputs had not changed.
    private var refreshID: String {
        let days = refreshDays.reduce(0) { $0 &+ $1.totalTokens }
        let stats = refreshStats.reduce(0) { $0 &+ $1.totalTokens &+ $1.calls }
        let day = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate)
        return "\(horizon)|\(days)|\(stats)|\(day)"
    }
    private let modelPalette: [Color] = [Theme.chartBlue, Theme.claude, Theme.chartGreen, Theme.chartAmber, Theme.textTertiary()]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("用量对照").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("截至昨日，和此前同样长的一段比较")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Picker("时段", selection: $horizon) {
                    Text("7 天").tag(7)
                    Text("14 天").tag(14)
                    Text("28 天").tag(28)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }
            if loading {
                ProgressView("正在汇总历史记录…").frame(maxWidth: .infinity, minHeight: 180)
            } else if history.total == 0 && history.priorTotal == 0 {
                StandbyEmptyState(label: "这两个时段暂无用量记录").frame(maxWidth: .infinity, minHeight: 160)
            } else {
                trend
                composition
                Text(narrative)
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: refreshID) {
            let firstLoad = history.current.isEmpty && history.previous.isEmpty
            if firstLoad { loading = true }
            let days = horizon
            let fresh = await Task.detached(priority: .utility) {
                AnalysisHistory.load(days: days, now: Date())
            }.value
            guard !Task.isCancelled else { return }
            if !sameSeries(history, fresh) { history = fresh }
            loading = false
        }
    }

    private var estimate: ModelPricing.Estimate { ModelPricing.estimate(history.currentModels) }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                figure(UsageStats.formatTokens(history.total), caption: "近 \(horizon) 天 Token",
                       note: shift(history.total, history.priorTotal))
                figure(costHeadline, caption: "按刊例价估算", note: costNote)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(range(history.current)).font(Theme.Font.caption)
                    Text("对比 " + range(history.previous))
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Chart {
                ForEach(Array(history.current.enumerated()), id: \.element.id) { index, day in
                    ForEach(AnalysisSource.allCases) { source in
                        let amount = source.value(day)
                        if amount > 0 {
                            BarMark(x: .value("天", index), y: .value("Token", amount))
                                .foregroundStyle(by: .value("来源", source.label))
                        }
                    }
                }
                ForEach(Array(history.previous.enumerated()), id: \.element.id) { index, day in
                    LineMark(x: .value("天", index), y: .value("此前", day.tokens))
                        .foregroundStyle(Theme.textTertiary())
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }
            }
            .chartForegroundStyleScale(domain: AnalysisSource.allCases.map(\.label),
                                       range: AnalysisSource.allCases.map(\.color))
            .chartLegend(.hidden)
            .chartXScale(domain: 0...(max(horizon - 1, 1)))
            .chartXAxis {
                AxisMarks(values: [0, (horizon - 1) / 2, horizon - 1]) { value in
                    AxisValueLabel {
                        if let index = value.as(Int.self), history.current.indices.contains(index) {
                            Text(history.current[index].date, format: .dateTime.month().day())
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Int.self) {
                            Text(UsageStats.formatTokens(number)).monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: 188)
            .transaction { $0.disablesAnimations = true }
            HStack(spacing: 14) {
                ForEach(AnalysisSource.allCases) { source in
                    HStack(spacing: 5) {
                        Circle().fill(source.color).frame(width: 7, height: 7)
                        Text(source.label)
                    }
                }
                HStack(spacing: 5) {
                    Capsule().strokeBorder(Theme.textTertiary(), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: 14, height: 2)
                    Text("此前总量")
                }
                Spacer(minLength: 0)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textSecondary)
            .frame(height: 18)
        }
        .padding(20).panelCard()
    }

    private var composition: some View {
        let ranked = history.currentModels.sorted { $0.totalTokens > $1.totalTokens }
        let shown = Array(ranked.prefix(4))
        let restTokens = ranked.dropFirst(4).reduce(0) { $0 + $1.totalTokens }
        let total = max(history.total, 1)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Token 去了哪些模型").font(Theme.Font.chromeEmph)
            MixBar(segments: mixSegments(shown: shown, rest: restTokens, total: total))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, model in
                    modelRow(model, color: modelPalette[index], share: Double(model.totalTokens) / Double(total))
                }
                if restTokens > 0 {
                    HStack(spacing: 10) {
                        Circle().fill(modelPalette[4]).frame(width: 8, height: 8)
                        Text("其余 \(ranked.count - 4) 个模型")
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(UsageStats.formatTokens(restTokens))
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                        Text(shareText(Double(restTokens) / Double(total)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(20).panelCard()
    }

    private func modelRow(_ model: ModelUsage, color: Color, share: Double) -> some View {
        let prior = history.previousModels.first { $0.model == model.model }?.totalTokens ?? 0
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.model).lineLimit(1).truncationMode(.middle)
                    .font(Theme.Font.caption)
                Text(modelDetail(model))
                    .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(UsageStats.formatTokens(model.totalTokens))
                    .font(Theme.Font.caption)
                    .monospacedDigit()
                Text(shift(model.totalTokens, prior))
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            .frame(width: 88, alignment: .trailing)
            Text(shareText(share))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func mixSegments(shown: [ModelUsage], rest: Int, total: Int) -> [(Color, Double)] {
        let denom = Double(max(total, 1))
        var segments = shown.enumerated().map { (modelPalette[$0.offset], Double($0.element.totalTokens) / denom) }
        if rest > 0 { segments.append((modelPalette[4], Double(rest) / denom)) }
        return segments.filter { $0.1 > 0 }
    }

    private func figure(_ value: String, caption: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            Text(caption).font(Theme.Font.caption).lineLimit(1)
            Text(note).font(Theme.Font.micro).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var narrative: String {
        var sentences: [String] = []
        if let peak = history.current.max(by: { $0.tokens < $1.tokens }), history.total > 0, peak.tokens > 0 {
            let day = UsageStats.formatter("M月d日").string(from: peak.date)
            let share = Double(peak.tokens) / Double(history.total) * 100
            sentences.append(String(format: "用量最高的一天是 %@，占这 %d 天的 %.0f%%。", day, horizon, share))
        }
        let parts = [("Claude Code", history.claude), ("Codex", history.codex), ("第三方", history.thirdParty)]
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        if let lead = parts.first, history.total > 0 {
            let share = Double(lead.1) / Double(max(history.claude + history.codex + history.thirdParty, 1)) * 100
            sentences.append(String(format: "%@ 贡献了这段来源用量的 %.0f%%。", lead.0, share))
        }
        if history.codex > 0 && history.priorCodex == 0 {
            sentences.append("Codex 的用量是这段新出现的，此前同时段没有 Codex 记录。")
        }
        let ranked = history.currentModels.sorted { $0.totalTokens > $1.totalTokens }
        let notable = ranked.prefix(3).filter { history.total > 0 && Double($0.totalTokens) / Double(history.total) >= 0.08 }
        if let cached = notable.max(by: { $0.cacheHitRate < $1.cacheHitRate }),
           let plain = notable.min(by: { $0.cacheHitRate < $1.cacheHitRate }),
           cached.model != plain.model, cached.cacheHitRate >= 0.05, plain.cacheHitRate < 0.01 {
            sentences.append("\(cached.model) 的输入有 \(cached.cacheHitPercent)% 来自缓存，\(plain.model) 几乎没有缓存命中。")
        }
        if sentences.isEmpty { return "这段还没有足够的记录可以比较。" }
        return sentences.joined()
    }

    private var costHeadline: String {
        let amounts = [(ModelPricing.Currency.cny, estimate.cost.cny), (.usd, estimate.cost.usd)]
            .filter { $0.1 > 0 }.map { ModelPricing.format($0.1, currency: $0.0) }
        return amounts.isEmpty ? "暂无刊例价" : amounts.joined(separator: " + ")
    }
    private var costNote: String {
        if estimate.unpricedModels == 0 { return "覆盖了这段出现的全部模型" }
        let uncovered = history.total > 0 ? Double(estimate.unpricedTokens) / Double(history.total) * 100 : 0
        return String(format: "%.0f%% 的 Token 没有刊例价，未计入上面的金额", uncovered)
    }

    private func modelDetail(_ model: ModelUsage) -> String {
        var parts = ["\(model.calls.formatted()) 次调用"]
        if model.totalInputTokens > 0 {
            parts.append(model.cacheHitRate >= 0.01 ? "缓存命中 \(model.cacheHitPercent)%" : "没有缓存命中")
        }
        return parts.joined(separator: " · ")
    }
    private func sameSeries(_ lhs: AnalysisHistory, _ rhs: AnalysisHistory) -> Bool {
        lhs.current.map(\.tokens) == rhs.current.map(\.tokens)
            && lhs.previous.map(\.tokens) == rhs.previous.map(\.tokens)
            && lhs.currentModels.map(\.totalTokens) == rhs.currentModels.map(\.totalTokens)
            && lhs.calls == rhs.calls && lhs.priorCalls == rhs.priorCalls
    }
    private func shareText(_ share: Double) -> String { String(format: "%.0f%%", share * 100) }
    private func shift(_ now: Int, _ before: Int) -> String {
        guard before > 0 else { return now > 0 ? "此前没有用量" : "两边都没有用量" }
        let ratio = Double(now) / Double(before)
        if ratio >= 10 { return String(format: "是此前的 %.0f 倍", ratio) }
        return String(format: "较此前 %+.0f%%", (ratio - 1) * 100)
    }
    private func range(_ days: [AnalysisDay]) -> String {
        guard let first = days.first, let last = days.last else { return "—" }
        let formatter = UsageStats.formatter("M月d日")
        return formatter.string(from: first.date) + "–" + formatter.string(from: last.date)
    }
}

/// Fixed-height share bar. Widths are painted, not proposed, so the row cannot
/// renegotiate its size while the parent lays out.
private struct MixBar: View {
    let segments: [(Color, Double)]

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = segments.count > 1 ? 2 : 0
            let usable = max(0, size.width - gap * CGFloat(max(segments.count - 1, 0)))
            var x: CGFloat = 0
            for (index, segment) in segments.enumerated() {
                let width = usable * CGFloat(segment.1)
                let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(4, size.height / 2)), with: .color(segment.0))
                x += width + (index < segments.count - 1 ? gap : 0)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
