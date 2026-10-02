import Foundation

// MARK: - Model Config

struct ModelConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var contextTokens: String = ""
    var disableCompact: Bool = true
    var disableExperimentalBetas: Bool = true
    var autoCompactWindow: String = ""
    var maxConcurrentSubagents: String = "20"
    var workflowMaxConcurrentAgents: String = "30"

    init(id: UUID = UUID(), name: String, contextTokens: String = "",
         disableCompact: Bool = true, disableExperimentalBetas: Bool = true,
         autoCompactWindow: String = "", maxConcurrentSubagents: String = "20",
         workflowMaxConcurrentAgents: String = "30") {
        self.id = id
        self.name = name
        self.contextTokens = contextTokens
        self.disableCompact = disableCompact
        self.disableExperimentalBetas = disableExperimentalBetas
        self.autoCompactWindow = autoCompactWindow
        self.maxConcurrentSubagents = maxConcurrentSubagents
        self.workflowMaxConcurrentAgents = workflowMaxConcurrentAgents
    }

    static func concurrencyValidationError(subagents: String, workflow: String) -> String? {
        func count(_ raw: String) -> Int? {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(value)
        }
        guard let subagents = count(subagents), subagents > 0 else {
            return "Subagent 并发数必须为正整数。"
        }
        guard let workflow = count(workflow), (1...256).contains(workflow) else {
            return "Workflow 并发数必须为 1–256 的整数。"
        }
        return nil
    }

    /// Hand-written: the synthesized decoder ignores property defaults, so one
    /// row missing a key would throw and `Provider.init(from:)` would fall back
    /// to an empty `models` array, silently losing every row in the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        contextTokens = try c.decodeIfPresent(String.self, forKey: .contextTokens) ?? ""
        disableCompact = try c.decodeIfPresent(Bool.self, forKey: .disableCompact) ?? true
        disableExperimentalBetas = try c.decodeIfPresent(Bool.self, forKey: .disableExperimentalBetas) ?? true
        autoCompactWindow = try c.decodeIfPresent(String.self, forKey: .autoCompactWindow) ?? ""
        maxConcurrentSubagents = try c.decodeIfPresent(String.self, forKey: .maxConcurrentSubagents) ?? "20"
        workflowMaxConcurrentAgents = try c.decodeIfPresent(String.self, forKey: .workflowMaxConcurrentAgents) ?? "30"
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, contextTokens, disableCompact, disableExperimentalBetas, autoCompactWindow
        case maxConcurrentSubagents, workflowMaxConcurrentAgents
    }
}

// MARK: - Provider

struct Provider: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var authToken: String = ""
    var baseURL: String = ""
    var models: [ModelConfig] = []
    var activeModelID: UUID? = nil
    /// Route this vendor through the local inspect proxy (Claude Code
    /// Anthropic `/v1/messages` and the Codex OpenAI twin).
    var captureEnabled: Bool = false
    /// Shared with the Codex record of the same configuration. Activation
    /// stays on `ProvidersFile.activeProviderID` and is not part of this id.
    var profileID: UUID? = nil
    /// Catalog entry that owns the client-specific base URL. Nil for custom hosts.
    var catalogID: String? = nil

    var activeModel: ModelConfig? {
        models.first { $0.id == activeModelID } ?? models.first
    }

    init(name: String, authToken: String = "", baseURL: String = "",
         models: [ModelConfig] = [], activeModelID: UUID? = nil,
         captureEnabled: Bool = false, profileID: UUID? = nil, catalogID: String? = nil) {
        self.name = name
        self.authToken = authToken
        self.baseURL = baseURL
        self.models = models
        self.activeModelID = activeModelID
        self.captureEnabled = captureEnabled
        self.profileID = profileID
        self.catalogID = catalogID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        authToken = try c.decodeIfPresent(String.self, forKey: .authToken) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""

        // Try new format ([ModelConfig]) first, then old format ([String])
        if let newModels = try? c.decode([ModelConfig].self, forKey: .models) {
            models = newModels
        } else if let oldModelNames = try? c.decode([String].self, forKey: .models) {
            // Read old-format provider-level settings using dynamic keys
            let anyC = try decoder.container(keyedBy: AnyCodingKey.self)
            let ctx = try anyC.decodeIfPresent(String.self, forKey: AnyCodingKey("contextTokens")) ?? ""
            let dc = try anyC.decodeIfPresent(Bool.self, forKey: AnyCodingKey("disableCompact")) ?? false
            let deb = try anyC.decodeIfPresent(Bool.self, forKey: AnyCodingKey("disableExperimentalBetas")) ?? false
            let aw = try anyC.decodeIfPresent(String.self, forKey: AnyCodingKey("autoCompactWindow")) ?? ""
            models = oldModelNames.map { name in
                ModelConfig(name: name, contextTokens: ctx, disableCompact: dc,
                            disableExperimentalBetas: deb, autoCompactWindow: aw)
            }
        } else {
            models = []
        }

        // activeModelID: UUID (new) or String name (old)
        if let newID = try? c.decodeIfPresent(UUID.self, forKey: .activeModelID) {
            activeModelID = newID
        } else {
            let anyC = try decoder.container(keyedBy: AnyCodingKey.self)
            if let oldName = try anyC.decodeIfPresent(String.self, forKey: AnyCodingKey("activeModel")) {
                activeModelID = models.first(where: { $0.name == oldName })?.id ?? models.first?.id
            } else {
                activeModelID = models.first?.id
            }
        }
        captureEnabled = try c.decodeIfPresent(Bool.self, forKey: .captureEnabled) ?? false
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        catalogID = try c.decodeIfPresent(String.self, forKey: .catalogID)
    }

    /// Only store keys that map to stored properties (for Encodable).
    private enum CodingKeys: String, CodingKey {
        case id, name, authToken, baseURL, models, activeModelID, captureEnabled, profileID, catalogID
    }

    /// Dynamic key for reading old-format fields during decoding only.
    struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(_ string: String) { stringValue = string; intValue = nil }
        init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { return nil }
    }
}

struct ProvidersFile: Codable {
    var providers: [Provider]
    var activeProviderID: UUID?
}
