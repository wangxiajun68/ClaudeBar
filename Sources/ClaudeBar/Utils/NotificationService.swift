import Foundation
import UserNotifications
import AppKit
import os

extension Notification.Name {
    /// Posted when the user taps an idle notification (or its Resume action).
    /// The payload names the agent and the session, not a pid: a pid only
    /// exists for a live Claude process, and Cursor / Codex banners have none
    /// — the key is what the terminal resumes (`claude --resume <id>` already
    /// works for an ended session), while `pid` is only the *shortcut* to a
    /// window that is still holding the session open.
    ///
    /// - `agent`: "claude" | "codex" | "cursor"
    /// - `sessionId`: Claude session uuid / Codex thread id / Cursor composer id
    /// - `cwd`: the project directory (absent only when the source had none)
    /// - `pid`: Int, Claude (and a live Codex CLI) only
    /// - `inDesktop`: Bool, Codex only
    static let resumeSession = Notification.Name("com.claudebar.resumeSession")

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

    private static let logger = Logger(subsystem: "com.claudebar.app", category: "Notifications")
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
    ///
    /// This is the one function in the file that reaches the prompting API, so
    /// the build-channel gate lives here rather than at every caller — a dev
    /// build must not leave a notification grant in the user's TCC database
    /// (see `BuildChannel.promptsForSystemPermissions`). The status read itself
    /// is non-prompting and stays ungated, which is what lets
    /// `PermissionCenter` still answer "已授权 / 未授权" off a dev build.
    ///
    /// The result is logged rather than dropped: when the user denies the
    /// prompt, every later banner fails silently and this is the only record
    /// that says why.
    func requestAuthorizationIfNeeded() {
        guard BuildChannel.promptsForSystemPermissions else { return }
        guard AppPresentation.allowsInterface else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard AppPresentation.allowsInterface else { return }
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        Self.logger.error("notification authorization request failed: \(error.localizedDescription, privacy: .public)")
                    } else if !granted {
                        Self.logger.notice("notification authorization was denied by the user")
                    }
                }
            default:
                break
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
        post(delivery: .always,
             title: "Claude 需要你确认",
             body: "\(session.projectFolder) · \(session.waitingReason.isEmpty ? "等待你确认" : session.waitingReason)",
             subtitle: "waiting-\(session.pid)",
             categoryID: Self.waitingCategoryID,
             route: ResumeRoute(agent: "claude", sessionId: session.sessionId, cwd: session.cwd,
                                pid: session.pid, inDesktop: false))
    }

    /// Cursor flavor of the parked-on-user banner.
    func notifyNeedsInput(cursor session: CursorSessionInfo) {
        post(delivery: .always,
             title: "Cursor 需要你确认",
             body: "\(session.projectFolder) · 等待你确认计划",
             subtitle: "waiting-cursor-\(session.composerId)",
             categoryID: Self.waitingCategoryID,
             route: ResumeRoute(agent: "cursor", sessionId: session.composerId, cwd: session.cwd,
                                pid: nil, inDesktop: false))
    }

    /// A confirmed final answer, never the last intermediate tool name.
    func notifyIdle(session: SessionInfo) {
        post(delivery: .idlePreference,
             title: "Claude 已完成",
             body: "\(session.projectFolder) · 最终答复已就绪",
             subtitle: "session-\(session.pid)",
             categoryID: Self.categoryID,
             route: ResumeRoute(agent: "claude", sessionId: session.sessionId, cwd: session.cwd,
                                pid: session.pid, inDesktop: false))
    }

    /// Cursor flavor — same state machine, violet distinct label.
    func notifyIdle(cursor session: CursorSessionInfo) {
        post(delivery: .idlePreference,
             title: "Cursor 已完成",
             body: "\(session.projectFolder) · 最终答复已就绪",
             subtitle: "cursor-\(session.composerId)",
             categoryID: Self.categoryID,
             route: ResumeRoute(agent: "cursor", sessionId: session.composerId, cwd: session.cwd,
                                pid: nil, inDesktop: false))
    }

    /// Codex flavor — the tool name
    /// leads so sessions from different agents stay distinguishable.
    func notifyIdle(external session: ExternalSessionInfo) {
        post(delivery: .idlePreference,
             title: "\(session.kind.displayName) 已完成",
             body: "\(session.projectFolder) · 最终答复已就绪",
             subtitle: session.id,
             categoryID: Self.categoryID,
             route: ResumeRoute(agent: "codex", sessionId: session.sessionId, cwd: session.cwd,
                                pid: session.holderPID,
                                inDesktop: session.inDesktop))
    }

    /// What gates one banner, and why the parked ones are different.
    ///
    /// `idleNotifyEnabled` is the 「空闲通知」 switch (default off, an opt-in
    /// permission — see docs/design/10-notch-island.md §5). It gates the
    /// **completion** banners, whose island alert is a repeatable one-shot edge
    /// the user can catch later. A park is the other edge: the strip refuses a
    /// `.needsInput` alert while the island is off, alerts are off, or the
    /// strip is open (`.expanded`), the menu-bar icon reads *idle* by design,
    /// and the edge never fires again — so `NotchIslandController` posts this
    /// banner exactly when the strip could not carry it. Letting the idle
    /// switch silence that fallback resurrects the silent park the fallback
    /// exists to prevent, so it posts whenever notifications are permitted.
    enum Delivery {
        /// Completion banner: requires the 「空闲通知」 switch.
        case idlePreference
        /// Parked-on-user fallback: gated by the system authorization only.
        case always
    }

    /// What a banner's tap should open, in a form `UNNotificationContent`
    /// can carry (property-list values only, so no enum and no URL).
    struct ResumeRoute {
        var agent: String
        var sessionId: String
        var cwd: String
        var pid: Int?
        var inDesktop: Bool
    }

    private func post(delivery: Delivery, title: String, body: String, subtitle: String,
                      categoryID: String, route: ResumeRoute) {
        guard AppPresentation.allowsInterface else { return }
        if delivery == .idlePreference, !AppPreferences.shared.idleNotifyEnabled { return }
        ensureCategory()
        // The parked fallback is a sole-signal path, so it must not reach the
        // prompting API at all: asking here would post a TCC prompt from a
        // background island event, and a dev build must never write that grant
        // (`BuildChannel.promptsForSystemPermissions` is the first gate inside
        // this call). The two non-prompting statuses below cover every state
        // that can exist without this build having asked.
        if delivery == .idlePreference {
            requestAuthorizationIfNeeded()
        } else {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.submit(title: title, body: body, subtitle: subtitle,
                                categoryID: categoryID, route: route)
                case .denied, .notDetermined:
                    // Denied: macOS drops the banner anyway — submitting would
                    // buy one silent XPC round trip per park. Not determined:
                    // the user never opted in to notifications, which is
                    // exactly what the 「空闲通知」 switch-collection means.
                    Self.logger.notice("parked-session banner skipped (authorization not granted)")
                @unknown default:
                    break
                }
            }
            return
        }
        submit(title: title, body: body, subtitle: subtitle, categoryID: categoryID, route: route)
    }

    /// Build the notification and hand it to the system. Every argument comes
    /// from the shipped builders above, so this is the one place the content
    /// shape (category, identifier, tap payload) exists.
    private func submit(title: String, body: String, subtitle: String,
                        categoryID: String, route: ResumeRoute) {
        guard AppPresentation.allowsInterface else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = Self.userInfo(for: route)

        // The identifier is keyed on the session (`waiting-<pid>`,
        // `session-<pid>`, …), so a re-post for the same session *replaces*
        // the pending banner instead of stacking on it.
        let request = UNNotificationRequest(
            identifier: subtitle, content: content, trigger: nil)
        // The error used to be dropped with the single-argument form: a banner
        // that never appeared had no trace anywhere.
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Self.logger.error("notification \(subtitle, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present banners even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        guard AppPresentation.allowsInterface else { return [] }
        return [.banner, .sound]
    }

    /// The plist-safe payload a banner carries. Keys stay flat strings so a
    /// future read never has to know which agent wrote them.
    private static func userInfo(for route: ResumeRoute) -> [String: Any] {
        var info: [String: Any] = ["agent": route.agent, "sessionId": route.sessionId]
        if !route.cwd.isEmpty { info["cwd"] = route.cwd }
        if let pid = route.pid { info["pid"] = pid }
        if route.inDesktop { info["inDesktop"] = true }
        return info
    }

    /// Tap on the banner or the "在终端继续" action → resume that session in
    /// the app that owns it (`resumeSession(_:)` switches on `agent`).
    ///
    /// The route always carries the session key; only Claude (and a live Codex
    /// CLI) also carries a pid, which is the shortcut to a window already
    /// holding it. A Cursor or Codex banner used to post nothing but a pid —
    /// which it did not have — so its 在终端继续 / 去确认 action was inert.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let agent = info["agent"] as? String,
              let sessionId = info["sessionId"] as? String, !sessionId.isEmpty else { return }
        var payload: [String: Any] = ["agent": agent, "sessionId": sessionId]
        if let cwd = info["cwd"] as? String { payload["cwd"] = cwd }
        if let pid = info["pid"] as? Int { payload["pid"] = pid }
        if let inDesktop = info["inDesktop"] as? Bool { payload["inDesktop"] = inDesktop }
        NotificationCenter.default.post(name: .resumeSession, object: nil, userInfo: payload)
    }
}
