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

    var activeModel: ModelConfig? {
        models.first { $0.id == activeModelID } ?? models.first
    }

    init(name: String, authToken: String = "", baseURL: String = "",
         models: [ModelConfig] = [], activeModelID: UUID? = nil) {
        self.name = name
        self.authToken = authToken
        self.baseURL = baseURL
        self.models = models
        self.activeModelID = activeModelID
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
    }

    /// Only store keys that map to stored properties (for Encodable).
    private enum CodingKeys: String, CodingKey {
        case id, name, authToken, baseURL, models, activeModelID
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

// MARK: - Migration from old presets format

struct MigrationHelper {
    /// Convert old PresetsFile.json to new ProvidersFile. Returns nil if no old file exists.
    static func migrateIfNeeded() -> ProvidersFile? {
        let oldURL = FilePaths.oldPresetsFile
        guard FileManager.default.fileExists(atPath: oldURL.path),
              let data = try? Data(contentsOf: oldURL),
              let oldFile = try? JSONDecoder().decode(PresetsFile.self, from: data),
              !oldFile.presets.isEmpty else { return nil }

        // Group presets by baseURL
        var groups: [String: (presets: [Preset], active: Bool)] = [:]
        for p in oldFile.presets {
            let key = p.env.ANTHROPIC_BASE_URL
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if groups[key] == nil {
                groups[key] = (presets: [], active: false)
            }
            groups[key]!.presets.append(p)
            if p.name == oldFile.activePresetName {
                groups[key]!.active = true
            }
        }

        var providers: [Provider] = []
        var activeID: UUID?

        for (_, group) in groups {
            guard let first = group.presets.first else { continue }

            // Each old preset becomes a ModelConfig
            var models: [ModelConfig] = []
            var seenNames = Set<String>()
            for p in group.presets where !p.env.ANTHROPIC_MODEL.isEmpty {
                let m = p.env.ANTHROPIC_MODEL
                if !seenNames.contains(m) {
                    seenNames.insert(m)
                    models.append(ModelConfig(
                        name: m,
                        contextTokens: p.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS,
                        disableCompact: p.env.DISABLE_COMPACT == "1",
                        disableExperimentalBetas: p.env.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS == "1",
                        autoCompactWindow: p.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW
                    ))
                }
            }
            if models.isEmpty {
                models.append(ModelConfig(name: "default"))
            }

            let providerName: String
            if let host = URL(string: first.env.ANTHROPIC_BASE_URL)?.host {
                providerName = host.components(separatedBy: ".")
                    .first(where: { !["api", "www"].contains($0) })?.capitalized ?? "Provider"
            } else {
                providerName = first.name
            }

            var provider = Provider(
                name: providerName,
                authToken: first.env.ANTHROPIC_AUTH_TOKEN,
                baseURL: first.env.ANTHROPIC_BASE_URL,
                models: models
            )
            provider.activeModelID = models.first?.id
            providers.append(provider)

            if group.active || oldFile.activePresetName == first.name {
                activeID = provider.id
            }
        }

        try? FileManager.default.removeItem(at: oldURL)
        return ProvidersFile(providers: providers, activeProviderID: activeID)
    }
}
