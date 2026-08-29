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

                GlassEffectContainer(spacing: Theme.Space.s24) {
                    VStack(alignment: .leading, spacing: Theme.Space.s24) {
                        // Raw config
                        settingCard("配置文件", icon: "gearshape") {
                            HStack {
                                Text("~/.claude/settings.json")
                                    .font(Theme.Font.bodySmall)
                                    .foregroundColor(Theme.textSecondary)
                                Spacer()
                                Button("打开") { openSettingsFile() }
                                    .disabled(!providerStore.hasSettingsFile)
                                    .buttonStyle(.glass)
                                    .tint(Theme.claude)
                            }
                            HStack {
                                Text("~/.claude/claude-bar-providers.json")
                                    .font(Theme.Font.bodySmall)
                                    .foregroundColor(Theme.textSecondary)
                                Spacer()
                                Button("打开") { openProvidersFile() }
                                    .buttonStyle(.glass)
                                    .tint(Theme.claude)
                            }
                        }

                        // About
                        settingCard("关于", icon: "info.circle") {
                            row("名称", "ClaudeBar")
                            row("版本", "1.4.0")
                            row("构建", "swiftc · ad-hoc")
                            row("最低系统", "macOS 26 (Tahoe)")
                        }

                        // Actions
                        settingCard("操作", icon: "power") {
                            Button(role: .destructive) {
                                NSApplication.shared.terminate(nil)
                            } label: {
                                Label("退出 ClaudeBar", systemImage: "power")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.statusError)
                        }
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
            content()
        }
        .padding(Theme.Space.s16)
        .panelCard()
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value).font(Theme.Font.bodySmall).foregroundColor(Theme.textPrimary.opacity(0.85))
        }
    }

    private func openSettingsFile() {
        NSWorkspace.shared.open(FilePaths.settingsFile)
    }

    private func openProvidersFile() {
        NSWorkspace.shared.open(FilePaths.presetsFile)
    }
}
