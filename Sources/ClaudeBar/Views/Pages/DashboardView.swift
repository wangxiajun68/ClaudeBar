import SwiftUI

/// Dashboard page: the 宫格 overview. Four metric tiles carry the key numbers,
/// live sessions appear as an adaptive tile grid, and per-model usage lands in
/// its own tile grid. All data flows from `ProviderStore`.
struct DashboardView: View {
    @EnvironmentObject var providerStore: ProviderStore
    /// Injected by the window so a tile tap navigates to the page.
    var onNavigate: (AppPage) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                titleBar
                ResourceStrip()
                    .padding(Theme.Space.s16)
                    .sectionRules()
                    .resourceMonitorScope(.dashboard)
                metricRow
                sessionOverview
                usageTop
            }
            .padding(Theme.Space.s24)
        }
        .background(Theme.base0.opacity(0.30))
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("概览")
                .font(Theme.Font.titleLarge)
                .tracking(Theme.Tracking.titleLarge)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            Spacer()
            Button(action: { providerStore.refresh() }) {
                Label("刷新", systemImage: "arrow.clockwise")
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
                       detail: providerStore.currentEnv?.ANTHROPIC_MODEL ?? "") {
                onNavigate(.providers)
            }
            MetricTile(label: "余额", value: balanceValue, detail: "") {
                onNavigate(.providers)
            }
            MetricTile(label: "会话", value: sessionValue,
                       detail: "\(runningCount) 运行中 · \(totalSessionCount) 活动") {
                onNavigate(.sessions)
            }
            MetricTile(label: "Token 总量", value: tokenTotalValue,
                       detail: UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate)) {
                onNavigate(.usage)
            }
        }
    }

    // MARK: Metric values

    private var activeConfigLabel: String {
        providerStore.providers.first(where: { $0.id == providerStore.activeProviderID })?.name ?? "未配置"
    }

    private var balanceValue: String {
        if providerStore.balanceLoading { return "⋯" }
        if let b = providerStore.balanceText { return "¥\(b)" }
        return "—"
    }

    private var sessionValue: String {
        "\(runningCount)/\(totalSessionCount)"
    }

    private var tokenTotalValue: String {
        UsageStats.formatTokens(providerStore.usageStats.reduce(0) { $0 + $1.totalTokens })
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
                    .font(Theme.Font.titleSmall)
                    .tracking(Theme.Tracking.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Text("\(runningCount) 运行中 / \(totalSessionCount) 活动")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: runningCount)
            }
            .padding(.horizontal, Theme.Space.s16)

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
                .padding(.horizontal, Theme.Space.s16)
                if overviewRows.count > 8 {
                    Button(action: { onNavigate(.sessions) }) {
                        Label("查看全部 \(overviewRows.count) 个会话", systemImage: "arrow.right")
                            .font(Theme.Font.bodySmall)
                    }
                    .buttonStyle(.plain)
                    .tint(Theme.accent)
                    .padding(.horizontal, Theme.Space.s16)
                    .padding(.vertical, Theme.Space.s8)
                }
            }
        }
        .padding(.vertical, Theme.Space.s8)
        .sectionRules()
    }

    /// Unified view-model for one overview tile (Claude or Cursor).
    struct OverviewRow: Identifiable {
        let id: String
        let tint: Color
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
                Text("用量排行")
                    .font(Theme.Font.titleSmall)
                    .tracking(Theme.Tracking.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Text(UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                StandbyEmptyState(label: "暂无用量")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                TileGrid(.pageUsage) {
                    ForEach(Array(providerStore.usageStats.prefix(5).enumerated()), id: \.element.id) { _, stat in
                        UsageModelTile(stat: stat, maxTokens: maxUsageTokens)
                    }
                }
            }
        }
        .padding(Theme.Space.s16)
        .sectionRules()
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

/// A stroke ring that breathes in and out for as long as it is on screen.
/// Removed entirely (not merely faded) when the session goes idle — mirrors
/// SessionsView's BusyPulseRing.
private struct BusyPulseRing: View {
    let color: Color
    @State private var phase = false

    var body: some View {
        Circle()
            .strokeBorder(color.opacity(0.4), lineWidth: 3)
            .scaleEffect(phase ? 1.7 : 1)
            .opacity(phase ? 0.5 : 0.2)
            .onAppear { phase = true }
            .onDisappear { phase = false }
            .animation(Theme.Animation.pulse.repeatForever(autoreverses: true), value: phase)
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
                HStack(spacing: 6) {
                    Circle()
                        .fill(row.tint)
                        .frame(width: 6, height: 6)
                    OverviewStatusDot(tint: row.tint, isBusy: row.busy)
                    Text(row.project)
                        .font(Theme.Font.bodySmall)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(row.updated)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
                SessionLoadChip(key: row.load, shared: row.loadShared)
                ContextBar(ratio: row.contextRatio)
                    .opacity(row.contextRatio > 0 ? 1 : 0.25)
                HStack {
                    Text(row.activity.isEmpty ? " " : row.activity)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(row.contextRatio > 0 ? row.contextLabel : "—")
                        .font(Theme.Font.captionMono)
                        .foregroundColor(row.contextRatio > 0 ? Theme.contextColor(row.contextRatio) : Theme.textTertiary())
                        .lineLimit(1)
                }
            }
            .padding(Theme.Space.s12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tile(tint: row.busy ? row.tint : nil, hovered: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .buttonStyle(.plain)
        .hoverState($isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.project)，\(row.busy ? "运行中" : "空闲")，上下文 \(row.contextLabel)")
        .accessibilityHint("在会话页查看")
    }
}
