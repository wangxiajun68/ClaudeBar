import SwiftUI
import AppKit

/// Task-oriented categories replace the previous wall of unrelated tiles.
struct SettingsView: View {
    @ProviderState(.configuration) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject var prefs = AppPreferences.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var category: SettingsCategory = .general
    @State private var installedTerminals: Set<ResumeTerminal> = []
    @State private var codexPortDraft = ""
    @State private var portError: String?
    @State private var weatherCityDraft = ""
    @State private var amapKeyDraft = ""
    /// What the last committed key was, so the row can tell "unchanged" from
    /// "edited but not saved". A separate `@State` rather than `prefs.amapAPIKey`
    /// because the commit itself moves the pref — the confirmation has to
    /// survive that.
    @State private var amapKeySaved = ""
    @State private var showProxyAdvanced = false
    @FocusState private var codexPortFocused: Bool
    @FocusState private var weatherCityFocused: Bool
    @FocusState private var amapKeyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text("设置")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Picker("设置分类", selection: $category) {
                    ForEach(SettingsCategory.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch category {
                    case .general: generalSettings
                    case .island: islandSettings
                    case .privacy: PermissionsSection()
                    case .proxy: proxySettings
                    }
                    footer
                }
                .frame(maxWidth: 800, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollHoverGate()
            .id(category)
        }
        .background(Theme.bgPrimary)
        .onAppear {
            codexPortDraft = String(prefs.codexProxyPort)
            weatherCityDraft = prefs.weatherCity
            amapKeyDraft = prefs.amapAPIKey
            amapKeySaved = prefs.amapAPIKey
            refreshInstalledTerminals()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshInstalledTerminals() }
        }
        .onChange(of: prefs.codexProxyPort) { _, port in
            if !codexPortFocused { codexPortDraft = String(port) }
        }
        .onChange(of: prefs.weatherCity) { _, city in
            if !weatherCityFocused { weatherCityDraft = city }
        }
        .onChange(of: prefs.amapAPIKey) { _, key in
            if !amapKeyFocused { amapKeyDraft = key }
        }
        // Switching categories can remove a focused field before its blur
        // callback. Commit drafts explicitly at this boundary as well.
        .onChange(of: category) { old, _ in
            if old == .general { commitWeatherCity(); commitAmapKey() }
            if old == .proxy { commitCodexPort() }
        }
    }

    private var generalSettings: some View {
        VStack(spacing: 24) {
            SettingsGroup(title: "基本设置") {
                SettingsRow(title: "外观") {
                    Picker("外观", selection: $prefs.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsDivider()
                SettingsToggleRow(title: "登录时启动", caption: launchAtLogin.lastError ?? "登录 Mac 后自动运行 ClaudeBar。",
                                  isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.setEnabled($0) }))
                if launchAtLogin.needsApproval {
                    SettingsDivider()
                    SettingsRow(title: "允许后台启动", caption: "请在系统的「登录项」中允许 ClaudeBar。") {
                        ActionButton("打开登录项", tone: .neutral) { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
                SettingsDivider()
                SettingsRow(title: "继续会话的终端", caption: resumeTerminalCaption) {
                    Picker("继续会话的终端", selection: $prefs.resumeTerminal) {
                        ForEach(ResumeTerminal.allCases) { terminal in
                            Text(installedTerminals.contains(terminal) ? terminal.label : "\(terminal.label)（未安装）")
                                .tag(terminal)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            SettingsGroup(title: "用量与花费") {
                SettingsRow(title: "Token 单位") {
                    Picker("Token 单位", selection: $prefs.tokenUnitStyle) {
                        Text(TokenUnitStyle.chinese.label).tag(TokenUnitStyle.chinese)
                        Text(TokenUnitStyle.metric.label).tag(TokenUnitStyle.metric)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsDivider()
                SettingsRow(title: "显示货币", caption: prefs.costDisplay.needsRate ? "按汇率换算；可在下方设置手动汇率。" : "保留人民币与美元原始金额。") {
                    Picker("显示货币", selection: $prefs.costDisplay) {
                        ForEach(CostDisplay.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                if prefs.costDisplay.needsRate {
                    SettingsDivider()
                    ExchangeRateTile()
                }
            }

            SettingsGroup(title: "天气与问候") {
                SettingsToggleRow(
                    title: "天气渲染",
                    caption: "开着：天空按实时天气画云、雨雪、雾与闪电。关掉：只留一片按太阳高度角变化的天空贴图，不再画天气，也不再联网取天气。",
                    isOn: $prefs.greetingWeatherRendering)
                SettingsDivider()
                SettingsRow(title: "天气城市", caption: "未使用当前位置时生效，留空则不显示城市天气。") {
                    TextField("输入城市", text: $weatherCityDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .focused($weatherCityFocused)
                        .accessibilityLabel("天气城市")
                        .onSubmit { commitWeatherCity() }
                        .onChange(of: weatherCityFocused) { _, focused in
                            if !focused { commitWeatherCity() }
                        }
                }
                SettingsDivider()
                SettingsRow(title: "高德 Key", caption: "填写后走高德天气（仅大陆城市）；留空自动改用中国天气网，无需申请。") {
                    HStack(spacing: 8) {
                        SecureField("高德 Web 服务 Key", text: $amapKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .focused($amapKeyFocused)
                            .accessibilityLabel("高德 Key")
                            .onSubmit { commitAmapKey() }
                        // A key is a credential: an explicit save, inside the row,
                        // with the row itself saying whether it took. The other
                        // text fields here still commit on blur — a city name is
                        // cheap to retype, a pasted key is not, and a blur-commit
                        // gives no confirmation that the secret was stored.
                        ActionButton("保存", size: .regular) { commitAmapKey() }
                            .disabled(!amapKeyEdited)
                            // `ActionButton` draws its own plate, so `.disabled`
                            // alone would leave it looking pressable while doing
                            // nothing — dim it explicitly.
                            .opacity(amapKeyEdited ? 1 : 0.45)
                        if amapKeyEdited {
                            Text("未保存")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Ink.warning)
                                .accessibilityLabel("高德 Key 有未保存的修改")
                        } else if amapKeyDraft == amapKeySaved && !amapKeyDraft.isEmpty {
                            Text("已保存")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Ink.success)
                                .accessibilityLabel("高德 Key 已保存")
                        }
                    }
                }
                SettingsDivider()
                SettingsRow(title: "问候字体") {
                    Picker("问候字体", selection: $prefs.greetingTypeface) {
                        ForEach(GreetingTypeface.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
        }
    }

    private var islandSettings: some View {
        VStack(spacing: 24) {
            SettingsGroup(title: "灵动岛", caption: "移到屏幕顶部的刘海，查看会话和用量。") {
                SettingsToggleRow(title: "启用灵动岛", isOn: $prefs.notchIslandEnabled)
            }
            if prefs.notchIslandEnabled {
                SettingsGroup(title: "显示与提醒") {
                    SettingsToggleRow(title: "收起时显示两翼", caption: "在刘海两侧显示运行会话和今日用量。", isOn: $prefs.notchIslandShowsWings)
                    SettingsDivider()
                    SettingsToggleRow(title: "会话完成时提醒", caption: "从刘海展开提示，6 秒后自动收起。", isOn: $prefs.notchIslandAlertsEnabled)
                    SettingsDivider()
                    SettingsToggleRow(title: "全屏时显示", isOn: $prefs.notchIslandInFullScreen)
                }
            }
        }
    }

    private var proxySettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "本地代理", caption: "Claude Code 与 Codex 的供应商在「模型」页选择。") {
                SettingsToggleRow(title: "启用本地代理", caption: "在本机转发模型请求。", isOn: Binding(
                    get: { prefs.codexRoutingEnabled },
                    set: { on in
                        prefs.codexRoutingEnabled = on
                        codexStore.syncProxyWithPreferences()
                        codexStore.reactivateActive()
                        providerStore.reactivateActive()
                    }))
                if prefs.codexRoutingEnabled {
                    SettingsDivider()
                    SettingsRow(title: "监听端口", caption: codexStore.proxyRunning ? "正在监听 127.0.0.1:\(prefs.codexProxyPort)" : "代理尚未开始监听。") {
                        TextField("15721", text: $codexPortDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .monospacedDigit()
                            .focused($codexPortFocused)
                            .accessibilityLabel("本地代理监听端口")
                            .onSubmit { commitCodexPort() }
                            .onChange(of: codexPortFocused) { _, focused in
                                if !focused { commitCodexPort() }
                            }
                    }
                    if let portError {
                        Text(portError)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Ink.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)
                    }
                }
            }

            if prefs.codexRoutingEnabled {
                DisclosureGroup("第三方接入", isExpanded: $showProxyAdvanced) {
                    VStack(alignment: .leading, spacing: 24) {
                        SettingsGroup(title: "客户端连接") {
                            SettingsRow(title: "Base URL", caption: LocalProxyAddress.openaiRoot) {
                                ActionButton("复制地址", tone: .neutral) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(LocalProxyAddress.openaiRoot, forType: .string)
                                }
                            }
                            SettingsDivider()
                            ProxyCurlExample(model: proxyCurlModel)
                            SettingsDivider()
                            SettingsToggleRow(title: "记录第三方流量", caption: "第三方客户端的请求将显示在「流量」页。", isOn: $prefs.proxyThirdPartyTrafficEnabled)
                        }
                        SettingsGroup(title: "第三方供应商", caption: "仅影响第三方客户端，不改变 Claude Code 或 Codex 的配置。") {
                            ProxyUpstreamPickers()
                        }
                    }
                    .padding(.top, 16)
                }
                .font(.system(size: 13, weight: .medium))
                .tint(Theme.textSecondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("ClaudeBar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("打开日志") { NSWorkspace.shared.open(FilePaths.logsDir) }
            Button("帮助") { NotificationCenter.default.post(.showMainWindow(page: .help)) }
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
        .padding(.top, 4)
        .padding(.horizontal, 4)
    }

    private func commitCodexPort() {
        let trimmed = codexPortDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1024...65535).contains(port) else {
            portError = "请输入 1024–65535 之间的端口；当前端口仍为 \(prefs.codexProxyPort)。"
            return
        }
        portError = nil
        codexPortDraft = String(port)
        guard port != prefs.codexProxyPort else { return }
        prefs.codexProxyPort = port
        codexStore.restartProxyAndReactivate()
    }

    private func commitWeatherCity() {
        let city = weatherCityDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        weatherCityDraft = city
        guard city != prefs.weatherCity else { return }
        prefs.weatherCity = city
    }

    private func commitAmapKey() {
        let key = amapKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        amapKeyDraft = key
        amapKeySaved = key
        amapKeyFocused = false
        guard key != prefs.amapAPIKey else { return }
        prefs.amapAPIKey = key
        WeatherStore.shared.refresh()
    }

    /// Whether the row's draft differs from what is stored — what the Save
    /// button's enabled state and the 已保存／未保存 caption both read.
    private var amapKeyEdited: Bool { amapKeyDraft != prefs.amapAPIKey }

    private func refreshInstalledTerminals() {
        installedTerminals = Set(ResumeTerminal.allCases.filter(\.isInstalled))
    }

    private var resumeTerminalCaption: String {
        switch prefs.resumeTerminal.resolved(installed: installedTerminals) {
        case .otty, .automatic: return "优先切换到已打开的会话。"
        case .warp, .terminal: return "自动执行继续命令需开启「权限与隐私 → 在终端继续会话」。"
        }
    }

    private var proxyCurlModel: String {
        codexStore.resolvedThirdPartyOpenAI()?.activeModel?.name
            ?? codexStore.activeProvider?.activeModel?.name
            ?? providerStore.activeProvider?.activeModel?.name
            ?? ""
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "通用"
    case appearance = "外观与天气"
    case island = "灵动岛"
    case usage = "用量与计费"
    case privacy = "权限与隐私"
    case proxy = "本地代理"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .appearance: return "sun.max"
        case .island: return "rectangle.topthird.inset.filled"
        case .usage: return "chart.bar.xaxis"
        case .privacy: return "hand.raised"
        case .proxy: return "point.3.connected.trianglepath.dotted"
        }
    }
    var caption: String {
        switch self {
        case .general: return "从启动到继续会话，按你的工作习惯运行。"
        case .appearance: return "选择界面配色，让天空与问候成为自己的风景。"
        case .island: return "将会话进展与用量，留在屏幕顶部。"
        case .usage: return "统一数字的读法，明确每一笔花费的估算依据。"
        case .privacy: return "每项访问都有用途，系统授权由你掌握。"
        case .proxy: return "管理本机模型请求转发，以及第三方客户端接入。"
        }
    }
}

/// Owned by the window shell above its appearance identity boundary. Switching
/// palette must not erase navigation or submit/discard explicit drafts.
@MainActor final class SettingsState: ObservableObject {
    @Published var category: SettingsCategory = .general
    @Published var codexPortDraft = ""
    @Published var portError: String?
    @Published var weatherCityDraft = ""
    @Published var amapKeyDraft = ""
    @Published var amapKeySaved = ""
    @Published var showProxyAdvanced = false
    @Published var showWeatherAdvanced = false
    var initialized = false
}
