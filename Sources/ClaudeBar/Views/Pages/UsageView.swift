import SwiftUI

/// Usage analytics page: period tabs, heatmap, platform, provider and model breakdowns.
struct UsageView: View {
    @ProviderState([.usage, .configuration]) var providerStore: ProviderStore
    @EnvironmentObject private var codexStore: CodexProviderStore
    @ObservedObject private var ledger = CursorLedgerStore.shared
    @State private var showCustomDatePicker = false
    @State private var officialCodexUsage: [ModelUsage] = []
    @State private var attributionInterval: DateInterval?
    @State private var displayedAnalytics: AnalyticsSnapshot?

    /// Only complete data for the selected window enters the presentation.
    /// Keep the previous snapshot while the index answers a new period.
    private struct AnalyticsSnapshot: Equatable {
        let days: [DayUsage]
        let stats: [ModelUsage]
        let sources: [UsageSource: [ModelUsage]]
        let period: UsagePeriod
        let interval: DateInterval
    }

    private var readyAnalytics: AnalyticsSnapshot? {
        let period = providerStore.usagePeriod
        let interval = UsageStats.interval(for: period, reference: providerStore.usageReferenceDate)
        guard providerStore.usagePublishedInterval == interval else { return nil }
        return AnalyticsSnapshot(days: UsageStats.heatmapDays(for: period,
                                                             periodDays: providerStore.usageDays,
                                                             weekDays: providerStore.usageWeekDays),
                                 stats: providerStore.usageStats, sources: providerStore.usageBySource,
                                 period: period, interval: interval)
    }
    private struct AttributionRequest: Equatable {
        let interval: DateInterval
        let codex: [ModelUsage]
    }

