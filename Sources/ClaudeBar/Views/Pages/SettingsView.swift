import SwiftUI
import AppKit

/// Task-oriented categories replace the previous wall of unrelated tiles.
struct SettingsView: View {
    @ProviderState(.configuration) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject var prefs = AppPreferences.shared
    @ObservedObject private var permissions = PermissionCenter.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var state = SettingsState()
    @State private var installedTerminals: Set<ResumeTerminal> = []
    @FocusState private var codexPortFocused: Bool
    @FocusState private var weatherCityFocused: Bool
    @FocusState private var amapKeyFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 860 {
                    navigation
                        .frame(width: 200)
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                }
                VStack(spacing: 0) {
                    if geometry.size.width < 860 { compactNavigation }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            categoryHeader
                            switch state.category {
                            case .general: generalSettings
                            case .appearance: appearanceSettings
                            case .usage: usageSettings
                            case .island: islandSettings
                            case .privacy: PermissionsSection()
                            case .proxy: proxySettings
                            }
                        }
                        .frame(maxWidth: 900, alignment: .leading)
                        .padding(geometry.size.width >= 860 ? 32 : 24)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollHoverGate()
                    .id(state.category)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bgPrimary)
        .onAppear {
            if !state.initialized {
                state.codexPortDraft = String(prefs.codexProxyPort)
                state.weatherCityDraft = prefs.weatherCity
                state.amapKeyDraft = prefs.amapAPIKey
                state.amapKeySaved = prefs.amapAPIKey
                state.initialized = true
            }
            refreshInstalledTerminals()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshInstalledTerminals() }
        }
        .onChange(of: prefs.codexProxyPort) { _, port in
            if !codexPortFocused { state.codexPortDraft = String(port) }
        }
        .onChange(of: prefs.weatherCity) { _, city in
            if !weatherCityFocused { state.weatherCityDraft = city }
        }
        .onChange(of: state.category) { old, _ in
            if old == .appearance { commitWeatherCity() }
            // Port and credential drafts require their explicit action.
        }
        .onChange(of: prefs.amapAPIKey) { _, key in
            if !amapKeyFocused { state.amapKeyDraft = key }
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                AppGlyph(name: "slider.horizontal.3", size: 23).foregroundColor(Theme.Ink.claude)
                Text("设置").font(.system(size: 23, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 12).padding(.top, 8)
            VStack(spacing: 5) {
                ForEach(SettingsCategory.allCases) { item in
                    Button { state.category = item } label: {
                        HStack(spacing: 12) {
                            AppGlyph(name: item.symbol, size: 17)
                                .foregroundColor(state.category == item ? Theme.Ink.claude : Theme.textSecondary)
                                .frame(width: 22)
                            Text(item.rawValue).font(.system(size: 13, weight: state.category == item ? .semibold : .medium))
                            Spacer(minLength: 0)
                            if state.category == item {
                                Circle().fill(Theme.Ink.claude).frame(width: 4, height: 4)
                            }
                        }
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(state.category == item ? Theme.cardSurface : .clear, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(state.category == item ? Theme.hairline : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(state.category == item ? .isSelected : [])
                }
            }
            Spacer()
            footer
        }
        .padding(16)
        .background(Theme.bgSecondary.opacity(0.45))
    }

    private var compactNavigation: some View {
        HStack {
            Text("设置").font(.system(size: 18, weight: .semibold, design: .rounded))
            Spacer()
            Menu {
                ForEach(SettingsCategory.allCases) { item in
                    Button { state.category = item } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                    }
                }
            } label: { InstrumentMenuLabel(title: state.category.rawValue) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("设置分类")
            Button { NotificationCenter.default.post(.showMainWindow(page: .help)) } label: {
                AppGlyph(name: "questionmark.circle", size: 16)
            }.buttonStyle(.plain).help("帮助")
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var categoryHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.category.rawValue)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(state.category.caption)
                    .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            AppGlyph(name: state.category.symbol, size: 34)
                .foregroundColor(Theme.Ink.claude)
                .frame(width: 68, height: 68)
                .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.hairline))
                .accessibilityHidden(true)
        }
        .padding(.bottom, 4)
    }

    private var generalSettings: some View {
        VStack(spacing: 24) {
            SettingsGroup(title: "启动与会话", symbol: "terminal") {
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
                    Menu {
                        ForEach(ResumeTerminal.allCases) { terminal in
                            Button { prefs.resumeTerminal = terminal } label: {
                                Text(installedTerminals.contains(terminal) ? terminal.label : "\(terminal.label)（未安装）")
                            }
                        }
                    } label: { InstrumentMenuLabel(title: prefs.resumeTerminal.label) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .accessibilityLabel("继续会话的终端")
                }
            }

        }
    }

    private var usageSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "显示与换算", symbol: "chart.bar.xaxis") {
                SettingsRow(title: "Token 单位") {
                    SegmentedCapsule(items: [TokenUnitStyle.chinese, .metric], selection: prefs.tokenUnitStyle,
                                     title: { $0.label }, onSelect: { prefs.tokenUnitStyle = $0 })
                }
                SettingsDivider()
                SettingsRow(title: "显示货币", caption: prefs.costDisplay.needsRate ? "按汇率换算；可在下方设置手动汇率。" : "保留人民币与美元原始金额。") {
                    SegmentedCapsule(items: CostDisplay.allCases, selection: prefs.costDisplay,
                                     title: { $0.label }, onSelect: { prefs.costDisplay = $0 })
                }
                if prefs.costDisplay.needsRate {
                    SettingsDivider()
                    ExchangeRateTile()
                }
            }

            ModelPriceCard()
                .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))

        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "界面外观", symbol: "circle.lefthalf.filled") {
                SettingsRow(title: "配色", caption: "浅冰色与石墨色，两套完整界面。") {
                    SegmentedCapsule(items: AppearanceMode.allCases, selection: prefs.appearance,
                                     title: { $0.label }, symbol: { $0 == .light ? "sun.max" : "moon" },
                                     onSelect: { prefs.appearance = $0 })
                }
            }
            SettingsGroup(title: "天气与问候", symbol: "cloud.sun") {
                SettingsToggleRow(
                    title: "天气渲染",
                    caption: "天空随实时天气变化；关闭后保留日照天空，停止天气查询。",
                    isOn: $prefs.greetingWeatherRendering)
                SettingsDivider()
                SettingsRow(title: "天气城市", caption: permissions.isEnabled(.currentLocation) ? "备用城市：当前位置不可用时使用。" : "留空则不显示城市天气；回车或离开输入框时保存。") {
                    TextField("输入城市", text: $state.weatherCityDraft)
                        .textFieldStyle(InstrumentFieldStyle())
                        .frame(width: 180)
                        .focused($weatherCityFocused)
                        .accessibilityLabel("天气城市")
                        .disabled(!prefs.greetingWeatherRendering)
                        .onSubmit { commitWeatherCity() }
                        .onChange(of: weatherCityFocused) { _, focused in
                            if !focused { commitWeatherCity() }
                        }
                }
                SettingsDivider()
                DisclosureGroup("自定义天气服务", isExpanded: $state.showWeatherAdvanced) {
                SettingsRow(title: "高德 Key", caption: "填写后走高德天气（仅大陆城市）；留空自动改用中国天气网，无需申请。") {
                    HStack(spacing: 8) {
                        SecureField("高德 Web 服务 Key", text: $state.amapKeyDraft)
                            .textFieldStyle(InstrumentFieldStyle())
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
                        } else if state.amapKeyDraft == state.amapKeySaved && !state.amapKeyDraft.isEmpty {
                            Text("已保存")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Ink.success)
                                .accessibilityLabel("高德 Key 已保存")
                        }
                    }
                }
                }
                .font(Theme.Font.caption).tint(Theme.textSecondary)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .disabled(!prefs.greetingWeatherRendering)
                SettingsDivider()
                SettingsRow(title: "问候字体") {
                    Menu {
                        ForEach(GreetingTypeface.allCases) { typeface in
                            Button(typeface.label) { prefs.greetingTypeface = typeface }
                        }
                    } label: { InstrumentMenuLabel(title: prefs.greetingTypeface.label) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .accessibilityLabel("问候字体")
                }
            }
        }
    }

    private var islandSettings: some View {
        VStack(spacing: 24) {
            SettingsGroup(title: "灵动岛", symbol: "rectangle.topthird.inset.filled", caption: "启用后，将显示与提醒集中到屏幕顶部。") {
                SettingsToggleRow(title: "启用灵动岛", isOn: $prefs.notchIslandEnabled)
            }
            if prefs.notchIslandEnabled {
                SettingsGroup(title: "显示与提醒", symbol: "bell") {
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
            SettingsGroup(title: "本地代理", symbol: "point.3.connected.trianglepath.dotted", caption: "Claude Code 与 Codex 的供应商在「模型」页选择。") {
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
                    SettingsRow(title: "监听端口", caption: codexStore.proxyRunning ? "127.0.0.1:\(prefs.codexProxyPort) · 应用后重新监听" : "应用后生效，端口范围 1024–65535。") {
                        HStack(spacing: 8) {
                            TextField("15721", text: $state.codexPortDraft)
                                .textFieldStyle(InstrumentFieldStyle())
                                .frame(width: 85).monospacedDigit()
                                .focused($codexPortFocused)
                                .accessibilityLabel("本地代理监听端口")
                                .onSubmit { commitCodexPort() }
                            ActionButton("应用", tone: .neutral) { commitCodexPort() }
                                .disabled(state.codexPortDraft == String(prefs.codexProxyPort))
                        }
                    }
                    if let portError = state.portError {
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
                DisclosureGroup("第三方接入", isExpanded: $state.showProxyAdvanced) {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button { NSWorkspace.shared.open(FilePaths.logsDir) } label: {
                    Label("日志", systemImage: "doc.text")
                }
                Button { NotificationCenter.default.post(.showMainWindow(page: .help)) } label: {
                    Label("帮助", systemImage: "questionmark.circle")
                }
            }
            .buttonStyle(.plain).font(Theme.Font.caption)
            Text("ClaudeBar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
        }
        .foregroundColor(Theme.textSecondary).padding(.horizontal, 12)
    }

    private func commitCodexPort() {
        let trimmed = state.codexPortDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1024...65535).contains(port) else {
            state.portError = "请输入 1024–65535 之间的端口；当前端口仍为 \(prefs.codexProxyPort)。"
            return
        }
        state.portError = nil
        state.codexPortDraft = String(port)
        guard port != prefs.codexProxyPort else { return }
        prefs.codexProxyPort = port
        codexStore.restartProxyAndReactivate()
    }

    private func commitWeatherCity() {
        let city = state.weatherCityDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        state.weatherCityDraft = city
        guard city != prefs.weatherCity else { return }
        prefs.weatherCity = city
    }

    private func commitAmapKey() {
        let key = state.amapKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        state.amapKeyDraft = key
        state.amapKeySaved = key
        amapKeyFocused = false
        guard key != prefs.amapAPIKey else { return }
        prefs.amapAPIKey = key
        WeatherStore.shared.refresh()
    }

    /// Whether the row's draft differs from what is stored — what the Save
    /// button's enabled state and the 已保存／未保存 caption both read.
    private var amapKeyEdited: Bool { state.amapKeyDraft != prefs.amapAPIKey }

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
