import Foundation
import Combine
import AppKit
import SwiftUI

/// Light / dark canvas. Not “follow system” — the ice sheet and the night
/// sheet are two authored palettes, switched on purpose.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var label: String { self == .light ? "浅色" : "深色" }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

extension Notification.Name {
    static let appearanceDidChange = Notification.Name("com.claudebar.appearanceDidChange")
}

enum AppearanceSync {
    static func apply() {
        NSApp.appearance = Theme.nsAppearance
        NotificationCenter.default.post(name: .appearanceDidChange, object: nil)
    }
}

/// Token magnitude style for `UsageStats.formatTokens` output.
enum TokenUnitStyle: String {
    /// 中文量级：38.7M → "3869.1万"（默认）。
    case chinese
    /// 国际量级：38690638 → "38.7M"。
    case metric

    var label: String {
        switch self {
        case .chinese: return "万 / 亿"
        case .metric: return "K / M / B"
        }
    }
}

/// App-level preferences (as opposed to provider config): persisted to
/// UserDefaults, observed by the popup / main-window action bars via
/// `@ObservedObject AppPreferences.shared`.
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    /// Post a macOS notification when a session flips busy → idle.
    @Published var idleNotifyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(idleNotifyEnabled, forKey: "idleNotifyEnabled")
            if idleNotifyEnabled { NotificationService.shared.requestAuthorizationIfNeeded() }
        }
    }

    /// Display unit for token counts (万/亿 vs K/M/B).
    @Published var tokenUnitStyle: TokenUnitStyle {
        didSet { UserDefaults.standard.set(tokenUnitStyle.rawValue, forKey: "tokenUnitStyle") }
    }

    /// How estimated model spend is presented across currencies.
    @Published var costDisplay: CostDisplay = .split {
        didSet {
            UserDefaults.standard.set(costDisplay.rawValue, forKey: "costDisplay")
            if didSetReady, costDisplay.needsRate { ExchangeRate.shared.refreshIfStale() }
        }
    }

    /// A user-pinned USD→CNY rate, overriding the fetched one. Set it to stop
    /// the app making any outbound request for a rate at all.
    @Published var manualUSDToCNY: Double? {
        didSet {
            if let rate = manualUSDToCNY, rate > 0 {
                UserDefaults.standard.set(rate, forKey: "manualUSDToCNY")
            } else {
                UserDefaults.standard.removeObject(forKey: "manualUSDToCNY")
            }
        }
    }

    @Published var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearanceMode")
            if didSetReady { AppearanceSync.apply() }
        }
    }

    var isDark: Bool { appearance == .dark }

    /// Route Codex traffic through the local compatibility proxy (fixes
    /// openai/codex#23186 — MCP namespace tools unusable on generic backends).
    @Published var codexRoutingEnabled: Bool {
        didSet { UserDefaults.standard.set(codexRoutingEnabled, forKey: "codexRoutingEnabled") }
    }

    /// Port for the local Codex proxy (127.0.0.1:<port>).
    @Published var codexProxyPort: Int {
        didSet { UserDefaults.standard.set(codexProxyPort, forKey: "codexProxyPort") }
    }

    /// When on, third-party clients (not Claude Code / Codex) proxied through the
    /// local server are written to Traffic (access log + capture when enabled).
    @Published var proxyThirdPartyTrafficEnabled: Bool {
        didSet { UserDefaults.standard.set(proxyThirdPartyTrafficEnabled, forKey: "proxyThirdPartyTrafficEnabled") }
    }

    /// Third-party OpenAI traffic (`/chat/completions`, `/responses`). `nil`
    /// follows the active Codex vendor. Otherwise a Codex-list provider id.
    @Published var proxyThirdPartyOpenAIProviderID: UUID? {
        didSet {
            UserDefaults.standard.set(
                proxyThirdPartyOpenAIProviderID?.uuidString ?? "",
                forKey: "proxyThirdPartyOpenAIProviderID")
        }
    }

    /// Third-party Anthropic traffic (`/messages`). `nil` follows the active
    /// Claude Code vendor.
    @Published var proxyThirdPartyAnthropicProviderID: UUID? {
        didSet {
            UserDefaults.standard.set(
                proxyThirdPartyAnthropicProviderID?.uuidString ?? "",
                forKey: "proxyThirdPartyAnthropicProviderID")
        }
    }

    /// When on, capture + usage use SQLite. When off, they append JSON/JSONL
    /// under Application Support/ClaudeBar/logs — no database is opened.
    @Published var databaseEnabled: Bool {
        didSet {
            UserDefaults.standard.set(databaseEnabled, forKey: "databaseEnabled")
            ProxyCaptureStore.shared.reloadPersistence()
            UsageIndex.reloadPersistence()
            ProxyUsageStore.shared.reset()
            NotificationCenter.default.post(name: .persistenceModeDidChange, object: nil)
        }
    }

    // MARK: VPN 代理（mihomo 内核）— 与上面的 LLM 本地代理无关

    /// 总开关：运行 mihomo 内核。
    @Published var vpnEnabled: Bool {
        didSet { UserDefaults.standard.set(vpnEnabled, forKey: "vpnEnabled") }
    }
    /// 接管 macOS 系统代理（networksetup）。
    @Published var vpnSystemProxyEnabled: Bool {
        didSet { UserDefaults.standard.set(vpnSystemProxyEnabled, forKey: "vpnSystemProxyEnabled") }
    }
    /// TUN 模式；关闭时恢复系统 DNS。
    @Published var vpnTunEnabled: Bool {
        didSet {
            UserDefaults.standard.set(vpnTunEnabled, forKey: "vpnTunEnabled")
            if !vpnTunEnabled {
                Task { @MainActor in VpnTunDnsHelper.restoreSystemDNSIfNeeded() }
            }
        }
    }
    /// mihomo 混合端口（HTTP + SOCKS）。
    @Published var vpnMixedPort: Int {
        didSet { UserDefaults.standard.set(vpnMixedPort, forKey: "vpnMixedPort") }
    }
    /// 允许局域网设备使用本机代理。
    @Published var vpnAllowLan: Bool {
        didSet { UserDefaults.standard.set(vpnAllowLan, forKey: "vpnAllowLan") }
    }
    /// external-controller API 密钥（可空）。
    @Published var vpnControllerSecret: String {
        didSet { UserDefaults.standard.set(vpnControllerSecret, forKey: "vpnControllerSecret") }
    }
    /// 守卫循环：其他软件清除系统代理时自动恢复。
    @Published var vpnGuardEnabled: Bool {
        didSet { UserDefaults.standard.set(vpnGuardEnabled, forKey: "vpnGuardEnabled") }
    }

    /// Global ⌘⇧A region screenshot (Carbon hotkey).
    @Published var screenshotHotkeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(screenshotHotkeyEnabled, forKey: "screenshotHotkeyEnabled")
            if didSetReady { ScreenshotHotKey.shared.setEnabled(screenshotHotkeyEnabled) }
        }
    }

    // MARK: 继续会话

    /// Where 继续 / double-click resumes a Claude Code or Codex session.
    @Published var resumeTerminal: ResumeTerminal {
        didSet { UserDefaults.standard.set(resumeTerminal.rawValue, forKey: "resumeTerminal") }
    }

    // MARK: 刘海灵动岛

    /// Show the notch island at the top center of the notched screen.
    @Published var notchIslandEnabled: Bool {
        didSet { UserDefaults.standard.set(notchIslandEnabled, forKey: "notchIslandEnabled") }
    }
    /// Collapsed island shows the busy agent and today's tokens beside the notch.
    @Published var notchIslandShowsWings: Bool {
        didSet { UserDefaults.standard.set(notchIslandShowsWings, forKey: "notchIslandShowsWings") }
    }
    /// Grow a short alert out of the notch when a session finishes.
    @Published var notchIslandAlertsEnabled: Bool {
        didSet { UserDefaults.standard.set(notchIslandAlertsEnabled, forKey: "notchIslandAlertsEnabled") }
    }
    /// Keep the island over full-screen apps.
    @Published var notchIslandInFullScreen: Bool {
        didSet { UserDefaults.standard.set(notchIslandInFullScreen, forKey: "notchIslandInFullScreen") }
    }

    private var didSetReady = false

    private init() {
        idleNotifyEnabled = UserDefaults.standard.object(forKey: "idleNotifyEnabled") as? Bool ?? false
        appearance = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "") ?? .light
        tokenUnitStyle = TokenUnitStyle(rawValue: UserDefaults.standard.string(forKey: "tokenUnitStyle") ?? "") ?? .chinese
        costDisplay = CostDisplay(rawValue: UserDefaults.standard.string(forKey: "costDisplay") ?? "") ?? .split
        // Read through a `Double` sentinel rather than `object(forKey:) as? Double`:
        // the stored value is a number, and a 0 rate is not a rate.
        let manual = UserDefaults.standard.double(forKey: "manualUSDToCNY")
        manualUSDToCNY = manual > 0 ? manual : nil
        codexRoutingEnabled = UserDefaults.standard.object(forKey: "codexRoutingEnabled") as? Bool ?? false
        codexProxyPort = UserDefaults.standard.object(forKey: "codexProxyPort") as? Int ?? 15721
        proxyThirdPartyTrafficEnabled = UserDefaults.standard.object(forKey: "proxyThirdPartyTrafficEnabled") as? Bool ?? true
        proxyThirdPartyOpenAIProviderID = Self.uuid(from: "proxyThirdPartyOpenAIProviderID")
        proxyThirdPartyAnthropicProviderID = Self.uuid(from: "proxyThirdPartyAnthropicProviderID")
        databaseEnabled = UserDefaults.standard.object(forKey: "databaseEnabled") as? Bool ?? true

        // VPN proxy module (defined in Utils/VPNPreferences.swift).
        // `as?` with a fallback rather than `as!`: this dictionary is built
        // inline today, but the cast sits in `init()`, i.e. *before any UI
        // exists* — a future `[String: Any]` from JSON or UserDefaults would
        // trap on launch with no window and no message.
        let vpn = Self.vpnDefaults()
        vpnEnabled = vpn["vpnEnabled"] as? Bool ?? false
        vpnSystemProxyEnabled = vpn["vpnSystemProxyEnabled"] as? Bool ?? false
        vpnTunEnabled = vpn["vpnTunEnabled"] as? Bool ?? false
        vpnMixedPort = vpn["vpnMixedPort"] as? Int ?? 7890
        vpnAllowLan = vpn["vpnAllowLan"] as? Bool ?? false
        vpnControllerSecret = vpn["vpnControllerSecret"] as? String ?? ""
        vpnGuardEnabled = vpn["vpnGuardEnabled"] as? Bool ?? true
        screenshotHotkeyEnabled = UserDefaults.standard.object(forKey: "screenshotHotkeyEnabled") as? Bool ?? false
        resumeTerminal = UserDefaults.standard.string(forKey: "resumeTerminal").flatMap(ResumeTerminal.init(rawValue:)) ?? .automatic
        notchIslandEnabled = UserDefaults.standard.object(forKey: "notchIslandEnabled") as? Bool ?? true
        notchIslandShowsWings = UserDefaults.standard.object(forKey: "notchIslandShowsWings") as? Bool ?? true
        notchIslandAlertsEnabled = UserDefaults.standard.object(forKey: "notchIslandAlertsEnabled") as? Bool ?? true
        notchIslandInFullScreen = UserDefaults.standard.object(forKey: "notchIslandInFullScreen") as? Bool ?? false
        didSetReady = true
    }

    private static func uuid(from key: String) -> UUID? {
        let s = UserDefaults.standard.string(forKey: key) ?? ""
        guard !s.isEmpty else { return nil }
        return UUID(uuidString: s)
    }
}