    var body: some View {
        // Derived once: the subtitle's caption read both of these, so the body
        // used to run the date formatter and the whole `usageStats` reduce twice
        // per pass.
        let periodLabel = UsageStats.label(for: providerStore.usagePeriod,
                                           reference: providerStore.usageReferenceDate)
        // The period's own interval, not one inferred from whichever days
        // happen to have rows: it identifies the requested window. The
        // analytics section is keyed to it and appears only once the store
        // has published this same window, and both the attribution task and
        // `providerGroups` match on it.
        let interval = UsageStats.interval(for: providerStore.usagePeriod,
                                           reference: providerStore.usageReferenceDate)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                titleBar

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if providerStore.usagePeriod != .all {
                            Button(action: { shiftUsage(-1) }) { Image(systemName: "chevron.left").frame(width: 22, height: 24) }
                                .buttonStyle(.plain).accessibilityLabel("上一周期")
                        }
                        Text(periodLabel).font(.system(size: 13, weight: .semibold)).fixedSize()
                        if providerStore.usagePeriod != .all {
                            Button(action: { shiftUsage(1) }) { Image(systemName: "chevron.right").frame(width: 22, height: 24) }
                                .buttonStyle(.plain).accessibilityLabel("下一周期")
                        }
                        Spacer(minLength: 12)
                        PeriodTabs(period: providerStore.usagePeriod, onSelect: selectPeriod)
                        Button(action: {
                            providerStore.refreshUsage(rescan: true)
                            providerStore.requestSettlement(force: true)
                        }) {
                            Image(systemName: "arrow.clockwise").frame(width: 26, height: 26)
                        }.buttonStyle(.plain).help("重新统计本周期用量").accessibilityLabel("重新统计本周期用量")
                        ProgressView().controlSize(.small)
                            .frame(width: 16, height: 16)
                            .opacity(providerStore.usageLoading || providerStore.usagePublishedInterval != interval ? 1 : 0)
                            .accessibilityHidden(!providerStore.usageLoading && providerStore.usagePublishedInterval == interval)
                    }.foregroundColor(Theme.textPrimary)
                    if showCustomDatePicker {
                        DatePicker("日期", selection: $providerStore.usageReferenceDate, displayedComponents: [.date])
                            .datePickerStyle(.compact)
                    }
                }.padding(.horizontal, 14).padding(.vertical, 8).usageFigure()

                if let snapshot = displayedAnalytics {
                    UsageAnalyticsSection(days: snapshot.days, stats: snapshot.stats,
                                          sources: snapshot.sources, period: snapshot.period,
                                          interval: snapshot.interval,
                                          onSelectMonth: { date in
                        providerStore.usagePeriod = .month
                        providerStore.usageReferenceDate = date
                        showCustomDatePicker = false
                    }) { date in
                        providerStore.usagePeriod = .day
                        providerStore.usageReferenceDate = date
                        showCustomDatePicker = false
                    }

                    // Stable identity retains the last computed chart while the
                    // next analysis task runs; there is no second loading flash.
                    .allowsHitTesting(snapshot.interval == interval && snapshot.period == providerStore.usagePeriod)

                    VStack(alignment: .leading, spacing: 24) {
                        platformBreakdown
                        providerBreakdown
                        modelBreakdown
                    }.padding(.top, 16)
                } else {
                    ProgressView("读取本周期记录…").frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .scrollHoverGate()
        .background(Theme.bgPrimary)
        .onChange(of: readyAnalytics, initial: true) { _, snapshot in
            if let snapshot { displayedAnalytics = snapshot }
        }
        .task(id: AttributionRequest(interval: interval, codex: providerStore.usageBySource[.codex] ?? [])) {
            let rows = await Task.detached(priority: .utility) { UsageIndex.fetchOfficialCodex(in: interval) }.value
            guard !Task.isCancelled else { return }
            officialCodexUsage = rows
            attributionInterval = interval
        }
    }

    private var titleBar: some View {
        PageTitle(title: "用量")
    }

    private var platformBreakdown: some View {
        let total = providerStore.usageStats.reduce(0) { $0 + $1.totalTokens }
        let thirdParty = providerStore.usageBySource[.thirdParty] ?? []
        return VStack(alignment: .leading, spacing: Theme.Space.s12) {
            SectionHeader(icon: "square.grid.2x2", title: "按平台",
                          tint: Theme.claude, ink: Theme.Ink.claude,
                          count: thirdParty.isEmpty ? 3 : 4)
            Text("Codex 包含官方和自定义模型、当前及归档会话；本地占比包含第三方代理记录。Cursor 按官方账单单独统计。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
            TileGrid(.pageUsage) {
                UsagePlatformCard(source: .claude, stats: providerStore.usageBySource[.claude] ?? [],
                                  overallTokens: total)
                CursorTokenUsageCard(window: UsageStats.interval(
                    for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate))
                UsagePlatformCard(source: .codex, stats: providerStore.usageBySource[.codex] ?? [],
                                  overallTokens: total)
                if !thirdParty.isEmpty {
                    UsagePlatformCard(source: .thirdParty, stats: thirdParty,
                                      overallTokens: total)
                }
            }
        }
    }

    private var modelBreakdown: some View {
        let cursorStats = ledger.rows.values.map {
            ModelUsage(model: $0.model, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                       cacheReadTokens: $0.cacheReadTokens, cacheCreationTokens: $0.cacheWriteTokens)
        }
        let rows = UsageModelInventory.rows(local: providerStore.usageStats,
                                            sources: providerStore.usageBySource,
                                            cursor: cursorStats, costs: providerStore.usageCostLines)
        return VStack(alignment: .leading, spacing: Theme.Space.s12) {
            SectionHeader(icon: "cube", title: "按模型",
                          tint: Theme.cursor, ink: Theme.Ink.cursor, count: rows.count)
            Text("列出所选周期的全部本地模型及 Cursor 账单中的模型；同一模型的两种用量分别显示。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
            if rows.isEmpty && !providerStore.usageLoading && !ledger.loading {
                StandbyEmptyState(label: "暂无用量", symbol: "chart.bar",
                                  tint: Theme.textSecondary, block: true)
            } else {
                TileGrid(.pageUsage, minColumnWidth: 320) {
                    ForEach(rows) { row in
                        let slices = row.hasLocal ? UsageSource.allCases.map { source in
                            SourceRing.Slice(label: source.label, value: row.sourceTokens[source] ?? 0,
                                             color: source.color)
                        } : [SourceRing.Slice(label: "Cursor", value: row.displayed.totalTokens, color: Theme.cursor)]
                        UsageModelCard(
                            stat: row.displayed,
                            slices: slices,
                            costLine: row.costLine,
                            settlement: ledger.rows[row.id].map { ModelPricing.Cost(usd: $0.costCents / 100) },
                            settlementWindow: row.cursor == nil ? nil : ledger.windowLabel,
                            cursorStat: row.hasLocal ? row.cursor : nil,
                            cursorOnly: !row.hasLocal
                        )
                    }
                }
            }
        }
    }

    private var providerBreakdown: some View {
        let groups = providerGroups
        let total = groups.reduce(0) { $0 + $1.total.totalTokens }
        return VStack(alignment: .leading, spacing: Theme.Space.s12) {
            SectionHeader(icon: "building.2", title: "按供应商",
                          tint: Theme.statusSuccess, ink: Theme.Ink.success,
                          count: groups.count,
                          note: "会话来源优先 · 其余按配置归属",
                          noteTint: Theme.textTertiary())
                .help("Codex 官方用量按会话供应商标识归属；其他记录按当前模型配置匹配，缺失或多重匹配计入未归属。Cursor 账单保持独立。")
            if total == 0 && !providerStore.usageLoading {
                StandbyEmptyState(label: "暂无用量", symbol: "chart.bar",
                                  tint: Theme.textSecondary, block: true)
            } else {
                TileGrid(.pageUsage) {
                    ForEach(groups) { group in
                        UsageProviderCard(group: group, overallTokens: total)
                    }
                }
            }
        }
    }

    /// Usage grouped by owning provider.
    ///
    /// Ownership is resolved per *source*: a Claude Code model is looked up
    /// among the Claude Code vendors, a Codex model among the Codex ones, and
    /// only third-party traffic — which is not either platform's own — against
    /// the union of both. Registering every configured model under
    /// `.thirdParty` as well made one Claude model look owned by Claude *and*
    /// by third-party, so a model with exactly one real owner produced two
    /// groups carrying the same `name` — and `UsageProviderGroup.id` **is** the
    /// name, which is a duplicate ForEach id (SwiftUI then reuses and drops
    /// rows at random). A name that genuinely maps to two providers now lands
    /// in 未归属, which is what its help text says.
    private var providerGroups: [UsageProviderGroup] {
        // Keyed by provider *name*, not id: the two stores hand out different
        // ids for the same vendor (`Provider.profileID` is what links them), and
        // all this needs is a stable label per bucket.
        var keys: [UsageSource: [String: Set<String>]] = [:]
        func register(_ source: UsageSource, _ provider: Provider) {
            for model in provider.models {
                let key = ModelPricing.canonical(model.name)
                keys[source, default: [:]][key, default: []].insert(provider.name)
            }
        }
        /// Third-party traffic has no platform of its own, so it may be served
        /// by any vendor; a platform's own traffic only by that platform's.
        func candidates(for source: UsageSource, key: String) -> Set<String> {
            switch source {
            case .claude: return keys[.claude]?[key] ?? []
            case .codex: return keys[.codex]?[key] ?? []
            case .thirdParty: return (keys[.claude]?[key] ?? []).union(keys[.codex]?[key] ?? [])
            }
        }

        for provider in providerStore.providers { register(.claude, provider) }
        for provider in codexStore.providers { register(.codex, provider.asDisplayProvider) }

        var grouped: [String: [String: ModelUsage]] = [:]
        func add(_ stat: ModelUsage, to name: String) {
            guard stat.totalTokens > 0 else { return }
            var model = grouped[name]?[stat.model] ?? ModelUsage(model: stat.model)
            model.merge(stat)
            grouped[name, default: [:]][stat.model] = model
        }
        let interval = UsageStats.interval(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate)
        let official = Dictionary((attributionInterval == interval ? officialCodexUsage : []).map { ($0.model, $0) }, uniquingKeysWith: { first, _ in first })
        for source in UsageSource.allCases {
            for stat in providerStore.usageBySource[source] ?? [] {
                let parts = UsageProviderAttribution.split(stat, official: source == .codex ? official[stat.model] : nil)
                add(parts.official, to: "OpenAI 官方")
                let owners = candidates(for: source, key: ModelPricing.canonical(stat.model))
                add(parts.remaining, to: owners.count == 1 ? (owners.first ?? "未归属") : "未归属")
            }
        }
        return grouped.map { name, models in
            UsageProviderGroup(name: name, models: models.values.sorted { $0.totalTokens > $1.totalTokens })
        }
        .sorted { lhs, rhs in
            if lhs.name == "未归属" { return false }
            if rhs.name == "未归属" { return true }
            return lhs.total.totalTokens > rhs.total.totalTokens
        }
    }

    private func selectPeriod(_ period: UsagePeriod) {
        if period == .custom {
            // Toggle, not "always open": the same chip closes the picker, and
            // that click used to leave the page on a 自定义 period the user
            // never chose — the reference date kept its old value, so the
            // figures silently narrowed to a single day while the picker was
            // dismissed.
            let opening = !showCustomDatePicker
            withAnimation(Theme.Animation.smooth) { showCustomDatePicker = opening }
            if opening {
                providerStore.usagePeriod = .custom
            } else if providerStore.usagePeriod == .custom {
                providerStore.usagePeriod = .month
                providerStore.usageReferenceDate = Date()
            }
        } else {
            showCustomDatePicker = false
            providerStore.usagePeriod = period
            providerStore.usageReferenceDate = Date()
        }
        // A new period is a new window, and Cursor's ledger answers for a
        // window — so this is where the money read is re-aimed. After the two
        // assignments above, because the window is derived from both of them.
        // A no-op inside the store when the window is already in hand.
        providerStore.requestSettlement()
    }

    private func shiftUsage(_ amount: Int) {
        providerStore.usageReferenceDate = UsageStats.shift(
            providerStore.usagePeriod, reference: providerStore.usageReferenceDate, by: amount
        )
        // Paging to another month pages the money too — the ledger's window
        // follows the reference date, not just the period kind.
        providerStore.requestSettlement()
    }

}

private struct UsageProviderGroup: Identifiable {
    let name: String
    let models: [ModelUsage]
    var id: String { name }
    var total: ModelUsage { models.reduce(into: ModelUsage(model: name)) { $0.merge($1) } }
}

/// The 模型明细 rows and Token 构成 bar shared by the platform, provider and
/// Cursor cards.
///
/// Extracted because the three copies had already drifted — only the Cursor
/// card's rows revealed their full name on hover, and only it and the platform
/// card had an empty state — so the block is drawn once here: every row shows
/// the name behind its middle truncation, and a card that can be empty hands in
/// its own label (a provider group is built from recorded rows, so it never
/// passes one).
///
/// A transparent `Group`-shaped body: the three call sites keep their own
/// `VStack` and spacing, since the Cursor card shares its stack with the window
/// caption and the coverage notes.
struct UsageModelBreakdown: View {
    let stats: [ModelUsage]
    var emptyLabel: String? = nil
    /// Hover text for the bar. Only the Cursor card spells the four totals out;
    /// the others leave it empty and the strip speaks for itself.
    var stripHelp: String = ""

    var body: some View {
        HairlineDivider()
        Text("模型明细")
            .font(Theme.Font.microSemibold)
            .foregroundColor(Theme.textSecondary)
        if let emptyLabel, stats.isEmpty {
            StandbyEmptyState(label: emptyLabel, symbol: "chart.bar", tint: Theme.textSecondary)
        } else {
            ForEach(stats) { model in
                HStack(spacing: 8) {
                    Text(model.model).lineLimit(1).truncationMode(.middle).help(model.model)
                    Spacer(minLength: 4)
                    RollingNumberText(UsageStats.formatTokens(model.totalTokens))
                        .monospacedDigit()
                }
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textSecondary)
            }
            Text("Token 构成")
                .font(Theme.Font.microSemibold)
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 4)
            TokenMixStrip(stats: stats, compact: true)
                .help(stripHelp)
        }
    }
}

