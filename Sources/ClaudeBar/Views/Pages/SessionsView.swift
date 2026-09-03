import SwiftUI

/// Hover-revealed action chips: fade + slide in and accept hits only while
/// the parent tile is hovered.
private struct SessionActionChips<Content: View>: View {
    let isHovered: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 4) { content() }
            .opacity(isHovered ? 1 : 0)
            .offset(x: isHovered ? 0 : 10)
            .allowsHitTesting(isHovered)
            .animation(Theme.Animation.smooth, value: isHovered)
    }
}

/// Pulsing status dot: filled + ringed while `isOn`, muted gray otherwise.
private struct PulsingStatusDot: View {
    let isOn: Bool
    let color: Color
    var big: Bool = false

    var body: some View {
        Circle()
            .fill(isOn ? color : Theme.statusIdle.opacity(0.55))
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

/// A stroke ring that breathes in and out for as long as it is on screen.
/// Removed entirely (not merely faded) when the session goes idle.
private struct BusyPulseRing: View {
    let color: Color
    var big: Bool = false
    var compact: Bool = false
    @State private var phase = false

    var body: some View {
        Circle()
            .strokeBorder(color.opacity(0.4), lineWidth: compact ? 2 : (big ? 4 : 3))
            .scaleEffect(phase ? (compact ? 1.8 : 1.7) : 1)
            .opacity(phase ? 0.5 : 0.2)
            .onAppear { phase = true }
            .onDisappear { phase = false }
            .animation(Theme.Animation.pulse.repeatForever(autoreverses: true), value: phase)
    }
}

/// Full session page: all live Claude Code and Cursor sessions as an adaptive
/// tile grid, with expandable subagent trees inside each tile and
/// double-click-to-resume. Mirrors the menu-bar popup's sessions at full width.
struct SessionsView: View {
    @EnvironmentObject var providerStore: ProviderStore

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
        .background(Theme.base0.opacity(0.30))
    }

    private var titleBar: some View {
        Text("会话")
            .font(Theme.Font.titleLarge)
            .foregroundColor(Theme.textPrimary)
            .lineLimit(1)
            .fixedSize()
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
                        SessionTileFull(session: session, store: providerStore)
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
                        CursorTileFull(session: session, store: providerStore)
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
        let alive = providerStore.externalSessions.filter { $0.kind == kind && $0.isAlive }
        let active = alive.filter(\.isActive).count
        return sectionContainer(
            title: kind.displayName,
            icon: kind.icon,
            count: alive.count,
            active: active
        ) {
            if alive.isEmpty {
                emptyHint("暂无 \(kind.displayName) 会话")
            } else {
                TileGrid(.pageSession) {
                    ForEach(alive) { session in
                        ExternalTileFull(session: session)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func sectionContainer<C: View>(title: String, icon: String, count: Int, active: Int,
                                            @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(Theme.Font.micro)
                    .foregroundColor(active > 0 ? Theme.claude : Theme.textSecondary)
                Text(title.uppercased())
                    .font(Theme.Font.labelSection)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Text("\(active) 运行 · \(count) 总计")
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textTertiary())
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: active)
            }
            content()
        }
        .padding(Theme.Space.s16)
        .sectionRules()
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
                .fill(isBusy ? color : Theme.statusIdle.opacity(0.5))
                .frame(width: 4, height: 4)
                .overlay {
                    if isBusy { BusyPulseRing(color: color, big: false, compact: true) }
                }
            Text(activity)
                .font(Theme.Font.captionMono)
                .foregroundColor(isBusy ? .white.opacity(0.7) : .white.opacity(0.4))
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
    @ObservedObject var store: ProviderStore
    private var isExpanded: Bool { store.expandedSessionPIDs.contains(session.pid) }
    private var isBusy: Bool { session.status == .busy }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 8) {
                PulsingStatusDot(isOn: isBusy, color: Theme.statusBusy, big: true)
                Text(session.projectFolder)
                    .font(Theme.Font.bodyLarge)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(isBusy ? "busy" : "idle")
                    .font(Theme.Font.caption)
                    .monospacedDigit()
                    .foregroundColor(isBusy ? Theme.claudeHi : Theme.textTertiary())
            }

            // Context block and activity line are always rendered (dimmed
            // when there is no data) so every tile in a grid row keeps the
            // same height regardless of what the transcript scan found.
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack {
                    Text(session.contextLabel)
                        .font(Theme.Font.captionMono)
                        .foregroundColor(Theme.contextColor(session.contextRatio))
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
        .tile(tint: isBusy ? Theme.claude : nil, hovered: isHovered)
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
        TerminalLauncher.resumeClaudeSession(cwd: session.cwd, sessionId: session.sessionId)
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
                Text("(\(wf.runningCount)●)").font(Theme.Font.caption).foregroundColor(Theme.statusBusy)
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
    @ObservedObject var store: ProviderStore
    private var isExpanded: Bool { store.cursorExpanded.contains(session.composerId) }
    private var isActive: Bool { session.status == .active }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 8) {
                PulsingStatusDot(isOn: isActive, color: Theme.cursorAccent, big: true)
                Text(session.projectFolder.isEmpty ? "cursor" : session.projectFolder)
                    .font(Theme.Font.bodyLarge)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(isActive ? "active" : "idle")
                    .font(Theme.Font.caption)
                    .foregroundColor(isActive ? Theme.cursorHi : Theme.textTertiary())
            }

            // Space-reserved context + activity lines — see SessionTileFull.
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack {
                    Text(session.contextLabel)
                        .font(Theme.Font.captionMono)
                        .foregroundColor(Theme.contextColor(session.contextRatio))
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
        .tile(tint: isActive ? Theme.cursorAccent : nil, hovered: isHovered)
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

/// An external-agent session tile (Codex). Codex has no PID file and no resume URL scheme, so the tile is read-only:
/// reveal the working directory in Finder, double-click included. Teal tint
/// distinguishes the family from Claude (blue) and Cursor (violet).
private struct ExternalTileFull: View {
    let session: ExternalSessionInfo
    @State private var isHovered = false

    private var tint: Color { Theme.external }
    private var isActive: Bool { session.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: 8) {
                PulsingStatusDot(isOn: isActive, color: tint, big: true)
                Text(session.projectFolder.isEmpty ? session.kind.displayName : session.projectFolder)
                    .font(Theme.Font.bodyLarge)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(session.kind.displayName)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.externalHi)
                Text(isActive ? "active" : "idle")
                    .font(Theme.Font.caption)
                    .foregroundColor(isActive ? Theme.externalHi : Theme.textTertiary())
            }

            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                HStack {
                    Text(session.contextLabel)
                        .font(Theme.Font.captionMono)
                        .foregroundColor(Theme.contextColor(session.contextRatio))
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

            HStack {
                Text(session.cwd.isEmpty ? " " : session.cwd)
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .opacity(session.cwd.isEmpty ? 0.25 : 1)

            HStack {
                Text(session.model.isEmpty ? " " : session.model)
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                SessionActionChips(isHovered: isHovered) {
                    ActionChip(systemImage: "folder", tint: tint, help: "在 Finder 显示") {
                        revealCwd()
                    }
                }
            }
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(tint: isActive ? tint : nil, hovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { revealCwd() }
        .hoverState($isHovered)
        .help("\(session.cwd)\n双击以在 Finder 中显示")
    }

    private func revealCwd() {
        guard !session.cwd.isEmpty,
              FileManager.default.fileExists(atPath: session.cwd) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
    }
}
