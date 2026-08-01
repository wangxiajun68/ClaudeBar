import Foundation

struct EnvConfig: Codable, Equatable {
    var ANTHROPIC_AUTH_TOKEN: String = ""
    var ANTHROPIC_BASE_URL: String = ""
    var ANTHROPIC_MODEL: String = ""
    var CLAUDE_CODE_MAX_CONTEXT_TOKENS: String = ""
    var DISABLE_COMPACT: String = ""
    var GITHUB_PERSONAL_ACCESS_TOKEN: String = ""
    var CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: String = ""
    var ANTHROPIC_DEFAULT_OPUS_MODEL: String = ""
    var ANTHROPIC_DEFAULT_OPUS_MODEL_NAME: String = ""
    var ANTHROPIC_DEFAULT_SONNET_MODEL: String = ""
    var ANTHROPIC_DEFAULT_SONNET_MODEL_NAME: String = ""
    var ANTHROPIC_DEFAULT_HAIKU_MODEL: String = ""
    var ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME: String = ""
    var ANTHROPIC_DEFAULT_FABLE_MODEL: String = ""
    var ANTHROPIC_DEFAULT_FABLE_MODEL_NAME: String = ""
    var CLAUDE_CODE_AUTO_COMPACT_WINDOW: String = ""

    enum CodingKeys: String, CodingKey {
        case ANTHROPIC_AUTH_TOKEN
        case ANTHROPIC_BASE_URL
        case ANTHROPIC_MODEL
        case CLAUDE_CODE_MAX_CONTEXT_TOKENS
        case DISABLE_COMPACT
        case GITHUB_PERSONAL_ACCESS_TOKEN
        case CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS
        case ANTHROPIC_DEFAULT_OPUS_MODEL
        case ANTHROPIC_DEFAULT_OPUS_MODEL_NAME
        case ANTHROPIC_DEFAULT_SONNET_MODEL
        case ANTHROPIC_DEFAULT_SONNET_MODEL_NAME
        case ANTHROPIC_DEFAULT_HAIKU_MODEL
        case ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME
        case ANTHROPIC_DEFAULT_FABLE_MODEL
        case ANTHROPIC_DEFAULT_FABLE_MODEL_NAME
        case CLAUDE_CODE_AUTO_COMPACT_WINDOW
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ANTHROPIC_AUTH_TOKEN = try c.decodeIfPresent(String.self, forKey: .ANTHROPIC_AUTH_TOKEN) ?? ""
        ANTHROPIC_BASE_URL = try c.decodeIfPresent(String.self, forKey: .ANTHROPIC_BASE_URL) ?? ""
        ANTHROPIC_MODEL = try c.decodeIfPresent(String.self, forKey: .ANTHROPIC_MODEL) ?? ""
        CLAUDE_CODE_MAX_CONTEXT_TOKENS = try c.decodeIfPresent(String.self, forKey: .CLAUDE_CODE_MAX_CONTEXT_TOKENS) ?? ""
        DISABLE_COMPACT = try c.decodeIfPresent(String.self, forKey: .DISABLE_COMPACT) ?? ""
        GITHUB_PERSONAL_ACCESS_TOKEN = try c.decodeIfPresent(String.self, forKey: .GITHUB_PERSONAL_ACCESS_TOKEN) ?? ""
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = try c.decodeIfPresent(String.self, forKey: .CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS) ?? ""
        ANTHROPIC_DEFAULT_OPUS_MODEL = try c.decodeIfPresent(String.self, forKey: .ANTHROPIC_DEFAULT_OPUS_MODEL) ?? ""
        ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = try c.decodeIfPresent(String.self, forKey: .ANTHROPIC_DEFAULT_OPUS_MODEL_NAME) ?? ""
        ANTHROPIC_DEFAULT_SONNET_MODEL = try c.decodeIfPresent(String.self, forKey: .ANTHROPIC_DEFAULT_SONNET_MODEL) ?? ""
        ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = try c.decodeIfPresent(String.self, forKey: .ANTHROPIC_DEFAULT_SONNET_MODEL_NAME) ?? ""
        ANTHROPIC_DEFAULT_HAIKU_MODEL = try c.decodeIfPresent(String.self, forKey: .ANTHROPIC_DEFAULT_HAIKU_MODEL) ?? ""
        ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME = try c.decodeIfPresent(String.self, forKey: .ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME) ?? ""
        ANTHROPIC_DEFAULT_FABLE_MODEL = try c.decodeIfPresent(String.self, forKey: .ANTHROPIC_DEFAULT_FABLE_MODEL) ?? ""
        ANTHROPIC_DEFAULT_FABLE_MODEL_NAME = try c.decodeIfPresent(String.self, forKey: .ANTHROPIC_DEFAULT_FABLE_MODEL_NAME) ?? ""
        CLAUDE_CODE_AUTO_COMPACT_WINDOW = try c.decodeIfPresent(String.self, forKey: .CLAUDE_CODE_AUTO_COMPACT_WINDOW) ?? ""
    }