private struct UsageProviderCard: View {
    let group: UsageProviderGroup
    let overallTokens: Int
    @State private var hovered = false

    var body: some View {
        let total = group.total
        let shareLabel = UsageAnalysis.share(total.totalTokens, of: overallTokens)
        return Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(Theme.chartPurple).frame(width: 7, height: 7).padding(.top, 6)
                    Text(group.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 5) {
                        HStack(spacing: 5) {
                            RollingNumberText("\(total.calls) 次")
                        }
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                        CacheHitBadge(stat: total)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RollingNumberText(UsageStats.formatTokens(total.totalTokens))
                        .font(Theme.Font.displayMetricSmall)
                        .monospacedDigit()
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        RollingNumberText(shareLabel)
                            .font(Theme.Font.tileValueSmall)
                            .foregroundColor(Theme.textPrimary)
                        Text("供应商占比")
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.textTertiary())
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        UsageModelBreakdown(stats: group.models)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity).frame(height: 260, alignment: .topLeading)
            .tile(hovered: hovered, lift: false)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .hoverState($hovered)
    }
}

/// Period totals by client platform, using the same source rows as the chart above.
private struct UsagePlatformCard: View {
    let source: UsageSource
    let stats: [ModelUsage]
    let overallTokens: Int
    @State private var hovered = false

