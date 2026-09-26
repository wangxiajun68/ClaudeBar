import SwiftUI
import AppKit

/// Settings as a 宫格 of control tiles — one concern per cell, same grammar
/// as the dashboard metric grid.
struct SettingsView: View {
    @ProviderState(.configuration) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject var prefs = AppPreferences.shared
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    @Bindable private var batteryController = BatteryChargeController.shared
    /// Read by the VPN tile's title. Without observing it the title only
    /// refreshed when something *else* invalidated the page, so a core that
    /// finished starting (or failed) while this page was open kept its old
    /// label — 「内核启动中」 forever, or 「VPN 未启用」 over a crashed core.
    @ObservedObject private var vpn = VpnManager.shared

    @State private var presentFiles: Set<URL> = []
    /// Which resume terminals are installed, refreshed by the same 5 s scan as
    /// `presentFiles`. `ResumeTerminal.isInstalled` is a LaunchServices lookup
    /// (`urlForApplication`) plus a file stat, and the Picker asked for all four
    /// on every body pass — seven such probes per pass once the caption's
    /// `resolved` chain is counted.
    @State private var installedTerminals: Set<ResumeTerminal> = []
    @State private var codexPortDraft = ""
    @FocusState private var codexPortFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s24) {
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

                PermissionsSection()

                section("电池管理授权", icon: "battery.100percent") {
                    SettingTile(icon: "lock.shield", title: "授权电池管理",
                                caption: batteryController.lastError ?? (batteryController.helperInstalled
                                    ? "已授权。日常启动和重启应用无需重复授权；仅辅助工具代码更新时需重新授权。"
                                    : "一次管理员授权，安装本机电池辅助工具；之后启动充电管理自动复用。")) {
                        Button(batteryController.authorizingHelper ? "授权中…" : (batteryController.helperInstalled ? "已授权" : "立即授权")) {
                            batteryController.authorizeHelper()
                        }
                        .adaptiveGlassButton()
                        .disabled(batteryController.authorizingHelper || batteryController.pending || batteryController.helperInstalled)
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

                section("模型花费", icon: "banknote") {
                    SettingTile(icon: "yensign.circle", title: "显示货币",
                                caption: costDisplayCaption) {
                        Picker("", selection: $prefs.costDisplay) {
                            ForEach(CostDisplay.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        .labelsHidden()
                    }
                    // Only rendered once a conversion is actually asked for —
                    // in 分列 mode there is no rate, so a tile about one would
                    // be a control with nothing behind it.
                    if prefs.costDisplay.needsRate {
                        ExchangeRateTile()
                    }
                }

                section("继续会话", icon: "terminal") {
                    SettingTile(icon: "arrow.uturn.forward", title: "打开方式",
                                caption: resumeTerminalCaption) {
                        Picker("", selection: $prefs.resumeTerminal) {
                            ForEach(ResumeTerminal.allCases) { terminal in
                                Text(installedTerminals.contains(terminal) ? terminal.label
                                     : "\(terminal.label)（未安装）")
                                    .tag(terminal)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                        .labelsHidden()
                    }
                }

                section("灵动岛", icon: "capsule.portrait") {
                    SettingTile(icon: "capsule", title: "刘海灵动岛",
                                caption: "鼠标移到刘海展开：运行中的会话、当前路由与近 30 天用量；无刘海的屏幕在菜单栏中央显示。") {
                        Toggle("", isOn: $prefs.notchIslandEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Theme.claude)
                    }
                    SettingTile(icon: "waveform", title: "两翼",
                                caption: "收起时在刘海两侧显示运行中的会话与今日用量，会遮住紧贴刘海的菜单栏图标。") {
                        Toggle("", isOn: $prefs.notchIslandShowsWings)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Theme.claude)
                    }
                    .disabled(!prefs.notchIslandEnabled)
                    SettingTile(icon: "checkmark.bubble", title: "完成提醒",
                                caption: "会话结束时从刘海弹出提醒，可一键回到该会话；悬停暂停，6 秒后自动收起。不需要通知权限。") {
                        Toggle("", isOn: $prefs.notchIslandAlertsEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Theme.claude)
                    }
                    .disabled(!prefs.notchIslandEnabled)
                    SettingTile(icon: "arrow.up.left.and.arrow.down.right", title: "全屏应用中显示",
                                caption: "关闭时，全屏应用所在的空间不显示灵动岛。") {
                        Toggle("", isOn: $prefs.notchIslandInFullScreen)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Theme.claude)
                    }
                    .disabled(!prefs.notchIslandEnabled)
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
                        // A draft + commit, the same shape `VPNView` uses for
                        // its mixed port. The old `Binding(get:set:)` claimed to
                        // "commit on focus loss / submit" but a SwiftUI
                        // `TextField` calls `set` on every keystroke, so it
                        // wrote UserDefaults mid-typing (a 4-digit prefix is a
                        // valid-looking port), and nothing restarted the proxy
                        // on focus loss — only Return did. Typing a new port and
                        // clicking away therefore left every *description* of
                        // the proxy (this caption, the 第三方接入 base URL, the
                        // curl snippet, the help text) advertising a port the
                        // listener was not on.
                        TextField("15721", text: $codexPortDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 88)
                            .multilineTextAlignment(.trailing)
                            .focused($codexPortFocused)
                            .onSubmit { commitCodexPort() }
                            .onChange(of: codexPortFocused) { _, on in
                                if !on { commitCodexPort() }
                            }
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

                // Same grammar as every other settings section: a header plus
                // the tile grid. These two used to be bare `panelCard()` panels
                // holding full-width rows, which made the proxy block read as a
                // list inside a page of cards.
                VStack(alignment: .leading, spacing: Theme.Space.s10) {
                    SectionHeader(icon: "arrow.triangle.branch", title: "代理上游", tint: Theme.codex)
                    ProxyUpstreamPickers()
                }

                VStack(alignment: .leading, spacing: Theme.Space.s10) {
                    SectionHeader(icon: "curlybraces", title: "第三方接入", tint: Theme.codex)
                    TileGrid(.pageSetting) {
                        SettingTile(icon: "link", title: "Base URL",
                                    caption: LocalProxyAddress.openaiRoot,
                                    tint: Theme.codex) {
                            Button("复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(LocalProxyAddress.openaiRoot, forType: .string)
                            }
                            .adaptiveGlassButton()
                        }
                        SettingTile(icon: "key.horizontal", title: "鉴权",
                                    caption: "代理注入密钥，不再接受任意 Bearer。",
                                    tint: Theme.codex) {
                            Text("令牌")
                                .font(Theme.Font.caption)
                                .foregroundColor(Theme.textSecondary)
                        }
                        ProxyCurlExample(model: proxyCurlModel)
                    }
                }

                section("VPN 代理", icon: "globe") {
                    SettingTile(icon: "globe", title: "VPN 代理",
                                caption: "托管 mihomo 并接管系统流量。节点在「VPN」页。") {
                        Toggle("", isOn: Binding(
                            get: { prefs.vpnEnabled },
                            set: { on in
                                prefs.vpnEnabled = on
                                // Turning it on has to ask for the system proxy
                                // too, the way every other entry point does
                                // (VPN 页的「启动」、订阅自动启动、popup 的
                                // VPN chip), and the way this tile's own caption
                                // promises ("接管系统流量"). `waitUntilReady`
                                // applies it only `if vpnSystemProxyEnabled`, so
                                // without this line a user who enabled the VPN
                                // from Settings got a running mihomo and no
                                // takeover at all.
                                if on {
                                    prefs.vpnSystemProxyEnabled = true
                                    VpnManager.shared.syncRuntime()
                                } else {
                                    VpnManager.shared.syncRuntime()
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
                            NotificationCenter.default.post(.showMainWindow(page: .vpn))
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
                            helpIdle: providerStore.activeProvider == nil
                                ? "先在「模型」页激活一个供应商" : "向当前 Claude Code 供应商发送最短请求") {
                            guard let p = providerStore.activeProvider else { return }
                            tests.testVendor(id: p.id, claude: p, model: p.activeModel, codex: nil)
                        }
                        .disabled(providerStore.activeProvider == nil)
                    }
                    SettingTile(icon: "terminal", title: "检测 Codex",
                                caption: currentCodexCaption, tint: Theme.codex) {
                        ConnectivityTileButton(
                            outcome: activeCodexOutcome,
                            helpIdle: codexStore.activeProvider == nil
                                ? "先在「模型」页激活一个 Codex 供应商" : "向当前 Codex 供应商发送最短请求") {
                            guard let p = codexStore.activeProvider else { return }
                            tests.testVendor(
                                id: p.id,
                                claude: p.asDisplayProvider,
                                model: p.activeModel.map { ModelConfig(id: $0.id, name: $0.name) },
                                codex: p)
                        }
                        .disabled(codexStore.activeProvider == nil)
                    }
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
        .onAppear {
            codexPortDraft = String(prefs.codexProxyPort)
            installedTerminals = Set(ResumeTerminal.allCases.filter(\.isInstalled))
        }
        // Keep the draft honest when the value is changed from elsewhere (the
        // popup's upstream pickers, a preset import) — but never while the user
        // is editing it, or a stray publish would overwrite what they typed.
        .onChange(of: prefs.codexProxyPort) { _, port in
            if !codexPortFocused { codexPortDraft = String(port) }
        }
        .task {
            while !Task.isCancelled {
                if UIWakePolicy.hasVisibleMainWindow {
                    let files = await Task.detached(priority: .utility) { Self.existingFiles() }.value
                    guard !Task.isCancelled else { return }
                    if files != presentFiles { presentFiles = files }
                    let terminals = Set(ResumeTerminal.allCases.filter(\.isInstalled))
                    if terminals != installedTerminals { installedTerminals = terminals }
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task { await batteryController.refreshHelperAuthorization() }
    }

    /// Validate and apply the port draft — on Return and on focus loss, which
    /// is what the old comment claimed the binding did. The proxy is restarted
    /// only when the value actually changed, so tabbing through the field is
    /// free.
    private func commitCodexPort() {
        let digits = codexPortDraft.filter(\.isNumber)
        guard let port = Int(digits), (1024...65535).contains(port) else {
            codexPortDraft = String(prefs.codexProxyPort)
            return
        }
        codexPortDraft = String(port)
        guard port != prefs.codexProxyPort else { return }
        prefs.codexProxyPort = port
        codexStore.restartProxyAndReactivate()
    }

    private func section<C: View>(_ title: String, icon: String, tint: Color = Theme.claude,
                                  @ViewBuilder content: @escaping () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s10) {
            SectionHeader(icon: icon, title: title, tint: tint)
            TileGrid(.pageSetting) { content() }
        }
    }

    /// Scan off-main once per refresh, never from a tile's body evaluation.
    nonisolated private static func existingFiles() -> Set<URL> {
        var files = Set<URL>()
        for dir in [FilePaths.claudeDir, FilePaths.codexDir] {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            files.formUnion(entries)
        }
        return files
    }

    private func fileTile(_ path: String, _ url: URL) -> some View {
        let name = (path as NSString).lastPathComponent
        return SettingTile(icon: "doc", title: name, caption: path) {
            Button("打开") { NSWorkspace.shared.open(url) }
                .adaptiveGlassButton()
                .disabled(!presentFiles.contains(url))
        }
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

    /// Says what the choice costs the user, not just what it does. The default
    /// is the only one that makes no outbound request, and the converted modes
    /// are the only reason this app ever fetches an exchange rate — worth
    /// stating where the switch is.
    private var costDisplayCaption: String {
        switch prefs.costDisplay {
        case .split:
            return "人民币与美元分列，不做换算，也不联网查汇率。"
        case .cny, .usd:
            if let note = ExchangeRate.shared.note { return "按 \(note) 折算成一个数字。" }
            return "按实时汇率折算成一个数字，需要联网查询。"
        }
    }

    private var proxyCurlModel: String {        codexStore.resolvedThirdPartyOpenAI()?.activeModel?.name
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

    /// Resolved against the cached install set, not a fresh LaunchServices
    /// probe per body pass.
    private var resumeTerminalCaption: String {
        switch prefs.resumeTerminal.resolved(installed: installedTerminals) {
        case .otty, .automatic:
            return "Otty：会话已在某个标签页运行时直接切过去，否则新开标签页 resume。无需自动化权限。"
        case .warp:
            return "Warp：在会话目录新开窗口并执行 resume；需开启“权限与隐私 → 在终端继续会话”。"
        case .terminal:
            return "终端：新开窗口执行 resume；需开启“权限与隐私 → 在终端继续会话”。"
        }
    }

    private var vpnStatusText: String {
        switch vpn.state {
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
///
/// The surface is the shared tile (`tint` drives the wash, the corner lens and
/// the hover edge), because a settings page of bespoke "circle behind a card"
/// panels read as a different family from every other grid in the app. The
/// `GlyphWell` beside the title is the card's mark; the lens is the depth
/// behind it, drawn in the same hue and carrying no glyph of its own.
struct SettingTile<Control: View>: View {
    let icon: String
    let title: String
    var caption: String = ""
    var tint: Color = Theme.claude
    @ViewBuilder var control: () -> Control
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                GlyphWell(name: icon, tint: tint, size: 36, engaged: hovered)
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                control()
                    .controlSize(.small)
            }
            .frame(height: 40)
            Text(caption.isEmpty ? " " : caption)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(3)
                .frame(minHeight: 42, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(tint: tint, hovered: hovered,
              lens: DepthLensSpec(tint: tint, size: 124))
        .hoverState($hovered)
    }
}
