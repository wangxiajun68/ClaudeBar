import SwiftUI

/// Hover-revealed action chips: fade + slide in and accept hits only while
/// the parent tile is hovered.
/// Trailing action chips on a session tile.
///
/// They stay transparent until hover — the affordance emerges from the tile
/// instead of competing with the status line — but "invisible to a mouse"
/// must not mean "unreachable": a keyboard or VoiceOver user can't hover, so
/// the chips also reveal while they hold focus.
///
/// Two signals, because neither alone is enough:
/// - `@Environment(\.accessibilityVoiceOverEnabled)` — the label exposes the
///   chips to VoiceOver even while they are transparent; without it the
///   controls simply do not exist in the accessibility tree.
/// - `@FocusState` — the chips become fully visible once keyboard focus
///   lands on one of them, so tabbing through announces them on screen too.
private struct SessionActionChips<Content: View>: View {
    let isHovered: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @FocusState private var focused: Bool

    /// Visible when hovered, focused, or assistive tech is listening. VoiceOver
    /// reveals *and* keeps them hittable — a control it can announce but not
    /// operate would be worse than one it never sees.
    private var revealed: Bool { isHovered || focused || voiceOver }

    var body: some View {
        HStack(spacing: 4) {
            content()
                .focused($focused)
        }
        .opacity(revealed ? 1 : 0)
        .offset(x: revealed ? 0 : 10)
        .allowsHitTesting(revealed)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: revealed)
    }
}

/// Status dot: filled + haloed while `isOn`, muted gray otherwise. Shared with
/// the dashboard and the popup; see `SessionStatusViews.swift`.
///
/// Full session page: one section per tool family — Claude Code, Cursor, then
/// one per external kind (Codex …) — each an adaptive tile grid with
/// double-click-to-resume, and the Codex tiles carrying their sub-agent swarm.
/// Mirrors the menu-bar popup's sessions at full width.
struct SessionsView: View {
    @ProviderState([.sessions, .expansion]) var providerStore: ProviderStore
    /// The session a stuck-thread cleanup was confirmed for. One dialog serves
    /// both the tile and the grid card, so it lives on the page rather than on
    /// each of them.
    @State private var pendingCleanup: ExternalSessionInfo?

    var body: some View {
        ScrollView {
            // Lazy, like the dashboard and usage pages: this list carries every
            // Claude, Cursor and Codex card, and a plain `VStack` builds all of
            // them (plus every section header) on every poll.
            LazyVStack(alignment: .leading, spacing: Theme.Space.s24) {
                titleBar
                claudeSection
                cursorSection
                externalSections
            }
            .padding(Theme.Space.s24)
        }
        .scrollHoverGate()
        .resourceMonitorScope(.sessions)
        .background(Theme.bgPrimary)
    }

    private var titleBar: some View {
        PageTitle(title: "会话")
    }

    // MARK: Claude Code

    private var claudeSection: some View {
        let alive = providerStore.aliveSessions
        let busy = providerStore.busySessionCount
        return sectionContainer(
            title: "Claude Code",
            icon: "rectangle.connected.to.line.below",
            count: alive.count,
            active: busy
        ) {
            if alive.isEmpty {
                emptyHint("暂无 Claude Code 会话")
            } else {
                TileGrid(.pageSession) {
                    ForEach(alive) { session in
                        SessionTileFull(session: session, store: providerStore, isExpanded: providerStore.expandedSessionPIDs.contains(session.pid))
                    }
                }
            }
        }
    }

    // MARK: Cursor

    private var cursorSection: some View {
        let alive = providerStore.cursorSessions
        let active = providerStore.activeCursorCount
        // The section *is* Cursor, so its well draws Cursor's own mark — the
        // cube, from the bundle, the same artwork the session badges use. It
        // was the `cursorarrow.motionlines` glyph, which is a pointer rather
        // than the product's mark. Same for Codex below.
        return sectionContainer(
            title: "Cursor",
            icon: "cursorarrow.motionlines",
            count: alive.count,
            active: active,
            mark: .cursor
        ) {
            if alive.isEmpty {
                emptyHint("暂无 Cursor 会话")
            } else {
                TileGrid(.pageSession) {
                    ForEach(alive) { session in
                        CursorTileFull(session: session)
                    }
                }
            }
        }
    }

