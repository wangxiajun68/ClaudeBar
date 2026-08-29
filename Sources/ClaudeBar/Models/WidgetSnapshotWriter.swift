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
    @discardableResult
    static func write(_ snapshot: WidgetSnapshot, deduplicatingAgainst lastData: Data?) -> Data? {
        guard let data = try? JSONEncoder().encode(snapshot) else { return lastData }
        guard data != lastData else { return data }
        persist(data)
        WidgetCenter.shared.reloadAllTimelines()
        return data
    }

    private static func persist(_ data: Data) {
        // 1. App Group container (or ~/.claude fallback — see FilePaths).
        try? data.write(to: FilePaths.widgetSnapshotFile, options: .atomic)
        // 2. ~/.claude/
        try? data.write(to: FilePaths.claudeDir.appendingPathComponent(AppConfig.widgetSnapshotFileName), options: .atomic)
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
