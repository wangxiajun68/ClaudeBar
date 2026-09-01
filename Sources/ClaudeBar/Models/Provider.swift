import Foundation

// MARK: - Model Config

struct ModelConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var contextTokens: String = ""
    var disableCompact: Bool = true
    var disableExperimentalBetas: Bool = true
    var autoCompactWindow: String = ""
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

    var activeModel: ModelConfig? {
        models.first { $0.id == activeModelID } ?? models.first
    }

    init(name: String, authToken: String = "", baseURL: String = "",
         models: [ModelConfig] = [], activeModelID: UUID? = nil,
         captureEnabled: Bool = false) {
        self.name = name
        self.authToken = authToken
        self.baseURL = baseURL
        self.models = models
        self.activeModelID = activeModelID
        self.captureEnabled = captureEnabled
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
    }

    /// Only store keys that map to stored properties (for Encodable).
    private enum CodingKeys: String, CodingKey {
        case id, name, authToken, baseURL, models, activeModelID, captureEnabled
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
