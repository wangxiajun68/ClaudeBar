import SwiftUI

/// Full session list: all live Claude Code and Cursor sessions with expandable
/// subagent trees and double-click-to-resume. Mirrors the menu-bar popup's
/// sessions but at full width with richer detail.
struct SessionsView: View {
    @EnvironmentObject var providerStore: ProviderStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                titleBar
                claudeSection
                cursorSection
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
                emptyHint("无活跃 Claude Code 会话")
            } else {
                VStack(spacing: Theme.Space.s8) {
                    ForEach(alive) { session in
                        SessionRowFull(session: session, store: providerStore)
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
                emptyHint("无活跃 Cursor 会话")
            } else {
                VStack(spacing: Theme.Space.s8) {
                    ForEach(alive) { session in
                        CursorSessionRowFull(session: session, store: providerStore)
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
                    .symbolEffect(.pulse, options: .repeating, isActive: active > 0)
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
        .panelCard()
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundColor(Theme.textTertiary())
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
    }
}

// MARK: - Full session rows

/// A wide, detailed Claude Code session row with subagent expansion.
/// On hover the row lifts + gains an accent edge and trailing action chips
/// (resume / reveal cwd) slide in — the affordances emerge from the row
/// instead of being hidden behind a double-click.
private struct SessionRowFull: View {
    let session: SessionInfo
    @ObservedObject var store: ProviderStore
    private var isExpanded: Bool { store.expandedSessionPIDs.contains(session.pid) }
    private var isBusy: Bool { session.status == .busy }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusBadge(isOn: isBusy, color: Theme.statusBusy, big: true)
                Text(session.projectFolder)
                    .font(Theme.Font.bodyLarge)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(session.name.isEmpty ? "PID \(session.pid)" : session.name)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                // Fixed-width status + action columns so the expand chevron
                // and hover chips line up across all rows.
                Text(isBusy ? "busy" : "idle")
                    .font(Theme.Font.caption)
                    .monospacedDigit()
                    .foregroundColor(isBusy ? Theme.claudeHi : Theme.textTertiary())
                    .frame(width: 34, alignment: .trailing)
                // Trailing actions: reveal on hover. The expand chevron stays
                // always-on when there are subagents; the resume/open chips
                // slide in only while the pointer is over the row.
                if !session.subagents.isEmpty || !session.workflows.isEmpty {
                    Button(action: { toggle() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 4) {
                    ActionChip(systemImage: "play.fill", tint: Theme.accent, help: "在终端恢复") {
                        resume()
                    }
                    ActionChip(systemImage: "folder", tint: Theme.cursorAccent, help: "在 Finder 显示") {
                        revealCwd()
                    }
                }
                .opacity(isHovered ? 1 : 0)
                .offset(x: isHovered ? 0 : 10)
                .allowsHitTesting(isHovered)
            }

            if session.contextTokens > 0 {
                HStack(spacing: 8) {
                    // Fixed-size context label + capped bar: the model name
                    // column therefore starts at the same x in every row.
                    Text(session.contextLabel)
                        .font(Theme.Font.captionMono)
                        .foregroundColor(Theme.contextColor(session.contextRatio))
                        .lineLimit(1)
                        .fixedSize()
                    ContextBar(ratio: session.contextRatio)
                        .frame(width: 160)
                    if !session.model.isEmpty {
                        Text(session.model)
                            .font(Theme.Font.captionMono)
                            .foregroundColor(Theme.textTertiary())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 150, alignment: .leading)
                    } else {
                        Color.clear.frame(width: 150, height: 1)
                    }
                    Spacer(minLength: 8)
                    Text("\(session.messageCount) msgs · \(session.relativeUpdated)")
                        .font(Theme.Font.caption)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            if !session.currentActivity.isEmpty {
                ActivityLine(activity: session.currentActivity, isBusy: isBusy)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.subagents) { subagentRow($0) }
                    ForEach(session.workflows) { workflowRow($0) }
                }
                .padding(.leading, 16)
            }
        }
        .padding(Theme.Space.s12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .fill(isBusy ? Theme.claude.opacity(0.07) : (isHovered ? Theme.cardFill(0.08) : Color.clear)))
        .scaleEffect(isHovered ? 1.004 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { resume() }
        .hoverState($isHovered)
        .help("\(session.cwd)\n双击在终端恢复")
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
                // Fixed width so the trailing activity column lines up across
                // subagent rows instead of drifting with content length.
                Text("↳ \(agent.activity)").font(Theme.Font.captionMono).foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 220, alignment: .trailing)
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

/// A wide Cursor session row. Same hover-reveal pattern as the Claude row:
/// actions (open in Cursor / show in Finder) slide in on hover and the row
/// gains a leading accent edge.
private struct CursorSessionRowFull: View {
    let session: CursorSessionInfo
    @ObservedObject var store: ProviderStore
    private var isExpanded: Bool { store.cursorExpanded.contains(session.composerId) }
    private var isActive: Bool { session.status == .active }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusBadge(isOn: isActive, color: Theme.cursorAccent, big: true)
                Text(session.projectFolder.isEmpty ? "cursor" : session.projectFolder)
                    .font(Theme.Font.bodyLarge)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if !session.name.isEmpty {
                    Text(session.name).font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Text(isActive ? "active" : "idle")
                    .font(Theme.Font.caption)
                    .foregroundColor(isActive ? Theme.cursorHi : Theme.textTertiary())
                    .frame(width: 44, alignment: .trailing)
                HStack(spacing: 4) {
                    ActionChip(systemImage: "cursorarrow", tint: Theme.cursorAccent, help: "在 Cursor 打开") {
                        openCursor()
                    }
                    ActionChip(systemImage: "folder", tint: Theme.accent, help: "在 Finder 显示") {
                        revealCwd()
                    }
                }
                .opacity(isHovered ? 1 : 0)
                .offset(x: isHovered ? 0 : 10)
                .allowsHitTesting(isHovered)
            }

            if session.contextPercent >= 0 {
                HStack(spacing: 8) {
                    Text(session.contextLabel)
                        .font(Theme.Font.captionMono)
                        .foregroundColor(Theme.contextColor(session.contextRatio))
                        .lineLimit(1)
                        .fixedSize()
                    ContextBar(ratio: session.contextRatio)
                        .frame(width: 160)
                    Spacer(minLength: 8)
                    Text(session.relativeUpdated).font(Theme.Font.caption).monospacedDigit().foregroundColor(Theme.textTertiary())
                        .lineLimit(1).fixedSize()
                }
            }

            if !session.currentActivity.isEmpty {
                ActivityLine(activity: session.currentActivity, isBusy: isActive, color: Theme.cursorAccent)
            }
        }
        .padding(Theme.Space.s12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .fill(isActive ? Theme.cursorAccent.opacity(0.07) : (isHovered ? Theme.cardFill(0.08) : Color.clear)))
        .scaleEffect(isHovered ? 1.004 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openCursor() }
        .hoverState($isHovered)
        .help("\(session.cwd)\n双击在 Cursor 打开")
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
