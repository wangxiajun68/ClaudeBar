import Foundation

struct SettingsManager {
    static func readSettings() -> (env: EnvConfig?, raw: [String: Any]) {
        guard FileManager.default.fileExists(atPath: FilePaths.settingsFile.path),
              let data = try? Data(contentsOf: FilePaths.settingsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, [:])
        }

        let env: EnvConfig?
        if let envDict = json["env"] as? [String: String] {
            env = EnvConfig(
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
        } else {
            env = nil
        }

        return (env, json)
    }

    static func writeSettings(env: EnvConfig) throws {
        // Read existing env so empty preset values don't nuke user's manual config
        let (existingEnv, _) = readSettings()

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
        // Fix: JSONSerialization escapes forward slashes in strings (e.g. https:\/\/...).
        // Replace them back so URLs are clean and readable.
        if let raw = String(data: data, encoding: .utf8) {
            let cleaned = raw.replacingOccurrences(of: "\\/", with: "/")
            data = cleaned.data(using: .utf8) ?? data
        }
        try data.write(to: FilePaths.settingsFile, options: .atomic)
    }
}
