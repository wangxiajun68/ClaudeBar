import SwiftUI

extension Notification.Name {
    static let showMainWindow = Notification.Name("com.claudebar.showMainWindow")
    static let openProvidersEditor = Notification.Name("com.claudebar.openProvidersEditor")
    static let openVPNPage = Notification.Name("com.claudebar.openVPNPage")
    static let openHelpPage = Notification.Name("com.claudebar.openHelpPage")
}

/// Menu-bar popup shell — switcher HUD, one-line machine KPIs, then
/// the three working surfaces (models / sessions / usage).
struct MenuBarView: View {
    let providerStore: ProviderStore
    let codexStore: CodexProviderStore
    @ObservedObject var prefs = AppPreferences.shared
    @State private var panel = PanelState()
    @State private var confirmRestore = false
    @State private var hasSettingsFile = false
    @State private var hasCodexProviders = false

    init(providerStore: ProviderStore, codexStore: CodexProviderStore) {
        self.providerStore = providerStore
        self.codexStore = codexStore
        // fittingSize is read immediately when the panel opens. Seed the
        // real state so its first layout never measures the empty variant.
        _hasSettingsFile = State(initialValue: providerStore.hasSettingsFile)
        _hasCodexProviders = State(initialValue: !codexStore.providers.isEmpty)
    }

    private enum SectionHeight {
        /// Cap only — the card hugs live sessions instead of leaving a blank well.
        static let sessions: CGFloat = 190
        static let usage: CGFloat = 280
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(panel: panel)
                .appearLift()

            MachineKpiStrip()
                .appearLift(delay: 0.04)

            PowerFlowCard(compact: true)

            if !hasSettingsFile && !hasCodexProviders {
                missingSettingsView
                    .appearLift(delay: 0.08)
            } else {
                sessionsPanel
                    .frame(maxHeight: SectionHeight.sessions, alignment: .top)
                    .panelCard()
                    .appearLift(delay: 0.08)

                UsagePanel()
                    .frame(minHeight: 260, maxHeight: SectionHeight.usage, alignment: .top)
                    .panelCard()
                    .appearLift(delay: 0.12)
            }

            actionBar
                .appearLift(delay: 0.16)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(width: 424)
        .background(Theme.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .ignoresSafeArea()
        .preferredColorScheme(prefs.appearance.colorScheme)
        .id(prefs.appearance)
        // Only shell-relevant changes invalidate the popup; session and usage
        // updates are observed by their own panels.
        .onReceive(providerStore.$hasSettingsFile.removeDuplicates()) { hasSettingsFile = $0 }
        .onReceive(codexStore.$providers.map { !$0.isEmpty }.removeDuplicates()) { hasCodexProviders = $0 }
        .task(id: panel.feedbackToken) {
            guard panel.feedbackToken > 0 else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.Animation.smooth) { panel.feedbackMessage = nil }
        }
    }

    private var missingSettingsView: some View {
        VStack(spacing: Theme.Space.s8) {
            AppGlyph(name: "exclamationmark.triangle", size: 16, box: 20)
                .foregroundColor(Theme.Ink.warning)
            Text("未找到 settings.json")
                .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            Text("请先运行 Claude Code，然后刷新。")
                .font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity)
        .panelCard()
    }

    private var sessionsPanel: some View { SessionsPanelView() }

    private var actionBar: some View {
        HStack(spacing: Theme.Space.s4) {
            iconButton("arrow.clockwise", help: "刷新", color: Theme.textSecondary) {
                providerStore.refresh()
                panel.showFeedback("已刷新")
            }
            iconButton("macwindow", help: "打开主窗口", color: Theme.accent) {
                NotificationCenter.default.post(name: .showMainWindow, object: nil)
            }
            iconButton("questionmark.circle", help: "帮助", color: Theme.textSecondary) {
                // Window first, then the page: the same order the providers
                // editor uses, so the window exists before it is asked to route.
                NotificationCenter.default.post(name: .showMainWindow, object: nil)
                NotificationCenter.default.post(name: .openHelpPage, object: nil)
            }
            iconButton("arrow.uturn.backward", help: "还原官方配置", color: Theme.textSecondary) {
                confirmRestore = true
            }
            .confirmationDialog("还原官方配置", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("还原 Claude Code") {
                    providerStore.restoreOfficial()
                    panel.showFeedback("Claude Code 已还原为官方")
                }
                Button("还原 Codex") {
                    codexStore.restoreOfficial()
                    panel.showFeedback("Codex 已还原为官方")
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("去掉第三方中转覆盖。供应商列表不删，新开会话后生效。")
            }
            iconButton("pencil.line", help: "管理模型", color: Theme.cursorAccent) { openEditor() }
            iconButton("gearshape", help: "打开 settings.json", color: Theme.textSecondary) { openSettingsFile() }
                .disabled(!hasSettingsFile)
            iconButton(prefs.idleNotifyEnabled ? "bell.fill" : "bell.slash",
                       help: "会话空闲时发送系统通知",
                       color: prefs.idleNotifyEnabled ? Theme.statusBusy : Theme.textSecondary) {
                prefs.idleNotifyEnabled.toggle()
                panel.showFeedback(prefs.idleNotifyEnabled ? "已开启空闲通知" : "已关闭空闲通知")
            }
            iconButton(prefs.appearance == .dark ? "sun.max" : "moon",
                       help: prefs.appearance == .dark ? "切换浅色" : "切换深色",
                       color: Theme.textSecondary) {
                prefs.appearance = prefs.appearance == .dark ? .light : .dark
            }
            Spacer()
            iconButton("power", help: "退出", color: Theme.statusError) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.top, 2)
    }

    private func iconButton(_ icon: String, help: String, color: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconChip(systemImage: icon, tint: color)
        }
        .buttonStyle(.pressable)
        .help(help)
        // `.help` is only a tooltip — without an explicit label VoiceOver
        // reads the symbol name ("arrow.clockwise").
        .accessibilityLabel(help)
    }

    private func openEditor() {
        NotificationCenter.default.post(name: .showMainWindow, object: nil)
        NotificationCenter.default.post(name: .openProvidersEditor, object: nil)
    }

    private func openSettingsFile() {
        NSWorkspace.shared.open(FilePaths.settingsFile)
    }
}
