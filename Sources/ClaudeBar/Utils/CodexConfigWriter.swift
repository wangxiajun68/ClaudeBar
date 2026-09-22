import Foundation

/// Section-aware, line-preserving editor for `~/.codex/config.toml` plus the
/// `auth.json` writer. We only own a handful of top-level keys and the
/// `[model_providers.<key>]` table; every other line — comments, blank lines,
/// `[projects."…"]`, `[mcp_servers.*]`, `notify = [...]` — is copied
/// verbatim, so switching providers never damages Codex's own state.
///
/// This is deliberately NOT a TOML parser: dotted table names like
/// `projects."/Users/…"` are treated as opaque strings and matched exactly.
enum CodexConfigWriter {

    // MARK: - TOML Document

    struct TOMLSection {
        var headerLine: String  // verbatim, e.g. `[projects."/Users/…"]`
        var name: String        // raw header text between the brackets
        var lines: [String]     // verbatim key lines / comments / blanks
    }

    struct TOMLDocument {
        var preamble: [String] = []
        var sections: [TOMLSection] = []

        mutating func removePreambleLines(keys: Set<String>) {
            preamble.removeAll { line in
                guard let m = line.range(of: #"^\s*([A-Za-z0-9_-]+)\s*="#, options: .regularExpression) else { return false }
                let key = line[m].replacingOccurrences(of: #"[\s=]"#, with: "", options: .regularExpression)
                return keys.contains(key)
            }
        }
    }

    /// Split into preamble + sections. A line whose trimmed form starts with
    /// `[` and ends with `]` opens a new section; its header text is opaque.
    static func parse(_ text: String) -> TOMLDocument {
        var doc = TOMLDocument()
        var current: TOMLSection? = nil
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 {
                if let c = current { doc.sections.append(c) }
                current = TOMLSection(headerLine: trimmed,
                                      name: String(trimmed.dropFirst().dropLast()),
                                      lines: [])
            } else if var c = current {
                c.lines.append(line)
                current = c
            } else {
                doc.preamble.append(line)
            }
        }
        if let c = current { doc.sections.append(c) }
        return doc
    }

