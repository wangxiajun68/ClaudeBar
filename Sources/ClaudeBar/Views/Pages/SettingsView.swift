import SwiftUI
import AppKit

/// Settings as a 宫格 of control tiles — one concern per cell, same grammar
/// as the dashboard metric grid.
struct SettingsView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject var prefs = AppPreferences.shared
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    @ObservedObject private var screenshotHotKey = ScreenshotHotKey.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                PageTitle(title: "设置")

                // First section: it is the only setting that decides whether the
                // app is running at all; the rest are grouped by module weight.
                section("启动", icon: "power") {
                    SettingTile(icon: "power", title: "开机自启",
                                caption: launchCaption) {
                        Toggle("", isOn: Binding(
                            get: { launchAtLogin.isOn },
                            // `Binding(get:set:)` rather than `$prefs.x`: the
                            // setter has to talk to SMAppService, and the value
                            // read back after that is the system's, not the
                            // one that was asked for.
                            set: { on in launchAtLogin.setEnabled(on) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Theme.claude)
                    }
                    if launchAtLogin.needsApproval {
                        SettingTile(icon: "hand.raised", title: "等待系统允许",
                                    caption: "「系统设置 → 通用 → 登录项」中允许 ClaudeBar。") {
                            Button("打开") { LaunchAtLogin.openLoginItemsSettings() }
                                .adaptiveGlassButton()
                        }
                    }
                }

                section("外观", icon: "paintpalette") {
                    SettingTile(icon: "circle.lefthalf.filled", title: "主题",
                                caption: "浅色冰面或深色石墨。") {
                        Picker("", selection: $prefs.appearance) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                        .labelsHidden()
                    }
                    SettingTile(icon: "textformat.123", title: "Token 单位",
                                caption: "用量数字的量级写法。") {
                        Picker("", selection: $prefs.tokenUnitStyle) {
                            ForEach([TokenUnitStyle.chinese, .metric], id: \.self) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                        .labelsHidden()
                    }
                }

                section("截图与通知", icon: "bell") {
                    SettingTile(icon: "camera", title: "区域截图 ⌘⇧A",
                                caption: screenshotCaption) {
                        Toggle("", isOn: $prefs.screenshotHotkeyEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Theme.claude)
                    }
                    SettingTile(icon: "bell", title: "空闲通知",
                                caption: "会话由运行转为空闲时发送系统通知。") {
                        Toggle("", isOn: $prefs.idleNotifyEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Theme.claude)
                    }
                }

                section("存储", icon: "internaldrive") {
                    SettingTile(icon: "cylinder", title: "SQLite 存储",
                                caption: prefs.databaseEnabled
                                ? "流量与用量写入 SQLite。关闭后改用 JSON，互不迁移。"
                                : "已关闭。重新开启不会自动导入。") {
                        Toggle("", isOn: $prefs.databaseEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Theme.claude)
                    }
                    SettingTile(icon: "folder", title: "日志目录",
                                caption: "~/Library/Application Support/ClaudeBar/logs") {
                        Button("打开") { NSWorkspace.shared.open(FilePaths.logsDir) }
                            .adaptiveGlassButton()
                    }
                }

                section("本地代理", icon: "network", tint: Theme.codex) {
                    SettingTile(icon: "network", title: "本地代理",
                                caption: "Claude Code 与 Codex 按「模型」页当前供应商转发。",
                                tint: Theme.codex) {
                        Toggle("", isOn: Binding(
                            get: { prefs.codexRoutingEnabled },
                            set: { on in
                                prefs.codexRoutingEnabled = on
                                codexStore.syncProxyWithPreferences()
                                codexStore.reactivateActive()
                                providerStore.reactivateActive()
                            }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Theme.codex)
                    }
                    SettingTile(icon: "waveform", title: "记录第三方流量",
                                caption: "非 CC / Codex 客户端经本地代理的请求写入「流量」页。",
                                tint: Theme.codex) {
                        Toggle("", isOn: $prefs.proxyThirdPartyTrafficEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Theme.codex)
                    }
                    SettingTile(icon: "number", title: "端口",
                                caption: proxyStatusCaption,
                                tint: Theme.codex) {
                        TextField("15721", text: Binding(
                            get: { String(prefs.codexProxyPort) },
                            set: { v in
                                // Commit on focus loss / submit, not per
                                // keystroke: the binding used to write
                                // UserDefaults on every character, so typing
                                // "15721" published 1, 15, 157, 1572, 15721
                                // and re-rendered every reader of the pref —
                                // and an intermediate value like "1" is a
                                // valid-looking port that nothing validates.
                                guard v != String(prefs.codexProxyPort),
                                      let port = Int(v), (1024...65535).contains(port) else { return }
                                prefs.codexProxyPort = port
                            }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 88)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { codexStore.restartProxyAndReactivate() }
                    }
                    SettingTile(icon: "wifi", title: "检测代理",
                                caption: "本机是否正在监听指定端口。",
                                tint: Theme.codex) {
                        ConnectivityTileButton(
                            outcome: tests.outcome(ConnectivityTestCenter.proxyKey),
                            helpIdle: "检测本机代理") {
                            tests.testProxy(port: prefs.codexProxyPort, running: codexStore.proxyRunning)
                        }
                    }
                }

                ProxyUpstreamPickers()
                    .padding(Theme.Space.s12)
                    .panelCard()

                ProxyCurlExample(model: proxyCurlModel)
                    .padding(Theme.Space.s12)
                    .panelCard()

                section("VPN 代理", icon: "globe") {
                    SettingTile(icon: "globe", title: "VPN 代理",
                                caption: "托管 mihomo 并接管系统流量。节点在「VPN」页。") {
                        Toggle("", isOn: Binding(
                            get: { prefs.vpnEnabled },
                            set: { on in
                                prefs.vpnEnabled = on
                                VpnManager.shared.syncRuntime()
                                if !on {
                                    VpnProxyGuard.shared.stop()
                                    VpnSystemProxyController.clearSystemProxyAsync()
                                }
                            }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Theme.claude)
                    }
                    SettingTile(icon: "antenna.radiowaves.left.and.right", title: vpnStatusText,
                                caption: "订阅、节点、系统代理与 TUN。") {
                        Button("打开") {
                            NotificationCenter.default.post(name: .openVPNPage, object: nil)
                        }
                        .adaptiveGlassButton()
                        .tint(Theme.claude)
                    }
                }

                section("连通性", icon: "antenna.radiowaves.left.and.right") {
                    SettingTile(icon: "cpu", title: "检测 Claude Code",
                                caption: currentCCCaption) {
                        ConnectivityTileButton(
                            outcome: activeVendorOutcome,
                            helpIdle: "向当前 Claude Code 供应商发送最短请求") {
                            guard let p = providerStore.activeProvider else { return }
                            tests.testVendor(id: p.id, claude: p, model: p.activeModel, codex: nil)
                        }
                    }
                    SettingTile(icon: "terminal", title: "检测 Codex",
                                caption: currentCodexCaption, tint: Theme.codex) {
                        ConnectivityTileButton(
                            outcome: activeCodexOutcome,
                            helpIdle: "向当前 Codex 供应商发送最短请求") {
                            guard let p = codexStore.activeProvider else { return }
                            tests.testVendor(
                                id: p.id,
                                claude: p.asDisplayProvider,
                                model: p.activeModel.map { ModelConfig(id: $0.id, name: $0.name) },
                                codex: p)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Space.s10) {
                    SectionHeader(icon: "fanblades", title: "风扇", tint: Theme.claude)
                    FanControlSection()
                        .padding(Theme.Space.s12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panelCard()
                }

                section("配置文件", icon: "doc.text") {
                    fileTile("~/.claude/settings.json", FilePaths.settingsFile)
                    fileTile("~/.claude/claude-bar-providers.json", FilePaths.presetsFile)
                    fileTile("~/.codex/config.toml", FilePaths.codexConfigFile)
                    fileTile("~/.codex/auth.json", FilePaths.codexAuthFile)
                    fileTile("~/.claude/claude-bar-codex-providers.json", FilePaths.codexProvidersFile)
                }

                section("关于", icon: "info.circle") {
                    SettingTile(icon: "app", title: "ClaudeBar",
                                caption: "macOS 15 · swiftc") {
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                            .font(Theme.Font.captionMono)
                            .foregroundColor(Theme.textSecondary)
                    }
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
            .padding(Theme.Space.s24)
        }
        .background(Theme.bgPrimary)
    }

    private func section<C: View>(_ title: String, icon: String, tint: Color = Theme.claude,
                                  @ViewBuilder content: @escaping () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s10) {
            SectionHeader(icon: icon, title: title, tint: tint)
            TileGrid(.pageSetting) { content() }
        }
    }

    /// Existence is measured once per render pass, not once per tile.
    ///
    /// `fileTile` used to call `fileExists` inline in its body, so five
    /// synchronous `stat`s ran on the main thread every time this page
    /// re-evaluated — and the page observes four observable objects, so that
    /// is often. One `contentsOfDirectory` over the two directories covers all
    /// five paths (and is what makes the state refreshable when a file appears
    /// or is deleted while the page is open).
    private static func existingFileNames() -> Set<String> {
        var names = Set<String>()
        let fm = FileManager.default
        for dir in [FilePaths.claudeDir, FilePaths.codexDir] {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            names.formUnion(entries)
        }
        return names
    }

    private var presentFiles: Set<String> { Self.existingFileNames() }

    private func fileTile(_ path: String, _ url: URL) -> some View {
        let name = (path as NSString).lastPathComponent
        return SettingTile(icon: "doc", title: name, caption: path) {
            Button("打开") { NSWorkspace.shared.open(url) }
                .adaptiveGlassButton()
                .disabled(!presentFiles.contains(name))
        }
    }

    private var screenshotCaption: String {
        if let err = screenshotHotKey.lastError, prefs.screenshotHotkeyEnabled {
            return err + "。关闭占用该键的截图软件后，重新打开此开关。"
        }
        if prefs.screenshotHotkeyEnabled && screenshotHotKey.isRegistered {
            return "热键已注册。首次使用需允许屏幕录制。"
        }
        return "全局拉框截图并复制到剪贴板。"
    }

    /// The login item's own state is the caption — there is no remembered
    /// preference to fall back on (see `LaunchAtLogin`), so whatever the system
    /// reports is what gets said. An ad-hoc-signed build reporting `.notFound`
    /// has to read as a failure, not as "on".
    private var launchCaption: String {
        if let err = launchAtLogin.lastError { return err }
        if launchAtLogin.isOn { return "登录时自动启动。可在「系统设置 → 通用 → 登录项」更改。" }
        return "登录时自动启动 ClaudeBar。"
    }

    private var proxyCurlModel: String {
        codexStore.resolvedThirdPartyOpenAI()?.activeModel?.name
            ?? codexStore.activeProvider?.activeModel?.name
            ?? providerStore.activeProvider?.activeModel?.name
            ?? ""
    }

    private var proxyStatusCaption: String {
        ProxyUpstreamPickers.statusLine(
            codex: codexStore.activeProvider,
            claude: providerStore.activeProvider,
            thirdOpenAI: codexStore.resolvedThirdPartyOpenAI(),
            thirdAnthropic: codexStore.resolvedThirdPartyAnthropic(),
            running: codexStore.proxyRunning,
            port: prefs.codexProxyPort)
    }

    private var vpnStatusText: String {
        switch VpnManager.shared.state {
        case .idle: return "VPN 未启用"
        case .missingCore: return "缺少内核"
        case .starting: return "内核启动中"
        case .running: return "VPN 运行中"
        case .failed: return "VPN 异常"
        }
    }

    private var currentCCCaption: String {
        if let p = providerStore.activeProvider {
            return "\(p.name) · \(p.activeModel?.name ?? "—")"
        }
        return "尚未激活 Claude Code 模型"
    }

    private var currentCodexCaption: String {
        if let p = codexStore.activeProvider {
            return "\(p.name) · \(p.activeModel?.name ?? "—")"
        }
        return "尚未激活 Codex 模型"
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

/// One settings control: icon + title + caption, control in the top trailing slot.
struct SettingTile<Control: View>: View {
    let icon: String
    let title: String
    var caption: String = ""
    var tint: Color = Theme.claude
    @ViewBuilder var control: () -> Control
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                GlyphWell(name: icon, tint: tint, size: 28, engaged: hovered)
                Spacer(minLength: 4)
                control()
                    .controlSize(.small)
            }
            .frame(height: 32)
            Text(title)
                .font(Theme.Font.chromeEmph)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Text(caption.isEmpty ? " " : caption)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(3)
                .frame(minHeight: 42, alignment: .topLeading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(hovered: hovered)
        .hoverState($hovered)
    }
}
