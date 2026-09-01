import SwiftUI

/// Settings page: open the raw settings.json, show app info, and quit.
/// Lightweight — most configuration happens via the Providers page.
struct SettingsView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject var prefs = AppPreferences.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                Text("设置")
                    .font(Theme.Font.titleLarge)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()

                VStack(alignment: .leading, spacing: Theme.Space.s24) {
                    // Display
                    settingCard("显示", icon: "textformat") {
                        HStack {
                            Text("Token 单位")
                                .font(Theme.Font.body)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Picker("", selection: $prefs.tokenUnitStyle) {
                                ForEach([TokenUnitStyle.chinese, .metric], id: \.self) { style in
                                    Text(style == .chinese ? "万 / 亿" : "K / M / B").tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }
                    }

                    // Notifications
                    settingCard("通知", icon: "bell") {
                        Toggle(isOn: $prefs.idleNotifyEnabled) {
                            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                                Text("空闲通知")
                                    .font(Theme.Font.body)
                                    .foregroundColor(Theme.textPrimary)
                                Text("会话从运行中变为空闲（Claude 跑完等你输入）时发送系统通知")
                                    .font(Theme.Font.caption)
                                    .foregroundColor(Theme.textTertiary())
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(Theme.claude)
                    }

                    // Codex local routing proxy
                    settingCard("Codex 路由代理", icon: "arrow.triangle.branch") {
                        Toggle(isOn: Binding(
                            get: { prefs.codexRoutingEnabled },
                            set: { on in
                                prefs.codexRoutingEnabled = on
                                codexStore.syncProxyWithPreferences()
                                codexStore.reactivateActive()
                            })) {
                            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                                Text("本地路由")
                                    .font(Theme.Font.body)
                                    .foregroundColor(Theme.textPrimary)
                                Text("修复 openai/codex#23186：Codex 的 MCP 工具包装只有官方后端能解析，通用 Responses/Chat 后端会丢弃。开启后 Codex 请求经本机代理转发并自动转换协议。")
                                    .font(Theme.Font.caption)
                                    .foregroundColor(Theme.textTertiary())
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(Theme.codex)
                        Divider()
                        HStack {
                            Text("端口")
                                .font(Theme.Font.body)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            TextField("15721", text: Binding(
                                get: { String(prefs.codexProxyPort) },
                                set: { v in prefs.codexProxyPort = Int(v) ?? prefs.codexProxyPort }))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .onSubmit { codexStore.restartProxyAndReactivate() }
                        }
                        HStack(spacing: Theme.Space.s6) {
                            Circle()
                                .fill(codexStore.proxyRunning ? Theme.external : Theme.statusIdle)
                                .frame(width: 6, height: 6)
                            Text(codexStore.proxyRunning
                                 ? "运行中 · 127.0.0.1:\(prefs.codexProxyPort)"
                                 : "未启用")
                                .font(Theme.Font.captionMono)
                                .foregroundColor(Theme.textSecondary)
                            Spacer()
                            if let err = codexStore.errorMessage {
                                Text(err)
                                    .font(Theme.Font.caption)
                                    .foregroundColor(Theme.statusError)
                                    .lineLimit(1)
                            }
                        }
                    }

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
