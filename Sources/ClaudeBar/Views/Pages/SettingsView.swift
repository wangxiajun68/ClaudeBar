import SwiftUI

/// Settings page: open the raw settings.json, show app info, and quit.
/// Lightweight — most configuration happens via the Providers page.
struct SettingsView: View {
    @EnvironmentObject var providerStore: ProviderStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                Text("设置")
                    .font(Theme.Font.titleLarge)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()

                VStack(alignment: .leading, spacing: Theme.Space.s24) {
                    // Raw config
                    settingCard("配置文件", icon: "gearshape") {
                        fileRow(path: "~/.claude/settings.json") {
                            openSettingsFile()
                        }
                        .disabled(!providerStore.hasSettingsFile)
                        Divider()
                        fileRow(path: "~/.claude/claude-bar-providers.json") {
                            openProvidersFile()
                        }
                    }

                    // About
                    settingCard("关于", icon: "info.circle") {
                        row("名称", "Axon")
                        row("原名", "ClaudeBar")
                        row("版本", "1.6.0")
                        row("构建", "swiftc · ad-hoc")
                        row("最低系统", "macOS 26 (Tahoe)")
                    }

                    // Actions
                    settingCard("操作", icon: "power") {
                        Button(role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        } label: {
                            Label("退出 Axon", systemImage: "power")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.statusError)
                    }
                }
            }
            .padding(Theme.Space.s24)
        }
        .background(Theme.base0.opacity(0.35))
    }

    private func settingCard<C: View>(_ title: String, icon: String,
                                       @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Label(title, systemImage: icon)
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            content()
        }
        .padding(Theme.Space.s16)
        .panelCard()
    }

    /// One settings.json / providers.json line: path on the left, "打开"
    /// button on the right — a shared layout so both rows align.
    private func fileRow(path: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(path)
                .font(Theme.Font.bodySmall)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("打开", action: action)
                .buttonStyle(.glass)
                .tint(Theme.claude)
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value).font(Theme.Font.bodySmall)
                .monospacedDigit()
                .foregroundColor(Theme.textPrimary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func openSettingsFile() {
        NSWorkspace.shared.open(FilePaths.settingsFile)
    }

    private func openProvidersFile() {
        NSWorkspace.shared.open(FilePaths.presetsFile)
    }
}
