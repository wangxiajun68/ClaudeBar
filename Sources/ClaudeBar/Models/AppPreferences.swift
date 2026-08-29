import Foundation
import Combine

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

    private init() {
        idleNotifyEnabled = UserDefaults.standard.object(forKey: "idleNotifyEnabled") as? Bool ?? true
    }
}
