import SwiftUI

extension Notification.Name {
    /// Bring the main window forward, optionally to a page. The destination
    /// rides in `userInfo` as an `AppPage` raw value, so one post carries both
    /// halves of the request — see `Notification.showMainWindow(page:editor:)`.
    ///
    /// There is no separate "open the editor once the window is up" name: the
    /// editor request is the same post with `editor: true`, because a surface
    /// cannot know whether the window it is asking for already exists, and a
    /// trailing second post loses the request whenever it has to be built.
    static let showMainWindow = Notification.Name("com.claudebar.showMainWindow")
}

extension Notification {
    /// Show the main window and route it to `page` in one post. `editor: true`
    /// additionally opens the provider editor for that page's active provider
    /// (what the popup's 「管理模型」 and 「去添加供应商」 mean).
    ///
    /// Posting `showMainWindow` and a separate page notification back to back
    /// used to lose the page whenever the window had to be built first: a fresh
    /// `NSHostingView` subscribes to the center on its first display pass
    /// (~50 ms), i.e. after the second post was published.
    static func showMainWindow(page: AppPage, editor: Bool = false) -> Notification {
        Notification(name: .showMainWindow, object: nil,
                     userInfo: ["page": page.rawValue, "editor": editor])
    }
}

/// Menu-bar popup shell — switcher HUD, one-line machine KPIs, then
/// the three working surfaces (models / sessions / usage).
struct MenuBarView: View {
    let providerStore: ProviderStore
    let codexStore: CodexProviderStore
    /// The two preferences this shell renders, subscribed individually.
    /// Observing `AppPreferences.shared` wholesale meant every unrelated write
    /// re-evaluated the whole popup — and the shell's body builds the header,
    /// the KPI strip, both panels and the action bar, so a settings text field
    /// (a proxy port, a mixed port) rebuilt all of them per keystroke. Same
    /// arrangement as `MainWindowView`.
    @State private var appearance = AppPreferences.shared.appearance
    @State private var idleNotifyEnabled = AppPreferences.shared.idleNotifyEnabled
    @State private var panel = PanelState()
    @State private var confirmRestore = false
    @State private var hasSettingsFile = false
    @State private var hasCodexProviders = false

    init(providerStore: ProviderStore, codexStore: CodexProviderStore) {
        self.providerStore = providerStore
        self.codexStore = codexStore
        // Seed the real state so the first frame uses the correct content.
        _hasSettingsFile = State(initialValue: providerStore.hasSettingsFile)
        _hasCodexProviders = State(initialValue: !codexStore.providers.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(panel: panel)
                .fixedSize(horizontal: false, vertical: true)
            MachineKpiStrip()
                .fixedSize(horizontal: false, vertical: true)
            PowerFlowCard(compact: true)
                .fixedSize(horizontal: false, vertical: true)
            if !hasSettingsFile && !hasCodexProviders {
                missingSettingsView
                Spacer(minLength: 0)
            } else {
                sessionsPanel
                    .frame(maxHeight: .infinity, alignment: .top)
                    .panelCard()
                UsagePanel()
                    .fixedSize(horizontal: false, vertical: true)
                    .panelCard()
            }
            actionBar
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(width: 424)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .ignoresSafeArea()
        .preferredColorScheme(appearance.colorScheme)
        // No `.id(appearance)` here. It destroyed and rebuilt the whole popup
        // graph on a theme toggle — new `PanelState`, reset scroll and
        // `showSwarm`/`showCustomDatePicker` state, re-run `onAppear` chains
        // (the popup's own action bar can toggle the theme) — which is exactly
        // the gesture most likely to show a hitch. `preferredColorScheme`
        // propagates through the environment on its own.
        .onReceive(AppPreferences.shared.$appearance.removeDuplicates()) { appearance = $0 }
        .onReceive(AppPreferences.shared.$idleNotifyEnabled.removeDuplicates()) { idleNotifyEnabled = $0 }
        // Only shell-relevant changes invalidate the popup; session and usage
        // updates are observed by their own panels.
        .onReceive(providerStore.$hasSettingsFile.removeDuplicates()) { hasSettingsFile = $0 }
        .onReceive(codexStore.$providers.map { !$0.isEmpty }.removeDuplicates()) { hasCodexProviders = $0 }
        .overlay(alignment: .bottom) {
            // The toast is the only reader of `panel.feedbackMessage`, so it
            // invalidates here rather than invalidating the shell: the write
            // used to re-evaluate the header, both panels and the action bar to
            // display nothing (nothing mounted the toast at all).
            FeedbackToast(message: panel.feedbackMessage)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .allowsHitTesting(false)
        }
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

    /// The popup's action bar — the highest-frequency control row in the app.
    ///
    /// It is now the `mymiamo` glass menu: **one** milled capsule the ten items
    /// share (`IconChipRow`), a hairline rule before the destructive action, and
    /// items that light up on hover rather than each carrying its own resting
    /// chip. Ten bordered squares in a flat line was the plainest object on the
    /// surface a user sees most often, and the fix is the group, not the glyph.
    private var actionBar: some View {
        IconChipRow(spacing: Theme.Space.s2) {
            if ProcessSampler.shared.host.batteryInstalled {
                CompactBatteryChargeControl()
            }
            iconButton("arrow.clockwise", help: "刷新", color: Theme.textSecondary) {
                providerStore.refresh()
                panel.showFeedback("已刷新")
            }
            iconButton("macwindow", help: "打开主窗口", color: Theme.accent) {
                NotificationCenter.default.post(name: .showMainWindow, object: nil)
            }
            iconButton("questionmark.circle", help: "帮助", color: Theme.textSecondary) {
                // One post naming the destination: the window has to exist
                // before it is asked to route, and a second notification would
                // race its installation.
                NotificationCenter.default.post(.showMainWindow(page: .help))
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
            iconButton(idleNotifyEnabled ? "bell.fill" : "bell.slash",
                       help: "会话空闲时发送系统通知",
                       color: idleNotifyEnabled ? Theme.statusBusy : Theme.textSecondary) {
                AppPreferences.shared.idleNotifyEnabled.toggle()
                // Read the preference, not `idleNotifyEnabled`: this
                // `@State` mirror is written by an `.onReceive` on a
                // `removeDuplicates` publisher, which coalesces the two writes
                // made in one runloop turn, so inside the action that toggled
                // it the mirror still holds the *previous* value and the toast
                // announced the opposite of what had just happened.
                panel.showFeedback(AppPreferences.shared.idleNotifyEnabled ? "已开启空闲通知" : "已关闭空闲通知")
            }
            iconButton(appearance == .dark ? "sun.max" : "moon",
                       help: appearance == .dark ? "切换浅色" : "切换深色",
                       color: Theme.textSecondary) {
                AppPreferences.shared.appearance = appearance == .dark ? .light : .dark
            }
            Spacer(minLength: Theme.Space.s4)
            // 退出 is separated by a rule, not just by a gap: it is the one item
            // on this row that ends the app, and it used to sit flush against
            // 深色 with nothing but 4pt between them.
            VerticalHairline()
                .frame(height: 18)
                .padding(.horizontal, Theme.Space.s2)
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
        NotificationCenter.default.post(.showMainWindow(page: .providers, editor: true))
    }

    private func openSettingsFile() {
        NSWorkspace.shared.open(FilePaths.settingsFile)
    }
}
