import Foundation

enum FilePaths {
    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
    }

    static var settingsFile: URL {
        claudeDir.appendingPathComponent("settings.json")
    }

    static var presetsFile: URL {
        // New format: providers based
        claudeDir.appendingPathComponent("claude-bar-providers.json")
    }

    static var oldPresetsFile: URL {
        // Old format: for migration only
        claudeDir.appendingPathComponent("claude-bar-presets.json")
    }

    /// Shared App Group identifier between the main app and the widget
    /// extension. The sandboxed widget cannot read `~/.claude`, so the
    /// snapshot is published here instead. Keep in sync with the widget
    /// target's `WidgetFilePaths.appGroupID`.
    static let appGroupID = "com.claudebar.app.widget"

    static var widgetSnapshotFile: URL {
        // Prefer the shared App Group container (readable by the sandboxed
        // widget extension). Fall back to ~/.claude if the container can't be
        // resolved (e.g. running outside a signed bundle).
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group.appendingPathComponent("claude-bar-widget-data.json")
        }
        return claudeDir.appendingPathComponent("claude-bar-widget-data.json")
    }

    // MARK: - Cursor

    /// `~/.cursor` — Cursor's user-data root (projects/, ai-tracking/, …).
    static var cursorDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor")
    }

    /// Cursor's global VS Code state DB. Holds `composerHeaders` (the session
    /// index table) and `cursorDiskKV` (per-message bubbles). Cursor keeps it
    /// open in WAL mode while running; we open it read-only.
    static var cursorStateDB: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// `~/.cursor/projects` — each subdirectory is a workspace, named after
    /// the encoded cwd.
    static var cursorProjectsDir: URL {
        cursorDir.appendingPathComponent("projects")
    }

    /// Cursor encodes a workspace path by dropping the leading "/" then
    /// replacing every "/" with "-". e.g.
    /// `/Users/wangxiajun/Project/ClaudeBar` → `Users-wangxiajun-Project-ClaudeBar`.
    /// Unlike Claude Code, Cursor does NOT prepend a leading "-".
    static func cursorProjectName(for cwd: String) -> String {
        let stripped = cwd.hasPrefix("/") ? String(cwd.dropFirst()) : cwd
        return stripped.replacingOccurrences(of: "/", with: "-")
    }

    /// The agent transcript for a Cursor composer:
    /// `~/.cursor/projects/<encoded-cwd>/agent-transcripts/<composerId>/<composerId>.jsonl`
    static func cursorTranscriptURL(cwd: String, composerId: String) -> URL {
        cursorProjectsDir
            .appendingPathComponent(cursorProjectName(for: cwd))
            .appendingPathComponent("agent-transcripts")
            .appendingPathComponent(composerId)
            .appendingPathComponent("\(composerId).jsonl")
    }
}
