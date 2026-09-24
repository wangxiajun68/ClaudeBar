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

/// Pulsing status dot: filled + ringed while `isOn`, muted gray otherwise.
private struct PulsingStatusDot: View {
    let isOn: Bool
    let color: Color
    var big: Bool = false

    var body: some View {
        Circle()
            .fill(isOn ? color : Theme.Ink.idle)
            .frame(width: big ? 8 : 6, height: big ? 8 : 6)
            .overlay {
                if isOn {
                    // Pulsing ring while busy. The repeating animation lives
                    // on a view that only exists while busy — an
                    // always-attached repeatForever animation keeps the
                    // render server ticking even when invisible, burning GPU
                    // on every idle session dot.
                    BusyPulseRing(color: color, big: big)
                }
            }
    }
}

/// Static halo for a busy session. Animated rings hitch scrolling.
private struct BusyPulseRing: View {
    let color: Color
    var big: Bool = false
    var compact: Bool = false

    var body: some View {
        Circle()
            .strokeBorder(color.opacity(0.35), lineWidth: compact ? 1.5 : (big ? 2.5 : 2))
            .scaleEffect(compact ? 1.8 : 1.7)
            .opacity(0.45)
    }
}

/// Full session page: all live Claude Code and Cursor sessions as an adaptive
/// tile grid, with expandable subagent trees inside each tile and
/// double-click-to-resume. Mirrors the menu-bar popup's sessions at full width.
struct SessionsView: View {
    @ProviderState([.sessions, .expansion]) var providerStore: ProviderStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                titleBar
                claudeSection
                cursorSection
                externalSections
            }
            .padding(Theme.Space.s24)
        }
        .resourceMonitorScope(.sessions)
        .background(Theme.bgPrimary)
    }

    private var titleBar: some View {
        PageTitle(title: "会话")
    }

    // MARK: Claude Code

    private var claudeSection: some View {
        let alive = providerStore.sessions.filter(\.isAlive)
        let busy = alive.filter { $0.status == .busy }.count
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
        let active = alive.filter { $0.status == .active }.count
        return sectionContainer(
            title: "Cursor",
            icon: "cursorarrow.rays",
            count: alive.count,
            active: active
        ) {
            if alive.isEmpty {
                emptyHint("暂无 Cursor 会话")
            } else {
                TileGrid(.pageSession) {
                    ForEach(alive) { session in
                        CursorTileFull(session: session, store: providerStore, isExpanded: providerStore.cursorExpanded.contains(session.composerId))
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
        let alive = tree.reduce(0) { $0 + 1 + $1.descendantCount }
        let active = tree.flatMap(\.flattened).filter { $0.session.isActive }.count
        return sectionContainer(
            title: kind.displayName,
            icon: kind.icon,
            count: alive,
            active: active
        ) {
            if tree.isEmpty {
                emptyHint("暂无 \(kind.displayName) 会话")
            } else if tree.count == 1 {
                // A lone session needs no grid: its swarm cluster wants the
                // whole page width, where 60 cards can spread out.
                ExternalSessionTile(node: tree[0])
            } else {
                // Several sessions: regular grid cells, the same 宫格 the Claude
                // and Cursor sections use. A session with no sub-agents is just
                // a card — it is not drawn any taller than its own readout.
                TileGrid(.pageSession) {
                    ForEach(tree) { node in
                        ExternalSessionGridCard(node: node)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func sectionContainer<C: View>(title: String, icon: String, count: Int, active: Int,
                                            @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            SectionHeader(icon: icon, title: title, tint: Theme.claude,
                          ink: Theme.Ink.claude,
                          count: count, activeCount: active)
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
    private var isBusy: Bool { session.status == .busy }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 8) {
                PulsingStatusDot(isOn: isBusy, color: Theme.statusBusy, big: true)
                Text(session.projectFolder)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                StatusPill(label: isBusy ? "运行中" : "空闲",
                           tint: isBusy ? Theme.statusBusy : Theme.statusIdle,
                           ink: isBusy ? Theme.Ink.claude : Theme.Ink.idle)
            }

            // Context block and activity line are always rendered (dimmed
            // when there is no data) so every tile in a grid row keeps the
            // same height regardless of what the transcript scan found.
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack {
                    Text(session.contextLabel)
                        .font(Theme.Font.tileValueSmall)
                        .foregroundColor(Theme.contextInk(session.contextRatio))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer()
                    Text("\(session.messageCount) msgs · \(session.relativeUpdated)")
                        .font(Theme.Font.caption)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
                ContextBar(ratio: session.contextRatio)
            }
            .opacity(session.contextTokens > 0 ? 1 : 0.25)

            ActivityLine(activity: session.currentActivity.isEmpty ? " " : session.currentActivity,
                         isBusy: isBusy, color: Theme.statusBusy)
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
        .tile(hovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { resume() }
        .hoverState($isHovered)
        .help("\(session.cwd)\n双击以在终端继续")
    }

    private func toggle() {
        if isExpanded { store.expandedSessionPIDs.remove(session.pid) }
        else { store.expandedSessionPIDs.insert(session.pid) }
    }

    /// Reveal the session's working directory in Finder.
    private func revealCwd() {
        guard !session.cwd.isEmpty,
              FileManager.default.fileExists(atPath: session.cwd) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
    }

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
            Text(wf.workflowId).font(Theme.Font.captionMono).foregroundColor(Theme.textTertiary())
                .lineLimit(1).truncationMode(.middle)
            Text("· \(wf.agents.count) agents").font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
                .lineLimit(1)
            if wf.runningCount > 0 {
                Text("(\(wf.runningCount)●)").font(Theme.Font.caption).foregroundColor(Theme.Ink.claude)
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
    let store: ProviderStore
    let isExpanded: Bool
    private var isActive: Bool { session.status == .active }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 8) {
                PulsingStatusDot(isOn: isActive, color: Theme.cursorAccent, big: true)
                Text(session.projectFolder.isEmpty ? "cursor" : session.projectFolder)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                StatusPill(label: isActive ? "运行中" : "空闲",
                           tint: isActive ? Theme.cursorAccent : Theme.statusIdle,
                           ink: isActive ? Theme.Ink.cursor : Theme.Ink.idle)
            }

            // Space-reserved context + activity lines — see SessionTileFull.
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack {
                    Text(session.contextLabel)
                        .font(Theme.Font.tileValueSmall)
                        .foregroundColor(Theme.contextInk(session.contextRatio))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer()
                    Text(session.relativeUpdated)
                        .font(Theme.Font.caption)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
                ContextBar(ratio: session.contextRatio)
            }
            .opacity(session.contextPercent >= 0 ? 1 : 0.25)

            ActivityLine(activity: session.currentActivity.isEmpty ? " " : session.currentActivity,
                         isBusy: isActive, color: Theme.cursorAccent)
            SessionLoadChip(key: .cursor, shared: true)
            HStack {
                Text(session.name)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                SessionActionChips(isHovered: isHovered) {
                    ActionChip(systemImage: "cursorarrow", tint: Theme.cursorAccent, help: "在 Cursor 打开") {
                        openCursor()
                    }
                    ActionChip(systemImage: "folder", tint: Theme.accent, help: "在 Finder 显示") {
                        revealCwd()
                    }
                }
            }
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(hovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openCursor() }
        .hoverState($isHovered)
        .help("\(session.cwd)\n双击以在 Cursor 中打开")
    }

    /// Reveal the session's working directory in Finder.
    private func revealCwd() {
        guard !session.cwd.isEmpty,
              FileManager.default.fileExists(atPath: session.cwd) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
    }

    private func openCursor() {
        guard !session.cwd.isEmpty, FileManager.default.fileExists(atPath: session.cwd) else { return }
        let cursorURL = URL(fileURLWithPath: "/Applications/Cursor.app")
        guard FileManager.default.fileExists(atPath: cursorURL.path) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: session.cwd)], withApplicationAt: cursorURL,
                               configuration: NSWorkspace.OpenConfiguration())
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
    @State private var isHovered = false

    private var session: ExternalSessionInfo { node.session }
    private var tint: Color { Theme.external }
    private var isActive: Bool { session.isActive }

    /// Every agent below this node, in pre-order (sub-agents first, then their
    /// own children).
    private var swarmAgents: [ExternalSessionInfo] {
        node.children.flatMap(\.flattened).map(\.session)
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
    private var tileHeight: CGFloat {
        let base = Self.tilePadding * 2 + Self.readoutHeight
        guard !swarmAgents.isEmpty else { return base }
        let cluster = AgentSwarmView.SwarmGrid.requiredHeight(
            count: swarmAgents.count, width: Self.swarmWidthEstimate)
        // Clamped so a 200-agent session does not push everything else off the
        // page; the cluster packs smaller cards to fit whatever it is given.
        return min(max(base, Self.tilePadding * 2 + Self.headerHeight + Self.swarmTopInset + cluster), 520)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s16) {
            // Left: the session's own readout, in a fixed column so every
            // tile's swarm gets the same amount of room.
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                HStack(spacing: 8) {
                    PulsingStatusDot(isOn: isActive, color: tint, big: true)
                    Text(session.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    StatusPill(label: isActive ? "运行中" : "空闲",
                                tint: isActive ? Theme.external : Theme.statusIdle,
                                ink: isActive ? Theme.Ink.success : Theme.Ink.idle)
                }

                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    HStack {
                        Text(session.contextLabel)
                            .font(Theme.Font.tileValueSmall)
                            .foregroundColor(Theme.contextInk(session.contextRatio))
                            .lineLimit(1)
                            .fixedSize()
                        Spacer()
                        Text(session.relativeUpdated)
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
                Text(session.model.isEmpty ? " " : session.model)
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
                swarmHeader
                AgentSwarmView(root: session, children: swarmAgents, onOpen: { resume($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Small breathing room above the cluster so the parent
                    // badge does not crowd the "子 agent" header.
                    .padding(.top, Self.swarmTopInset)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: tileHeight, alignment: .topLeading)
        .tile(hovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { resume(session) }
        .hoverState($isHovered)
        .help("\(session.cwd)\n双击以在 Codex 中继续")
    }

    private var swarmHeader: some View {
        HStack(spacing: 6) {
            Text("子 agent")
                .font(Theme.Font.labelSection)
                .foregroundColor(Theme.textSecondary)
            Text(swarmAgents.isEmpty ? "无" : "\(swarmAgents.count)")
                .font(Theme.Font.captionMono)
                .monospacedDigit()
                .foregroundColor(Theme.textTertiary())
            Spacer()
            if !swarmAgents.isEmpty {
                let running = swarmAgents.filter(\.isActive).count
                Text(running > 0 ? "\(running) 运行中" : "全部空闲")
                    .font(Theme.Font.caption)
                    .foregroundColor(running > 0 ? Theme.externalHi : Theme.textTertiary())
            }
            SessionActionChips(isHovered: isHovered) {
                ActionChip(systemImage: "play.fill", tint: tint, help: "在 Codex 中打开") {
                    resume(session)
                }
                ActionChip(systemImage: "folder", tint: tint, help: "在 Finder 显示") {
                    revealCwd()
                }
            }
        }
    }

    private func resume(_ target: ExternalSessionInfo) {
        TerminalLauncher.resumeCodexSession(cwd: target.cwd, sessionId: target.sessionId,
                                            pid: target.holderPID, inDesktop: target.inDesktop)
    }

    private func revealCwd() {
        guard !session.cwd.isEmpty,
              FileManager.default.fileExists(atPath: session.cwd) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
    }
}

/// A Codex session in the multi-session grid: a regular 宫格 card, the same
/// shape the Claude and Cursor sections use, so a page of sessions reads as one
/// wall of cards instead of a stack of full-width strips.
///
/// A session that spawned sub-agents carries a `⋯N` badge and a compact strip of
/// agent cards beneath its readout — names *and* recency, so the strip is
/// information rather than decoration. A session with none is simply a card:
/// no badge, no placeholder, no extra height. The full-width swarm stays
/// reachable through the badge's double-click target on the tile itself, and
/// through the popup on the card.
private struct ExternalSessionGridCard: View {
    let node: ProviderStore.ExternalSessionNode
    @State private var isHovered = false
    @State private var showSwarm = false

    private var session: ExternalSessionInfo { node.session }
    private var tint: Color { Theme.external }
    private var isActive: Bool { session.isActive }

    /// Every agent below this node, in pre-order — the cluster is drawn from the
    /// whole subtree, not just the direct children.
    private var swarmAgents: [ExternalSessionInfo] {
        node.children.flatMap(\.flattened).map(\.session)
    }

    /// Card width the strip is sized against — an estimate, not a measurement,
    /// so the grid row height does not reflow on every poll.
    private static let stripWidthEstimate: CGFloat = 300
    /// How many rows of agent cards a grid cell gives its strip. The cell is a
    /// normal 宫格 card, so it grows by a row or two, never to the height of its
    /// largest fan-out; the rest is counted by the `⋯N` badge.
    private static let stripRows = 2
    private static var strip: (visible: Int, height: CGFloat) {
        AgentSwarmView.SwarmGrid.strip(count: .max,
                                       width: stripWidthEstimate,
                                       maxRows: stripRows,
                                       compact: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 8) {
                PulsingStatusDot(isOn: isActive, color: tint, big: true)
                Text(session.displayName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if !swarmAgents.isEmpty {
                    Button { showSwarm = true } label: {
                        StatusPill(label: "⋯\(swarmAgents.count)", tint: Theme.externalHi,
                                ink: Theme.Ink.success)
                    }
                    .buttonStyle(.plain)
                    .help("查看 \(swarmAgents.count) 个子 agent")
                }
                StatusPill(label: isActive ? "运行中" : "空闲",
                                tint: isActive ? Theme.external : Theme.statusIdle,
                                ink: isActive ? Theme.Ink.success : Theme.Ink.idle)
            }

            // Context + recency, space-reserved so cards in a row stay level.
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack {
                    Text(session.contextLabel)
                        .font(Theme.Font.tileValueSmall)
                        .foregroundColor(Theme.contextInk(session.contextRatio))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer()
                    Text(session.relativeUpdated)
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
                        resume(session)
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
            if !swarmAgents.isEmpty {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                AgentSwarmView(root: session,
                               children: Array(swarmAgents.prefix(Self.strip.visible)),
                               compact: true,
                               onOpen: { resume($0) })
                    .frame(height: Self.strip.height)
            }
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(hovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { resume(session) }
        .hoverState($isHovered)
        .help("\(session.cwd)\n双击以在 Codex 中继续")
        .popover(isPresented: $showSwarm, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                Text("\(session.displayName) · \(swarmAgents.count) 个子 agent")
                    .font(Theme.Font.rowTitle)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                AgentSwarmView(root: session, children: swarmAgents, onOpen: { resume($0) })
                    .frame(width: 380, height: 300)
            }
            .padding(Theme.Space.s12)
        }
    }

    private func resume(_ target: ExternalSessionInfo) {
        TerminalLauncher.resumeCodexSession(cwd: target.cwd, sessionId: target.sessionId,
                                            pid: target.holderPID, inDesktop: target.inDesktop)
    }

    private func revealCwd() {
        guard !session.cwd.isEmpty,
              FileManager.default.fileExists(atPath: session.cwd) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
    }
}

