import SwiftUI
import Charts

/// Analysis first, then power controls, session details and the usage calendar.
/// Shares the selected usage period with the usage page.
struct DashboardView: View {
    @ProviderState([.configuration, .sessions, .usage]) var providerStore: ProviderStore
    /// Injected by the window so a tile tap navigates to the page.
    var onNavigate: (AppPage) -> Void = { _ in }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s16) {
                titleBar
                ResourceStrip()
                metricRow
                PowerFlowCard()
                sessionOverview
                usageTop
            }
            .padding(Theme.Space.s24)
        }
        .resourceMonitorScope(.dashboard)
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

    // MARK: Analysis

    private var metricRow: some View {
        DashboardAnalysisView(refreshStats: providerStore.usageStats,
                              refreshDays: providerStore.usageDays)
    }

    private var aliveCount: Int { providerStore.aliveSessions.count }

    /// Claude busy sessions + active Cursor sessions — from the store's own
    /// derived values rather than three fresh filter passes per body.
    private var runningCount: Int {
        providerStore.busySessionCount
            + providerStore.activeCursorCount
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

            // Derived once: `overviewRows` maps every live session through
            // `displayTitle` / `currentActivity` / `contextLabel` and a
            // `SessionTitle.condense` pass (five `replacingOccurrences` + a
            // scalar-width reduce) per row. Reading the property twice — once
            // for the grid, once for the overflow count — doubled that on
            // every poll and every usage publish.
            let all = overviewRows
            let rows = all.prefix(8)
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
                if all.count > 8 {
                    Button(action: { onNavigate(.sessions) }) {
                        Label("查看全部 \(all.count) 个会话", systemImage: "arrow.right")
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

    /// Unified view-model for one overview tile across all three platforms.
    struct OverviewRow: Identifiable {
        let id: String
        let platform: String
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
                    platform: "CC",
                    tint: Theme.claude,
                    pillInk: Theme.Ink.claude,
                    busy: s.status == .busy,
                    project: s.displayTitle,
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
                    platform: "Cursor",
                    tint: Theme.cursor,
                    pillInk: Theme.Ink.cursor,
                    busy: s.status == .active,
                    project: s.displayTitle,
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
                    platform: s.kind.displayName,
                    tint: Theme.external,
                    pillInk: Theme.Ink.success,
                    busy: s.isActive,
                    project: s.displayName,
                    activity: s.model,
                    contextRatio: s.contextRatio,
                    contextLabel: s.contextLabel,
                    updated: s.relativeUpdated,
                    load: .standardizedCwd(s.cwd)
                )
            }
        return claudeRows + cursorRows + externalRows
    }

    // MARK: Usage calendar

    /// The overview always draws a whole month. It used to share the usage
    /// page's period, so choosing one day collapsed this card into seven
    /// weekday tiles fed by a single day's rows.
    private var usageTop: some View {
        DashboardUsageCalendar()
    }
}

private struct DashboardUsageCalendar: View {
    @State private var anchor = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var days: [DayUsage] = []
    @State private var selected: Date?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            HStack(spacing: 8) {
                Text("用量分布")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 8)
                Button { shift(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                Text(UsageStats.formatter("yyyy年M月").string(from: anchor))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 88)
                Button { shift(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canGoForward ? Theme.textSecondary : Theme.textTertiary())
                .disabled(!canGoForward)
            }
            UsageHeatmap(days: days, period: .month, reference: anchor, onSelectDay: { selected = $0 })
            Text(selectionCaption)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if !loading && days.isEmpty {
                StandbyEmptyState(label: "这个月暂无用量")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(Theme.Space.s16)
        .panelCard()
        .task(id: anchor) {
            loading = true
            let month = anchor
            let fetched = await Task.detached(priority: .utility) {
                let interval = Calendar.current.dateInterval(of: .month, for: month)
                    ?? DateInterval(start: month, duration: 86400)
                return UsageIndex.fetchDaily(in: interval)
            }.value
            guard !Task.isCancelled else { return }
            days = fetched
            loading = false
        }
    }

    private var canGoForward: Bool {
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .month, value: 1, to: anchor) else { return false }
        return next <= (cal.dateInterval(of: .month, for: Date())?.start ?? Date())
    }

    private var selectionCaption: String {
        guard let selected else { return "整月分布。点某一天看当天 Token。" }
        let label = UsageStats.formatter("M月d日").string(from: selected)
        let key = UsageHeatmap.dayKey(selected)
        guard let day = days.first(where: { $0.day == key }) else { return "\(label) · 无用量" }
        return "\(label) · \(UsageStats.formatTokens(day.totalTokens))"
    }

    private func shift(_ months: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: months, to: anchor) else { return }
        anchor = next
        selected = nil
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
                    StatusPill(label: row.platform, tint: row.tint, ink: row.pillInk)
                        .fixedSize()
                    Spacer()
                    StatusPill(
                        label: row.busy ? "运行中" : "空闲",
                        tint: row.busy ? row.tint : Theme.statusIdle,
                        ink: row.busy ? row.pillInk : Theme.Ink.idle
                    )
                }
                Text(row.project)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(alignment: .firstTextBaseline) {
                    RollingNumberText(row.contextRatio > 0 ? row.contextLabel : "—")
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
        .accessibilityLabel("\(row.platform)，\(row.project)，\(row.busy ? "运行中" : "空闲")，上下文 \(row.contextLabel)")
        .accessibilityHint("在会话页查看")
    }
}

