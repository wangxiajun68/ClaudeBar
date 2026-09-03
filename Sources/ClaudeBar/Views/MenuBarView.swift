import SwiftUI

extension Notification.Name {
    static let showMainWindow = Notification.Name("com.claudebar.showMainWindow")
    static let openProvidersEditor = Notification.Name("com.claudebar.openProvidersEditor")
}

/// Menu-bar popup shell — pure composition. Content lives in `Views/Popup/`
/// (PanelHeader, SessionsPanel, ProvidersPanel, UsagePanel), UI state in
/// `PanelState`. Provider editing opens the main window.
struct MenuBarView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject var prefs = AppPreferences.shared
    @State private var panel = PanelState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(configCollapsed: $panel.configCollapsed, onFeedback: {
                panel.showFeedback("已刷新")
            })

            Divider().background(Theme.divider)

            ResourceStrip(dense: true)
                .padding(.horizontal, Theme.Space.s16)
                .padding(.vertical, Theme.Space.s8)

            Divider().background(Theme.divider)

            if !providerStore.hasSettingsFile && codexStore.providers.isEmpty {
                missingSettingsView
            } else {
                // Sections stack vertically; each scrolls independently rather
                // than the whole panel compressing. No height cap here — capping
                // the usage area squeezed its chips + tile grid.
                VStack(alignment: .leading, spacing: 0) {
                    ProvidersPanel(panel: panel, configCollapsed: $panel.configCollapsed)

                    Divider().background(Theme.divider)

                    sessionsPanel
                        .frame(maxHeight: 260)

                    Divider().background(Theme.divider)

                    UsagePanel()
                        .frame(maxWidth: .infinity)
                }
            }

            actionBar
        }
        .frame(width: 560)
        // Auto-dismiss the toast 2s after the latest showFeedback call.
        .task(id: panel.feedbackToken) {
            guard panel.feedbackToken > 0 else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.Animation.smooth) { panel.feedbackMessage = nil }
        }
    }

    // MARK: - Missing Settings

    private var missingSettingsView: some View {
        VStack(spacing: Theme.Space.s8) {
            Image(systemName: "exclamationmark.triangle")
                .font(Theme.Font.bodyLarge).foregroundColor(Theme.statusWarning)
            Text("未找到 settings.json")
                .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            Text("请先运行 Claude Code，然后刷新。")
                .font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity)
        .panelCard()
        .padding(Theme.Space.s16)
    }

    // MARK: - Sessions (forwarded)

    private var sessionsPanel: some View { SessionsPanelView() }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: Theme.Space.s4) {
            iconButton("arrow.clockwise", help: "刷新", color: Theme.textSecondary) {
                providerStore.refresh()
                panel.showFeedback("已刷新")
            }
            iconButton("macwindow", help: "打开主窗口", color: Theme.accent) {
                NotificationCenter.default.post(name: .showMainWindow, object: nil)
            }
            iconButton("pencil.line", help: "管理模型", color: Theme.cursorAccent) { openEditor() }
            iconButton("gearshape", help: "打开 settings.json", color: Theme.textSecondary) { openSettingsFile() }
                .disabled(!providerStore.hasSettingsFile)
            iconButton(prefs.idleNotifyEnabled ? "bell.fill" : "bell.slash",
                       help: "会话空闲时发送系统通知",
                       color: prefs.idleNotifyEnabled ? Theme.statusBusy : Theme.textSecondary) {
                prefs.idleNotifyEnabled.toggle()
                panel.showFeedback(prefs.idleNotifyEnabled ? "已开启空闲通知" : "已关闭空闲通知")
            }
            Spacer()
            iconButton("power", help: "退出", color: Theme.statusError) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, Theme.Space.s12).padding(.vertical, Theme.Space.s6)
    }

    private func iconButton(_ icon: String, help: String, color: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconChip(systemImage: icon, tint: color)
        }
        .buttonStyle(.pressable)
        .help(help)
    }

    // MARK: - External Actions

    private func openEditor() {
        NotificationCenter.default.post(name: .showMainWindow, object: nil)
        NotificationCenter.default.post(name: .openProvidersEditor, object: nil)
    }

    private func openSettingsFile() {
        NSWorkspace.shared.open(FilePaths.settingsFile)
    }
}