    // MARK: External tools — one section per tool

    /// One section per external tool, in a fixed display order. Tools with no
    /// sessions in the window collapse to a quiet empty hint so the page
    /// reads as a stable roster.
    private var externalSections: some View {
        ForEach(ExternalAgentKind.allCases, id: \.self) { kind in
            externalSection(kind: kind)
        }
    }

    private func externalSection(kind: ExternalAgentKind) -> some View {
        let tree = providerStore.externalSessionTree(kind: kind)
        // Counted from the stored per-node tally: `flatMap(\.flattened)` here
        // allocated the whole descendant list once per kind, per publish,
        // purely to count the active ones.
        //
        // `busy` and `agents` are deliberately separate tallies over separate
        // populations. `SectionHeader` renders its pill as
        // `"\(active)B · \(count - active)I"`, so `active` has to be a subset of
        // `count` — feeding it sessions-plus-agents (which is what the count
        // used to be too) is only safe while the two share a population. Now
        // that `count` is the row count of the grid below, an agent in `active`
        // reads as a negative idle figure: one busy session with five busy
        // helpers rendered "6B · -5I".
        let busy = tree.reduce(0) { $0 + ($1.session.isActive ? 1 : 0) }
        let activeAgents = tree.reduce(0) { $0 + $1.activeDescendantCount }
        let agents = tree.reduce(0) { $0 + $1.descendantCount }
        return sectionContainer(
            title: kind.displayName,
            icon: kind.icon,
            // Sessions, which is what the grid below lists. This used to add
            // every sub-agent to the same number, so the pill read "Codex · 5B
            // · 132I" above eleven cards — a count of rows that were not there.
            // The agents are counted where they are shown: the tile's 子 agent
            // header and its ⋯N badge.
            count: tree.count,
            active: busy,
            agentCount: agents,
            activeAgentCount: activeAgents,
            // Codex's own knot in the well: the section *is* the client.
            brand: kind.brand
        ) {
            if tree.isEmpty {
                emptyHint("暂无 \(kind.displayName) 会话")
            } else if tree.count == 1 {
                // A lone session needs no grid: its swarm cluster wants the
                // whole page width, where 60 cards can spread out.
                ExternalSessionTile(node: tree[0], onCleanUp: requestCleanup)
            } else {
                // Several sessions: regular grid cells, the same 宫格 the Claude
                // and Cursor sections use. A session with no sub-agents is just
                // a card — it is not drawn any taller than its own readout.
                TileGrid(.pageSession) {
                    ForEach(tree) { node in
                        ExternalSessionGridCard(node: node, onCleanUp: requestCleanup)
                    }
                }
            }
        }
        // One dialog for the section, driven by whichever card asked. See
        // `CodexCleanupDialog` for why cleanup is described once instead of in
        // every tile.
        .codexCleanupDialog(pending: $pendingCleanup) { session in
            providerStore.cleanUpExternalSession(session)
        }
    }

    /// Ask before removing, from either card shape.
    private func requestCleanup(_ session: ExternalSessionInfo) {
        pendingCleanup = session
    }

    // MARK: Helpers

    private func sectionContainer<C: View>(title: String, icon: String, count: Int, active: Int,
                                            agentCount: Int = 0, activeAgentCount: Int = 0,
                                            brand: Bool? = nil,
                                            mark: ProductBrandMark.Brand? = nil,
                                            @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            SectionHeader(icon: icon, title: title, brand: brand, mark: mark, tint: Theme.claude,
                          ink: Theme.Ink.claude,
                          count: count, activeCount: active,
                          // Sessions and the agents they spawned are different
                          // things, so they get different pills rather than one
                          // summed number that matches neither list. The agent
                          // pill carries its own busy count for the same reason.
                          //
                          // Rendered *inside* the header's own `HStack`, before
                          // the count pill. It used to be an
                          // `.overlay(alignment: .trailing)` on the header with
                          // a guessed `.padding(.trailing, 62)` — a constant
                          // measured against the pill's width at one session
                          // count, so a wider count ("12B · 30I") slid the pill
                          // straight under the label. Nothing in an overlay can
                          // know the pill's width; a sibling in the row can.
                          note: agentCount > 0
                              ? (activeAgentCount > 0
                                 ? "+\(agentCount) agent · \(activeAgentCount) 运行"
                                 : "+\(agentCount) agent")
                              : nil,
                          noteTint: activeAgentCount > 0 ? Theme.Ink.success : Theme.textTertiary())
            content()
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundColor(Theme.textTertiary())
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
    }
}