    static func render(_ doc: TOMLDocument) -> String {
        var out: [String] = doc.preamble
        for s in doc.sections {
            if !out.isEmpty && out.last != "" { out.append("") } // blank line between blocks
            out.append(s.headerLine)
            out.append(contentsOf: s.lines)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - TOML value serialization

    static func serialize(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Write config.toml

    /// Managed top-level keys (also used for reading the current state).
    static let managedTopLevelKeys: Set<String> = [
        "model", "model_provider", "model_reasoning_effort",
        "model_context_window", "model_auto_compact_token_limit",
        "disable_response_storage",
        "model_catalog_json",
    ]

    /// Preamble block written before the managed keys, once per file, so a
    /// clobbered `config.toml` is at least traceable to the app.
    static let managedMarker = "# Managed by ClaudeBar — [model_providers.custom] and the keys below are rewritten on every switch."

    /// `[model_providers.custom]` is the one table name that can collide with
    /// a table the user wrote by hand: it is Codex's own documented convention
    /// and `activeKey` defaults to `custom` (`CodexProvider.key`), so a user
    /// who configured their own `custom` provider — which is exactly what this
    /// app's own `ProviderBridge` treats as the Claude twin — would have it
    /// overwritten, `base_url` and all, by the next switch.
    ///
    /// Order of preference for the slot we write into:
    ///   1. the key the active provider already carries, if it is not `custom`;
    ///   2. `[model_providers.custom]`, if it does not exist yet;
    ///   3. the first `claudebar*` name (deterministic, ours by construction);
    ///   4. a fresh `claudebar` table, appending after any existing sections.
    ///
    /// Only (2) and (4) are truly safe; (1) is the user's own choice of key,
    /// and (3) reuses a table this app created. Nothing here picks an existing
    /// foreign name.
    static func resolvedProviderKey(requested key: String, in doc: TOMLDocument) -> String {
        let existing = Set(doc.sections.map(\.name))
        let header = "model_providers.custom"
        if !key.isEmpty, key != "custom" {
            // A key that resolves to a built-in provider id is not "the user's
            // choice" — Codex refuses the whole file:
            //   "model_providers contains reserved built-in provider IDs: … .
            //    Built-in providers cannot be overridden. Rename your custom
            //    provider (for example, `openai-custom`)."
            // (`validate_reserved_model_provider_ids` in
            // `codex-rs/config/src/config_toml.rs`; list in
            // `codex-rs/model-provider-info/src/lib.rs`.) `openai` is the one
            // users actually hit — a vendor literally named "OpenAI" produces
            // it — so rename rather than refuse, and leave an existing real
            // table alone if this name is already ours.
            if reservedProviderIDs.contains(key.lowercased()) {
                return freeProviderKey(basedOn: "\(key)-claudebar", existing: existing)
            }
            // A non-`custom` key that already exists is a table the user (or a
            // previous ClaudeBar run) created for this provider — reuse it.
            return key
        }
        if !existing.contains(header) { return "custom" }
        if let ours = doc.sections
            .map(\.name)
            .first(where: { $0.hasPrefix("model_providers.claudebar") }) {
            return String(ours.dropFirst("model_providers.".count))
        }
        return freeProviderKey(basedOn: "claudebar", existing: existing)
    }

    /// Built-in `model_providers` ids Codex reserves for itself. Writing a
    /// custom table under one of these is a hard load error, not a shadow.
    static let reservedProviderIDs: Set<String> = [
        "openai",
        "ollama",
        "lmstudio",
        "amazon-bedrock",
        "amazon-bedrock-runtime",
    ]

    private static func freeProviderKey(basedOn base: String, existing: Set<String>) -> String {
        if !existing.contains("model_providers.\(base)") { return base }
        var n = 2
        while existing.contains("model_providers.\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    /// The value older builds wrote where the proxy token belongs. The token
    /// check rejects it, so a table still carrying it 401s the thread pinned
    /// to that table — see `healProxyTokens`.
    static let proxyBearerPlaceholder = "PROXY_MANAGED"

    /// Copy `config.toml` aside once per launch before the first rewrite.
    ///
    /// The writer is verified byte-faithful for keys it does not own, but it
    /// does rewrite `[model_providers.<key>]` and the managed preamble, and a
    /// bad `activeKey` used to be able to take a neighbouring table with it —
    /// with no backup anywhere in the app. `config.toml.bak` is written once
    /// and never overwritten, so it always holds the state from before the
    /// first switch of this run.
    private static var didBackUp = false

    static func backUpOnce() {
        guard !didBackUp else { return }
        didBackUp = true
        let fm = FileManager.default
        let src = FilePaths.codexConfigFile
        let dst = src.appendingPathExtension("bak")
        guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { return }
        try? fm.copyItem(at: src, to: dst)
    }

    /// Writing happens off the main actor (`CodexProviderStore.activate`), so
    /// the latch needs its own lock rather than riding on main-thread timing.
    private static let backUpLock = NSLock()
    static func backUpOnceThreadSafe() {
        backUpLock.lock(); defer { backUpLock.unlock() }
        backUpOnce()
    }

    static func write(provider: CodexProvider, model: CodexModelConfig, key: String,
                      proxyBaseURL: String? = nil) throws {
        let url = FilePaths.codexConfigFile
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var doc = parse(text)
        // Before anything is rewritten: resolve which `[model_providers.*]`
        // table we are allowed to touch, and make sure a copy exists.
        let key = resolvedProviderKey(requested: key, in: doc)
        backUpOnceThreadSafe()

        // When routing through the local proxy, config.toml points at the
        // proxy and Codex always speaks Responses (the proxy consults
        // CodexProxyState for the real upstream's dialect).
        let effectiveBase = proxyBaseURL ?? provider.baseURL
        // Codex removed the Chat wire API outright: `wire_api = "chat"` now
        // fails *deserialization of the entire file* ("`wire_api = \"chat\"`
        // is no longer supported … set `wire_api = \"responses\"`" —
        // openai/codex `codex-rs/model-provider-info/src/lib.rs`, the
        // `Deserialize` impl for `WireApi`; only `responses` is accepted).
        // A provider row carrying `chat` therefore does not misroute, it stops
        // Codex from starting at all. The Chat dialect is still a real thing —
        // but it belongs to the proxy's *upstream* choice
        // (`CodexProxyTransform`), never to this file.
        let effectiveWireAPI = "responses"

        try CodexModelCatalog.write(
            provider: provider,
            fallbackContextWindow: Int(model.contextWindow).flatMap { $0 > 0 ? $0 : nil })

        // 1. Strip our managed top-level keys, re-append at preamble end.
        doc.removePreambleLines(keys: managedTopLevelKeys)
        var managed: [String] = [
            "model = \(serialize(model.name))",
            "model_provider = \(serialize(key))",
        ]
        if !model.reasoningEffort.isEmpty {
            managed.append("model_reasoning_effort = \(serialize(model.reasoningEffort))")
        }
        if let window = Int(model.contextWindow), window > 0 {
            managed.append("model_context_window = \(window)")
        }
        if let compact = Int(model.autoCompactTokenLimit), compact > 0 {
            managed.append("model_auto_compact_token_limit = \(compact)")
        }
        managed.append("disable_response_storage = \(provider.disableResponseStorage)")
        managed.append("model_catalog_json = \(serialize(CodexModelCatalog.filename))")
        doc.preamble = trimTrailingBlanks(doc.preamble) + managed

        // 2. Replace or create exactly [model_providers.<key>]; other
        //    [model_providers.*] tables stay untouched. Unknown keys in our
        //    table (comments, experimental flags we don't own) are preserved.
        let header = "model_providers.\(key)"
        var owned: [(String, String)] = [
            ("name", serialize(provider.name)),
            ("base_url", serialize(effectiveBase)),
            ("wire_api", serialize(effectiveWireAPI)),
            ("requires_openai_auth", String(provider.requiresOpenAIAuth)),
        ]
        if proxyBaseURL != nil {
            // The proxy now requires a bearer token, so `PROXY_MANAGED` alone
            // is not enough for Codex to get through it. `diagnose()` before a
            // switch may see this placeholder and report "configured".
            owned.append(("experimental_bearer_token", serialize(CodexProxyServer.configuredToken)))
        }
        upsertProviderSection(&doc, header: header, owned: owned,
                              dropKeys: proxyBaseURL == nil ? ["experimental_bearer_token"] : [])

        try FileManager.default.createDirectory(at: FilePaths.codexDir, withIntermediateDirectories: true)
        try render(doc).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Merge owned keys into `[model_providers.<key>]`. Lines whose key we
    /// don't manage are copied verbatim (comments, extra flags).
    private static func upsertProviderSection(_ doc: inout TOMLDocument, header: String,
                                              owned: [(String, String)],
                                              dropKeys: [String]) {
        let drop = Set(dropKeys)
        let newValues = Dictionary(uniqueKeysWithValues: owned)

        func isOwnedKey(_ line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { return nil }
            guard let eq = trimmed.firstIndex(of: "=") else { return nil }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            return key
        }

        if let idx = doc.sections.firstIndex(where: { $0.name == header }) {
            var seen = Set<String>()
            var lines: [String] = []
            for line in doc.sections[idx].lines {
                if let key = isOwnedKey(line) {
                    if drop.contains(key) { continue }
                    if let value = newValues[key] {
                        lines.append("\(key) = \(value)")
                        seen.insert(key)
                        continue
                    }
                }
                lines.append(line)
            }
            for (key, value) in owned where !seen.contains(key) {
                lines.append("\(key) = \(value)")
            }
            doc.sections[idx].lines = lines
        } else {
            let body = owned.map { "\($0.0) = \($0.1)" }
            doc.sections.append(TOMLSection(headerLine: "[\(header)]", name: header, lines: body))
        }
    }

    /// Read the managed top-level keys back for reconcile-on-load.
    static func readCurrent() -> (model: String, providerKey: String, wireAPI: String, baseURL: String)? {
        guard let text = try? String(contentsOf: FilePaths.codexConfigFile, encoding: .utf8) else { return nil }
        let doc = parse(text)
        var values: [String: String] = [:]
        for line in doc.preamble {
            guard let m = line.range(of: #"^\s*([A-Za-z0-9_-]+)\s*=\s*(.+?)\s*(#.*)?$"#, options: .regularExpression) else { continue }
            let full = line[m]
            let parts = full.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard managedTopLevelKeys.contains(key) else { continue }
            var value = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        guard let model = values["model"], !model.isEmpty else { return nil }
        let providerKey = values["model_provider"] ?? "custom"
        var wireAPI = "responses"
        var baseURL = ""
        if let section = doc.sections.first(where: { $0.name == "model_providers.\(providerKey)" }) {
            for line in section.lines {
                if let v = splitTOMLValue(line, key: "wire_api") { wireAPI = v }
                if let v = splitTOMLValue(line, key: "base_url") { baseURL = v }
            }
        }
        return (model, providerKey, wireAPI, baseURL)
    }

    /// True when `config.toml` currently routes through the local proxy —
    /// i.e. the section we manage holds the proxy's own base URL.
    static func usesProxy(proxyBaseURL: String) -> Bool {
        guard let current = readCurrent() else { return false }
        let trimmed = current.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed == proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            || trimmed.hasPrefix("http://127.0.0.1:")
            || trimmed.hasPrefix("http://localhost:")
    }

    /// Whether the managed section's `experimental_bearer_token` is the current
    /// proxy token. `false` covers both "some other value" and "already the
    /// proxy token from a previous run" — callers use it to decide whether a
    /// heal-write is needed, so a false positive only costs a redundant write.
    static func bearerIsProxyToken() -> Bool {
        guard let text = try? String(contentsOf: FilePaths.codexConfigFile, encoding: .utf8),
              let current = readCurrent() else { return false }
        let doc = parse(text)
        guard let section = doc.sections.first(where: { $0.name == "model_providers.\(current.providerKey)" }),
              let value = section.lines.compactMap({ splitTOMLValue($0, key: "experimental_bearer_token") }).first
        else { return false }
        return value == CodexProxyServer.configuredToken
    }

    /// Replace the `PROXY_MANAGED` placeholder left by older builds with the
    /// live proxy token, in every `[model_providers.*]` table that points at
    /// the proxy.
    ///
    /// The preamble's `model_provider` is not the only table a thread can be
    /// pinned to: Codex stores `model_provider_id` per thread, and threads
    /// created before the token requirement keep a table name the current
    /// preamble no longer names. `resolvedProviderKey` picks one table to
    /// manage and leaves the rest alone, so such a table sat there with the
    /// placeholder while the app's own heal-write (`startProxy`, which heals
    /// only `readCurrent().providerKey`) passed it by — the thread then 401s on
    /// every turn with nothing in the UI to explain why.
    ///
    /// Only the placeholder is touched: a table naming a *different* token is
    /// either a provider the user configured by hand or another proxy instance,
    /// and both are theirs to keep.
    ///
    /// - Returns: the table names whose token was rewritten, for logging.
    @discardableResult
    static func healProxyTokens(proxyBaseURL: String) -> [String] {
        let url = FilePaths.codexConfigFile
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var doc = parse(text)
        let token = CodexProxyServer.configuredToken
        guard !token.isEmpty else { return [] }

        let proxy = proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var healed: [String] = []

        for idx in doc.sections.indices {
            var lines = doc.sections[idx].lines
            let rawBase = lines.compactMap { splitTOMLValue($0, key: "base_url") }.first ?? ""
            let base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard base == proxy else { continue }

            var rewrote = false
            for (i, line) in lines.enumerated() {
                guard splitTOMLValue(line, key: "experimental_bearer_token") == proxyBearerPlaceholder
                else { continue }
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                lines[i] = "\(indent)experimental_bearer_token = \(serialize(token))"
                rewrote = true
            }
            // A table pointing straight at this proxy with no token at all is
            // the same 401 by a different route. Only a table aimed at *this*
            // proxy qualifies — another localhost port is someone else's
            // proxy, and its credential is not ours to replace.
            if !rewrote,
               !lines.contains(where: { splitTOMLValue($0, key: "experimental_bearer_token") != nil }) {
                lines.append("experimental_bearer_token = \(serialize(token))")
                rewrote = true
            }
            guard rewrote else { continue }
            doc.sections[idx].lines = lines
            healed.append(doc.sections[idx].name)
        }

        guard !healed.isEmpty else { return [] }
        try? FileManager.default.createDirectory(at: FilePaths.codexDir, withIntermediateDirectories: true)
        try? render(doc).write(to: url, atomically: true, encoding: .utf8)
        return healed
    }

    /// Extract `key = "value"` from a TOML line (owned sections only).
    private static func splitTOMLValue(_ line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(key) else { return nil }
        var rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        rest = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        var value = String(rest)
        if value.hasPrefix("\"") {
            let inner = value.dropFirst()
            if let end = inner.firstIndex(of: "\"") {
                return String(inner[..<end])
            }
        }
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    // MARK: - Write auth.json

    /// True when auth.json carries an official ChatGPT login (tokens block /
    /// chatgpt auth mode) that should survive a third-party switch.
    static func hasOfficialLogin(_ dict: [String: Any]) -> Bool {
        if dict["tokens"] is [String: Any] { return true }
        if let mode = dict["auth_mode"] as? String, mode == "chatgpt" { return true }
        return dict["id_token"] != nil
    }

    /// Custom id for the official ChatGPT route. `openai` itself is reserved
    /// and hard-codes `supports_websockets = true`, which is the "Reconnecting
    /// 1/5 … 5/5" loop on every new thread. This id is not reserved.
    static let officialHTTPProviderID = "openai_http"

    /// Drop the third-party overlay and point Codex at an HTTP-only official
    /// provider that still uses the ChatGPT login already in `auth.json`.
    ///
    /// cc-switch's "OpenAI Official" card writes an empty `config` and an
    /// empty `auth`, which leaves the built-in `openai` provider in place and
    /// does not rewrite a live login. Empty config is what brings the
    /// WebSocket retry budget back, so the table below is the one deliberate
    /// difference: `name = "OpenAI"` (Codex treats that name as first-party)
    /// and `supports_websockets = false`. `base_url` stays unset so a ChatGPT
    /// session uses `https://chatgpt.com/backend-api/codex`.
    ///
    /// Managed preamble keys go. `[model_providers.custom]` / `claudebar*` /
    /// the table we were pointing at go, including a previous `openai_http`
    /// so the official table is rewritten clean. Built-in ids and the user's
    /// other tables stay. `[projects.*]` and comments stay.
    static func restoreOfficial() throws {
        let url = FilePaths.codexConfigFile
        backUpOnceThreadSafe()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var doc = parse(text)
        var currentKey: String?
        for line in doc.preamble {
            if let value = splitTOMLValue(line, key: "model_provider") {
                currentKey = value
                break
            }
        }

        doc.removePreambleLines(keys: managedTopLevelKeys)
        doc.preamble.removeAll {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("# Managed by ClaudeBar")
        }
        doc.preamble = trimTrailingBlanks(doc.preamble) + [
            "model_provider = \(serialize(officialHTTPProviderID))",
        ]

        doc.sections.removeAll { section in
            guard section.name.hasPrefix("model_providers.") else { return false }
            let key = String(section.name.dropFirst("model_providers.".count))
            if reservedProviderIDs.contains(key.lowercased()) { return false }
            if key == officialHTTPProviderID || key == "custom" || key.hasPrefix("claudebar") {
                return true
            }
            if let currentKey, key == currentKey { return true }
            return false
        }
        doc.sections.append(TOMLSection(
            headerLine: "[model_providers.\(officialHTTPProviderID)]",
            name: "model_providers.\(officialHTTPProviderID)",
            lines: [
                "name = \"OpenAI\"",
                "wire_api = \"responses\"",
                "requires_openai_auth = true",
                "supports_websockets = false",
            ]
        ))

        try FileManager.default.createDirectory(at: FilePaths.codexDir, withIntermediateDirectories: true)
        try render(doc).write(to: url, atomically: true, encoding: .utf8)
    }

    /// cc-switch's unbound official card does not write `auth.json` at all:
    /// an empty stored auth follows whatever ChatGPT login is already on disk.
    ///
    /// A live session (tokens / id_token) is left byte-for-byte alone, except
    /// a third-party `OPENAI_API_KEY` sitting next to it is removed. A file
    /// that is only that key — no login — is deleted, matching
    /// `clear_stale_codex_live_auth_after_official_switch`. Anything else is
    /// left untouched so a restore cannot turn a login into a logout.
    static func restoreOfficialAuth() throws {
        let url = FilePaths.codexAuthFile
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let hasSession = json["tokens"] is [String: Any] || json["id_token"] != nil
        if hasSession {
            guard json["OPENAI_API_KEY"] != nil else { return }
            json.removeValue(forKey: "OPENAI_API_KEY")
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: .atomic)
            return
        }
        if json["OPENAI_API_KEY"] != nil {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func writeAuth(apiKey: String, preserveOfficialLogin: Bool) throws {
        let url = FilePaths.codexAuthFile
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        if preserveOfficialLogin && hasOfficialLogin(json) {
            // Keep every existing key (official tokens stay); only refresh
            // the third-party key. Note: Codex desktop may still prefer the
            // ChatGPT auth for custom providers — the key is present for
            // CLI / API-key flows.
            json["OPENAI_API_KEY"] = apiKey
        } else {
            json = ["OPENAI_API_KEY": apiKey, "auth_mode": "apikey"]
        }

        try FileManager.default.createDirectory(at: FilePaths.codexDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    private static func trimTrailingBlanks(_ lines: [String]) -> [String] {
        var out = lines
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        return out
    }
}
