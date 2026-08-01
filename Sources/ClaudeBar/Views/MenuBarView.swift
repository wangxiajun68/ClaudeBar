import SwiftUI

// MARK: - Window Delegate

private final class EditorWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        MenuBarView.editorWindowRef = nil
    }
}

struct MenuBarView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @State private var switchFeedback: String? = nil
    @State private var switchFeedbackTimer: Timer? = nil
    /// Collapse the model-config/provider area so sessions + usage get the
    /// full panel width. Sessions are the focus of the panel, so this
    /// defaults to collapsed. Persisted across launches via @AppStorage.
    @AppStorage("configCollapsed") private var configCollapsed: Bool = true

    fileprivate static var editorWindowRef: NSWindow?
    private static let windowDelegate = EditorWindowDelegate()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView

            Divider().background(Color(white: 0.27))

            if !providerStore.hasSettingsFile {
                missingSettingsView
            } else {
                // Sessions are the focus of the panel and sit on top. Below
                // them the body splits in two: model config on the left,
                // token usage on the right.
                VStack(alignment: .leading, spacing: 0) {
                    if !configCollapsed, let env = providerStore.currentEnv {
                        currentConfigView(env)
                        Divider().background(Color(white: 0.27))
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            sessionsSection
                            Divider().background(Color(white: 0.27))
                            cursorSessionsSection
                        }
                    }

                    Divider().background(Color(white: 0.27))

                    // Bottom split: model config (left) | token usage (right)
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            providersSection
                        }
                        .frame(maxWidth: .infinity)

                        Divider().background(Color(white: 0.27))

                        usageSection
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: 150)
                }
                .frame(maxHeight: 460)
            }

            actionBar
        }
        .frame(width: 560)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.42, green: 0.55, blue: 1.0),
                                 Color(red: 0.29, green: 0.42, blue: 0.97)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 20, height: 20)
                Text("CB").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
            }
            Text("ClaudeBar")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { configCollapsed.toggle() }
            }) {
                Image(systemName: configCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(configCollapsed ? "展开配置与供应商" : "折叠配置与供应商")
            Button(action: {
                providerStore.refresh()
                showFeedback("Refreshed")
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain).help("Refresh")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: - Current Config

    private func currentConfigView(_ env: EnvConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(providerStore.activeProviderID != nil ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)

                let providerName = providerStore.providers
                    .first(where: { $0.id == providerStore.activeProviderID })?.name
                Text(providerName ?? "Unsaved Config")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                if let model = providerStore.providers
                    .first(where: { $0.id == providerStore.activeProviderID })?.activeModel {
                    Text("/ \(model.name)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            HStack(spacing: 6) {
                if let host = URL(string: env.ANTHROPIC_BASE_URL)?.host {
                    Text(host)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer()
                if providerStore.balanceLoading {
                    Text("⋯").font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                } else if let balance = providerStore.balanceText {
                    Text("¥\(balance)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green.opacity(0.85))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Missing Settings

    private var missingSettingsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18)).foregroundColor(.orange)
            Text("No settings.json found")
                .font(.system(size: 12)).foregroundColor(.secondary)
            Text("Run Claude Code once, then click Refresh.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(.vertical, 24).frame(maxWidth: .infinity)
    }

    // MARK: - Providers

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PROVIDERS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(white: 0.53))
                .padding(.horizontal, 22).padding(.bottom, 4)

            VStack(spacing: 2) {
                ForEach(providerStore.providers) { provider in
                    ProviderRow(
                        provider: provider,
                        isActive: provider.id == providerStore.activeProviderID,
                        isExpanded: !providerStore.collapsedProviderIDs.contains(provider.id),
                        currentModelName: providerStore.currentEnv?.ANTHROPIC_MODEL,
                        onToggleExpand: {
                            if providerStore.collapsedProviderIDs.contains(provider.id) {
                                providerStore.collapsedProviderIDs.remove(provider.id)
                            } else {
                                providerStore.collapsedProviderIDs.insert(provider.id)
                            }
                        },
                        onActivateModel: { modelID in
                            providerStore.activateModel(providerID: provider.id, modelID: modelID)
                            if let m = provider.models.first(where: { $0.id == modelID }) {
                                showFeedback("\(provider.name) / \(m.name)")
                            }
                        }
                    )
                }
            }

            // Feedback toast
            if let feedback = switchFeedback {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green).font(.system(size: 10))
                    Text(feedback)
                        .font(.system(size: 11)).foregroundColor(.green)
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .transition(.opacity)
            }

            Divider().background(Color(white: 0.27)).padding(.top, 6)
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.2), value: switchFeedback)
    }

    // MARK: - Usage Stats

    @State private var showCustomDatePicker = false

    // MARK: - Cursor Sessions

    private var cursorSessionsSection: some View {
        let alive = providerStore.cursorSessions
        let activeCount = alive.filter { $0.status == .active }.count

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 10)).foregroundColor(Color(white: 0.53))
                Text("CURSOR")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(white: 0.53))
                Spacer()
                if alive.isEmpty {
                    Text("none")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.35))
                } else {
                    Text("● \(activeCount)A · \(alive.count - activeCount)I")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(white: 0.55))
                }
            }
            .padding(.horizontal, 16)

            if alive.isEmpty {
                Text("No active Cursor sessions")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 4)
            } else {
                LazyVGrid(columns: sessionGridColumns, spacing: 4) {
                    ForEach(alive) { session in
                        cursorSessionCard(session)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
        }
        .padding(.vertical, 6)
    }

    /// Grid layout for session cards: two columns → a 2×N "four-grid".
    private var sessionGridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
    }

    private func cursorSessionRow(_ session: CursorSessionInfo) -> some View {
        let isActive = session.status == .active
        let ratio = session.contextRatio
        // Cursor accent: purple, to distinguish from Claude's blue/green.
        let accentColor: Color = ratio < 0.6 ? Color(red: 0.62, green: 0.52, blue: 0.95)
                               : (ratio < 0.85 ? .yellow : .red)
        let hasAgents = !session.subagents.isEmpty
        let runningAgents = session.subagents.filter { $0.status == .running }.count
        let isExpanded = providerStore.cursorExpanded.contains(session.composerId)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Color(red: 0.62, green: 0.52, blue: 0.95) : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle().strokeBorder(isActive ? Color(red: 0.62, green: 0.52, blue: 0.95).opacity(0.4) : Color.clear, lineWidth: 3)
                            .scaleEffect(isActive ? 1.7 : 1)
                            .opacity(isActive ? 0.5 : 0)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                       value: isActive)
                    )
                Text(session.projectFolder)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                Text(isActive ? "active" : "idle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isActive ? Color(red: 0.62, green: 0.52, blue: 0.95) : Color.white.opacity(0.4))
            }

            // Composer name (the human title Cursor assigns), if present.
            if !session.name.isEmpty {
                Text(session.name)
                    .font(.system(size: 8))
                    .foregroundColor(Color.white.opacity(0.4))
                    .lineLimit(1)
                    .padding(.leading, 12)
            }

            // Context window bar — percent-based for Cursor.
            if session.contextPercent >= 0 {
                ContextBar(
                    label: session.contextLabel,
                    ratio: ratio,
                    color: accentColor,
                    leading: { EmptyView() },
                    trailing: {
                        if session.messageCount > 0 {
                            Text("\(session.messageCount) msgs")
                                .font(.system(size: 7))
                                .foregroundColor(Color.white.opacity(0.3))
                        }
                    }
                )
            }

            // Current activity line.
            if !session.currentActivity.isEmpty {
                activityLine(session.currentActivity, isBusy: isActive)
            }

            // Subagent summary + expansion.
            if hasAgents {
                HStack(spacing: 6) {
                    Button(action: {
                        if isExpanded {
                            providerStore.cursorExpanded.remove(session.composerId)
                        } else {
                            providerStore.cursorExpanded.insert(session.composerId)
                        }
                    }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.5))
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 8))
                        .foregroundColor(Color.white.opacity(0.4))
                    Text("\(session.subagents.count) agents")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.6))
                    if runningAgents > 0 {
                        Text("· \(runningAgents)●")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.green)
                    }
                    Spacer()
                }
                .padding(.leading, 2)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(session.subagents) { agent in
                            cursorSubagentRow(agent)
                        }
                    }
                    .padding(.leading, 10)
                }
            }

            HStack(spacing: 3) {
                Text(session.composerId.prefix(8))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.35))
                Text("· \(session.relativeUpdated)")
                    .font(.system(size: 8))
                    .foregroundColor(Color.white.opacity(0.3))
                Spacer()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(isActive ? Color(red: 0.62, green: 0.52, blue: 0.95).opacity(0.07) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openInCursor(session) }
        .help("\(session.name)\n\(session.cwd)\n双击在 Cursor 打开")
    }

    /// Compact card for the 2-column session grid. Shows status, project,
    /// context fill, activity, and recency in a tight tile.
    private func cursorSessionCard(_ session: CursorSessionInfo) -> some View {
        let isActive = session.status == .active
        let ratio = session.contextRatio
        let accentColor: Color = ratio < 0.6 ? Color(red: 0.62, green: 0.52, blue: 0.95)
                               : (ratio < 0.85 ? .yellow : .red)
        let hasAgents = !session.subagents.isEmpty
        let runningAgents = session.subagents.filter { $0.status == .running }.count
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isActive ? Color(red: 0.62, green: 0.52, blue: 0.95) : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(session.projectFolder.isEmpty ? "cursor" : session.projectFolder)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                if session.contextPercent >= 0 {
                    Text(session.contextLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(accentColor.opacity(0.9))
                }
            }

            // Context fill bar (percent-based).
            if session.contextPercent >= 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(accentColor)
                            .frame(width: max(2, geo.size.width * min(ratio, 1.0)), height: 3)
                    }
                }
                .frame(height: 3)
            }

            if !session.currentActivity.isEmpty {
                Text(session.currentActivity)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(isActive ? .white.opacity(0.65) : .white.opacity(0.35))
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                if hasAgents {
                    Text("⚙\(session.subagents.count)")
                        .font(.system(size: 8))
                        .foregroundColor(runningAgents > 0 ? .green : .white.opacity(0.35))
                }
                Text(session.relativeUpdated)
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.3))
                Spacer()
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isActive ? Color(red: 0.62, green: 0.52, blue: 0.95).opacity(0.08) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isActive ? Color(red: 0.62, green: 0.52, blue: 0.95).opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openInCursor(session) }
        .help("\(session.name)\n\(session.cwd)\n双击在 Cursor 打开")
    }

    /// One Cursor subagent: type · description, with current activity.
    private func cursorSubagentRow(_ agent: CursorSubagentInfo) -> some View {
        let running = agent.status == .running
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Circle()
                    .fill(running ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 4, height: 4)
                    .overlay(
                        Circle().strokeBorder(running ? Color.green.opacity(0.4) : Color.clear, lineWidth: 2)
                            .scaleEffect(running ? 1.8 : 1)
                            .opacity(running ? 0.5 : 0)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                       value: running)
                    )
                Text(agent.agentType)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(running ? Color.white.opacity(0.8) : Color.white.opacity(0.45))
                if !agent.description.isEmpty {
                    Text("· \(agent.description)")
                        .font(.system(size: 9))
                        .foregroundColor(Color.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer()
                if !running {
                    Text("✓")
                        .font(.system(size: 9))
                        .foregroundColor(Color.white.opacity(0.3))
                }
            }
            if !agent.activity.isEmpty {
                Text("↳ \(agent.activity)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(running ? Color.white.opacity(0.55) : Color.white.opacity(0.3))
                    .lineLimit(1)
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(running ? Color.green.opacity(0.05) : Color.clear))
    }

    // MARK: - Usage Stats (continued)

    // MARK: - Sessions

    private var sessionsSection: some View {
        let alive = providerStore.sessions.filter(\.isAlive)
        let busyCount = alive.filter { $0.status == .busy }.count

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.system(size: 10)).foregroundColor(Color(white: 0.53))
                Text("CLAUDE CODE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(white: 0.53))
                Spacer()
                if alive.isEmpty {
                    Text("none")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.35))
                } else {
                    Text("● \(busyCount)B · \(alive.count - busyCount)I")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(white: 0.55))
                }
            }
            .padding(.horizontal, 16)

            if alive.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 4)
            } else {
                LazyVGrid(columns: sessionGridColumns, spacing: 4) {
                    ForEach(alive) { session in
                        sessionCard(session)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        let isBusy = session.status == .busy
        let ratio = session.contextRatio
        // Context health: green < 60%, yellow < 85%, red otherwise.
        let ctxColor: Color = ratio < 0.6 ? .green : (ratio < 0.85 ? .yellow : .red)
        let hasAgents = !session.subagents.isEmpty || !session.workflows.isEmpty
        let runningAgents = session.subagents.filter { $0.status == .running }.count
            + session.workflows.reduce(0) { $0 + $1.runningCount }
        let isExpanded = providerStore.expandedSessionPIDs.contains(session.pid)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isBusy ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle().strokeBorder(isBusy ? Color.green.opacity(0.4) : Color.clear, lineWidth: 3)
                            .scaleEffect(isBusy ? 1.7 : 1)
                            .opacity(isBusy ? 0.5 : 0)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                       value: isBusy)
                    )
                Text(session.projectFolder)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                Text(isBusy ? "busy" : "idle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isBusy ? .green : Color.white.opacity(0.4))
            }

            // Context window bar
            if session.contextTokens > 0 {
                ContextBar(
                    label: session.contextLabel,
                    ratio: ratio,
                    color: ctxColor,
                    leading: {
                        if !session.model.isEmpty {
                            Text("· \(session.model)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.35))
                                .lineLimit(1)
                        }
                    },
                    trailing: {
                        if session.messageCount > 0 {
                            Text("\(session.messageCount) msgs")
                                .font(.system(size: 7))
                                .foregroundColor(Color.white.opacity(0.3))
                        }
                    }
                )
            }

            // Current activity line — shown whenever non-empty.
            if !session.currentActivity.isEmpty {
                activityLine(session.currentActivity, isBusy: isBusy)
            }

            // Subagent / workflow summary + expansion toggle.
            if hasAgents {
                HStack(spacing: 6) {
                    Button(action: {
                        if isExpanded {
                            providerStore.expandedSessionPIDs.remove(session.pid)
                        } else {
                            providerStore.expandedSessionPIDs.insert(session.pid)
                        }
                    }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.5))
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 8))
                        .foregroundColor(Color.white.opacity(0.4))
                    Text("\(session.subagents.count + session.workflows.reduce(0) { $0 + $1.agents.count }) agents")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.6))
                    if runningAgents > 0 {
                        Text("· \(runningAgents)●")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.green)
                    }
                    if !session.workflows.isEmpty {
                        Text("· ⚙\(session.workflows.count)")
                            .font(.system(size: 9))
                            .foregroundColor(Color.white.opacity(0.4))
                    }
                    Spacer()
                }
                .padding(.leading, 2)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(session.subagents) { agent in
                            subagentRow(agent)
                        }
                        ForEach(session.workflows) { wf in
                            workflowRow(wf)
                        }
                    }
                    .padding(.leading, 10)
                }
            }

            HStack(spacing: 3) {
                Text("\(session.pid)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.35))
                Text("· \(session.relativeUpdated)")
                    .font(.system(size: 8))
                    .foregroundColor(Color.white.opacity(0.3))
                Spacer()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(isBusy ? Color.green.opacity(0.07) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { resumeInTerminal(session) }
        .help("\(session.name) · PID \(session.pid)\n\(session.cwd)\n双击在 Terminal 恢复会话")
    }

    /// Compact card for the 2-column session grid. Shows status, project,
    /// context fill, activity, and recency in a tight tile.
    private func sessionCard(_ session: SessionInfo) -> some View {
        let isBusy = session.status == .busy
        let ratio = session.contextRatio
        let ctxColor: Color = ratio < 0.6 ? .green : (ratio < 0.85 ? .yellow : .red)
        let hasAgents = !session.subagents.isEmpty || !session.workflows.isEmpty
        let runningAgents = session.subagents.filter { $0.status == .running }.count
            + session.workflows.reduce(0) { $0 + $1.runningCount }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isBusy ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(session.projectFolder.isEmpty ? "session" : session.projectFolder)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                if session.contextTokens > 0 {
                    Text(session.contextLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(ctxColor.opacity(0.9))
                        .lineLimit(1)
                }
            }

            // Context fill bar.
            if session.contextTokens > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(ctxColor)
                            .frame(width: max(2, geo.size.width * min(ratio, 1.0)), height: 3)
                    }
                }
                .frame(height: 3)
            }

            if !session.currentActivity.isEmpty {
                Text(session.currentActivity)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(isBusy ? .white.opacity(0.7) : .white.opacity(0.35))
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                if hasAgents {
                    Text("⚙\(session.subagents.count + session.workflows.reduce(0) { $0 + $1.agents.count })")
                        .font(.system(size: 8))
                        .foregroundColor(runningAgents > 0 ? .green : .white.opacity(0.35))
                }
                if !session.model.isEmpty {
                    Text(session.model)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                        .lineLimit(1)
                }
                Spacer()
                Text(session.relativeUpdated)
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isBusy ? Color.green.opacity(0.08) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isBusy ? Color.green.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { resumeInTerminal(session) }
        .help("\(session.name) · PID \(session.pid)\n\(session.cwd)\n双击在 Terminal 恢复会话")
    }

    /// The session's current activity, e.g. "Bash · build.sh".
    private func activityLine(_ activity: String, isBusy: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isBusy ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 4, height: 4)
                .overlay(
                    Circle().strokeBorder(isBusy ? Color.green.opacity(0.4) : Color.clear, lineWidth: 2)
                        .scaleEffect(isBusy ? 1.8 : 1)
                        .opacity(isBusy ? 0.5 : 0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                   value: isBusy)
                )
            Text(activity)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(isBusy ? Color.white.opacity(0.7) : Color.white.opacity(0.4))
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 2)
    }

    /// Reusable context-window bar: a ratio bar with a label and optional
    /// leading/trailing text. Shared by Claude and Cursor session rows.
    private struct ContextBar<Leading: View, Trailing: View>: View {
        let label: String
        let ratio: Double
        let color: Color
        @ViewBuilder var leading: () -> Leading
        @ViewBuilder var trailing: () -> Trailing

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(color.opacity(0.9))
                    leading()
                    Spacer()
                    trailing()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 3)
                        if ratio > 0 {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(color)
                                .frame(width: max(2, geo.size.width * ratio), height: 3)
                        }
                    }
                }
                .frame(height: 3)
            }
        }
    }

    /// One live subagent: type · description, with its current activity.
    private func subagentRow(_ agent: SubagentInfo) -> some View {
        let running = agent.status == .running
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Circle()
                    .fill(running ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 4, height: 4)
                    .overlay(
                        Circle().strokeBorder(running ? Color.green.opacity(0.4) : Color.clear, lineWidth: 2)
                            .scaleEffect(running ? 1.8 : 1)
                            .opacity(running ? 0.5 : 0)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                       value: running)
                    )
                Text(agent.agentType)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(running ? Color.white.opacity(0.8) : Color.white.opacity(0.45))
                if !agent.description.isEmpty {
                    Text("· \(agent.description)")
                        .font(.system(size: 9))
                        .foregroundColor(Color.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer()
                if !running {
                    Text("✓")
                        .font(.system(size: 9))
                        .foregroundColor(Color.white.opacity(0.3))
                }
            }
            if !agent.activity.isEmpty {
                Text("↳ \(agent.activity)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(running ? Color.white.opacity(0.55) : Color.white.opacity(0.3))
                    .lineLimit(1)
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(running ? Color.green.opacity(0.05) : Color.clear))
    }

    /// A workflow rendered as a summary row (agents not individually expanded).
    private func workflowRow(_ wf: WorkflowInfo) -> some View {
        let running = wf.runningCount
        return HStack(spacing: 4) {
            Image(systemName: "gearshape")
                .font(.system(size: 8))
                .foregroundColor(Color.white.opacity(0.45))
            Text(wf.workflowId)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.6))
                .lineLimit(1)
            Text("· \(wf.agents.count) agents")
                .font(.system(size: 9))
                .foregroundColor(Color.white.opacity(0.4))
            if running > 0 {
                Text("(\(running)●)")
                    .font(.system(size: 9))
                    .foregroundColor(.green)
            } else {
                Text("✓")
                    .font(.system(size: 9))
                    .foregroundColor(Color.white.opacity(0.3))
            }
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
    }

    /// Double-click a Claude Code session: open a terminal in the session's
    /// project directory and auto-run `claude --resume <sessionId>` to restore
    /// that exact conversation (no interactive picker needed).
    ///
    /// Prefers Warp if installed (`/Applications/Warp.app`): opens a new Warp
    /// window at the cwd, then injects the command via System Events and
    /// submits it (Warp exposes no AppleScript `do script`, and its `warp://`
    /// scheme has no documented "run command" deep link, so keystroke
    /// injection is the reliable path). Falls back to Terminal's native
    /// `do script` when Warp is absent.
    private func resumeInTerminal(_ session: SessionInfo) {
        guard !session.cwd.isEmpty else { return }
        let safeCwd = session.cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let sid = session.sessionId
        // `claude --resume` opens an interactive list by default; passing the
        // sessionId as an argument resumes that specific session directly.
        let shellCmd = "cd \"\(safeCwd)\" && claude --resume \(sid)"

        if FileManager.default.fileExists(atPath: "/Applications/Warp.app") {
            resumeInWarp(shellCmd: shellCmd, cwd: session.cwd)
        } else {
            resumeInAppleTerminal(shellCmd: shellCmd)
        }
    }

    /// Warp path: Warp exposes no AppleScript `do script` and no `warp://`
    /// run-command deep link, so we open a window at the cwd (reliable +
    /// permission-free via LaunchServices) and then type+submit the command
    /// via osascript. The osascript runs on a background thread so the double-
    /// tap returns instantly — `activate`+`delay`+`keystroke` would otherwise
    /// block the main thread ~0.5s (or hang if an automation prompt is modal).
    /// Requires Automation permission for Warp on first use.
    private func resumeInWarp(shellCmd: String, cwd: String) {
        // Open (or focus) Warp at the cwd via LaunchServices — no Apple Events
        // permission needed, returns immediately, and lands a window there.
        NSWorkspace.shared.open([URL(fileURLWithPath: cwd)],
                               withApplicationAt: URL(fileURLWithPath: "/Applications/Warp.app"),
                               configuration: NSWorkspace.OpenConfiguration())
        // Escape the command for an AppleScript double-quoted string.
        let appleStr = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Run the injection off the main thread so the tap handler is instant.
        let script = """
        tell application "Warp" to activate
        delay 0.35
        tell application "System Events"
            keystroke "\(appleStr)"
            delay 0.08
            key code 36
        end tell
        """
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.launchPath = "/usr/bin/osascript"
            proc.arguments = ["-e", script]
            // run() is synchronous; fine here because we're already detached.
            _ = try? proc.run()
        }
    }

    /// Terminal fallback: native `do script` runs the command in a new window.
    private func resumeInAppleTerminal(shellCmd: String) {
        let appleStr = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(appleStr)\""
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        try? proc.run()
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Double-click a Cursor session: open the workspace folder in Cursor.app.
    private func openInCursor(_ session: CursorSessionInfo) {
        guard !session.cwd.isEmpty,
              FileManager.default.fileExists(atPath: session.cwd) else { return }
        let cursorURL = URL(fileURLWithPath: "/Applications/Cursor.app")
        guard FileManager.default.fileExists(atPath: cursorURL.path) else { return }
        let folderURL = URL(fileURLWithPath: session.cwd)
        NSWorkspace.shared.open([folderURL], withApplicationAt: cursorURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Period selector chips: 日 / 月 / 年 / 指定
            HStack(spacing: 4) {
                ForEach(UsagePeriod.allCases) { period in
                    let isOn = providerStore.usagePeriod == period
                    Button(action: {
                        if period == .custom {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showCustomDatePicker.toggle()
                            }
                            providerStore.usagePeriod = .custom
                        } else {
                            showCustomDatePicker = false
                            providerStore.usagePeriod = period
                            providerStore.usageReferenceDate = Date()
                        }
                    }) {
                        Text(period.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(isOn ? .white : Color(white: 0.55))
                            .padding(.horizontal, 7).padding(.vertical, 2.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isOn ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.bottom, 2)

            // Custom date picker (inline, only for custom period)
            if showCustomDatePicker {
                DatePicker("", selection: $providerStore.usageReferenceDate, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 16).padding(.bottom, 2)
                    .transition(.opacity)
            }

            // Date navigation: ◀ label ▶
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 10)).foregroundColor(Color(white: 0.53))
                Button(action: { shiftUsage(-1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(white: 0.5))
                        .frame(width: 14, height: 14)
                }.buttonStyle(.plain).help("上一个\(providerStore.usagePeriod.label)")

                Text(periodLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(white: 0.6))

                Button(action: { shiftUsage(1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(white: 0.5))
                        .frame(width: 14, height: 14)
                }.buttonStyle(.plain).help("下一个\(providerStore.usagePeriod.label)")

                Spacer()
                if providerStore.usageLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                } else {
                    Text(totalUsageLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(white: 0.6))
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 2)

            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                Text("无用量")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(providerStore.usageStats) { stat in
                        usageRow(stat)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private func shiftUsage(_ amount: Int) {
        providerStore.usageReferenceDate = UsageStats.shift(
            providerStore.usagePeriod, reference: providerStore.usageReferenceDate, by: amount
        )
    }

    private func usageRow(_ stat: ModelUsage) -> some View {
        let maxTokens = providerStore.usageStats.first?.totalTokens ?? 1
        let ratio = maxTokens > 0 ? CGFloat(stat.totalTokens) / CGFloat(maxTokens) : 0

        return HStack(spacing: 8) {
            Text(stat.model)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(for: stat.model))
                        .frame(width: max(3, geo.size.width * ratio), height: 5)
                }
            }
            .frame(width: 70, height: 12)

            Text(UsageStats.formatTokens(stat.totalTokens))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 1)
    }

    private var periodLabel: String {
        UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate)
    }

    private var totalUsageLabel: String {
        let total = providerStore.usageStats.reduce(0) { $0 + $1.totalTokens }
        return UsageStats.formatTokens(total)
    }

    private func barColor(for model: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.40, green: 0.58, blue: 0.95),
            Color(red: 0.30, green: 0.75, blue: 0.60),
            Color(red: 0.92, green: 0.62, blue: 0.40),
            Color(red: 0.78, green: 0.50, blue: 0.90),
            Color(red: 0.90, green: 0.50, blue: 0.55)
        ]
        let hash = abs(model.hashValue)
        return palette[hash % palette.count]
    }

    // MARK: - Action Bar (compact icon buttons)

    private var actionBar: some View {
        HStack(spacing: 4) {
            iconButton("arrow.clockwise", help: "刷新", color: .white.opacity(0.6)) {
                providerStore.refresh()
                showFeedback("已刷新")
            }
            iconButton("pencil.line", help: "编辑供应商", color: .blue) { openEditor() }
            iconButton("gearshape", help: "打开 settings.json", color: .secondary) { openSettingsFile() }
                .disabled(!providerStore.hasSettingsFile)
            Spacer()
            iconButton("power", help: "退出", color: .secondary) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func iconButton(_ icon: String, help: String, color: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Helpers

    private func showFeedback(_ message: String) {
        switchFeedbackTimer?.invalidate()
        withAnimation(.easeInOut(duration: 0.2)) { switchFeedback = message }
        switchFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.3)) { switchFeedback = nil } }
        }
    }

    // MARK: - External Actions

    private func openEditor() {
        if let existing = Self.editorWindowRef {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Edit Providers — ClaudeBar"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProviderEditorView(providerStore: providerStore))
        window.delegate = Self.windowDelegate
        window.setFrameAutosaveName("ClaudeBarProviderEditor")
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.editorWindowRef = window
    }

    private func openSettingsFile() {
        NSWorkspace.shared.open(FilePaths.settingsFile)
    }
}
