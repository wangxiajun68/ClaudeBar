import SwiftUI

/// Dashboard page: an information-first overview. Four metric tiles carry the
/// key numbers (active config, balance, sessions, token total), a session
/// overview lists every live Claude Code / Cursor session with its context
/// fill at a glance, and the usage top list rounds it out. All data flows
/// from `ProviderStore`.
struct DashboardView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @State private var refreshTick = 0
    /// Injected by the window so a tile/row tap navigates to the page.
    var onNavigate: (AppPage) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                titleBar
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
            Button(action: {
                refreshTick += 1
                providerStore.refresh()
            }) {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(Theme.Font.bodySmall)
            }
            .buttonStyle(.glass)
            .tint(Theme.claude)
        }
    }

    // MARK: Metric tiles

    /// The four key numbers, one tile each: label above, tabular value below.
    private var metricRow: some View {
        HStack(alignment: .top, spacing: Theme.Space.s12) {
            statTile("活跃配置", value: activeConfigLabel,
                     detail: providerStore.currentEnv?.ANTHROPIC_MODEL ?? "") {
                onNavigate(.providers)
            }
            statTile("余额", value: balanceValue, detail: "") {
                onNavigate(.providers)
            }
            statTile("会话", value: sessionValue,
                     detail: "\(runningCount) 忙碌 · \(aliveCount + providerStore.cursorSessions.count) 活跃") {
                onNavigate(.sessions)
            }
            statTile("Token 总量", value: tokenTotalValue,
                     detail: UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate)) {
                onNavigate(.usage)
            }
        }
    }

    private func statTile(_ label: String, value: String, detail: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(Theme.Font.caption)
                    .tracking(Theme.Tracking.caption)
                    .foregroundColor(Theme.textSecondary)
                Text(value)
                    .font(Theme.Font.displayMetricSmall)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: value)
                // Always render the detail line (space-reserved when empty) so
                // all four tiles stay the same height regardless of content.
                Text(detail.isEmpty ? " " : detail)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .buttonStyle(.plain)
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
        "\(runningCount)/\(aliveCount + providerStore.cursorSessions.count)"
    }

    private var tokenTotalValue: String {
        UsageStats.formatTokens(providerStore.usageStats.reduce(0) { $0 + $1.totalTokens })
    }

    private var aliveCount: Int {
        providerStore.sessions.filter(\.isAlive).count
    }

    private var runningCount: Int {
        providerStore.sessions.filter { $0.isAlive && $0.status == .busy }.count
            + providerStore.cursorSessions.filter { $0.status == .active }.count
    }

    // MARK: Session overview

    /// Every live session as one readable row: status dot, source tint,
    /// project, current activity, context fill. Tap navigates to the sessions
    /// page where the full actions (resume / reveal) live.
    private var sessionOverview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack {
                Text("活跃会话")
                    .font(Theme.Font.titleSmall)
                    .tracking(Theme.Tracking.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Text("\(runningCount) 忙碌 / \(aliveCount + providerStore.cursorSessions.count) 活跃")
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
                ForEach(Array(rows.enumerated()), id: \.element.id) { _, row in
                    SessionOverviewRow(row: row) { onNavigate(.sessions) }
                }
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

    /// Unified view-model for one overview row (Claude or Cursor).
    struct OverviewRow: Identifiable {
        let id: String
        let tint: Color
        let busy: Bool
        let project: String
        let activity: String
        let contextRatio: Double
        let contextLabel: String
        let updated: String
    }

    private var overviewRows: [OverviewRow] {
        var rows: [OverviewRow] = []
        for s in providerStore.sessions where s.isAlive {
            rows.append(OverviewRow(
                id: "c-\(s.pid)",
                tint: Theme.claude,
                busy: s.status == .busy,
                project: s.projectFolder,
                activity: s.currentActivity,
                contextRatio: s.contextRatio,
                contextLabel: s.contextLabel,
                updated: s.relativeUpdated
            ))
        }
        for s in providerStore.cursorSessions {
            rows.append(OverviewRow(
                id: "u-\(s.composerId)",
                tint: Theme.cursor,
                busy: s.status == .active,
                project: s.projectFolder.isEmpty ? "cursor" : s.projectFolder,
                activity: s.currentActivity,
                contextRatio: s.contextRatio,
                contextLabel: s.contextLabel,
                updated: s.relativeUpdated
            ))
        }
        return rows
    }

    // MARK: Usage top

    private var usageTop: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            HStack {
                Text("用量 Top")
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
            ForEach(Array(providerStore.usageStats.prefix(5).enumerated()), id: \.element.id) { _, stat in
                UsageBarRow(stat: stat, maxTokens: maxUsageTokens, density: .mini)
            }
            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                StandbyEmptyState(label: "no usage data")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        }
        .padding(Theme.Space.s16)
        .sectionRules()
    }

    private var maxUsageTokens: Int {
        max(providerStore.usageStats.first?.totalTokens ?? 1, 1)
    }
}

// MARK: - Session overview row

/// One row of the dashboard session overview: source dot + status, project
/// name, activity line, context bar with its label, and recency — everything
/// readable without interaction.
private struct SessionOverviewRow: View {
    let row: DashboardView.OverviewRow
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(row.tint)
                    .frame(width: 6, height: 6)
                StatusBadge(isOn: row.busy, color: row.busy ? row.tint : Theme.statusIdle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.project)
                        .font(Theme.Font.bodySmall)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !row.activity.isEmpty {
                        Text(row.activity)
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                // Fixed width (not maxWidth) so the project/activity column
                // — and therefore every column to its right — aligns across rows.
                .frame(width: 220, alignment: .leading)
                Spacer(minLength: 12)
                // Always reserve the context columns even when there is no
                // context data, so the trailing recency column stays aligned.
                ContextBar(ratio: row.contextRatio)
                    .frame(width: 120)
                    .opacity(row.contextRatio > 0 ? 1 : 0.25)
                Text(row.contextRatio > 0 ? row.contextLabel : "—")
                    .font(Theme.Font.captionMono)
                    .foregroundColor(row.contextRatio > 0 ? Theme.contextColor(row.contextRatio) : Theme.textTertiary())
                    .frame(width: 84, alignment: .trailing)
                    .lineLimit(1)
                Text(row.updated)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .frame(width: 64, alignment: .trailing)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.s16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(isHovered ? Theme.cardFill(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverState($isHovered)
        .help("在会话页查看")
    }
}

// Mini usage rows now use the shared `UsageBarRow(density: .mini)`
// from `Views/Shared/UsageBar.swift`.
