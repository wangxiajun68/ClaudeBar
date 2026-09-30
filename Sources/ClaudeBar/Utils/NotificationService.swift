import Foundation
import UserNotifications
import AppKit

extension Notification.Name {
    /// Posted when the user taps an idle notification (or its Resume action).
    /// userInfo["pid"] = Int — the session to resume in a terminal.
    static let resumeSession = Notification.Name("com.claudebar.resumeSession")

    /// SQLite vs JSON/JSONL persistence flipped in Settings.
    static let persistenceModeDidChange = Notification.Name("com.claudebar.persistenceModeDidChange")

    /// `CursorLedgerStore` finished a read and its money map changed.
    ///
    /// A notification rather than a direct call because the reader and the
    /// writer are on different schedules by design: the store reads on a
    /// network clock for whichever window the usage page selected, while
    /// `ProviderStore` republishes on the FSEvents clock. `ProviderStore`
    /// reacts with `refreshUsage(rescan: false)` — no transcripts changed, only
    /// the money.
    static let cursorLedgerDidChange = Notification.Name("com.claudebar.cursorLedgerDidChange")
}

/// Completion notifications: after a new final answer is confirmed, tell the
/// user it is ready. Encapsulates the
/// UNUserNotificationCenter plumbing — authorization, category registration,
/// and building the notification itself.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private var authorized = false
    private static let categoryID = "IDLE_SESSION"
    /// The parked-on-you category. Separate from `IDLE_SESSION` because the
    /// action is different — a parked prompt is answered in place ("去确认"),
    /// not resumed — and because iOS/macOS key the action set off the category.
    private static let waitingCategoryID = "NEEDS_INPUT"

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Authorization

    /// Ask for notification permission on first use. Silent no-op if denied.
    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    self.authorized = granted
                }
            case .authorized, .provisional:
                self.authorized = true
            default:
                self.authorized = false
            }
        }
    }

    // MARK: - Categories

    /// Register both categories (each with its own foreground action) once.
    private func ensureCategory() {
        let resume = UNNotificationAction(identifier: "RESUME", title: "在终端继续",
                                          options: [.foreground])
        let idle = UNNotificationCategory(
            identifier: Self.categoryID, actions: [resume], intentIdentifiers: [])
        // "去确认" reuses the same tap handler as quick-free: both end in
        // `TerminalLauncher` bringing the session forward, which is exactly what
        // answering a parked prompt requires. The label is what differs.
        let confirm = UNNotificationAction(identifier: "RESUME", title: "去确认",
                                           options: [.foreground])
        let waiting = UNNotificationCategory(
            identifier: Self.waitingCategoryID, actions: [confirm], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([idle, waiting])
    }

    // MARK: - Posting

    /// A session just parked on the user — a permission prompt, a plan to
    /// approve, or an `AskUserQuestion` dialog.
    ///
    /// The island's strip is the primary surface for this edge, but it is not
    /// always on screen: the user can turn the island off, and its alert is a
    /// one-shot that a strip already open (`.expanded`) refuses. When that
    /// happens nothing else tells the user — the menu-bar icon goes *idle*
    /// while a session waits, by design — so this banner is the fallback that
    /// keeps a parked Claude session from going silent. The caller decides when
    /// the strip could not carry it; this only posts.
    func notifyNeedsInput(session: SessionInfo) {
        post(
            title: "Claude 需要你确认",
            body: "\(session.projectFolder) · \(session.waitingReason.isEmpty ? "等待你确认" : session.waitingReason)",
            subtitle: "waiting-\(session.pid)",
            categoryID: Self.waitingCategoryID,
            pid: session.pid
        )
    }

    /// Cursor flavor of the parked-on-user banner.
    func notifyNeedsInput(cursor session: CursorSessionInfo) {
        post(
            title: "Cursor 需要你确认",
            body: "\(session.projectFolder) · 等待你确认计划",
            subtitle: "waiting-cursor-\(session.composerId)",
            categoryID: Self.waitingCategoryID,
            pid: nil
        )
    }

    /// A confirmed final answer, never the last intermediate tool name.
    func notifyIdle(session: SessionInfo) {
        post(
            title: "Claude 已完成",
            body: "\(session.projectFolder) · 最终答复已就绪",
            subtitle: "session-\(session.pid)",
            categoryID: Self.categoryID,
            pid: session.pid
        )
    }

    /// Cursor flavor — same state machine, violet distinct label.
    func notifyIdle(cursor session: CursorSessionInfo) {
        post(
            title: "Cursor 已完成",
            body: "\(session.projectFolder) · 最终答复已就绪",
            subtitle: "cursor-\(session.composerId)",
            categoryID: Self.categoryID,
            pid: nil
        )
    }

    /// Codex flavor — the tool name
    /// leads so sessions from different agents stay distinguishable.
    func notifyIdle(external session: ExternalSessionInfo) {
        post(
            title: "\(session.kind.displayName) 已完成",
            body: "\(session.projectFolder) · 最终答复已就绪",
            subtitle: session.id,
            categoryID: Self.categoryID,
            pid: nil
        )
    }

    private func post(title: String, body: String, subtitle: String,
                      categoryID: String, pid: Int?) {
        guard AppPreferences.shared.idleNotifyEnabled else { return }
        ensureCategory()
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryID
        if let pid {
            content.userInfo = ["pid": pid]
        }

        let request = UNNotificationRequest(
            identifier: subtitle, content: content, trigger: nil)
        // Replace any pending notification for the same session.
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present banners even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    /// Tap on the banner or the Resume action → resume that session.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let pid = response.notification.request.content.userInfo["pid"] as? Int
        NotificationCenter.default.post(
            name: .resumeSession, object: nil, userInfo: pid.map { ["pid": $0] })
    }
}
