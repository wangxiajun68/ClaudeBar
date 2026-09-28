import Foundation

/// Central home for tunable constants and cross-target string keys.
///
/// Filesystem locations intentionally live in `FilePaths` — this type only
/// holds non-path configuration (intervals, keys, identifiers) so there is a
/// single place to look when a timing or key needs to change.
enum AppConfig {
    // MARK: - Polling

    /// Interval for the live session poll. Drives the session heartbeat
    /// sparkline, idle notifications, and widget refresh cadence. The scan
    /// itself runs off-main (see `ProviderStore.refreshSessions`); this only
    /// controls how often the main run loop fires the trigger.
    static let sessionPollInterval: TimeInterval = 2.5
    /// When every session is idle the transcript tails do not change; poll slower.
    static let sessionPollIdleInterval: TimeInterval = 5

    /// Poll cadence when no window or popup is on screen. The session scan,
    /// Cursor DB read, and Codex directory walk are pure file I/O whose
    /// results nobody can see — so this skips the full scan cost in the
    /// background while staying inside the completion detector's 10 s candidate
    /// window: a busy→idle edge opens it, and the answer that confirms it is
    /// usually written *after* the edge (the transcript write and the status
    /// flip race), so a poll cadence at or beyond the window drops completions
    /// outright. 8 s leaves room for one missed poll; the widget and the
    /// menu-bar icon are the other readers at this tier.
    static let sessionPollHiddenInterval: TimeInterval = 8

    /// Number of busy/idle samples kept per session for the heartbeat
    /// sparkline. At the default 2.5s poll this covers the last minute.
    static let heartbeatLength = 24

    /// Background ChatGPT quota poll.
    ///
    /// Minutes, not seconds: quota windows move on a 5-hour / 7-day schedule,
    /// and every poll spawns a short-lived `codex app-server` (up to ~20 s of
    /// process lifetime). The only thing that needs this to be timely is the
    /// island's rollover alert, and 15 minutes of lag on a window that just
    /// reset is not something a user perceives.
    static let quotaPollInterval: TimeInterval = 900

    // MARK: - Widget snapshot

    /// UserDefaults key (in the shared App Group suite) under which the
    /// widget snapshot payload is published. The widget extension reads the
    /// same key — keep in sync with `WidgetProvider`.
    static let widgetSnapshotDefaultsKey = "widgetSnapshot"

    /// Bundle identifier of the widget extension. Its sandbox container is
    /// one of the snapshot write targets (see `WidgetSnapshotWriter`).
    static let widgetBundleID = "com.claudebar.app.widget"

    /// File name of the snapshot JSON in every write target.
    static let widgetSnapshotFileName = "claude-bar-widget-data.json"
}
