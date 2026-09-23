import Foundation

struct SettingsManager {
    /// Read and parse `~/.claude/settings.json` into an `EnvConfig`. Returns
    /// nil when the file is missing or has no `env` block. The raw top-level
    /// dict is read separately by `writeSettings()` when it needs to preserve
    /// sibling fields, so it is not surfaced here.
    static func readSettings() -> EnvConfig? {
        guard FileManager.default.fileExists(atPath: FilePaths.settingsFile.path),
              let data = try? Data(contentsOf: FilePaths.settingsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envDict = json["env"] as? [String: Any] else {
            return nil
        }

        return EnvConfig(
            ANTHROPIC_AUTH_TOKEN: (envDict["ANTHROPIC_AUTH_TOKEN"] as? String) ?? "",
            ANTHROPIC_BASE_URL: (envDict["ANTHROPIC_BASE_URL"] as? String) ?? "",
            ANTHROPIC_MODEL: (envDict["ANTHROPIC_MODEL"] as? String) ?? "",
            CLAUDE_CODE_MAX_CONTEXT_TOKENS: (envDict["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] as? String) ?? "",
            DISABLE_COMPACT: (envDict["DISABLE_COMPACT"] as? String) ?? "",
            GITHUB_PERSONAL_ACCESS_TOKEN: (envDict["GITHUB_PERSONAL_ACCESS_TOKEN"] as? String) ?? "",
            CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: (envDict["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"] as? String) ?? "",
            ANTHROPIC_DEFAULT_OPUS_MODEL: (envDict["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String) ?? "",
            ANTHROPIC_DEFAULT_OPUS_MODEL_NAME: (envDict["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"] as? String) ?? "",
            ANTHROPIC_DEFAULT_SONNET_MODEL: (envDict["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String) ?? "",
            ANTHROPIC_DEFAULT_SONNET_MODEL_NAME: (envDict["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"] as? String) ?? "",
            ANTHROPIC_DEFAULT_HAIKU_MODEL: (envDict["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String) ?? "",
            ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME: (envDict["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"] as? String) ?? "",
            ANTHROPIC_DEFAULT_FABLE_MODEL: (envDict["ANTHROPIC_DEFAULT_FABLE_MODEL"] as? String) ?? "",
            ANTHROPIC_DEFAULT_FABLE_MODEL_NAME: (envDict["ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"] as? String) ?? "",
            CLAUDE_CODE_AUTO_COMPACT_WINDOW: (envDict["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] as? String) ?? ""
        )
    }

    /// Keep the first pre-edit snapshot. Existing backups are never replaced.
    private static var didBackUp = false

    static func backUpOnce() {
        guard !didBackUp else { return }
        let source = FilePaths.settingsFile
        let backup = source.appendingPathExtension("bak")
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return }
        if manager.fileExists(atPath: backup.path) { didBackUp = true; return }
        do {
            try manager.copyItem(at: source, to: backup)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            didBackUp = true
        } catch {
            // Retry on the next write if the backup could not be created.
        }
    }

    static func writeSettings(env: EnvConfig) throws {
        var json = try readDocument()
        var values = try environment(in: json)
        let encoded = try JSONEncoder().encode(env)
        let configured = try JSONDecoder().decode([String: String].self, from: encoded)
        // Empty managed values clear the previous provider's credentials and
        // switches. Unrelated environment entries retain their original types.
        for key in managedEnvKeys { values.removeValue(forKey: key) }
        for (key, value) in configured where !value.isEmpty { values[key] = value }
        json["env"] = values
        backUpOnce()
        try writeDocument(json)
    }

    private enum DocumentError: LocalizedError {
        case invalidRoot, invalidEnvironment
        var errorDescription: String? {
            switch self {
            case .invalidRoot: return "settings.json 必须是 JSON 对象，未覆盖原文件。"
            case .invalidEnvironment: return "settings.json 的 env 必须是对象，未覆盖原文件。"
            }
        }
    }

    private static func readDocument() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: FilePaths.settingsFile.path) else { return [:] }
        let data = try Data(contentsOf: FilePaths.settingsFile)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentError.invalidRoot
        }
        return json
    }

    private static func environment(in json: [String: Any]) throws -> [String: Any] {
        guard let raw = json["env"] else { return [:] }
        guard let values = raw as? [String: Any] else { throw DocumentError.invalidEnvironment }
        return values
    }

    private static func writeDocument(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let manager = FileManager.default
        try manager.createDirectory(at: FilePaths.claudeDir, withIntermediateDirectories: true)
        try PrivateFileWriter.write(data, to: FilePaths.settingsFile)
    }

    /// Keys owned by provider switching and removed when restoring official login.
    static let managedEnvKeys: Set<String> = [
        "ANTHROPIC_AUTH_TOKEN",
        // cc-switch (and some presets) put the key in ANTHROPIC_API_KEY
        // instead. Official login reads neither — both have to go.
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
        "DISABLE_COMPACT",
        "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
        "ANTHROPIC_DEFAULT_FABLE_MODEL",
        "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
    ]

    /// Strip the third-party overlay from `settings.json` so Claude Code
    /// falls back to Anthropic's own endpoint and `~/.claude` login.
    ///
    /// Sibling top-level fields (`permissions`, plugins, …) and any `env`
    /// keys we do not own stay. An empty leftover `env` object is removed
    /// rather than left as `{}`.
    static func restoreOfficial() throws {
        guard FileManager.default.fileExists(atPath: FilePaths.settingsFile.path) else { return }
        var json = try readDocument()
        var values = try environment(in: json)
        for key in managedEnvKeys { values.removeValue(forKey: key) }
        if values.isEmpty { json.removeValue(forKey: "env") }
        else { json["env"] = values }
        backUpOnce()
        try writeDocument(json)
    }
}