    init(ANTHROPIC_AUTH_TOKEN: String = "", ANTHROPIC_BASE_URL: String = "", ANTHROPIC_MODEL: String = "", CLAUDE_CODE_MAX_CONTEXT_TOKENS: String = "", DISABLE_COMPACT: String = "", GITHUB_PERSONAL_ACCESS_TOKEN: String = "", CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: String = "", ANTHROPIC_DEFAULT_OPUS_MODEL: String = "", ANTHROPIC_DEFAULT_OPUS_MODEL_NAME: String = "", ANTHROPIC_DEFAULT_SONNET_MODEL: String = "", ANTHROPIC_DEFAULT_SONNET_MODEL_NAME: String = "", ANTHROPIC_DEFAULT_HAIKU_MODEL: String = "", ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME: String = "", ANTHROPIC_DEFAULT_FABLE_MODEL: String = "", ANTHROPIC_DEFAULT_FABLE_MODEL_NAME: String = "", CLAUDE_CODE_AUTO_COMPACT_WINDOW: String = "") {
        self.ANTHROPIC_AUTH_TOKEN = ANTHROPIC_AUTH_TOKEN
        self.ANTHROPIC_BASE_URL = ANTHROPIC_BASE_URL
        self.ANTHROPIC_MODEL = ANTHROPIC_MODEL
        self.CLAUDE_CODE_MAX_CONTEXT_TOKENS = CLAUDE_CODE_MAX_CONTEXT_TOKENS
        self.DISABLE_COMPACT = DISABLE_COMPACT
        self.GITHUB_PERSONAL_ACCESS_TOKEN = GITHUB_PERSONAL_ACCESS_TOKEN
        self.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS
        self.ANTHROPIC_DEFAULT_OPUS_MODEL = ANTHROPIC_DEFAULT_OPUS_MODEL
        self.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = ANTHROPIC_DEFAULT_OPUS_MODEL_NAME
        self.ANTHROPIC_DEFAULT_SONNET_MODEL = ANTHROPIC_DEFAULT_SONNET_MODEL
        self.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = ANTHROPIC_DEFAULT_SONNET_MODEL_NAME
        self.ANTHROPIC_DEFAULT_HAIKU_MODEL = ANTHROPIC_DEFAULT_HAIKU_MODEL
        self.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME = ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME
        self.ANTHROPIC_DEFAULT_FABLE_MODEL = ANTHROPIC_DEFAULT_FABLE_MODEL
        self.ANTHROPIC_DEFAULT_FABLE_MODEL_NAME = ANTHROPIC_DEFAULT_FABLE_MODEL_NAME
        self.CLAUDE_CODE_AUTO_COMPACT_WINDOW = CLAUDE_CODE_AUTO_COMPACT_WINDOW
    }
}

struct Preset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var env: EnvConfig

    enum CodingKeys: String, CodingKey {
        case id, name, env
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Old presets files don't have "id" — generate one so existing data survives
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.env = try c.decode(EnvConfig.self, forKey: .env)
    }

    init(name: String, env: EnvConfig) {
        self.id = UUID()
        self.name = name
        self.env = env
    }
}

struct PresetsFile: Codable {
    var presets: [Preset]
    var activePresetName: String?
}
