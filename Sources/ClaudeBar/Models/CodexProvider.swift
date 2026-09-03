import Foundation

// MARK: - Codex Model Config

struct CodexModelConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String                 // → model = "..."
    var reasoningEffort: String = "" // omit `model_reasoning_effort` when empty
    var contextWindow: String = ""   // → model_context_window ("" = don't write)
    var autoCompactTokenLimit: String = "" // → model_auto_compact_token_limit ("" = don't write)

    init(id: UUID = UUID(), name: String, reasoningEffort: String = "",
         contextWindow: String = "", autoCompactTokenLimit: String = "") {
        self.id = id
        self.name = name
        self.reasoningEffort = reasoningEffort
        self.contextWindow = contextWindow
        self.autoCompactTokenLimit = autoCompactTokenLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        let raw = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? ""
        // Legacy default was "max"; empty means omit the Codex field.
        reasoningEffort = raw == "max" ? "" : raw
        contextWindow = try c.decodeIfPresent(String.self, forKey: .contextWindow) ?? ""
        autoCompactTokenLimit = try c.decodeIfPresent(String.self, forKey: .autoCompactTokenLimit) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, reasoningEffort, contextWindow, autoCompactTokenLimit
    }
}

// MARK: - Codex Provider

struct CodexProvider: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var apiKey: String = ""
    var baseURL: String = ""          // → [model_providers.<key>].base_url
    var wireAPI: String = "responses" // "responses" | "chat"
    var requiresOpenAIAuth: Bool = true
    /// 切换第三方时保留 auth.json 里的官方 ChatGPT 登录态（桌面 App 门控缓解）。
    var preserveOfficialLogin: Bool = true
    var disableResponseStorage: Bool = true
    var models: [CodexModelConfig] = []
    var activeModelID: UUID? = nil
    /// Same flag as the Claude twin — Codex traffic goes through the local
    /// proxy so the Traffic page can record OpenAI Chat/Responses calls.
    var captureEnabled: Bool = false

    var activeModel: CodexModelConfig? {
        models.first { $0.id == activeModelID } ?? models.first
    }

    /// Display adapter for `ProviderTile` — IDs are preserved so activate/capture
    /// still target this Codex row.
    var asDisplayProvider: Provider {
        var p = Provider(
            name: name,
            authToken: apiKey,
            baseURL: baseURL,
            models: models.map {
                ModelConfig(id: $0.id, name: $0.name,
                            contextTokens: $0.contextWindow,
                            autoCompactWindow: $0.autoCompactTokenLimit)
            },
            activeModelID: activeModelID,
            captureEnabled: captureEnabled)
        p.id = id
        return p
    }

    init(name: String, apiKey: String = "", baseURL: String = "",
         wireAPI: String = "responses", requiresOpenAIAuth: Bool = true,
         preserveOfficialLogin: Bool = true, disableResponseStorage: Bool = true,
         models: [CodexModelConfig] = [], activeModelID: UUID? = nil,
         captureEnabled: Bool = false) {
        self.name = name
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.wireAPI = wireAPI
        self.requiresOpenAIAuth = requiresOpenAIAuth
        self.preserveOfficialLogin = preserveOfficialLogin
        self.disableResponseStorage = disableResponseStorage
        self.models = models
        self.activeModelID = activeModelID
        self.captureEnabled = captureEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        wireAPI = try c.decodeIfPresent(String.self, forKey: .wireAPI) ?? "responses"
        requiresOpenAIAuth = try c.decodeIfPresent(Bool.self, forKey: .requiresOpenAIAuth) ?? true
        preserveOfficialLogin = try c.decodeIfPresent(Bool.self, forKey: .preserveOfficialLogin) ?? true
        disableResponseStorage = try c.decodeIfPresent(Bool.self, forKey: .disableResponseStorage) ?? true
        models = try c.decodeIfPresent([CodexModelConfig].self, forKey: .models) ?? []
        activeModelID = try c.decodeIfPresent(UUID.self, forKey: .activeModelID) ?? models.first?.id
        captureEnabled = try c.decodeIfPresent(Bool.self, forKey: .captureEnabled) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, apiKey, baseURL, wireAPI, requiresOpenAIAuth,
             preserveOfficialLogin, disableResponseStorage, models, activeModelID,
             captureEnabled
    }
}

struct CodexProvidersFile: Codable {
    var providers: [CodexProvider]
    var activeProviderID: UUID?
    /// `[model_providers.X]` table key written to config.toml.
    var activeKey: String = "custom"
}

// MARK: - Built-in Presets

/// Built-in provider presets — only base_url / wire_api are authoritative;
/// model names are editable placeholders.
enum CodexPreset {
    static let deepseek = CodexProvider(
        name: "DeepSeek", baseURL: "https://api.deepseek.com", wireAPI: "chat",
        requiresOpenAIAuth: false,
        models: [CodexModelConfig(name: "deepseek-chat"), CodexModelConfig(name: "deepseek-reasoner")])
    static let moonshot = CodexProvider(
        name: "Kimi / Moonshot", baseURL: "https://api.moonshot.cn/v1", wireAPI: "chat",
        requiresOpenAIAuth: false,
        models: [CodexModelConfig(name: "kimi-k2-instruct")])
    static let glm = CodexProvider(
        name: "Zhipu GLM", baseURL: "https://open.bigmodel.cn/api/coding/paas/v4", wireAPI: "chat",
        requiresOpenAIAuth: false,
        models: [CodexModelConfig(name: "glm-4.7")])
    static let dashscope = CodexProvider(
        name: "阿里百炼", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", wireAPI: "chat",
        requiresOpenAIAuth: false,
        models: [CodexModelConfig(name: "qwen3-coder-plus"), CodexModelConfig(name: "qwen-max")])
    static let volcengine = CodexProvider(
        name: "火山方舟", baseURL: "https://ark.cn-beijing.volces.com/api/v3", wireAPI: "chat",
        requiresOpenAIAuth: false,
        models: [CodexModelConfig(name: "doubao-seed-code-preview-251028")])
    static let siliconflow = CodexProvider(
        name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", wireAPI: "chat",
        requiresOpenAIAuth: false,
        models: [CodexModelConfig(name: "deepseek-ai/DeepSeek-V3")])
    static let openAI = CodexProvider(
        name: "OpenAI 官方", baseURL: "https://api.openai.com/v1", wireAPI: "responses",
        requiresOpenAIAuth: false,
        models: [CodexModelConfig(name: "gpt-5.2-codex")])
    static let custom = CodexProvider(name: "自定义", baseURL: "", wireAPI: "responses", models: [])

    /// Built-in templates shown in the provider editor. Fill in API Key after picking one.
    static var all: [(label: String, provider: CodexProvider)] {
        [
            ("DeepSeek", deepseek),
            ("Kimi / Moonshot", moonshot),
            ("阿里百炼", dashscope),
            ("智谱 GLM", glm),
            ("火山方舟", volcengine),
            ("硅基流动", siliconflow),
            ("OpenAI 官方", openAI),
            ("自定义", custom),
        ]
    }
}
