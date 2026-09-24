import Foundation

/// Explicit per-client endpoints; never guess an Anthropic URL from an OpenAI URL.
enum ProviderClient: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }
}

struct ProviderCatalogEntry: Identifiable, Equatable {
    struct Endpoint: Equatable {
        let baseURL: String
        let models: [String]
        var wireAPI = "responses"
        /// Only documented alternate protocols; never derive a plan URL from its host.
        var chatBaseURL: String? = nil
        var modelsURL: String? = nil
        var supportedWireAPIs: [String] { chatBaseURL == nil ? [wireAPI] : ["responses", "chat"] }
        func url(for wire: String) -> String { wire == "chat" ? chatBaseURL ?? baseURL : baseURL }
    }
    enum Category: String, CaseIterable, Identifiable {
        case platform = "模型平台", coding = "Coding / Token Plan", gateway = "聚合与自建"
        var id: String { rawValue }
    }
    let id: String
    let name: String
    let monogram: String
    let color: UInt32
    let category: Category
    let detail: String
    let website: String
    let claude: Endpoint?
    let codex: Endpoint?
    func endpoint(for client: ProviderClient) -> Endpoint? { client == .claude ? claude : codex }

    // Protocol facts checked 2026-09-24; sources: docs/technical/13-provider-directory.md.
    // CC Switch informs the preset flow; current vendor docs own protocol support.
    // No affiliate links, credentials, executable remote templates, or auto-activation.
    static let all: [Self] = [
        .init(id: "anthropic", name: "Anthropic API", monogram: "A", color: 0xA66349, category: .platform,
              detail: "API Key 接入 · 非 Claude 订阅", website: "https://platform.claude.com/settings/keys",
              claude: .init(baseURL: "https://api.anthropic.com", models: ["claude-sonnet-4-6"]), codex: nil),
        .init(id: "deepseek", name: "DeepSeek", monogram: "D", color: 0x3974ED, category: .platform,
              detail: "深度求索 · 国内 API", website: "https://platform.deepseek.com",
              claude: .init(baseURL: "https://api.deepseek.com/anthropic", models: ["deepseek-v4-pro", "deepseek-v4-flash"], modelsURL: "https://api.deepseek.com/models"),
              codex: .init(baseURL: "https://api.deepseek.com", models: ["deepseek-flash", "deepseek-v4-pro"], chatBaseURL: "https://api.deepseek.com/v1", modelsURL: "https://api.deepseek.com/models")),
        .init(id: "kimi", name: "Kimi", monogram: "K", color: 0x5661DE, category: .platform,
              detail: "Moonshot · 开放平台", website: "https://platform.kimi.com",
              claude: .init(baseURL: "https://api.moonshot.cn/anthropic", models: ["kimi-k2.7-code"]),
              codex: .init(baseURL: "https://api.moonshot.cn/v1", models: ["kimi-k3", "kimi-k2.7-code"], chatBaseURL: "https://api.moonshot.cn/v1")),
        .init(id: "kimi-coding", name: "Kimi For Coding", monogram: "K", color: 0x5661DE, category: .coding,
              detail: "使用 Coding 订阅专用 Key", website: "https://www.kimi.com/code/",
              claude: .init(baseURL: "https://api.kimi.com/coding", models: ["kimi-for-coding"]), codex: nil),
        .init(id: "glm", name: "智谱 GLM", monogram: "GL", color: 0x3468CA, category: .platform,
              detail: "开放平台按量 API", website: "https://open.bigmodel.cn",
              claude: .init(baseURL: "https://open.bigmodel.cn/api/anthropic", models: ["glm-5.2"]),
              codex: .init(baseURL: "https://open.bigmodel.cn/api/paas/v4", models: ["glm-5.2"], wireAPI: "chat")),
        .init(id: "glm-coding", name: "智谱 Coding Plan", monogram: "GL", color: 0x3468CA, category: .coding,
              detail: "国内 Coding 套餐 · 专用 Key", website: "https://open.bigmodel.cn",
              claude: .init(baseURL: "https://open.bigmodel.cn/api/anthropic", models: ["glm-5.1"]),
              codex: .init(baseURL: "https://open.bigmodel.cn/api/v1", models: ["glm-5.3"], chatBaseURL: "https://open.bigmodel.cn/api/coding/paas/v4")),
        .init(id: "minimax-cn", name: "MiniMax", monogram: "M", color: 0xD85B70, category: .platform,
              detail: "国内 API / Token Plan · 按 Key 计费", website: "https://platform.minimax.cn",
              claude: .init(baseURL: "https://api.minimax.cn/anthropic", models: ["MiniMax-M3"]),
              codex: .init(baseURL: "https://api.minimax.cn/v1", models: ["MiniMax-M3"], chatBaseURL: "https://api.minimax.cn/v1")),
        .init(id: "qwen", name: "阿里百炼 / 千问", monogram: "Q", color: 0x7851D2, category: .platform,
              detail: "按量付费 API", website: "https://bailian.console.aliyun.com",
              claude: .init(baseURL: "https://dashscope.aliyuncs.com/apps/anthropic", models: ["qwen3.8-max", "qwen3.7-plus"]),
              codex: .init(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", models: ["qwen3.8-max"], chatBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1")),
        .init(id: "qwen-coding", name: "百炼 Coding Plan", monogram: "Q", color: 0x7851D2, category: .coding,
              detail: "填写订阅支持的模型与专用 Key", website: "https://bailian.console.aliyun.com",
              claude: .init(baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic", models: []),
              codex: .init(baseURL: "https://coding.dashscope.aliyuncs.com/v1", models: [], wireAPI: "chat")),
        .init(id: "openrouter", name: "OpenRouter", monogram: "OR", color: 0x6566C2, category: .gateway,
              detail: "聚合模型 · 使用完整模型 ID", website: "https://openrouter.ai/keys",
              claude: .init(baseURL: "https://openrouter.ai/api", models: ["anthropic/claude-sonnet-5"]),
              codex: .init(baseURL: "https://openrouter.ai/api/v1", models: ["openai/gpt-5.4"], chatBaseURL: "https://openrouter.ai/api/v1")),
        .init(id: "openai", name: "OpenAI API", monogram: "AI", color: 0x2D8C76, category: .platform,
              detail: "API Key 接入 · 非 ChatGPT 订阅", website: "https://platform.openai.com/api-keys", claude: nil,
              codex: .init(baseURL: "https://api.openai.com/v1", models: ["gpt-5.4", "gpt-5.4-mini"], chatBaseURL: "https://api.openai.com/v1")),
        .init(id: "siliconflow", name: "硅基流动", monogram: "SF", color: 0x6951E0, category: .gateway,
              detail: "多模型 API · 拉取账号可用模型", website: "https://cloud.siliconflow.cn",
              claude: .init(baseURL: "https://api.siliconflow.cn", models: []),
              codex: .init(baseURL: "https://api.siliconflow.cn/v1", models: [], wireAPI: "chat")),
        .init(id: "ark", name: "火山方舟", monogram: "V", color: 0x3370FF, category: .platform,
              detail: "按量 API · 填写模型或接入点 ID", website: "https://console.volcengine.com/ark",
              claude: .init(baseURL: "https://ark.cn-beijing.volces.com/api/compatible", models: []),
              codex: .init(baseURL: "https://ark.cn-beijing.volces.com/api/v3", models: [], chatBaseURL: "https://ark.cn-beijing.volces.com/api/v3")),
        .init(id: "ark-coding", name: "火山 Coding Plan", monogram: "V", color: 0x3370FF, category: .coding,
              detail: "Coding 套餐专用地址与 Key", website: "https://www.volcengine.com/activity/codingplan",
              claude: .init(baseURL: "https://ark.cn-beijing.volces.com/api/coding", models: ["ark-code-latest"]),
              codex: .init(baseURL: "https://ark.cn-beijing.volces.com/api/coding/v3", models: ["ark-code-latest"], chatBaseURL: "https://ark.cn-beijing.volces.com/api/coding/v3")),
        .init(id: "ark-agent", name: "火山 Agent Plan", monogram: "V", color: 0x3370FF, category: .coding,
              detail: "Agent 套餐 · 不与按量入口混用", website: "https://www.volcengine.com/activity/agentplan",
              claude: .init(baseURL: "https://ark.cn-beijing.volces.com/api/plan", models: ["ark-code-latest"]),
              codex: .init(baseURL: "https://ark.cn-beijing.volces.com/api/plan/v3", models: ["ark-code-latest"], chatBaseURL: "https://ark.cn-beijing.volces.com/api/plan/v3")),
        .init(id: "stepfun", name: "阶跃星辰", monogram: "S", color: 0x168CA3, category: .platform,
              detail: "按量 API · 与 Step Plan 分开", website: "https://platform.stepfun.com",
              claude: .init(baseURL: "https://api.stepfun.com", models: []),
              codex: .init(baseURL: "https://api.stepfun.com/v1", models: [], wireAPI: "chat")),
        .init(id: "step-plan", name: "Step Plan", monogram: "S", color: 0x168CA3, category: .coding,
              detail: "阶跃订阅 · 专用 step_plan 入口", website: "https://platform.stepfun.com/step-plan",
              claude: .init(baseURL: "https://api.stepfun.com/step_plan", models: ["step-5-preview", "step-3.7-flash"]),
              codex: .init(baseURL: "https://api.stepfun.com/step_plan/v1", models: ["step-5-preview", "step-3.7-flash"], wireAPI: "chat")),
        .init(id: "nvidia", name: "NVIDIA NIM", monogram: "N", color: 0x76B900, category: .gateway,
              detail: "API Catalog · 拉取可用模型", website: "https://build.nvidia.com", claude: nil,
              codex: .init(baseURL: "https://integrate.api.nvidia.com/v1", models: [], wireAPI: "chat")),
        .init(id: "gemini", name: "Google Gemini", monogram: "G", color: 0x4285F4, category: .platform,
              detail: "AI Studio · OpenAI 兼容接口", website: "https://aistudio.google.com/apikey", claude: nil,
              codex: .init(baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", models: [], wireAPI: "chat")),
        .init(id: "xai", name: "xAI / Grok", monogram: "X", color: 0x656565, category: .platform,
              detail: "Responses / Chat · 拉取模型", website: "https://console.x.ai", claude: nil,
              codex: .init(baseURL: "https://api.x.ai/v1", models: [], chatBaseURL: "https://api.x.ai/v1")),
        .init(id: "ollama", name: "Ollama", monogram: "Ol", color: 0x1A1A1A, category: .gateway,
              detail: "本机模型 · 无需真实 Key", website: "https://ollama.com",
              claude: .init(baseURL: "http://localhost:11434", models: []),
              codex: .init(baseURL: "http://localhost:11434/v1", models: [], wireAPI: "chat")),
        .init(id: "lmstudio", name: "LM Studio", monogram: "LM", color: 0x6B57FF, category: .gateway,
              detail: "本机服务 · 无需真实 Key", website: "https://lmstudio.ai",
              claude: .init(baseURL: "http://localhost:1234", models: []),
              codex: .init(baseURL: "http://localhost:1234/v1", models: [], chatBaseURL: "http://localhost:1234/v1")),
        .init(id: "litellm", name: "LiteLLM", monogram: "LL", color: 0x397D91, category: .gateway,
              detail: "已有网关 · 填写网关模型别名", website: "https://docs.litellm.ai",
              claude: .init(baseURL: "http://localhost:4000", models: []),
              codex: .init(baseURL: "http://localhost:4000/v1", models: []))
    ]

    static func entries(for client: ProviderClient) -> [Self] { all.filter { $0.endpoint(for: client) != nil } }
    /// URL identity, not a user-editable display name. Never classify a relay as its upstream.
    static func entry(id: String?) -> Self? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// URL identity. Several products can share one Claude path (智谱按量 and
    /// Coding Plan both use `/api/anthropic`); the Coding entry wins so an
    /// older saved row stays on the plan card. New rows carry `catalogID`.
    static func matching(baseURL: String) -> Self? {
        let hits = matchingAll(baseURL: baseURL)
        if hits.count <= 1 { return hits.first }
        return hits.first { $0.category == .coding } ?? hits.first
    }

    static func matchingAll(baseURL: String) -> [Self] {
        let value = identityURL(baseURL)
        guard !value.isEmpty else { return [] }
        return all.filter { $0.identityURLs.contains(value) }
    }

    var identityURLs: [String] {
        let urls = [claude?.baseURL, codex?.baseURL, codex?.chatBaseURL].compactMap { $0 } + legacyURLs
        return urls.map { Self.identityURL($0) }.filter { !$0.isEmpty }
    }
    private var legacyURLs: [String] {
        switch id {
        case "glm": return ["https://open.bigmodel.cn/api/paas/v4"]
        default: return []
        }
    }
    static func identityURL(_ raw: String) -> String {
        guard var url = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host != nil else { return "" }
        url.host = url.host?.lowercased()
        url.scheme = url.scheme?.lowercased()
        url.query = nil; url.fragment = nil
        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for method in ["chat/completions", "messages", "responses", "models"] {
            if path == method { path = ""; break }
            let suffix = "/" + method
            if path.hasSuffix(suffix) { path = String(path.dropLast(suffix.count)); break }
        }
        if path == "v1" { path = "" }
        else if path.hasSuffix("/v1") { path = String(path.dropLast(3)) }
        url.path = path.isEmpty ? "" : "/" + path
        return url.string ?? ""
    }
    var includesCodingPlan: Bool { category == .coding || id.hasPrefix("minimax") }
    var iconName: String {
        switch id {
        // Ollama and LM Studio ship their own marks; `default` already maps id
        // to filename, so they need no case here. Kept explicit so a future
        // rename of the catalog id cannot silently fall back to a system glyph.
        case "ollama": return "ollama"
        case "lmstudio": return "lmstudio"
        case "kimi-coding": return "kimi"
        case "glm", "glm-coding": return "zhipu"
        case "minimax-cn": return "minimax"
        case "qwen-coding": return "qwen"
        case "ark", "ark-agent", "ark-coding": return "volcengine"
        case "step-plan": return "stepfun"
        case "siliconflow": return "siliconcloud"
        default: return id
        }
    }

    /// Whether a base URL points at a server on this machine (or a private
    /// network), which is the only thing that decides if an API key is real.
    ///
    /// Local runtimes — Ollama, LM Studio, LiteLLM on loopback — serve with no
    /// authentication at all. Their key field exists only because the Claude
    /// and Codex clients require a non-empty `Authorization` header, so a
    /// placeholder like `ollama` is the correct value, not a fake credential.
    /// Validation must therefore key off the *host*, never the provider name:
    /// an Ollama behind a public reverse proxy genuinely does need a key.
    static func isLocalEndpoint(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty else { return false }
        // A subdomain of a private name is not private: `localhost.evil.com`
        // resolves on the public internet, so match these exactly.
        if host == "localhost" || host == "0.0.0.0" { return true }
        // URLComponents keeps IPv6 literals bracketed. Loopback is `::1` in any
        // of its spellings; a bracketed literal is never a public hostname.
        if host.hasPrefix("[") && host.hasSuffix("]") {
            let literal = String(host.dropFirst().dropLast()).lowercased()
            let groups = literal.split(separator: ":")
            if groups == ["1"] || groups.allSatisfy({ $0.isEmpty }) || literal == "::1" { return true }
            return groups.count >= 2 && groups.dropLast().allSatisfy { $0.isEmpty }
        }
        // Bonjour `.local` names never leave the local link.
        if host.hasSuffix(".local") && host != ".local" { return true }
        // Only bare IPv4 literals: "127.0.0.2.example.com" has octet-parseable
        // leading labels but is a public name.
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let a = UInt8(octets[0]), let b = UInt8(octets[1]),
              UInt8(octets[2]) != nil, UInt8(octets[3]) != nil else { return false }
        switch (a, b) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// The value the key field should carry for a local endpoint. Kept as a
    /// named constant so layouts and the placeholder agree on one string.
    static let localEndpointPlaceholderKey = "ollama"

    /// Why the key field is not required here, for the editor's help text.
    static func localEndpointNote(_ raw: String) -> String? {
        isLocalEndpoint(raw) ? "本机服务无需真实 Key，留空或填 ollama 均可" : nil
    }

    static func supportsNativeResponses(baseURL: String, model: String) -> Bool {
        all.contains { entry in
            guard let endpoint = entry.codex, endpoint.wireAPI == "responses" else { return false }
            return identityURL(endpoint.baseURL) == identityURL(baseURL)
        }
    }
    static func normalize(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
}

struct ProviderSetupDraft {
    let entry: ProviderCatalogEntry
    let client: ProviderClient
    var name: String
    var baseURL: String
    var apiKey = ""
    var model: String
    var additionalModels: [String] = []
    var wireAPI: String
    init(entry: ProviderCatalogEntry, client: ProviderClient) {
        self.entry = entry; self.client = client
        wireAPI = client == .claude ? "anthropic" : entry.codex?.wireAPI ?? "responses"
        name = entry.name; baseURL = entry.endpoint(for: client)?.baseURL ?? ""
        model = entry.endpoint(for: client)?.models.first ?? ""
    }
    var modelNames: [String] {
        var seen = Set<String>()
        return ([model] + additionalModels).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
    mutating func selectProtocol(_ wire: String) {
        wireAPI = wire
        if let endpoint = entry.codex { baseURL = endpoint.url(for: wire) }
    }
    var validationError: String? {
        if entry.endpoint(for: client) == nil { return "此预设不支持当前客户端。" }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写供应商名称。" }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return "请填写有效的接口地址，不要在地址中附带密钥。" }
        // Only a remote endpoint can require a real key. A loopback server
        // serves unauthenticated; demanding a key here is the single most
        // common way users get stuck configuring local Ollama / LM Studio.
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !ProviderCatalogEntry.isLocalEndpoint(baseURL) { return "请填写 API Key（自建网关填写网关 Key）。" }
        if modelNames.isEmpty { return "请填写账号可用的模型 ID。" }
        return nil
    }
    func makeClaude() -> Provider {
        let models = modelNames.map { ModelConfig(name: $0, disableCompact: false, disableExperimentalBetas: false) }
        return Provider(name: name.trimmingCharacters(in: .whitespacesAndNewlines), authToken: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                        baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), models: models, activeModelID: models.first?.id,
                        profileID: UUID(), catalogID: entry.id)
    }
    func makeCodex() -> CodexProvider {
        let models = modelNames.map { CodexModelConfig(name: $0) }
        return CodexProvider(name: name.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                             baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), wireAPI: wireAPI,
                             requiresOpenAIAuth: false, models: models, activeModelID: models.first?.id,
                             profileID: UUID(), catalogID: entry.id)
    }
}
