import SwiftUI

/// Usage analytics page: period tabs, heatmap, platform, provider and model breakdowns.
struct UsageView: View {
    @ProviderState([.usage, .configuration]) var providerStore: ProviderStore
    @EnvironmentObject private var codexStore: CodexProviderStore
    @State private var showCustomDatePicker = false
    @State private var showDetails = true

    var body: some View {
        // Derived once: the subtitle's caption read both of these, so the body
        // used to run the date formatter and the whole `usageStats` reduce twice
        // per pass.
        let periodLabel = UsageStats.label(for: providerStore.usagePeriod,
                                           reference: providerStore.usageReferenceDate)
        // The daily spark's buckets describe the period, so it is handed the
        // period's own interval rather than left to infer a span from whichever
        // days happen to have rows in them.
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
                        if providerStore.usageLoading { ProgressView().controlSize(.small) }
                    }.foregroundColor(Theme.textPrimary)
                    if showCustomDatePicker {
                        DatePicker("日期", selection: $providerStore.usageReferenceDate, displayedComponents: [.date])
                            .datePickerStyle(.compact)
                    }
                }.padding(.horizontal, 14).padding(.vertical, 8).usageFigure()

                if providerStore.usagePublishedInterval == interval {
                    UsageAnalyticsSection(days: providerStore.usageDays, stats: providerStore.usageStats,
                                          sources: providerStore.usageBySource,
                                          period: providerStore.usagePeriod, interval: interval) { date in
                        providerStore.usagePeriod = .day
                        providerStore.usageReferenceDate = date
                        showCustomDatePicker = false
                    }

                    .id(interval)

                    DisclosureGroup(isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 24) {
                            platformBreakdown
                            providerBreakdown
                            modelBreakdown
                        }.padding(.top, 16)
                    } label: {
                        HStack(spacing: 8) {
                            AppGlyph(name: "list.bullet.rectangle", size: 16).foregroundColor(Theme.Ink.claude)
                            Text("记录明细").font(Theme.Font.body)
                            Spacer()
                            Text("平台 · 供应商 · 模型 · 官方账单").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                        }
                    }
                    .padding(12).usageFigure()
                } else {
                    ProgressView("读取本周期记录…").frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .scrollHoverGate()
        .background(Theme.bgPrimary)
    }

    private var titleBar: some View {
        PageTitle(title: "用量")
    }

    private var platformBreakdown: some View {
        let total = providerStore.usageTotalBySource.reduce(0) { $0 + $1.tokens }
        return VStack(alignment: .leading, spacing: Theme.Space.s12) {
            SectionHeader(icon: "square.grid.2x2", title: "按平台",
                          tint: Theme.claude, ink: Theme.Ink.claude,
                          count: UsageSource.allCases.count + 1)
            Text("Cursor 按官方账单单独统计；上方图表和其他平台占比仅包含本地记录。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
            TileGrid(.pageUsage) {
                ForEach(UsageSource.allCases) { source in
                    UsagePlatformCard(
                        source: source,
                        stats: providerStore.usageBySource[source] ?? [],
                        days: providerStore.usageDaysBySource[source] ?? [],
                        overallTokens: total
                    )
                }
                CursorTokenUsageCard(window: UsageStats.interval(
                    for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate))
            }
        }
    }

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            SectionHeader(icon: "cube", title: "按模型",
                          tint: Theme.cursor, ink: Theme.Ink.cursor,
                          count: providerStore.usageStats.count)
            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                StandbyEmptyState(label: "暂无用量", symbol: "chart.bar",
                                  tint: Theme.textSecondary, block: true)
            } else {
                TileGrid(.pageUsage) {
                    let scale = max(providerStore.maxUsageTokens, 1)
                    // Cursor's real charge is not per-period — the API answers
                    // for a window — so a tile is captioned with the window it
                    // does cover whenever that is not the period on screen.
                    // Resolved once for the whole grid: every tile compares
                    // against the same two windows.
                    let periodWindow = UsageStats.interval(for: providerStore.usagePeriod,
                                                           reference: providerStore.usageReferenceDate)
                    let settlementCaption = providerStore.settlementCovers(periodWindow)
                        ? nil : providerStore.settlementWindowLabel
                    ForEach(providerStore.usageStats) { stat in
                        UsageModelCard(
                            stat: stat,
                            slices: providerStore.usageSourceSlices(for: stat),
                            share: Double(stat.totalTokens) / Double(scale),
                            costLine: providerStore.costLine(for: stat.model),
                            settlement: providerStore.settlement(for: stat.model),
                            settlementWindow: settlementCaption
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
                          note: "按当前模型配置归属",
                          noteTint: Theme.textTertiary())
                .help("历史会话未记录请求时的供应商；同名模型涉及多个供应商时计入未归属")
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
                let key = Self.normalized(model.name)
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
        for source in UsageSource.allCases {
            for stat in providerStore.usageBySource[source] ?? [] {
                let owners = candidates(for: source, key: Self.normalized(stat.model))
                let name = owners.count == 1 ? (owners.first ?? "未归属") : "未归属"
                var model = grouped[name]?[stat.model] ?? ModelUsage(model: stat.model)
                model.merge(stat)
                grouped[name, default: [:]][stat.model] = model
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

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

private struct UsageProviderCard: View {
    let group: UsageProviderGroup
    let overallTokens: Int
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        let total = group.total
        let share = overallTokens > 0 ? Double(total.totalTokens) / Double(overallTokens) : 0
        let shareLabel = UsageAnalysis.share(total.totalTokens, of: overallTokens)
        return Button {
            withAnimation(Theme.Animation.smooth) { open.toggle() }
        } label: {
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
                            Image(systemName: open ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
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

                AuroraSparkline(
                    values: AuroraSparkline.accentCurve(peak: min(max(share, 0.08), 1)),
                    tint: Theme.chartPurple,
                    live: hovered
                )
                .frame(height: 28)
                .help("装饰曲线，不代表逐日用量；真实趋势见上方用量图。")

                if open {
                    VStack(alignment: .leading, spacing: 8) {
                        HairlineDivider()
                        Text("模型明细")
                            .font(Theme.Font.microSemibold)
                            .foregroundColor(Theme.textSecondary)
                        ForEach(group.models) { model in
                            HStack(spacing: 8) {
                                Text(model.model).lineLimit(1).truncationMode(.middle)
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
                        TokenMixStrip(stats: group.models, compact: true)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tile(hovered: hovered)
            .folderPeek(hovered)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverState($hovered)
        .help(open ? "收起 \(group.name) 模型明细" : "查看 \(group.name) 模型明细")
        .accessibilityHint(open ? "收起模型明细" : "展开模型明细")
    }
}

/// Period totals by client platform, using the same source rows as the chart above.
private struct UsagePlatformCard: View {
    let source: UsageSource
    let stats: [ModelUsage]
    let days: [DayUsage]
    let overallTokens: Int
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        let total = stats.reduce(into: ModelUsage(model: source.label)) { $0.merge($1) }
        let share = overallTokens > 0 ? Double(total.totalTokens) / Double(overallTokens) : 0
        let shareLabel = UsageAnalysis.share(total.totalTokens, of: overallTokens)
        let ranked = stats.sorted { $0.totalTokens > $1.totalTokens }

        return Button {
            withAnimation(Theme.Animation.smooth) { open.toggle() }
        } label: {
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
                            Image(systemName: open ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
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
                        Text("平台占比")
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.textTertiary())
                    }
                }

                AuroraSparkline(
                    values: days.isEmpty ? [0, 0] : days.map { Double($0.totalTokens) },
                    tint: Theme.chartPurple,
                    live: hovered
                )
                .frame(height: 28)

                if open {
                    VStack(alignment: .leading, spacing: 8) {
                        HairlineDivider()
                        Text("模型明细")
                            .font(Theme.Font.microSemibold)
                            .foregroundColor(Theme.textSecondary)
                        if ranked.isEmpty {
                            StandbyEmptyState(label: "暂无用量", symbol: "chart.bar",
                                              tint: Theme.textSecondary)
                        } else {
                            ForEach(Array(ranked.prefix(4))) { model in
                                HStack(spacing: 8) {
                                    Text(model.model)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    RollingNumberText(UsageStats.formatTokens(model.totalTokens))
                                        .monospacedDigit()
                                }
                                .font(Theme.Font.micro)
                                .foregroundColor(Theme.textSecondary)
                            }
                            if ranked.count > 4 {
                                Text("另有 \(ranked.count - 4) 个模型")
                                    .rollingNumber()
                                    .font(Theme.Font.micro)
                                    .foregroundColor(Theme.textTertiary())
                            }
                            Text("Token 构成")
                                .font(Theme.Font.microSemibold)
                                .foregroundColor(Theme.textSecondary)
                                .padding(.top, 4)
                            TokenMixStrip(stats: stats, compact: true)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // One hue for the wash and the rings — the source's *shape* colour.
            // `source.ink` is the text mix (the title and the counts inside use
            // it); passing it as the wash made the surface darker than the
            // glyphs it was supposed to sit behind.
            .tile(tint: source.color, hovered: hovered,
                  lens: DepthLensSpec(tint: source.color, size: 124))
            .folderPeek(hovered)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverState($hovered)
        .help(open ? "收起 \(source.label) 模型明细" : "查看 \(source.label) 模型明细")
        .accessibilityHint(open ? "收起模型明细" : "展开模型明细")
    }
}
