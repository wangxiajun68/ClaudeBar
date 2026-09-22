import SwiftUI

/// Dashboard page: the 宫格 overview. Four metric tiles carry the key numbers,
/// live sessions appear as an adaptive tile grid, and per-model usage lands in
/// its own tile grid. All data flows from `ProviderStore`.
struct DashboardView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject private var prefs = AppPreferences.shared
    /// Injected by the window so a tile tap navigates to the page.
    var onNavigate: (AppPage) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                titleBar
                ResourceStrip()
                    .resourceMonitorScope(.dashboard)
                PowerFlowCard()
                VpnPowerCard(opensVPNPage: true)
                metricRow
                sessionOverview
                usageTop
            }
            .padding(Theme.Space.s24)
        }
        .background(Theme.bgPrimary)
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PageTitle(title: "概览")
            Spacer()
            Button(action: { providerStore.refresh() }) {
                HStack(spacing: 5) {
                    InstrumentGlyph(kind: .refresh, tint: .white)
                        .frame(width: 17, height: 17)
                    Text("刷新")
                }
                    .font(Theme.Font.bodySmall)
            }
            .adaptiveGlassButton()
            .tint(Theme.claude)
        }
    }

    // MARK: Metric tiles

    /// The four key numbers, one tile each.
    private var metricRow: some View {
        TileGrid(.pageMetric) {
            MetricTile(label: "活跃配置", value: activeConfigLabel,
                       detail: providerStore.currentEnv?.ANTHROPIC_MODEL ?? "",
                       instrumentIcon: .config, pill: "当前") {
                onNavigate(.providers)
            }
            SupplierBalanceCard(entries: providerStore.supplierBalances,
                                loading: providerStore.balanceLoading) {
                providerStore.refreshBalance()
            }
            MetricTile(label: "会话", value: sessionValue,
                       detail: "\(runningCount) 运行中 · \(totalSessionCount) 活动",
                       instrumentIcon: .sessions,
                       pill: runningCount > 0 ? "运行中" : "空闲") {
                onNavigate(.sessions)
            }
            MetricTile(label: "Token 总量", value: tokenTotalValue,
                       detail: UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate),
                       instrumentIcon: .tokens) {
                onNavigate(.usage)
            }
            MetricTile(label: "Codex 额度", value: codexQuotaValue, detail: codexQuotaDetail,
                       instrumentIcon: .quota,
                       pill: codexStore.quotaLoading ? "刷新中…" : "点击刷新",
                       quotaWindows: codexStore.quotaWindows) {
                codexStore.refreshQuota()
            }
            .disabled(codexStore.quotaLoading)
            .help(codexStore.quotaLoading ? "正在获取最新 Codex 额度" : "点击刷新 Codex 额度")
            .accessibilityHint("获取最新的 Codex 剩余额度")
            MetricTile(label: "Codex 配置", value: codexConfigValue, detail: codexConfigDetail,
                       instrumentIcon: .config, pill: "模型") {
                onNavigate(.providers)
            }
            MetricTile(label: "Claude Code 配置", value: ccConfigValue, detail: ccConfigDetail,
                       instrumentIcon: .config, pill: "模型") {
                onNavigate(.providers)
            }
            MetricTile(label: "本地代理", value: localProxyValue, detail: "127.0.0.1:\(prefs.codexProxyPort)",
                       instrumentIcon: .link, pill: codexStore.proxyRunning ? "监听" : "关闭") {
                onNavigate(.providers)
            }
        }
    }

    // MARK: Metric values

    private var activeConfigLabel: String {
        providerStore.providers.first(where: { $0.id == providerStore.activeProviderID })?.name ?? "未配置"
    }

    private var sessionValue: String {
        "\(runningCount)/\(totalSessionCount)"
    }

    private var tokenTotalValue: String {
        UsageStats.formatTokens(providerStore.usageStats.reduce(0) { $0 + $1.totalTokens })
    }

    private var codexQuotaValue: String {
        if codexStore.quotaLoading && codexStore.quotaWindows.isEmpty { return "⋯" }
        let windows = codexStore.quotaWindows
        if windows.isEmpty { return "—" }
        return windows.map { "剩余 \(Int(max(0, min(100, 100 - $0.usedPercent)).rounded()))%" }
            .joined(separator: " / ")
    }

    private var codexQuotaDetail: String {
        if codexStore.quotaLoading { return "正在获取最新额度…" }
        let windows = codexStore.quotaWindows
        if windows.isEmpty { return codexStore.quotaNote ?? "" }
        return windows.map { "\($0.label)已用 \($0.usedText)" }.joined(separator: " · ")
    }

    private var codexConfigValue: String {
        codexStore.activeProvider?.activeModel?.name ?? "未配置"
    }

    private var codexConfigDetail: String {
        codexStore.activeProvider?.name ?? "官方登录"
    }

    private var ccConfigValue: String {
        providerStore.activeModel?.name
            ?? providerStore.currentEnv?.ANTHROPIC_MODEL
            ?? "未配置"
    }

    private var ccConfigDetail: String {
        providerStore.activeProvider?.name ?? "官方登录"
    }

    private var localProxyValue: String {
        codexStore.proxyRunning ? "开" : "关"
    }

    private var aliveCount: Int {
        providerStore.sessions.filter(\.isAlive).count
    }

    /// Claude busy sessions + active Cursor sessions.
    private var runningCount: Int {
        providerStore.sessions.filter { $0.isAlive && $0.status == .busy }.count
            + providerStore.cursorSessions.filter { $0.status == .active }.count
            + providerStore.activeExternalCount
    }

    /// All live sessions across all sources — the denominator of the
    /// busy/total metrics.
    private var totalSessionCount: Int {
        aliveCount + providerStore.cursorSessions.count
            + providerStore.aliveExternalSessions.count
    }

    // MARK: Session overview grid

    /// Every live session as one tile: status, source tint, project, context
    /// fill, activity. Tap navigates to the sessions page where the full
    /// actions (resume / reveal) live.
    private var sessionOverview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack {
                Text("活跃会话")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                StatusPill(
                    label: "\(runningCount) 运行中 / \(totalSessionCount)",
                    tint: runningCount > 0 ? Theme.claude : Theme.statusIdle,
                    ink: runningCount > 0 ? Theme.Ink.claude : Theme.Ink.idle
                )
            }
            .padding(.horizontal, Theme.Space.s4)

            let rows = overviewRows.prefix(8)
            if rows.isEmpty {
                Text("暂无活跃会话")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textTertiary())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
            } else {
                TileGrid(.pageSession) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { _, row in
                        OverviewTile(row: row) { onNavigate(.sessions) }
                    }
                }
                if overviewRows.count > 8 {
                    Button(action: { onNavigate(.sessions) }) {
                        Label("查看全部 \(overviewRows.count) 个会话", systemImage: "arrow.right")
                            .font(Theme.Font.bodySmall)
                    }
                    .buttonStyle(.plain)
                    .tint(Theme.accent)
                    .padding(.vertical, Theme.Space.s8)
                }
            }
        }
        .padding(Theme.Space.s16)
        .panelCard()
    }

    /// Unified view-model for one overview tile (Claude or Cursor).
    struct OverviewRow: Identifiable {
        let id: String
        /// Row hue — a *shape* color (status dot, gauge).
        let tint: Color
        /// `tint` as readable text, for the running/idle capsule.
        let pillInk: Color
        let busy: Bool
        let project: String
        let activity: String
        let contextRatio: Double
        let contextLabel: String
        let updated: String
        let load: ProcessSampler.Key
        var loadShared: Bool = false
    }

    private var overviewRows: [OverviewRow] {
        let claudeRows = providerStore.sessions
            .filter(\.isAlive)
            .map { s in
                OverviewRow(
                    id: "c-\(s.pid)",
                    tint: Theme.claude,
                    pillInk: Theme.Ink.claude,
                    busy: s.status == .busy,
                    project: s.projectFolder,
                    activity: s.currentActivity,
                    contextRatio: s.contextRatio,
                    contextLabel: s.contextLabel,
                    updated: s.relativeUpdated,
                    load: .pid(s.pid)
                )
            }
        let cursorRows = providerStore.cursorSessions
            .map { s in
                OverviewRow(
                    id: "u-\(s.composerId)",
                    tint: Theme.cursor,
                    pillInk: Theme.Ink.cursor,
                    busy: s.status == .active,
                    project: s.projectFolder.isEmpty ? "cursor" : s.projectFolder,
                    activity: s.currentActivity,
                    contextRatio: s.contextRatio,
                    contextLabel: s.contextLabel,
                    updated: s.relativeUpdated,
                    load: .cursor,
                    loadShared: true
                )
            }
        // Codex — teal rows.
        let externalRows = providerStore.aliveExternalSessions
            .map { s in
                OverviewRow(
                    id: "e-\(s.kind.rawValue)-\(s.sessionId)",
                    tint: Theme.external,
                    pillInk: Theme.Ink.success,
                    busy: s.isActive,
                    project: s.projectFolder.isEmpty ? s.kind.displayName : s.projectFolder,
                    activity: s.model,
                    contextRatio: s.contextRatio,
                    contextLabel: s.contextLabel,
                    updated: s.relativeUpdated,
                    load: .standardizedCwd(s.cwd)
                )
            }
        return claudeRows + cursorRows + externalRows
    }

    // MARK: Usage top grid

    private var usageTop: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            HStack {
                Text("用量")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Text(UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            UsageHeatmap(
                days: providerStore.usageDays,
                period: providerStore.usagePeriod,
                reference: providerStore.usageReferenceDate,
                onSelectDay: { date in
                    providerStore.usagePeriod = .day
                    providerStore.usageReferenceDate = date
                },
                onSelectMonth: { date in
                    providerStore.usagePeriod = .month
                    providerStore.usageReferenceDate = date
                }
            )
            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                StandbyEmptyState(label: "暂无用量")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                TileGrid(.pageUsage) {
                    ForEach(Array(providerStore.usageStats.prefix(4))) { stat in
                        UsageModelCard(
                            stat: stat,
                            slices: providerStore.usageSourceSlices(for: stat),
                            share: Double(stat.totalTokens) / Double(maxUsageTokens)
                        )
                    }
                }
            }
        }
        .padding(Theme.Space.s16)
        .panelCard()
    }

    private var maxUsageTokens: Int {
        max(providerStore.usageStats.first?.totalTokens ?? 1, 1)
    }
}

