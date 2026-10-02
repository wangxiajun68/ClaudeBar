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

    /// Background ChatGPT quota poll: the steady heartbeat.
    ///
    /// Minutes, not seconds: every poll spawns a short-lived `codex app-server`
    /// (up to ~20 s of process lifetime). This cadence is kept *as well as* the
    /// poll aimed at a known reset instant — the reading is what the panel
    /// shows, so the allowance has to keep moving on screen even when nothing
    /// resets, and this is the rhythm it moves at. `QuotaPollScheduler` adds the
    /// extra look on top; it never shortens this one.
    static let quotaPollInterval: TimeInterval = 900

    /// Slack after the announced reset instant before the confirming poll.
    ///
    /// The window rolls *at* its instant, but the two clocks are not the same
    /// clock: the server's `resetsAt` is rounded to the minute and the device
    /// clock can sit a second or two off it. Asking exactly on the instant
    /// would read the old percentage and spend the re-check on a clock skew.
    /// Seconds, not minutes — the user is watching for this one.
    static let quotaResetGrace: TimeInterval = 5

    /// How far ahead a reset instant is worth aiming an extra poll at.
    ///
    /// A window that resets inside this is looked at when it resets instead of
    /// whenever the heartbeat next comes around, so a reset is reported within
    /// seconds rather than up to a quarter hour late. Anything further out is
    /// left to the heartbeat, which re-evaluates every `quotaPollInterval` — so
    /// by the time an instant does come inside this window, some heartbeat has
    /// already aimed at it. That no-reset-is-skimmed argument needs
    /// `quotaResetHorizon >= quotaPollInterval`; at the shipped values they are
    /// equal, the tight case, and `Tests/quota-reset-regressions.py` fails if
    /// that stops holding.
    static let quotaResetHorizon: TimeInterval = 900

    /// How long after a *predicted* reset instant the reading is still worth
    /// chasing.
    ///
    /// A fetch that fails in that moment would otherwise leave a "due" instant
    /// pinned in the past, and the aim re-armed against it on every reading.
    /// Past this the instant is abandoned and the heartbeat carries on.
    static let quotaResetDueWindow: TimeInterval = 300


    /// Cursor allowance poll.
    ///
    /// Slower than the ChatGPT quota poll because both of Cursor's windows are
    /// long-lived (a monthly plan and a weekly Grok window) and the probe is a
    /// pair of HTTP calls rather than a spawned process — 20 minutes still
    /// catches a reset within the same glance and keeps the account API quiet.
    static let cursorQuotaPollInterval: TimeInterval = 1_200

    // MARK: - Widget snapshot

    /// UserDefaults key (in the shared App Group suite) under which the
    /// widget snapshot payload is published. Defined in `BuildChannel`
    /// because the widget target reads the same key and does not compile
    /// this file.
    static let widgetSnapshotDefaultsKey = BuildChannel.widgetSnapshotDefaultsKey

    /// Bundle identifier of the widget extension. Its sandbox container is
    /// one of the snapshot write targets (see `WidgetSnapshotWriter`).
    static let widgetBundleID = BuildChannel.widgetBundleID

    /// File name of the snapshot JSON in every write target. Same owner as
    /// the defaults key above — one definition for both processes.
    static let widgetSnapshotFileName = BuildChannel.widgetSnapshotFileName
}
