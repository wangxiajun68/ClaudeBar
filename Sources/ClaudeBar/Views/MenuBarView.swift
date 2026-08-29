import SwiftUI

extension Notification.Name {
    static let showMainWindow = Notification.Name("com.claudebar.showMainWindow")
}

/// Menu-bar popup shell — pure composition. Content lives in `Views/Popup/`
/// (PanelHeader, SessionsPanel, ProvidersPanel, UsagePanel), UI state in
/// `PanelState`, window management in `ProviderEditorWindowController`.
struct MenuBarView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @State private var panel = PanelState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(configCollapsed: $panel.configCollapsed, onFeedback: {
                panel.showFeedback("Refreshed")
            })

            Divider().background(Theme.divider)

            if !providerStore.hasSettingsFile {
                missingSettingsView
            } else {
                // Sessions on top; below, config+providers (left) | usage (right).
                VStack(alignment: .leading, spacing: 0) {
                    ProvidersPanel(panel: panel, configCollapsed: $panel.configCollapsed)

                    Divider().background(Theme.divider)

                    sessionsPanel
                        .frame(maxHeight: 300)

                    Divider().background(Theme.divider)

                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { EmptyView() }.frame(maxWidth: 0).hidden()
                        UsagePanel()
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: 150)
                }
                .frame(maxHeight: 460)
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
            iconButton("pencil.line", help: "编辑供应商", color: Theme.cursorAccent) { openEditor() }
            iconButton("gearshape", help: "打开 settings.json", color: Theme.textSecondary) { openSettingsFile() }
                .disabled(!providerStore.hasSettingsFile)
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
        ProviderEditorWindowController.shared.show(store: providerStore)
    }

    private func openSettingsFile() {
        NSWorkspace.shared.open(FilePaths.settingsFile)
    }
}