// MARK: - Session overview tile

/// Status dot for an overview tile: tinted + pulsing ring while busy, muted
/// tint while idle.
private struct OverviewStatusDot: View {
    let tint: Color
    let isBusy: Bool

    var body: some View {
        Circle()
            .fill(isBusy ? tint : tint.opacity(0.35))
            .frame(width: 6, height: 6)
            .overlay {
                if isBusy { BusyPulseRing(color: tint) }
            }
    }
}

/// Static halo for a busy session. A `repeatForever` pulse kept a display
/// link running for every live tile and hitching scroll.
private struct BusyPulseRing: View {
    let color: Color

    var body: some View {
        Circle()
            .strokeBorder(color.opacity(0.35), lineWidth: 2)
            .scaleEffect(1.7)
            .opacity(0.45)
    }
}

/// One tile of the dashboard session overview: source dot + status header,
/// full-width context bar with its label, activity line, and recency —
/// everything readable without interaction.
private struct OverviewTile: View {
    let row: DashboardView.OverviewRow
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                HStack(spacing: 8) {
                    OverviewStatusDot(tint: row.tint, isBusy: row.busy)
                    Text(row.project)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    StatusPill(
                        label: row.busy ? "运行中" : "空闲",
                        tint: row.busy ? row.tint : Theme.statusIdle,
                        ink: row.busy ? row.pillInk : Theme.Ink.idle
                    )
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(row.contextRatio > 0 ? row.contextLabel : "—")
                        .font(Theme.Font.tileValueSmall)
                        .foregroundColor(row.contextRatio > 0 ? Theme.contextInk(row.contextRatio) : Theme.textTertiary())
                        .lineLimit(1)
                    Spacer()
                    SessionLoadChip(key: row.load, shared: row.loadShared)
                }
                ContextBar(ratio: row.contextRatio, height: 6)
                    .opacity(row.contextRatio > 0 ? 1 : 0.25)
                HStack {
                    Text(row.activity.isEmpty ? " " : row.activity)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(row.updated)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
            }
            .padding(Theme.Space.s12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tile(hovered: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverState($isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.project)，\(row.busy ? "运行中" : "空闲")，上下文 \(row.contextLabel)")
        .accessibilityHint("在会话页查看")
    }
}