// MARK: - Full session tiles

/// A session activity line: dot + text, dimmed when idle.
private struct ActivityLine: View {
    let activity: String
    let isBusy: Bool
    var color: Color = Theme.statusBusy

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isBusy ? color : Theme.Ink.idle)
                .frame(width: 4, height: 4)
                .overlay {
                    if isBusy { BusyPulseRing(color: color, big: false, compact: true) }
                }
            Text(activity)
                .font(Theme.Font.captionMono)
                .foregroundColor(isBusy ? Theme.textPrimary : Theme.textTertiary())
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 2)
    }
}

/// A Claude Code session tile with subagent expansion. On hover the tile
/// lifts and trailing action chips (resume / reveal cwd) slide in — the
/// affordances emerge from the tile instead of being hidden behind a
/// double-click.
private struct SessionTileFull: View {
    let session: SessionInfo
    let store: ProviderStore
    let isExpanded: Bool
    private var isBusy: Bool { session.isBusy }
    private var isWaiting: Bool { session.isWaiting }
    /// The tile's three-state capsule; see `Theme.sessionStatus`.
    private var status: (label: String, tint: Color, ink: Color) {
        Theme.sessionStatus(waiting: isWaiting, active: isBusy,
                            accent: Theme.statusBusy, ink: Theme.Ink.claude)
    }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 8) {
                PulsingStatusDot(isOn: isBusy, color: isWaiting ? Theme.statusWarning : Theme.statusBusy, big: true)
                SessionTitleLine(label: session.cardLabel,
                                 font: .system(size: 14, weight: .semibold, design: .rounded))
                Spacer(minLength: 4)
                StatusPill(label: status.label, tint: status.tint, ink: status.ink)
            }

            // Context block and activity line are always rendered (dimmed
            // when there is no data) so every tile in a grid row keeps the
            // same height regardless of what the transcript scan found.
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack {
                    RollingNumberText(session.contextLabel)
                        .font(Theme.Font.tileValueSmall)
                        .foregroundColor(Theme.contextInk(session.contextRatio))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer()
                    RollingNumberText("\(session.messageCount) msgs · \(session.relativeUpdated)")
                        .font(Theme.Font.caption)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
                ContextBar(ratio: session.contextRatio)
            }
            .opacity(session.contextTokens > 0 ? 1 : 0.25)

            ActivityLine(activity: isWaiting ? waitingActivity : (session.displayActivity.isEmpty ? " " : session.displayActivity),
                         isBusy: isBusy || isWaiting,
                         color: isWaiting ? Theme.statusWarning : Theme.statusBusy)
            SessionLoadChip(key: .pid(session.pid))

            HStack(spacing: 4) {
                Text(session.model)
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.name)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                // Expand chevron stays always-on when there are subagents;
                // action chips slide in only while hovered.
                if !session.subagents.isEmpty || !session.workflows.isEmpty {
                    Button(action: { toggle() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                SessionActionChips(isHovered: isHovered) {
                    ActionChip(systemImage: "play.fill", tint: Theme.accent, help: "在终端恢复") {
                        resume()
                    }
                    ActionChip(systemImage: "folder", tint: Theme.cursorAccent, help: "在 Finder 显示") {
                        revealCwd()
                    }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.subagents) { subagentRow($0) }
                    ForEach(session.workflows) { workflowRow($0) }
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Hue is information here, not decoration: three agent families share
        // this grid, and the card's own accent is what makes a page of them
        // scannable by row. Busy-ness stays with the dot and the capsule, so
        // the wash never moves under the pointer.
        .tile(tint: Theme.claude, hovered: isHovered,
              lens: DepthLensSpec(tint: Theme.claude, size: 132))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { resume() }
        .hoverState($isHovered)
        .help("\(session.cwd)\n双击以在终端继续")
    }

    private func toggle() {
        if isExpanded { store.expandedSessionPIDs.remove(session.pid) }
        else { store.expandedSessionPIDs.insert(session.pid) }
    }

    /// The reason line while the turn is parked on the user.
    private var waitingActivity: String {
        session.waitingReason.isEmpty ? "等待你确认" : session.waitingReason
    }

    /// Reveal the session's working directory in Finder.
    private func revealCwd() { TerminalLauncher.revealInFinder(cwd: session.cwd) }

    private func resume() {
        TerminalLauncher.resumeClaudeSession(cwd: session.cwd, sessionId: session.sessionId,
                                             pid: session.isAlive ? session.pid : nil)
    }

    @ViewBuilder
    private func subagentRow(_ agent: SubagentInfo) -> some View {
        let running = agent.status == .running
        HStack(spacing: 6) {
            Circle().fill(running ? Theme.statusBusy : Theme.textTertiary()).frame(width: 4, height: 4)
            Text(agent.agentType).font(Theme.Font.bodySmall).foregroundColor(running ? Theme.textPrimary.opacity(0.85) : Theme.textTertiary())
                .lineLimit(1)
            if !agent.description.isEmpty {
                Text("· \(agent.description)").font(Theme.Font.bodySmall).foregroundColor(Theme.textTertiary())
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if !agent.activity.isEmpty {
                Text("↳ \(agent.activity)").font(Theme.Font.captionMono).foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private func workflowRow(_ wf: WorkflowInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape").font(Theme.Font.captionMono).foregroundColor(Theme.textTertiary())
            Text(wf.name.isEmpty ? wf.workflowId : wf.name).font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            Text(wf.status.label).font(Theme.Font.caption)
                .foregroundColor(wf.status == .failed ? Theme.Ink.error : wf.status == .running ? Theme.Ink.claude : Theme.textTertiary())
            if !wf.phase.isEmpty {
                Text(wf.phase).font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
                    .lineLimit(1).truncationMode(.tail)
            }
            RollingNumberText("· \(wf.completedCount)/\(wf.totalCount) agents").font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
                .lineLimit(1)
            if wf.runningCount > 0 {
                Text("(\(wf.runningCount)●)").rollingNumber("(\(wf.runningCount)●)").font(Theme.Font.caption).foregroundColor(Theme.Ink.claude)
            }
            if wf.failedCount > 0 {
                Text("\(wf.failedCount) 失败").font(Theme.Font.caption).foregroundColor(Theme.Ink.error)
            }
            Spacer()
        }
    }
}

/// A Cursor session tile. Same hover-reveal pattern as the Claude tile:
/// actions (open in Cursor / show in Finder) slide in on hover and the tile
/// carries the violet cursor tint while active.
private struct CursorTileFull: View {
    let session: CursorSessionInfo
    private var isActive: Bool { session.isBusy }
    private var isWaiting: Bool { session.isWaiting }
    /// The tile's three-state capsule; see `Theme.sessionStatus`.
    private var status: (label: String, tint: Color, ink: Color) {
        Theme.sessionStatus(waiting: isWaiting, active: isActive,
                            accent: Theme.cursorAccent, ink: Theme.Ink.cursor)
    }
    @State private var isHovered = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 8) {
                PulsingStatusDot(isOn: isActive, color: isWaiting ? Theme.statusWarning : Theme.cursorAccent, big: true)
                SessionTitleLine(label: session.cardLabel,
                                 font: .system(size: 14, weight: .semibold, design: .rounded))
                Spacer(minLength: 4)
                StatusPill(label: status.label, tint: status.tint, ink: status.ink)
            }

            // Space-reserved context + activity lines — see SessionTileFull.
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack {
                    RollingNumberText(session.contextLabel)
                        .font(Theme.Font.tileValueSmall)
                        .foregroundColor(Theme.contextInk(session.contextRatio))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer()
                    RollingNumberText(session.relativeUpdated)
                        .font(Theme.Font.caption)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
                ContextBar(ratio: session.contextRatio)
            }
            .opacity(session.contextPercent >= 0 ? 1 : 0.25)

            ActivityLine(activity: isWaiting ? "等待你确认计划"
                                             : (session.displayActivity.isEmpty ? " " : session.displayActivity),
                         isBusy: isActive || isWaiting,
                         color: isWaiting ? Theme.statusWarning : Theme.cursorAccent)
            SessionLoadChip(key: .cursor, shared: true)
            HStack {
                Text(session.name)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if !session.subagents.isEmpty {
                    Button(action: { isExpanded.toggle() }) {
                        HStack(spacing: 4) {
                            Text("\(session.subagents.count)")
                                .font(Theme.Font.caption)
                                .foregroundColor(Theme.textTertiary())
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(Theme.Font.micro)
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "收起子 agent" : "展开子 agent")
                }
                SessionActionChips(isHovered: isHovered) {
                    ActionChip(systemImage: "cursorarrow",
                               tint: Theme.cursorAccent, help: "在 Cursor 打开") {
                        openCursor()
                    }
                    ActionChip(systemImage: "folder", tint: Theme.accent, help: "在 Finder 显示") {
                        revealCwd()
                    }
                }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.subagents) { cursorAgentRow($0) }
                }
                .padding(.top, 2)
            }
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(tint: Theme.cursor, hovered: isHovered,
              lens: DepthLensSpec(tint: Theme.cursor, size: 132))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openCursor() }
        .hoverState($isHovered)
        .help("\(session.cwd)\n双击以在 Cursor 中打开")
    }

    /// Reveal the session's working directory in Finder.
    private func revealCwd() { TerminalLauncher.revealInFinder(cwd: session.cwd) }

    private func openCursor() {
        TerminalLauncher.openInCursor(cwd: session.cwd)
    }

    private func cursorAgentRow(_ agent: CursorSubagentInfo) -> some View {
        let running = agent.status == .running
        return HStack(spacing: 6) {
            Circle().fill(running ? Theme.cursorAccent : Theme.textTertiary()).frame(width: 4, height: 4)
            Text(agent.agentType).font(Theme.Font.bodySmall)
                .foregroundColor(running ? Theme.textPrimary.opacity(0.85) : Theme.textTertiary())
                .lineLimit(1)
            if !agent.description.isEmpty {
                Text("· \(agent.description)").font(Theme.Font.bodySmall).foregroundColor(Theme.textTertiary())
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if !agent.activity.isEmpty {
                Text("↳ \(agent.activity)").font(Theme.Font.captionMono).foregroundColor(Theme.textTertiary())
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

/// A Codex session row: the parent session's own readout, plus its sub-agents
/// as a card grid. Depth-nested children remain reachable — the swarm is built
/// from the node's whole subtree, not just its direct children.
///
/// Used for a session that is the **only** one of its kind: nothing shares the
/// row with it, so its cluster gets the full page width, where 60 agent cards
/// can actually spread out.
private struct ExternalSessionTile: View {
    let node: ProviderStore.ExternalSessionNode
    /// Offered only while the session's open turn has stopped advancing; the
    /// page owns the confirmation and the cleanup itself.
    var onCleanUp: ((ExternalSessionInfo) -> Void)? = nil
    @State private var isHovered = false

    private var session: ExternalSessionInfo { node.session }
    private var tint: Color { Theme.external }
    private var isActive: Bool { session.isActive }
    /// Codex journals no park (see `ExternalSessionInfo.isWaiting`), so this is
    /// `false` today; reading it here keeps the tile's three-state vocabulary
    /// identical to the Claude and Cursor tiles, and a future signal lands in
    /// one place.
    private var isWaiting: Bool { session.isWaiting }
    /// The tile's three-state capsule; see `Theme.sessionStatus`.
    private var status: (label: String, tint: Color, ink: Color) {
        Theme.sessionStatus(waiting: isWaiting, active: isActive,
                            accent: Theme.external, ink: Theme.Ink.success)
    }

    /// Every agent below this node, in pre-order (sub-agents first, then their    /// own children).
    ///
    /// `node.children.flatMap(\.flattened)` allocates the whole descendant
    /// list per read, and `body` read it through `tileHeight` + the swarm
    /// header several times — `O(subtree)` recomputed per access, on every
    /// poll. `body` hoists it into one `let` and passes it down instead.
    static func swarmAgents(of node: ProviderStore.ExternalSessionNode) -> [ExternalSessionInfo] {
        node.children.flatMap(\.flattened)
    }

    /// Left column width. The swarm column takes the rest, and its header and
    /// its cluster share the same origin — header labels and the leftmost cards
    /// line up down the whole page instead of every tile starting its grid at a
    /// different x.
    private static let readoutWidth: CGFloat = 232
    private static let tilePadding: CGFloat = 12
    private static let headerHeight: CGFloat = 20
    private static let swarmTopInset: CGFloat = 16
    /// Width a tile's swarm column is assumed to have when sizing the tile.
    /// An estimate, not a measurement: the tile height must not reflow on every
    /// poll, and the cluster packs smaller cards to fit whatever it is given.
    private static let swarmWidthEstimate = AgentSwarmView.SwarmGrid.tileEstimateWidth
    /// Height of the readout column — cwd, model, context bar, session id.
    private static let readoutHeight: CGFloat = 176

    /// Height for this session: the readout column's height, or the cluster's,
    /// whichever is taller. A session whose fan-out is small stays as short as
    /// its own readout rather than reserving room for agents it does not have.
    private static func tileHeight(agentCount: Int) -> CGFloat {
        let base = tilePadding * 2 + readoutHeight
        guard agentCount > 0 else { return base }
        let cluster = AgentSwarmView.SwarmGrid.requiredHeight(
            count: agentCount, width: swarmWidthEstimate)
        // Clamped so a 200-agent session does not push everything else off the
        // page; the cluster packs smaller cards to fit whatever it is given.
        return min(max(base, tilePadding * 2 + headerHeight + swarmTopInset + cluster), 520)
    }

    var body: some View {
        // Derived once per render: these used to re-walk the subtree on every
        // access from `tileHeight`, the header and the cluster's arguments.
        let agents = ExternalSessionTile.swarmAgents(of: node)
        let height = Self.tileHeight(agentCount: agents.count)
        return HStack(alignment: .top, spacing: Theme.Space.s16) {
            // Left: the session's own readout, in a fixed column so every
            // tile's swarm gets the same amount of room.
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                HStack(spacing: 8) {
                    PulsingStatusDot(isOn: isActive, color: isWaiting ? Theme.statusWarning : tint, big: true)
                    SessionTitleLine(label: session.cardLabel,
                                     font: .system(size: 14, weight: .semibold, design: .rounded))
                    Spacer(minLength: 4)
                    StatusPill(label: status.label, tint: status.tint, ink: status.ink)
                    if let onCleanUp, session.hasStalledTurn {
                        ActionChip(systemImage: "bandage", tint: Theme.Ink.warning,
                                   help: "清理这个卡住的会话") { onCleanUp(session) }
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    HStack {
                        RollingNumberText(session.contextLabel)
                            .font(Theme.Font.tileValueSmall)
                            .foregroundColor(Theme.contextInk(session.contextRatio))
                            .lineLimit(1)
                            .fixedSize()
                        Spacer()
                        RollingNumberText(session.relativeUpdated)
                            .font(Theme.Font.caption)
                            .monospacedDigit()
                            .foregroundColor(Theme.textTertiary())
                            .lineLimit(1)
                    }
                    ContextBar(ratio: session.contextRatio)
                }
                .opacity(session.contextLimit > 0 || session.contextTokens > 0 ? 1 : 0.25)

                SessionLoadChip(key: .standardizedCwd(session.cwd))
                Text(session.cwd.isEmpty ? " " : session.cwd)
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textTertiary(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(session.cwd.isEmpty ? 0.25 : 1)
                Text(session.isActive && !session.currentActivity.isEmpty
                     ? session.currentActivity
                     : (session.model.isEmpty ? " " : session.model))
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.sessionId)
                    .font(Theme.Font.tileDetail)
                    .foregroundColor(Theme.textTertiary(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: Self.readoutWidth, alignment: .topLeading)

            // Right: the swarm cluster, hanging under its header.
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                swarmHeader(agents)
                AgentSwarmView(root: session, children: agents, onOpen: {
                    TerminalLauncher.resumeCodexSession(cwd: $0.cwd, sessionId: $0.sessionId,
                                                        pid: $0.holderPID, inDesktop: $0.inDesktop)
                })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Small breathing room above the cluster so the parent
                    // badge does not crowd the "子 agent" header.
                    .padding(.top, Self.swarmTopInset)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
        // Tint, but deliberately **no** corner lens: this tile's trailing half
        // is a cluster of live agent cards, and rings receding off that corner
        // would run under the swarm rather than behind the header the way they
        // do on the readout-only tiles.
        .tile(tint: tint, hovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            TerminalLauncher.resumeCodexSession(cwd: session.cwd, sessionId: session.sessionId,
                                                pid: session.holderPID, inDesktop: session.inDesktop)
        }
        .hoverState($isHovered)
        .help("\(session.cwd)\n双击以在 Codex 中继续")
    }

    private func swarmHeader(_ agents: [ExternalSessionInfo]) -> some View {
        HStack(spacing: 6) {
            Text("子 agent")
                .font(Theme.Font.labelSection)
                .foregroundColor(Theme.textSecondary)
            RollingNumberText(agents.isEmpty ? "无" : "\(agents.count)")
                .font(Theme.Font.captionMono)
                .monospacedDigit()
                .foregroundColor(Theme.textTertiary())
            Spacer()
            if !agents.isEmpty {
                let running = agents.filter(\.isActive).count
                Text(running > 0 ? "\(running) 运行中" : "全部空闲")
                    .rollingNumber(running > 0 ? "\(running) 运行中" : "全部空闲")
                    .font(Theme.Font.caption)
                    .foregroundColor(running > 0 ? Theme.externalHi : Theme.textTertiary())
            }
            SessionActionChips(isHovered: isHovered) {
                ActionChip(systemImage: "play.fill", tint: tint, help: "在 Codex 中打开") {
                    TerminalLauncher.resumeCodexSession(cwd: session.cwd, sessionId: session.sessionId,
                                                        pid: session.holderPID,
                                                        inDesktop: session.inDesktop)
                }
                ActionChip(systemImage: "folder", tint: tint, help: "在 Finder 显示") {
                    revealCwd()
                }
            }
        }
    }

    private func revealCwd() { TerminalLauncher.revealInFinder(cwd: session.cwd) }
}

/// A Codex session in the multi-session grid: a regular 宫格 card, the same
/// shape the Claude and Cursor sections use, so a page of sessions reads as one
/// wall of cards instead of a stack of full-width strips.
///
/// A session that spawned sub-agents carries a `⋯N` badge and a compact strip of
/// agent cards beneath its readout — names *and* recency, so the strip is
/// information rather than decoration. A session with none is simply a card:
/// no badge, no placeholder, no extra height. The full-width swarm opens from
/// that `⋯N` badge, which is the grid card's only route to it — the tile's own
/// double-click resumes the session.
private struct ExternalSessionGridCard: View {
    let node: ProviderStore.ExternalSessionNode
    var onCleanUp: ((ExternalSessionInfo) -> Void)? = nil
    @State private var isHovered = false
    @State private var showSwarm = false

    private var session: ExternalSessionInfo { node.session }
    private var tint: Color { Theme.external }
    private var isActive: Bool { session.isActive }
    /// Codex journals no park (see `ExternalSessionInfo.isWaiting`), so this is
    /// `false` today; reading it here keeps the tile's three-state vocabulary
    /// identical to the Claude and Cursor tiles, and a future signal lands in
    /// one place.
    private var isWaiting: Bool { session.isWaiting }

    /// The card's three-state capsule; see `Theme.sessionStatus`.
    private var status: (label: String, tint: Color, ink: Color) {
        Theme.sessionStatus(waiting: isWaiting, active: isActive,
                            accent: Theme.external, ink: Theme.Ink.success)
    }

    /// Card width the strip is sized against — an estimate, not a measurement,
    /// so the grid row height does not reflow on every poll.
    private static let stripWidthEstimate: CGFloat = 300
    /// How many rows of agent cards a grid cell gives its strip. The cell is a
    /// normal 宫格 card, so it grows by a row or two, never to the height of its
    /// largest fan-out; the rest is counted by the `⋯N` badge.
    private static let stripRows = 2
    /// Constant: the strip asks for `count: .max`, so this never varies and it
    /// was pure overhead to recompute it on every read of `body`.
    private static let strip: (visible: Int, height: CGFloat) = AgentSwarmView.SwarmGrid.strip(
        count: .max, width: stripWidthEstimate, maxRows: stripRows, compact: true)

    var body: some View {
        // One subtree walk per render — this used to run on every read of
        // `swarmAgents` from the badge, the strip, its prefix and the popover.
        let agents = ExternalSessionTile.swarmAgents(of: node)
        return VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 8) {
                PulsingStatusDot(isOn: isActive, color: tint, big: true)
                SessionTitleLine(label: session.cardLabel,
                                 font: .system(size: 14, weight: .semibold, design: .rounded))
                Spacer(minLength: 4)
                if !agents.isEmpty {
                    Button { showSwarm = true } label: {
                        StatusPill(label: "⋯\(agents.count)", tint: Theme.externalHi,
                                ink: Theme.Ink.success)
                    }
                    .buttonStyle(.plain)
                    .help("查看 \(agents.count) 个子 agent")
                }
                StatusPill(label: status.label, tint: status.tint, ink: status.ink)
                if let onCleanUp, session.hasStalledTurn {
                    ActionChip(systemImage: "bandage", tint: Theme.Ink.warning,
                               help: "清理这个卡住的会话") { onCleanUp(session) }
                }
            }

            // Context + recency, space-reserved so cards in a row stay level.
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack {
                    RollingNumberText(session.contextLabel)
                        .font(Theme.Font.tileValueSmall)
                        .foregroundColor(Theme.contextInk(session.contextRatio))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer()
                    RollingNumberText(session.relativeUpdated)
                        .font(Theme.Font.caption)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
                ContextBar(ratio: session.contextRatio)
            }
            .opacity(session.contextLimit > 0 || session.contextTokens > 0 ? 1 : 0.25)

            Text(session.cwd.isEmpty ? " " : session.cwd)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textTertiary(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(session.cwd.isEmpty ? 0.25 : 1)

            SessionLoadChip(key: .standardizedCwd(session.cwd))

            Text(session.model.isEmpty ? " " : session.model)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 4) {
                Text(session.sessionId)
                    .font(Theme.Font.tileDetail)
                    .foregroundColor(Theme.textTertiary(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                SessionActionChips(isHovered: isHovered) {
                    ActionChip(systemImage: "play.fill", tint: tint, help: "在 Codex 中打开") {
                        TerminalLauncher.resumeCodexSession(cwd: session.cwd,
                                                            sessionId: session.sessionId,
                                                            pid: session.holderPID,
                                                            inDesktop: session.inDesktop)
                    }
                    ActionChip(systemImage: "folder", tint: tint, help: "在 Finder 显示") {
                        revealCwd()
                    }
                }
            }

            // The agents, right under the session's own readout. Only drawn when
            // there are some — an empty session's card ends here. A two-row
            // strip holds the first `strip.visible` agents; the badge above
            // accounts for the rest.
            if !agents.isEmpty {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                AgentSwarmView(root: session,
                               children: Array(agents.prefix(Self.strip.visible)),
                               compact: true,
                               onOpen: {
                                   TerminalLauncher.resumeCodexSession(cwd: $0.cwd, sessionId: $0.sessionId,
                                                                       pid: $0.holderPID, inDesktop: $0.inDesktop)
                               })
                    .frame(height: Self.strip.height)
            }
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Same reasoning as `ExternalSessionTile`: the agent strip occupies the
        // card's lower half, so the ornament is the hue, not the rings.
        .tile(tint: tint, hovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            TerminalLauncher.resumeCodexSession(cwd: session.cwd, sessionId: session.sessionId,
                                                pid: session.holderPID, inDesktop: session.inDesktop)
        }
        .hoverState($isHovered)
        .help("\(session.cwd)\n双击以在 Codex 中继续")
        .popover(isPresented: $showSwarm, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                RollingNumberText("\(session.displayName) · \(agents.count) 个子 agent")
                    .font(Theme.Font.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                AgentSwarmView(root: session, children: agents, onOpen: {
                    TerminalLauncher.resumeCodexSession(cwd: $0.cwd, sessionId: $0.sessionId,
                                                        pid: $0.holderPID, inDesktop: $0.inDesktop)
                })
                    .frame(width: 380, height: 300)
            }
            .padding(Theme.Space.s12)
        }
    }

    private func revealCwd() { TerminalLauncher.revealInFinder(cwd: session.cwd) }
}
