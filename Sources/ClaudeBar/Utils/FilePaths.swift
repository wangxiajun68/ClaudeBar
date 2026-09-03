import Foundation

enum FilePaths {
    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
    }

    static var settingsFile: URL {
        claudeDir.appendingPathComponent("settings.json")
    }

    /// Provider-based config file (the current on-disk format).
    static var presetsFile: URL {
        claudeDir.appendingPathComponent("claude-bar-providers.json")
    }

    // MARK: - Codex

    /// `~/.codex` — Codex CLI/desktop config root.
    static var codexDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    static var codexConfigFile: URL {
        codexDir.appendingPathComponent("config.toml")
    }

    static var codexAuthFile: URL {
        codexDir.appendingPathComponent("auth.json")
    }

    static var codexModelCatalogFile: URL {
        CodexModelCatalog.fileURL
    }

    /// Codex provider list managed by ClaudeBar (separate from the Claude
    /// providers file so the two lists stay independent).
    static var codexProvidersFile: URL {
        claudeDir.appendingPathComponent("claude-bar-codex-providers.json")
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

    // MARK: - App Support / logs

    /// `~/Library/Application Support/ClaudeBar`
    static var appSupportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// JSON / JSONL logs used when the SQLite stores are turned off.
    static var logsDir: URL {
        let dir = appSupportDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var captureIndexFile: URL { logsDir.appendingPathComponent("captures.jsonl") }
    static var capturePayloadsDir: URL {
        let dir = logsDir.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var captureSeqFile: URL { logsDir.appendingPathComponent("capture-seq") }
    static var proxyLogFile: URL { logsDir.appendingPathComponent("proxy.jsonl") }
    static var usageFilesJSON: URL { logsDir.appendingPathComponent("usage-files.json") }
    static var usageRollupJSONL: URL { logsDir.appendingPathComponent("usage-rollup.jsonl") }
    static var usageCursorJSON: URL { logsDir.appendingPathComponent("usage-cursor.json") }

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

    /// Cursor encodes a workspace path by replacing every character outside
    /// `[A-Za-z0-9-]` with "-". Verified against on-disk directories:
    /// `/Project/prompt_engineering` → `Users-…-Project-prompt-engineering`
    /// (underscore), `/Project/demo.1` → `…-Project-demo-1` (dot).
    /// Replacing only "/" misses underscores and dots and breaks transcript
    /// lookup for those workspaces.
    static func cursorProjectName(for cwd: String) -> String {
        let trimmed = cwd.hasPrefix("/") ? String(cwd.dropFirst()) : cwd
        let scalars = trimmed.unicodeScalars.map { scalar -> Unicode.Scalar in
            (65...90).contains(scalar.value)      // A-Z
                || (97...122).contains(scalar.value)  // a-z
                || (48...57).contains(scalar.value)   // 0-9
                || scalar == "-"
                ? scalar : "-"
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// The agent transcript for a Cursor composer:
    /// `~/.cursor/projects/<encoded-cwd>/agent-transcripts/<composerId>/<composerId>.jsonl`
    ///
    /// `cwd` and `composerId` come from Cursor's own DB/filesystem, so their
    /// path segments are already trusted (no traversal sanitization needed).
    static func cursorTranscriptURL(cwd: String, composerId: String) -> URL {
        cursorProjectsDir
            .appendingPathComponent(cursorProjectName(for: cwd))
            .appendingPathComponent("agent-transcripts")
            .appendingPathComponent(composerId)
            .appendingPathComponent("\(composerId).jsonl")
    }
}
