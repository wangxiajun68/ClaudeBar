import Foundation
import WidgetKit

/// Publishes the widget snapshot payload.
///
/// The sandboxed widget extension cannot read `~/.claude`, so the host app
/// writes the JSON to several locations and lets the widget pick the first
/// readable one (see `WidgetProvider`). Write targets:
///
/// 1. Shared App Group container (or `~/.claude` fallback — see
///    `FilePaths.widgetSnapshotFile`).
/// 2. `~/.claude/` — convenient for manual debugging.
/// 3. The widget's own sandbox container.
/// 4. Shared `UserDefaults` (App Group suite).
///
/// All writes are best-effort: a failure in one target never blocks the
/// others, and the UserDefaults copy acts as the last-resort fallback.
enum WidgetSnapshotWriter {
    /// Serializes `snapshot` and writes it to every target, then reloads the
    /// widget timelines. Returns early when the payload is byte-identical to
    /// the previous write, so the poll cadence does not hammer disk or
    /// `WidgetCenter` with unchanged data.
    ///
    /// `updatedAt` is stamped with `Date()` on every build, so a raw byte
    /// comparison never matched and every poll wrote four files plus a
    /// timeline reload. Compare on a normalized copy instead — the timestamp
    /// is metadata about when we *would* have written, not content.
    @discardableResult
    static func write(_ snapshot: WidgetSnapshot, deduplicatingAgainst lastData: Data?) -> Data? {
        // Every target below is another app's container (the widget's
        // sandbox, the App Group); on macOS 15+ touching them raises the
        // "access data from other apps" prompt, so it is strictly opt-in.
        guard PermissionGate.allows(.widgetData) else { return lastData }
        var normalized = snapshot
        normalized.updatedAt = Date(timeIntervalSince1970: 0)
        // One encoder, two encodes: the first for the dedup key, the second
        // only when the payload actually changed. Both used to build a fresh
        // `JSONEncoder` per call on the main actor, every poll.
        let encoder = JSONEncoder()
        guard let key = try? encoder.encode(normalized) else { return lastData }
        guard key != lastData else { return lastData }
        guard let data = try? encoder.encode(snapshot) else { return lastData }
        persist(data)
        WidgetCenter.shared.reloadAllTimelines()
        return key
    }

    private static func persist(_ data: Data) {
        // 1. App Group container (or ~/.claude fallback — see FilePaths).
        try? data.write(to: FilePaths.widgetSnapshotFile, options: .atomic)
        // 2. ~/.claude/ — only when it is a different path from #1. The
        // `widgetSnapshotFile` fallback *is* `~/.claude/...`, so an
        // unsandboxed or unsigned run wrote the same file twice per poll.
        let legacy = FilePaths.claudeDir.appendingPathComponent(AppConfig.widgetSnapshotFileName)
        if legacy.path != FilePaths.widgetSnapshotFile.path {
            try? data.write(to: legacy, options: .atomic)
        }
        // 3. Widget's own sandbox container (sandboxed widget can read this).
        let widgetContainer = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(AppConfig.widgetBundleID)/Data/\(AppConfig.widgetSnapshotFileName)")
        try? data.write(to: widgetContainer, options: .atomic)
        // 4. UserDefaults (App Group). `synchronize()` is a deprecated no-op
        // on modern macOS — UserDefaults flush automatically.
        if let shared = UserDefaults(suiteName: FilePaths.appGroupID) {
            shared.set(data, forKey: AppConfig.widgetSnapshotDefaultsKey)
        }
    }
}
