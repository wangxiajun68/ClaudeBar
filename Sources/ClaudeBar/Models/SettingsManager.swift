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

    /// Copy `settings.json` aside once per launch, before the first rewrite.
    ///
    /// This file holds `ANTHROPIC_AUTH_TOKEN` and is regenerated wholesale on
    /// every provider switch; the app had no backup anywhere. Written once and
    /// never overwritten, so it holds the state from before the first switch
    /// of this run. Together with the 0600 mode below, that is the difference
    /// between "a bad switch is recoverable" and "the user's key is gone".
    private static var didBackUp = false

    static func backUpOnce() {
        guard !didBackUp else { return }
        didBackUp = true
        let fm = FileManager.default
        let src = FilePaths.settingsFile
        let dst = src.appendingPathExtension("bak")
        guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { return }
        try? fm.copyItem(at: src, to: dst)
    }

    static func writeSettings(env: EnvConfig) throws {
        backUpOnce()
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
        // This file carries `ANTHROPIC_AUTH_TOKEN`. The default umask leaves a
        // newly created file at 0644 — world-readable — and 0644 is exactly
        // what an existing one has after the first write. Narrow it every
        // time, since the atomic rename replaces the inode.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: FilePaths.settingsFile.path)
        // The backup is a copy of the same secret; narrow it too.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: FilePaths.settingsFile.appendingPathExtension("bak").path)
    }

    /// Keys ClaudeBar writes into `env` on every vendor switch. Restoring the
    /// official Anthropic login means *deleting* them — `writeSettings`'
    /// `preserve()` keeps a previous token when the new value is empty, which
    /// is the opposite of what "go back to official" has to do.
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
        backUpOnce()
        let url = FilePaths.settingsFile
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if var env = json["env"] as? [String: Any] {
            for key in managedEnvKeys { env.removeValue(forKey: key) }
            if env.isEmpty {
                json.removeValue(forKey: "env")
            } else {
                json["env"] = env
            }
        }
        var out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        if let raw = String(data: out, encoding: .utf8) {
            out = raw.replacingOccurrences(of: "\\/", with: "/").data(using: .utf8) ?? out
        }
        try FileManager.default.createDirectory(at: FilePaths.claudeDir, withIntermediateDirectories: true)
        try out.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
