import Foundation

// MARK: - Codex Model Config

struct CodexModelConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String                 // → model = "..."
    var reasoningEffort: String = "" // → model_reasoning_effort ("" = don't write)
    var contextWindow: String = ""   // → model_context_window ("" = don't write)
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

    var activeModel: CodexModelConfig? {
        models.first { $0.id == activeModelID } ?? models.first
    }

    init(name: String, apiKey: String = "", baseURL: String = "",
         wireAPI: String = "responses", requiresOpenAIAuth: Bool = true,
         preserveOfficialLogin: Bool = true, disableResponseStorage: Bool = true,
         models: [CodexModelConfig] = [], activeModelID: UUID? = nil) {
        self.name = name
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.wireAPI = wireAPI
        self.requiresOpenAIAuth = requiresOpenAIAuth
        self.preserveOfficialLogin = preserveOfficialLogin
        self.disableResponseStorage = disableResponseStorage
        self.models = models
        self.activeModelID = activeModelID
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, apiKey, baseURL, wireAPI, requiresOpenAIAuth,
             preserveOfficialLogin, disableResponseStorage, models, activeModelID
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
    static let openAI = CodexProvider(
        name: "OpenAI 官方", baseURL: "https://api.openai.com/v1", wireAPI: "responses",
        requiresOpenAIAuth: false,
        models: [CodexModelConfig(name: "gpt-5.2-codex", reasoningEffort: "high")])
    /// Aibox 中转的是 GLM 等 Chat Completions 模型。它的 `/v1/responses` 只能
    /// 吃第一轮 `message`；第二轮回放 `function_call` 会 400
    /// `untagged enum ResponseInput`。和官方 GLM / cc-switch Chat / Codex++
    /// protocol_proxy 一样走 Chat。
    static let aibox = CodexProvider(
        name: "Aibox",
        apiKey: "",
        baseURL: "http://aibox.richaibox.com:2026/v1", wireAPI: "chat",
        requiresOpenAIAuth: true,
        models: [CodexModelConfig(name: "glm-5.3-flash", reasoningEffort: "high", contextWindow: "400000")])
    static let custom = CodexProvider(name: "自定义", baseURL: "", wireAPI: "responses", models: [])

    static var all: [(label: String, provider: CodexProvider)] {
        [("Aibox", aibox), ("DeepSeek", deepseek), ("Kimi / Moonshot", moonshot), ("Zhipu GLM", glm),
         ("OpenAI 官方", openAI), ("自定义", custom)]
    }
}
