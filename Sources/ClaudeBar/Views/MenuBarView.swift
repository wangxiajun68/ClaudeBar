import SwiftUI

// MARK: - Window Delegate

private final class EditorWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        MenuBarView.editorWindowRef = nil
    }
}

extension Notification.Name {
    static let showMainWindow = Notification.Name("com.claudebar.showMainWindow")
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

            Divider().background(Theme.divider)

            if !providerStore.hasSettingsFile {
                missingSettingsView
            } else {
                // Sessions are the focus of the panel and sit on top. Below
                // them the body splits in two: model config on the left,
                // token usage on the right.
                VStack(alignment: .leading, spacing: 0) {
                    if !configCollapsed, let env = providerStore.currentEnv {
                        currentConfigView(env)
                        Divider().background(Theme.divider)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            sessionsSection
                            Divider().background(Theme.divider)
                            cursorSessionsSection
                        }
                    }

                    Divider().background(Theme.divider)

                    // Bottom split: model config (left) | token usage (right)
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            providersSection
                        }
                        .frame(maxWidth: .infinity)

                        Divider().background(Theme.divider)

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
                Circle()
                    .fill(Theme.claude)
                    .frame(width: 20, height: 20)
                Text("A")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.base0)
            }
            .symbolEffect(.pulse, options: .repeating, isActive: providerStore.sessions.contains { $0.isAlive && $0.status == .busy })
            Text("Axon")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button(action: {
                withAnimation(Theme.Animation.smooth) { configCollapsed.toggle() }
            }) {
                Image(systemName: configCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.glass)
            .help(configCollapsed ? "展开配置与供应商" : "折叠配置与供应商")
            Button(action: {
                providerStore.refresh()
                showFeedback("Refreshed")
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.glass)
            .sensoryFeedback(.selection, trigger: providerStore.sessions.map(\.pid))
            .help("Refresh")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: - Current Config

    private func currentConfigView(_ env: EnvConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(providerStore.activeProviderID != nil ? Theme.statusBusy : Theme.statusWarning)
                    .frame(width: 6, height: 6)

                let providerName = providerStore.providers
                    .first(where: { $0.id == providerStore.activeProviderID })?.name
                Text(providerName ?? "Unsaved Config")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textPrimary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let model = providerStore.providers
                    .first(where: { $0.id == providerStore.activeProviderID })?.activeModel {
                    Text("/ \(model.name)")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 6) {
                if let host = URL(string: env.ANTHROPIC_BASE_URL)?.host {
                    Text(host)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
                Spacer()
                if providerStore.balanceLoading {
                    Text("⋯").font(.system(size: 11)).foregroundColor(Theme.textTertiary())
                } else if let balance = providerStore.balanceText {
                    Text("¥\(balance)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.statusBusy.opacity(0.85))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Missing Settings

    private var missingSettingsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18)).foregroundColor(Theme.statusWarning)
            Text("No settings.json found")
                .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            Text("Run Claude Code once, then click Refresh.")
                .font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity)
        .panelCard()
        .padding(Theme.Space.s16)
    }

    // MARK: - Providers

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PROVIDERS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
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
                        .foregroundColor(Theme.statusBusy).font(.system(size: 10))
                    Text(feedback)
                        .font(.system(size: 11)).foregroundColor(Theme.statusBusy)
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .transition(.opacity)
            }

            Divider().background(Theme.divider).padding(.top, 6)
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .animation(Theme.Animation.smooth, value: switchFeedback)
    }

    @State private var showCustomDatePicker = false

    // MARK: - Cursor Sessions

    private var cursorSessionsSection: some View {
        let alive = providerStore.cursorSessions
        let activeCount = alive.filter { $0.status == .active }.count

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                Text("CURSOR")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                if alive.isEmpty {
                    Text("none")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary())
                } else {
                    Text("● \(activeCount)A · \(alive.count - activeCount)I")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .contentTransition(.numericText())
                        .animation(Theme.Animation.smooth, value: activeCount)
                        .animation(Theme.Animation.smooth, value: alive.count)
                }
            }
            .padding(.horizontal, 16)

            if alive.isEmpty {
                Text("No active Cursor sessions")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 16).padding(.bottom, 4)
            } else {
                LazyVGrid(columns: sessionGridColumns, spacing: 4) {
                    ForEach(alive) { session in
                        CursorSessionCardView(session: session) { openInCursor(session) }
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

    // MARK: - Sessions

    private var sessionsSection: some View {
        let alive = providerStore.sessions.filter(\.isAlive)
        let busyCount = alive.filter { $0.status == .busy }.count

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                Text("CLAUDE CODE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                if alive.isEmpty {
                    Text("none")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary())
                } else {
                    Text("● \(busyCount)B · \(alive.count - busyCount)I")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .contentTransition(.numericText())
                        .animation(Theme.Animation.smooth, value: busyCount)
                        .animation(Theme.Animation.smooth, value: alive.count)
                }
            }
            .padding(.horizontal, 16)

            if alive.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 16).padding(.bottom, 4)
            } else {
                LazyVGrid(columns: sessionGridColumns, spacing: 4) {
                    ForEach(alive) { session in
                        SessionCardView(session: session) { resumeInTerminal(session) }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Resume / Open Actions

    /// Double-click a Claude Code session: open a terminal in the session's
    /// project directory and auto-run `claude --resume <sessionId>`. The
    /// Warp-vs-Terminal selection and osascript wiring live in
    /// `TerminalLauncher`, shared with the main-window Sessions page so the
    /// two surfaces can't drift apart.
    private func resumeInTerminal(_ session: SessionInfo) {
        TerminalLauncher.resumeClaudeSession(cwd: session.cwd, sessionId: session.sessionId)
    }

    /// Double-click a Cursor session: open the workspace folder in Cursor.app.
    private func openInCursor(_ session: CursorSessionInfo) {
        TerminalLauncher.openInCursor(cwd: session.cwd)
    }

    // MARK: - Usage Stats

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Period selector chips: 日 / 月 / 年 / 指定
            HStack(spacing: 4) {
                ForEach(UsagePeriod.allCases) { period in
                        let isOn = providerStore.usagePeriod == period
                        Button(action: {
                            if period == .custom {
                                withAnimation(Theme.Animation.bouncy) {
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
                                .foregroundColor(isOn ? .white : Theme.textSecondary)
                                .padding(.horizontal, 7).padding(.vertical, 2.5)
                                .glassEffect(
                                    .regular.tint(isOn ? Theme.accent.opacity(0.3) : .clear),
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                        }
                        .buttonStyle(.pressable)
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

            // Date navigation: ◀ label ▶ — the total gets a fixed trailing
            // slot so the label column doesn't shift when the number changes.
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                Button(action: { shiftUsage(-1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textTertiary(0.5))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.glass)
                .help("上一个\(providerStore.usagePeriod.label)")

                Text(periodLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textTertiary(0.6))
                    .lineLimit(1)

                Button(action: { shiftUsage(1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textTertiary(0.5))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.glass)
                .help("下一个\(providerStore.usagePeriod.label)")

                Spacer(minLength: 8)
                if providerStore.usageLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                        .frame(width: 64, alignment: .trailing)
                } else {
                    Text(totalUsageLabel)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary(0.6))
                        .frame(width: 64, alignment: .trailing)
                        .contentTransition(.numericText())
                        .animation(Theme.Animation.smooth, value: totalUsageLabel)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 2)

            if providerStore.usageStats.isEmpty && !providerStore.usageLoading {
                Text("无用量")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 16).padding(.bottom, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(providerStore.usageStats) { stat in
                        UsageRowView(stat: stat, maxTokens: providerStore.usageStats.first?.totalTokens ?? 1)
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

    private var periodLabel: String {
        UsageStats.label(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate)
    }

    private var totalUsageLabel: String {
        let total = providerStore.usageStats.reduce(0) { $0 + $1.totalTokens }
        return UsageStats.formatTokens(total)
    }

    // MARK: - Action Bar (compact icon buttons)

    private var actionBar: some View {
        HStack(spacing: 4) {
            iconButton("arrow.clockwise", help: "刷新", color: Theme.textSecondary) {
                providerStore.refresh()
                showFeedback("已刷新")
            }
            iconButton("macwindow", help: "打开主窗口", color: Theme.accent) {
                NotificationCenter.default.post(name: .showMainWindow, object: nil)
            }
            iconButton("pencil.line", help: "编辑供应商", color: Theme.cursorAccent) { openEditor() }
            iconButton("gearshape", help: "打开 settings.json", color: Theme.textSecondary) { openSettingsFile() }
                .disabled(!providerStore.hasSettingsFile)
            Spacer()
            iconButton("power", help: "退出", color: Theme.statusError) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func iconButton(_ icon: String, help: String, color: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconChip(systemImage: icon, tint: color)
        }
        .buttonStyle(.pressable)
        .help(help)
    }

    // MARK: - Helpers

    private func showFeedback(_ message: String) {
        switchFeedbackTimer?.invalidate()
        withAnimation(Theme.Animation.smooth) { switchFeedback = message }
        switchFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            DispatchQueue.main.async { withAnimation(Theme.Animation.smooth) { switchFeedback = nil } }
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
