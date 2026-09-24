import Foundation
import UserNotifications
import AppKit

extension Notification.Name {
    /// Posted when the user taps an idle notification (or its Resume action).
    /// userInfo["pid"] = Int — the session to resume in a terminal.
    static let resumeSession = Notification.Name("com.claudebar.resumeSession")

    /// SQLite vs JSON/JSONL persistence flipped in Settings.
    static let persistenceModeDidChange = Notification.Name("com.claudebar.persistenceModeDidChange")
}

/// Completion notifications: after a new final answer is confirmed, tell the
/// user it is ready. Encapsulates the
/// UNUserNotificationCenter plumbing — authorization, category registration,
/// and building the notification itself.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private var authorized = false
    private static let categoryID = "IDLE_SESSION"

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

    /// Register the idle category (with a Resume action) once.
    private func ensureCategory() {
        let resume = UNNotificationAction(identifier: "RESUME", title: "在终端继续",
                                          options: [.foreground])
        let category = UNNotificationCategory(
            identifier: Self.categoryID, actions: [resume], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Posting

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
