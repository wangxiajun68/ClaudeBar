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
              let envDict = json["env"] as? [String: String] else {
            return nil
        }

        return EnvConfig(
            ANTHROPIC_AUTH_TOKEN: envDict["ANTHROPIC_AUTH_TOKEN"] ?? "",
            ANTHROPIC_BASE_URL: envDict["ANTHROPIC_BASE_URL"] ?? "",
            ANTHROPIC_MODEL: envDict["ANTHROPIC_MODEL"] ?? "",
            CLAUDE_CODE_MAX_CONTEXT_TOKENS: envDict["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] ?? "",
            DISABLE_COMPACT: envDict["DISABLE_COMPACT"] ?? "",
            GITHUB_PERSONAL_ACCESS_TOKEN: envDict["GITHUB_PERSONAL_ACCESS_TOKEN"] ?? "",
            CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: envDict["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"] ?? "",
            ANTHROPIC_DEFAULT_OPUS_MODEL: envDict["ANTHROPIC_DEFAULT_OPUS_MODEL"] ?? "",
            ANTHROPIC_DEFAULT_OPUS_MODEL_NAME: envDict["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"] ?? "",
            ANTHROPIC_DEFAULT_SONNET_MODEL: envDict["ANTHROPIC_DEFAULT_SONNET_MODEL"] ?? "",
            ANTHROPIC_DEFAULT_SONNET_MODEL_NAME: envDict["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"] ?? "",
            ANTHROPIC_DEFAULT_HAIKU_MODEL: envDict["ANTHROPIC_DEFAULT_HAIKU_MODEL"] ?? "",
            ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME: envDict["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"] ?? "",
            ANTHROPIC_DEFAULT_FABLE_MODEL: envDict["ANTHROPIC_DEFAULT_FABLE_MODEL"] ?? "",
            ANTHROPIC_DEFAULT_FABLE_MODEL_NAME: envDict["ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"] ?? "",
            CLAUDE_CODE_AUTO_COMPACT_WINDOW: envDict["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] ?? ""
        )
    }

    static func writeSettings(env: EnvConfig) throws {
        // By design, an empty preset value does NOT overwrite a value the user
        // set manually — so switching to a provider without an auth token
        // keeps the previously-written token. This prevents preset gaps from
        // wiping hand-edited config, at the cost of needing an explicit clear
        // path if a credential must be removed (delete it in settings.json).
        let existingEnv = readSettings()

        func preserve(newValue: String, existing: String?) -> String {
            if !newValue.isEmpty { return newValue }
            if let existing = existing, !existing.isEmpty { return existing }
            return ""
        }

        let envDict: [String: String] = [
            "ANTHROPIC_AUTH_TOKEN": preserve(newValue: env.ANTHROPIC_AUTH_TOKEN, existing: existingEnv?.ANTHROPIC_AUTH_TOKEN),
            "ANTHROPIC_BASE_URL": preserve(newValue: env.ANTHROPIC_BASE_URL, existing: existingEnv?.ANTHROPIC_BASE_URL),
            "ANTHROPIC_MODEL": preserve(newValue: env.ANTHROPIC_MODEL, existing: existingEnv?.ANTHROPIC_MODEL),
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": preserve(newValue: env.CLAUDE_CODE_MAX_CONTEXT_TOKENS, existing: existingEnv?.CLAUDE_CODE_MAX_CONTEXT_TOKENS),
            "DISABLE_COMPACT": preserve(newValue: env.DISABLE_COMPACT, existing: existingEnv?.DISABLE_COMPACT),
            "GITHUB_PERSONAL_ACCESS_TOKEN": preserve(newValue: env.GITHUB_PERSONAL_ACCESS_TOKEN, existing: existingEnv?.GITHUB_PERSONAL_ACCESS_TOKEN),
            "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": preserve(newValue: env.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS, existing: existingEnv?.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS),
            "ANTHROPIC_DEFAULT_OPUS_MODEL": preserve(newValue: env.ANTHROPIC_DEFAULT_OPUS_MODEL, existing: existingEnv?.ANTHROPIC_DEFAULT_OPUS_MODEL),
            "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": preserve(newValue: env.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME, existing: existingEnv?.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME),
            "ANTHROPIC_DEFAULT_SONNET_MODEL": preserve(newValue: env.ANTHROPIC_DEFAULT_SONNET_MODEL, existing: existingEnv?.ANTHROPIC_DEFAULT_SONNET_MODEL),
            "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": preserve(newValue: env.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME, existing: existingEnv?.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME),
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": preserve(newValue: env.ANTHROPIC_DEFAULT_HAIKU_MODEL, existing: existingEnv?.ANTHROPIC_DEFAULT_HAIKU_MODEL),
            "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": preserve(newValue: env.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME, existing: existingEnv?.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME),
            "ANTHROPIC_DEFAULT_FABLE_MODEL": preserve(newValue: env.ANTHROPIC_DEFAULT_FABLE_MODEL, existing: existingEnv?.ANTHROPIC_DEFAULT_FABLE_MODEL),
            "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME": preserve(newValue: env.ANTHROPIC_DEFAULT_FABLE_MODEL_NAME, existing: existingEnv?.ANTHROPIC_DEFAULT_FABLE_MODEL_NAME),
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW": preserve(newValue: env.CLAUDE_CODE_AUTO_COMPACT_WINDOW, existing: existingEnv?.CLAUDE_CODE_AUTO_COMPACT_WINDOW),
        ]

        // Preserve existing top-level fields (permissions, plugins, etc.)
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: FilePaths.settingsFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        json["env"] = envDict

        var data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        // JSONSerialization escapes "/" in strings (e.g. https:\/\/…);
        // unescape so URLs stay clean and diffable. Content is otherwise
        // untouched, so the result is still valid JSON.
        if let raw = String(data: data, encoding: .utf8) {
            data = raw.replacingOccurrences(of: "\\/", with: "/").data(using: .utf8) ?? data
        }
        // Ensure the parent directory exists before the atomic write (fresh
        // machines may not have ~/.claude yet — reading is tolerant of a
        // missing file, writing is not).
        try FileManager.default.createDirectory(at: FilePaths.claudeDir, withIntermediateDirectories: true)
        try data.write(to: FilePaths.settingsFile, options: .atomic)
    }
}
