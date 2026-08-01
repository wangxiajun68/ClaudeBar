import WidgetKit
import SwiftUI
import Foundation

// MARK: - File Paths (widget-local copy)

private enum WidgetFilePaths {
    /// Shared App Group identifier — must match the main app's `FilePaths.appGroupID`.
    /// The widget runs sandboxed and cannot read `~/.claude`, so it reads the
    /// snapshot the main app publishes to this shared container.
    static let appGroupID = "com.claudebar.app.widget"

    static var widgetSnapshotFile: URL? {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        return group.appendingPathComponent("claude-bar-widget-data.json")
    }
}

// MARK: - Timeline Entry

struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot

    static let placeholder = WidgetEntry(
        date: Date(),
        snapshot: WidgetSnapshot(
            todayTotalTokens: 0,
            modelBreakdown: [],
            activeProviderName: "—",
            activeModelName: "—",
            balanceText: nil,
            totalSessionCount: 0,
            busySessionCount: 0,
            sessions: [],
            cursorSessions: [],
            updatedAt: Date()
        )
    )
}

// MARK: - Timeline Provider

struct WidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(loadEntry() ?? .placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let entry = loadEntry() ?? diagnosticEntry()
        let nextUpdate = Date().addingTimeInterval(30)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    /// Diagnostic: returns an entry that SHOWS what went wrong
    private func diagnosticEntry() -> WidgetEntry {
        var diag = ""

        // Check UserDefaults
        if let shared = UserDefaults(suiteName: WidgetFilePaths.appGroupID) {
            let data = shared.data(forKey: "widgetSnapshot")
            diag += "UD:\(data?.count ?? -1)B "
        } else {
            diag += "UD:nil "
        }

        // Check container
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetFilePaths.appGroupID) {
            let url = container.appendingPathComponent("claude-bar-widget-data.json")
            let exists = FileManager.default.fileExists(atPath: url.path)
            let size = (try? Data(contentsOf: url))?.count ?? -1
            diag += "F:\(exists ? "Y" : "N")/\(size)B"
        } else {
            diag += "Container:nil"
        }

        // Use non-zero values so the widget doesn't show "empty state"
        return WidgetEntry(date: Date(), snapshot: WidgetSnapshot(
            todayTotalTokens: 1,
            modelBreakdown: [],
            activeProviderName: diag,
            activeModelName: "diagnostic",
            balanceText: nil,
            totalSessionCount: 1,
            busySessionCount: 0,
            sessions: [],
            cursorSessions: [],
            updatedAt: Date()
        ))
    }

    private func loadEntry() -> WidgetEntry? {
        var data: Data?

        // 1. Try shared UserDefaults
        if let shared = UserDefaults(suiteName: WidgetFilePaths.appGroupID) {
            data = shared.data(forKey: "widgetSnapshot")
        }

        // 2. Fall back to file in App Group container
        if data == nil, let url = WidgetFilePaths.widgetSnapshotFile {
            data = try? Data(contentsOf: url)
        }

        // 3. Fall back to ~/.claude/
        if data == nil {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let claudePath = home.appendingPathComponent(".claude/claude-bar-widget-data.json")
            data = try? Data(contentsOf: claudePath)
        }

        // 4. Widget's own sandbox container (written by main app)
        if data == nil {
            let home = FileManager.default.homeDirectoryForCurrentUser
            // homeDirectory already ends with /Data for sandboxed processes
            let sandboxPath = home.appendingPathComponent("claude-bar-widget-data.json")
            data = try? Data(contentsOf: sandboxPath)
        }

        guard let raw = data,
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: raw)
        else { return nil }

        return WidgetEntry(date: Date(), snapshot: snapshot)
    }
}
