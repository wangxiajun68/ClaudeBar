import SwiftUI

/// Resource status, power controls and active sessions.
struct DashboardView: View {
    /// `.sessions` only. Nothing in this body reads a configuration field, and
    /// `.configuration` publishes on `refreshBalance`'s first line
    /// (`balanceLoading = true`) plus every `refresh()`'s `currentEnv` /
    /// `hasSettingsFile` write — so a balance fetch for an account this page
    /// does not show re-derived `overviewRows` (the `SessionTitle.condense` +
    /// `replacingOccurrences` pass the comment below exists to do once) and
    /// rebuilt `DashboardView(onNavigate:)`'s non-diffable closure.
    @ProviderState(.sessions) var providerStore: ProviderStore
    /// Injected by the window so a tile tap navigates to the page.
    var onNavigate: (AppPage) -> Void = { _ in }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s16) {
                titleBar
                ResourceStrip()
                PowerFlowCard()
                sessionOverview
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
            // every poll.
            let all = overviewRows
            let cap = Self.overviewCap
            let rows = all.prefix(cap)
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
                if all.count > cap {
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
        // The accent wash + ring, same as the session tiles inside it, so the
        // card and its grid are one block rather than a panel holding cards.
        // Raw `claude`, not `Ink.claude`: the ink variant is the *text* mix and
        // would make the wash darker than the tiles it contains.
        .panelCard(tint: Theme.claude)
    }

    /// How many session tiles the overview card shows before handing off to
    /// the sessions page.
    ///
    /// Six, i.e. two full rows: `TileGrid(.pageSession)` is adaptive at a 280pt
    /// minimum, so the default window (1120pt, minus the 24pt page padding each
    /// side) lays out three columns, and two rows is what fits above the fold at
    /// the default 720pt window height — with a battery installed
    /// (`PowerFlowCard` plus its controls) not even one row is fully visible.
    ///
    /// The number itself matters less than its being reachable: this used to be
    /// `prefix(8)` tested against `all.count > 8`, which can never both hold, so
    /// the "查看全部" button never rendered and any session past the eighth was
    /// invisible on the page with no hint that more existed. Whatever the cap is,
    /// the overflow line below has to be able to fire.
    private static let overviewCap = 6

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
            .tile(tint: row.tint, hovered: isHovered,
                  lens: DepthLensSpec(tint: row.tint, size: 118))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverState($isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.platform)，\(row.project)，\(row.busy ? "运行中" : "空闲")，上下文 \(row.contextLabel)")
        .accessibilityHint("在会话页查看")
    }
}
