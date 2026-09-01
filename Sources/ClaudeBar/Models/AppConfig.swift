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

    /// Number of busy/idle samples kept per session for the heartbeat
    /// sparkline. At the default 2.5s poll this covers the last minute.
    static let heartbeatLength = 24

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
