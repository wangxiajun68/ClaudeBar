import Foundation
import Combine

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

    private init() {
        idleNotifyEnabled = UserDefaults.standard.object(forKey: "idleNotifyEnabled") as? Bool ?? true
        tokenUnitStyle = TokenUnitStyle(rawValue: UserDefaults.standard.string(forKey: "tokenUnitStyle") ?? "") ?? .chinese
    }
}
