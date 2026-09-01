import Foundation

/// Bidirectional conversion between Claude Code providers and Codex providers.
///
/// Shared contract:
///   CC  `contextTokens`       ↔ Codex `contextWindow`                 (`model_context_window`)
///   CC  `autoCompactWindow`   ↔ Codex `autoCompactTokenLimit`         (`model_auto_compact_token_limit`)
///   CC  `authToken` / `baseURL` ↔ Codex `apiKey` / OpenAI-compatible URL
///
/// Claude Code talks Anthropic (`/anthropic`, `/messages`); Codex talks
/// OpenAI Chat/Responses. Host-specific rewrites are the known pairs from
/// this machine's live configs (Zhipu, DashScope, OpenRouter, DeepSeek,
/// Aibox). Everything else uses the generic strip-/anthropic + `/v1` rules.
enum ProviderBridge {

    struct ImportResult: Equatable {
        var added: Int = 0
        var updated: Int = 0
        var modelsAdded: Int = 0

        var isEmpty: Bool { added == 0 && updated == 0 && modelsAdded == 0 }

        var summary: String {
            if isEmpty { return "没有可导入的新供应商" }
            var parts: [String] = []
            if added > 0 { parts.append("新增 \(added) 个供应商") }
            if updated > 0 { parts.append("更新 \(updated) 个") }
            if modelsAdded > 0 { parts.append("\(modelsAdded) 个模型") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Disk

    static func readClaudeProviders() -> [Provider] {
        guard let data = try? Data(contentsOf: FilePaths.presetsFile),
              let file = try? JSONDecoder().decode(ProvidersFile.self, from: data) else { return [] }
        return file.providers
    }

    static func readCodexProviders() -> [CodexProvider] {
        guard let data = try? Data(contentsOf: FilePaths.codexProvidersFile),
              let file = try? JSONDecoder().decode(CodexProvidersFile.self, from: data) else { return [] }
        return file.providers
    }

    // MARK: - Provider conversion

    static func toCodex(_ source: Provider) -> CodexProvider {
        let url = openaiCompatibleURL(source.baseURL)
        let models = source.models.map { model -> CodexModelConfig in
            CodexModelConfig(
                id: UUID(),
                name: stripClaudeModelSuffix(model.name),
                reasoningEffort: "",
                contextWindow: model.contextTokens,
                autoCompactTokenLimit: model.disableCompact ? "" : model.autoCompactWindow)
        }
        let activeSlug = source.activeModel.map { stripClaudeModelSuffix($0.name) }
        let activeID = models.first {
            $0.name.caseInsensitiveCompare(activeSlug ?? "") == .orderedSame
        }?.id ?? models.first?.id
        let wire = url.lowercased().contains("api.openai.com") ? "responses" : "chat"
        return CodexProvider(
            name: source.name,
            apiKey: source.authToken,
            baseURL: url,
            wireAPI: wire,
            requiresOpenAIAuth: false,
            preserveOfficialLogin: true,
            disableResponseStorage: true,
            models: models,
            activeModelID: activeID)
    }

    static func toClaude(_ source: CodexProvider) -> Provider {
        let url = anthropicCompatibleURL(source.baseURL)
        let models = source.models.map { model -> ModelConfig in
            ModelConfig(
                id: UUID(),
                name: claudeModelName(fromCodex: model.name, contextWindow: model.contextWindow),
                contextTokens: model.contextWindow,
                disableCompact: false,
                disableExperimentalBetas: false,
                autoCompactWindow: model.autoCompactTokenLimit)
        }
        let activeSlug = source.activeModel?.name ?? ""
        let activeID = models.first {
            stripClaudeModelSuffix($0.name).caseInsensitiveCompare(activeSlug) == .orderedSame
        }?.id ?? models.first?.id
        return Provider(
            name: source.name,
            authToken: source.apiKey,
            baseURL: url,
            models: models,
            activeModelID: activeID)
    }

    /// Claude and Codex records of the same vendor — name or rewritten OpenAI URL.
    static func matches(_ claude: Provider, _ codex: CodexProvider) -> Bool {
        if claude.name.caseInsensitiveCompare(codex.name) == .orderedSame { return true }
        return normalizeURL(claude.baseURL) == normalizeURL(codex.baseURL)
            && !claude.baseURL.isEmpty && !codex.baseURL.isEmpty
    }

    /// Codex extras that have no Claude equivalent. The unified editor keeps
    /// them on the Claude form and the projector writes them through.
    struct CodexExtras: Equatable {
        var wireAPI: String = "chat"
        var requiresOpenAIAuth: Bool = false
        var preserveOfficialLogin: Bool = true
        var disableResponseStorage: Bool = true
        /// Stripped model slug → reasoning effort (`""` = don't write).
        var reasoningBySlug: [String: String] = [:]
    }

    static func extras(from codex: CodexProvider) -> CodexExtras {
        var map: [String: String] = [:]
        for m in codex.models {
            map[m.name.lowercased()] = m.reasoningEffort
        }
        return CodexExtras(
            wireAPI: codex.wireAPI,
            requiresOpenAIAuth: codex.requiresOpenAIAuth,
            preserveOfficialLogin: codex.preserveOfficialLogin,
            disableResponseStorage: codex.disableResponseStorage,
            reasoningBySlug: map)
    }

    /// Overlay Claude fields onto an existing Codex record, keeping Codex-only
    /// flags / reasoning unless `extras` supplies replacements.
    static func overlay(_ source: Provider, onto dest: CodexProvider, extras: CodexExtras? = nil) -> CodexProvider {
        var out = dest
        out.name = source.name
        if !source.authToken.isEmpty { out.apiKey = source.authToken }
        let url = openaiCompatibleURL(source.baseURL)
        if !url.isEmpty { out.baseURL = url }

        var models = dest.models
        for m in source.models {
            let slug = stripClaudeModelSuffix(m.name)
            let compact = m.disableCompact ? "" : m.autoCompactWindow
            let effort = extras?.reasoningBySlug[slug.lowercased()]
            if let idx = models.firstIndex(where: { $0.name.caseInsensitiveCompare(slug) == .orderedSame }) {
                models[idx].name = slug
                models[idx].contextWindow = m.contextTokens
                models[idx].autoCompactTokenLimit = compact
                if let effort { models[idx].reasoningEffort = effort }
            } else {
                models.append(CodexModelConfig(
                    name: slug,
                    reasoningEffort: effort ?? "",
                    contextWindow: m.contextTokens,
                    autoCompactTokenLimit: compact))
            }
        }
        let slugs = Set(source.models.map { stripClaudeModelSuffix($0.name).lowercased() })
        models.removeAll { !slugs.contains($0.name.lowercased()) }
        out.models = models

        if let active = source.activeModel {
            let slug = stripClaudeModelSuffix(active.name)
            out.activeModelID = models.first {
                $0.name.caseInsensitiveCompare(slug) == .orderedSame
            }?.id ?? models.first?.id
        }

        if let extras {
            out.wireAPI = extras.wireAPI
            out.requiresOpenAIAuth = extras.requiresOpenAIAuth
            out.preserveOfficialLogin = extras.preserveOfficialLogin
            out.disableResponseStorage = extras.disableResponseStorage
        }
        return out
    }

    // MARK: - Merge

    static func merge(into existing: inout [CodexProvider], from imported: [CodexProvider]) -> ImportResult {
        var result = ImportResult()
        for incoming in imported {
            guard !incoming.models.isEmpty else { continue }
            if let idx = existing.firstIndex(where: { matches($0, incoming) }) {
                result.updated += 1
                result.modelsAdded += mergeCodexModels(into: &existing[idx], from: incoming)
                if !incoming.apiKey.isEmpty {
                    existing[idx].apiKey = incoming.apiKey
                }
                if existing[idx].baseURL.isEmpty {
                    existing[idx].baseURL = incoming.baseURL
                }
            } else {
                var copy = incoming
                copy.id = UUID()
                existing.append(copy)
                result.added += 1
                result.modelsAdded += copy.models.count
            }
        }
        return result
    }

    static func merge(into existing: inout [Provider], from imported: [Provider]) -> ImportResult {
        var result = ImportResult()
        for incoming in imported {
            guard !incoming.models.isEmpty else { continue }
            if let idx = existing.firstIndex(where: { matches($0, incoming) }) {
                result.updated += 1
                result.modelsAdded += mergeClaudeModels(into: &existing[idx], from: incoming)
                if !incoming.authToken.isEmpty {
                    existing[idx].authToken = incoming.authToken
                }
                if existing[idx].baseURL.isEmpty {
                    existing[idx].baseURL = incoming.baseURL
                }
            } else {
                var copy = incoming
                copy.id = UUID()
                existing.append(copy)
                result.added += 1
                result.modelsAdded += copy.models.count
            }
        }
        return result
    }

    // MARK: - Names

    /// Claude Code uses `glm-5.2[1M]` to opt into a 1M window. Codex wants
    /// the upstream slug with no suffix.
    static func stripClaudeModelSuffix(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"\[\d+[kKmM]\]$"#, options: .regularExpression) else {
            return trimmed
        }
        return String(trimmed[..<range.lowerBound])
    }

    /// Reverse: a ≥1M Codex window becomes the `[1M]` marker Claude Code
    /// already uses on this machine.
    static func claudeModelName(fromCodex name: String, contextWindow: String) -> String {
        let slug = stripClaudeModelSuffix(name)
        if slug != name { return name }
        if let n = Int(contextWindow), n >= 1_000_000 { return slug + "[1M]" }
        return slug
    }

    // MARK: - URLs

    static func openaiCompatibleURL(_ raw: String) -> String {
        var s = trimSlash(raw)
        let lower = s.lowercased()

        if lower.contains("open.bigmodel.cn") {
            return "https://open.bigmodel.cn/api/coding/paas/v4"
        }
        if lower.contains("dashscope.aliyuncs.com") {
            return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        }
        if lower.contains("openrouter.ai") {
            if lower.hasSuffix("/messages") {
                s = String(s.dropLast("/messages".count))
            }
            return trimSlash(s)
        }
        if lower.hasSuffix("/anthropic") {
            s = trimSlash(String(s.dropLast("/anthropic".count)))
        }
        if lower.contains("moonshot") || lower.contains("kimi.com") {
            if s.range(of: #"/v\d+$"#, options: .regularExpression) == nil {
                return s + "/v1"
            }
            return s
        }
        if isBareOrigin(s) {
            return s + "/v1"
        }
        return s
    }

    static func anthropicCompatibleURL(_ raw: String) -> String {
        let s = trimSlash(raw)
        let lower = s.lowercased()

        if lower.contains("open.bigmodel.cn") {
            return "https://open.bigmodel.cn/api/anthropic"
        }
        if lower.contains("dashscope.aliyuncs.com") {
            return "https://dashscope.aliyuncs.com/apps/anthropic"
        }
        if lower.contains("openrouter.ai") {
            return lower.hasSuffix("/messages") ? s : s + "/messages"
        }
        if lower.contains("deepseek.com") {
            return "https://api.deepseek.com/anthropic"
        }
        if lower.contains("moonshot") || lower.contains("kimi.com") {
            let stripped = s.replacingOccurrences(
                of: #"/v\d+$"#, with: "", options: .regularExpression)
            return trimSlash(stripped) + "/anthropic"
        }
        if let url = URL(string: s), url.path == "/v1" {
            // Aibox / local OpenAI-compat roots: Claude Code talks to the
            // origin, not /v1 and not /anthropic.
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.path = ""
            if let rebuilt = parts?.string { return trimSlash(rebuilt) }
        }
        if lower.hasSuffix("/anthropic") || lower.hasSuffix("/messages") {
            return s
        }
        return s
    }

    // MARK: - Internals

    private static func matches(_ a: CodexProvider, _ b: CodexProvider) -> Bool {
        if a.name.caseInsensitiveCompare(b.name) == .orderedSame { return true }
        return normalizeURL(a.baseURL) == normalizeURL(b.baseURL)
            && !a.baseURL.isEmpty && !b.baseURL.isEmpty
    }

    private static func matches(_ a: Provider, _ b: Provider) -> Bool {
        if a.name.caseInsensitiveCompare(b.name) == .orderedSame { return true }
        return normalizeURL(a.baseURL) == normalizeURL(b.baseURL)
            && !a.baseURL.isEmpty && !b.baseURL.isEmpty
    }

    private static func mergeCodexModels(into dest: inout CodexProvider, from src: CodexProvider) -> Int {
        var added = 0
        for incoming in src.models {
            if let idx = dest.models.firstIndex(where: {
                $0.name.caseInsensitiveCompare(incoming.name) == .orderedSame
            }) {
                if dest.models[idx].contextWindow.isEmpty {
                    dest.models[idx].contextWindow = incoming.contextWindow
                } else if !incoming.contextWindow.isEmpty {
                    dest.models[idx].contextWindow = incoming.contextWindow
                }
                if !incoming.autoCompactTokenLimit.isEmpty {
                    dest.models[idx].autoCompactTokenLimit = incoming.autoCompactTokenLimit
                }
            } else {
                var copy = incoming
                copy.id = UUID()
                dest.models.append(copy)
                added += 1
            }
        }
        if dest.activeModelID == nil { dest.activeModelID = dest.models.first?.id }
        return added
    }

    private static func mergeClaudeModels(into dest: inout Provider, from src: Provider) -> Int {
        var added = 0
        for incoming in src.models {
            if let idx = dest.models.firstIndex(where: {
                stripClaudeModelSuffix($0.name).caseInsensitiveCompare(stripClaudeModelSuffix(incoming.name)) == .orderedSame
            }) {
                if !incoming.contextTokens.isEmpty {
                    dest.models[idx].contextTokens = incoming.contextTokens
                }
                if !incoming.autoCompactWindow.isEmpty {
                    dest.models[idx].autoCompactWindow = incoming.autoCompactWindow
                    dest.models[idx].disableCompact = incoming.disableCompact
                }
            } else {
                var copy = incoming
                copy.id = UUID()
                dest.models.append(copy)
                added += 1
            }
        }
        if dest.activeModelID == nil { dest.activeModelID = dest.models.first?.id }
        return added
    }

    private static func trimSlash(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func normalizeURL(_ s: String) -> String {
        openaiCompatibleURL(s).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isBareOrigin(_ s: String) -> Bool {
        guard let url = URL(string: s), url.host != nil else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty
    }
}
