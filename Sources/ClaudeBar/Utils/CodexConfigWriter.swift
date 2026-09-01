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

    static let proxyBearerPlaceholder = "PROXY_MANAGED"

    static func write(provider: CodexProvider, model: CodexModelConfig, key: String,
                      proxyBaseURL: String? = nil) throws {
        let url = FilePaths.codexConfigFile
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var doc = parse(text)

        // When routing through the local proxy, config.toml points at the
        // proxy and Codex always speaks Responses (the proxy consults
        // CodexProxyState for the real upstream's dialect).
        let effectiveBase = proxyBaseURL ?? provider.baseURL
        let effectiveWireAPI = proxyBaseURL != nil ? "responses" : provider.wireAPI

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
            owned.append(("experimental_bearer_token", serialize(proxyBearerPlaceholder)))
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
