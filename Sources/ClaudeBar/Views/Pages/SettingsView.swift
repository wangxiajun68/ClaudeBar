import SwiftUI
import AppKit

/// Settings: grouped modules with a shared row geometry — label leading,
/// control trailing, caption under the row. Width is capped so columns align.
struct SettingsView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject var prefs = AppPreferences.shared
    @ObservedObject private var tests = ConnectivityTestCenter.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s32) {
                Text("设置")
                    .font(Theme.Font.titleLarge)
                    .foregroundColor(Theme.textPrimary)

                group("外观") {
                    row("Token 单位") {
                        Picker("", selection: $prefs.tokenUnitStyle) {
                            ForEach([TokenUnitStyle.chinese, .metric], id: \.self) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                }

                group("通知") {
                    toggleRow(
                        "空闲通知",
                        isOn: $prefs.idleNotifyEnabled,
                        caption: "会话由运行转为空闲时发送系统通知。")
                }

                group("存储") {
                    toggleRow(
                        "SQLite 存储",
                        isOn: $prefs.databaseEnabled,
                        caption: prefs.databaseEnabled
                            ? "流量记录与用量统计写入 SQLite。关闭后改用 JSON / JSONL 文件，两者互不迁移。"
                            : "已关闭。流量记录写入 logs/captures；用量统计写入 logs/usage-*。重新开启不会自动导入。")
                    Divider()
                    fileRow("~/Library/Application Support/ClaudeBar/logs") {
                        NSWorkspace.shared.open(FilePaths.logsDir)
                    }
                }

                group("风扇") {
                    Text("通过 Apple SMC 读取转速并手动调速。逻辑参考 Stats；切换为手动后系统温控不再接管该风扇。")
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textTertiary())
                        .fixedSize(horizontal: false, vertical: true)
                    FanControlSection()
                }

                group("本地代理") {
                    toggleRow(
                        "本地代理",
                        isOn: Binding(
                            get: { prefs.codexRoutingEnabled },
                            set: { on in
                                prefs.codexRoutingEnabled = on
                                codexStore.syncProxyWithPreferences()
                                codexStore.reactivateActive()
                            }),
                        caption: "经本机代理转发请求，并在 Chat 与 Responses 之间转换协议。Codex、Claude Code 以外的 OpenAI 兼容客户端也可把 Base URL 指到下面的地址。请求日志在「流量 → 日志」；完整抓包需在供应商上开启流量记录。",
                        tint: Theme.codex)
                    Divider()
                    row("端口") {
                        TextField("15721", text: Binding(
                            get: { String(prefs.codexProxyPort) },
                            set: { v in prefs.codexProxyPort = Int(v) ?? prefs.codexProxyPort }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { codexStore.restartProxyAndReactivate() }
                    }
                    HStack(spacing: Theme.Space.s8) {
                        Circle()
                            .fill(codexStore.proxyRunning ? Theme.external : Theme.statusIdle)
                            .frame(width: 6, height: 6)
                        Text(codexStore.proxyRunning
                             ? "已启用  127.0.0.1:\(prefs.codexProxyPort)"
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
                    Divider()
                    ConnectivityProbeButton(
                        title: "检测代理",
                        help: "检测本机代理是否正在监听指定端口。",
                        outcome: tests.outcome(ConnectivityTestCenter.proxyKey),
                        tint: Theme.codex
                    ) {
                        tests.testProxy(port: prefs.codexProxyPort, running: codexStore.proxyRunning)
                    }
                    Divider()
                    ProxyCurlExample(model: proxyCurlModel)
                }

                group("连通性") {
                    VStack(alignment: .leading, spacing: Theme.Space.s6) {
                        Text("当前供应商")
                            .font(Theme.Font.body)
                            .foregroundColor(Theme.textPrimary)
                        Text(currentVendorCaption)
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.textTertiary())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ConnectivityProbeButton(
                        title: "检测 Claude Code",
                        help: "向当前 Claude Code 供应商发送一次最短 Anthropic Messages 请求。",
                        outcome: activeVendorOutcome,
                        disabled: providerStore.activeProvider == nil
                    ) {
                        guard let p = providerStore.activeProvider else { return }
                        tests.testVendor(
                            id: p.id,
                            claude: p,
                            model: p.activeModel,
                            codex: nil)
                    }
                    ConnectivityProbeButton(
                        title: "检测 Codex",
                        help: "向当前 Codex 供应商发送一次最短 Chat / Responses 请求。",
                        outcome: activeCodexOutcome,
                        tint: Theme.codex,
                        disabled: codexStore.activeProvider == nil
                    ) {
                        guard let p = codexStore.activeProvider else { return }
                        tests.testVendor(
                            id: p.id,
                            claude: p.asDisplayProvider,
                            model: p.activeModel.map { ModelConfig(id: $0.id, name: $0.name) },
                            codex: p)
                    }
                }

                group("配置文件") {
                    fileRow("~/.claude/settings.json") {
                        NSWorkspace.shared.open(FilePaths.settingsFile)
                    }
                    .disabled(!fileExists(FilePaths.settingsFile))
                    Divider()
                    fileRow("~/.claude/claude-bar-providers.json") {
                        NSWorkspace.shared.open(FilePaths.presetsFile)
                    }
                    .disabled(!fileExists(FilePaths.presetsFile))
                    Divider()
                    fileRow("~/.codex/config.toml") {
                        NSWorkspace.shared.open(FilePaths.codexConfigFile)
                    }
                    .disabled(!fileExists(FilePaths.codexConfigFile))
                    Divider()
                    fileRow("~/.codex/auth.json") {
                        NSWorkspace.shared.open(FilePaths.codexAuthFile)
                    }
                    .disabled(!fileExists(FilePaths.codexAuthFile))
                    Divider()
                    fileRow("~/.claude/claude-bar-codex-providers.json") {
                        NSWorkspace.shared.open(FilePaths.codexProvidersFile)
                    }
                    .disabled(!fileExists(FilePaths.codexProvidersFile))
                }

                group("关于") {
                    infoRow("名称", "ClaudeBar")
                    infoRow("版本", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    infoRow("构建", "swiftc · ad-hoc")
                    infoRow("系统要求", "macOS 15")
                }

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("退出 ClaudeBar")
                        .frame(maxWidth: .infinity)
                }
                .adaptiveGlassButton(prominent: true)
                .tint(Theme.statusError)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(Theme.Space.s24)
        }
        .background(Theme.base0.opacity(0.35))
    }

    // MARK: - Modules

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(title)
                .font(Theme.Font.labelSection)
                .foregroundColor(Theme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                content()
            }
            .padding(Theme.Space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.s16) {
            Text(title)
                .font(Theme.Font.body)
                .foregroundColor(Theme.textPrimary)
            Spacer(minLength: Theme.Space.s12)
            control()
        }
        .frame(minHeight: 22)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, caption: String,
                           tint: Color = Theme.claude) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(tint)
            Text(caption)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fileRow(_ path: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.s16) {
            Text(path)
                .font(Theme.Font.bodySmall)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s12)
            Button("打开", action: action)
                .adaptiveGlassButton()
                .tint(Theme.claude)
                .fixedSize()
        }
        .frame(minHeight: 22)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(Theme.Font.bodySmall)
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(Theme.Font.bodySmall)
                .monospacedDigit()
                .foregroundColor(Theme.textPrimary.opacity(0.85))
                .lineLimit(1)
        }
        .frame(minHeight: 20)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private var proxyCurlModel: String {
        codexStore.activeProvider?.activeModel?.name
            ?? providerStore.activeProvider?.activeModel?.name
            ?? ""
    }

    private var currentVendorCaption: String {
        var parts: [String] = []
        if let p = providerStore.activeProvider {
            parts.append("Claude Code：\(p.name) · \(p.activeModel?.name ?? "—")")
        }
        if let p = codexStore.activeProvider {
            parts.append("Codex：\(p.name) · \(p.activeModel?.name ?? "—")")
        }
        if parts.isEmpty {
            return "尚未激活模型。请先在「模型」页分别选择 Claude Code 与 Codex。"
        }
        return parts.joined(separator: "\n")
    }

    private var activeVendorOutcome: ConnectivityOutcome {
        guard let p = providerStore.activeProvider else { return .idle }
        if let m = p.activeModel {
            return tests.outcome(ConnectivityTestCenter.vendorModelKey(p.id, m.id))
        }
        return tests.outcome(ConnectivityTestCenter.vendorKey(p.id))
    }

    private var activeCodexOutcome: ConnectivityOutcome {
        guard let p = codexStore.activeProvider else { return .idle }
        if let m = p.activeModel {
            return tests.outcome(ConnectivityTestCenter.vendorModelKey(p.id, m.id))
        }
        return tests.outcome(ConnectivityTestCenter.vendorKey(p.id))
    }
}
