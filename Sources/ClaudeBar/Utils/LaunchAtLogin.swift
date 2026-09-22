import AppKit
import ServiceManagement

/// Login-item state, read from `SMAppService` rather than remembered.
///
/// Deliberately **not** backed by a `UserDefaults` pref. A stored "the user
/// wanted this on" flag can only drift from reality: `register()` can fail
/// silently, and a user can flip the item off in System Settings behind the
/// app's back. Both leave a toggle that claims the app will launch at login when
/// it will not. The system is the single source of truth, so there is nothing to
/// keep in sync — the switch reports what `status` says and nothing else.
///
/// `requiresApproval` maps to `isOn == false` for the same reason: in that state
/// macOS has **not** agreed to launch the app, so showing "on" would be a lie
/// with a green tint.
///
/// Signing caveat: registration is bound to the app's path and signature. The
/// release/CI builds are ad-hoc signed and unnotarized, where `status` commonly
/// reports `.notFound` or registration quietly does nothing — hence the honest
/// caption rather than an optimistic toggle. Dev builds use the trusted
/// `ClaudeBar Dev` identity and behave normally. Note also that a copy launched
/// from `.build/ClaudeBar.app` registers a path that later gets wiped.
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    /// Whether macOS will launch the app at login. False while approval is
    /// pending — see the type comment.
    @Published private(set) var isOn = false

    /// Why the toggle is not reflecting what the user asked for, if it is not.
    /// Sticky until the next `refresh()`, same as `ScreenshotHotKey.lastError`.
    @Published private(set) var lastError: String?

    /// The user must allow the item in System Settings before it takes effect.
    @Published private(set) var needsApproval = false

    private var activationObserver: NSObjectProtocol?

    private init() {}

    /// Read the system's answer. Cheap, so it runs at launch and on every
    /// app activation — the latter is what makes a change made in System
    /// Settings show up when the user comes back.
    func refresh() {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            isOn = true
            lastError = nil
            needsApproval = false
        case .notRegistered:
            isOn = false
            lastError = nil
            needsApproval = false
        case .requiresApproval:
            isOn = false
            lastError = "已在系统设置中等待允许"
            needsApproval = true
        case .notFound:
            isOn = false
            lastError = "系统未找到登录项；请确认应用位于 /Applications"
            needsApproval = false
        @unknown default:
            isOn = false
            lastError = nil
            needsApproval = false
        }
        startWatchingActivation()
    }

    /// Register or unregister, then re-read — never assume the call took, since
    /// the status is what the toggle shows.
    func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            // A batchmgr error here is the ad-hoc-signing case above, or a
            // policy block; either way the user gets the reason rather than a
            // toggle that springs back with no explanation.
            lastError = "操作失败：\(error.localizedDescription)"
        }
        refresh()
    }

    /// Deep link into System Settings → General → Login Items, for the
    /// `requiresApproval` caption. Same URL the fan helper alert uses.
    static func openLoginItemsSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Watch for the app coming back to the foreground so a change made in
    /// System Settings is picked up. Registered once.
    private func startWatchingActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }
}