    var body: some View {
        let total = stats.reduce(into: ModelUsage(model: source.label)) { $0.merge($1) }
        let shareLabel = UsageAnalysis.share(total.totalTokens, of: overallTokens)
        let ranked = stats.sorted { $0.totalTokens > $1.totalTokens }

        return Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(source.color).frame(width: 7, height: 7).padding(.top, 6)
                    Text(source.label)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 5) {
                        HStack(spacing: 5) {
                            RollingNumberText("\(total.calls) 次")
                        }
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                        CacheHitBadge(stat: total)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RollingNumberText(UsageStats.formatTokens(total.totalTokens))
                        .font(Theme.Font.displayMetricSmall)
                        .monospacedDigit()
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        RollingNumberText(shareLabel)
                            .font(Theme.Font.tileValueSmall)
                            .foregroundColor(Theme.textPrimary)
                        Text("本地占比")
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.textTertiary())
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // `ranked`, not `stats`: the SQL grouping gives no
                        // stable row order, so the rows are sorted by size for
                        // display. The strip only sums, so it reads the same.
                        UsageModelBreakdown(stats: ranked, emptyLabel: "暂无用量")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity).frame(height: 260, alignment: .topLeading)
            // One hue for the wash and the rings — the source's *shape* colour.
            // `source.ink` is the text mix (the title and the counts inside use
            // it); passing it as the wash made the surface darker than the
            // glyphs it was supposed to sit behind.
            .tile(tint: source.color, hovered: hovered,
                  lens: DepthLensSpec(tint: source.color, size: 124), lift: false)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .hoverState($hovered)
    }
}
