import Foundation

enum MigrationClient: String, Codable, CaseIterable, Sendable {
    case claude, codex, cursorCLI, cursorDesktop

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursorCLI: return "Cursor CLI"
        case .cursorDesktop: return "Cursor"
        }
    }
}

struct MigrationSource: Identifiable, Codable, Equatable, Sendable {
    var id: String { client.rawValue + ":" + sessionID }
    let client: MigrationClient
    let sessionID: String
    let cwd: String
    let title: String
    var isBusy = false
    var isSubagent = false
}

enum MigrationTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, claudeCodexModel, codexCurrent, codexOfficial, cursorCLI, cursorDesktop
    var id: String { rawValue }
    var client: MigrationClient {
        switch self {
        case .claude, .claudeCodexModel: return .claude
        case .codexCurrent, .codexOfficial: return .codex
        case .cursorCLI: return .cursorCLI
        case .cursorDesktop: return .cursorDesktop
        }
    }
    var label: String {
        switch self {
        case .claude: return "Claude Code · 当前配置"
        case .claudeCodexModel: return "Claude Code · Codex 自定义模型"
        case .codexCurrent: return "Codex · 当前配置"
        case .codexOfficial: return "Codex · 官方登录"
        case .cursorCLI: return "Cursor CLI · Auto"
        case .cursorDesktop: return "Cursor 桌面 · 项目模型"
        }
    }
}

struct MigrationImage: Codable, Equatable, Sendable {
    let mediaType: String
    /// data URL or http(s) URL. Bytes stay here, not inside the text projection.
    let dataURL: String
}

/// One finished tool call. Call IDs stay out. Writers still emit `MigrationMessage.text`
/// until a same-client resume proves native tool blocks are not executed again.
struct MigrationToolExchange: Codable, Equatable, Sendable {
    let name: String
    /// Canonical JSON of the original input value.
    let inputJSON: String
    /// Canonical JSON of the archived output, with image bytes removed.
    let outputJSON: String
    var images: [MigrationImage] = []
    /// `claude`, `codex`, or `cursor`. Writers use it to rebuild the native result.
    var outputKind: String = "claude"
    /// Cursor 3.23.12 tool enum copied from the source bubble. Never invented.
    var cursorTool: Int? = nil
    var cursorStatus: String? = nil
}

struct MigrationMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let role: Role
    let text: String
    var images: [MigrationImage] = []
    var tool: MigrationToolExchange? = nil

    init(role: Role, text: String, images: [MigrationImage] = [], tool: MigrationToolExchange? = nil) {
        self.role = role
        self.text = text
        self.images = images
        self.tool = tool
    }

    var carriedImageCount: Int { images.count + (tool?.images.count ?? 0) }
    var carriedImageBytes: Int {
        images.reduce(0) { $0 + $1.dataURL.utf8.count }
            + (tool?.images.reduce(0) { $0 + $1.dataURL.utf8.count } ?? 0)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        images = try container.decodeIfPresent([MigrationImage].self, forKey: .images) ?? []
        tool = try container.decodeIfPresent(MigrationToolExchange.self, forKey: .tool)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        if !images.isEmpty { try container.encode(images, forKey: .images) }
        if let tool { try container.encode(tool, forKey: .tool) }
    }

    private enum CodingKeys: String, CodingKey { case role, text, images, tool }
}

struct MigrationPreview: Sendable {
    let source: MigrationSource
    let messages: [MigrationMessage]
    let fingerprint: String
    let omissions: [String]
    var completedToolCount = 0
    var textBytes: Int { messages.reduce(0) { $0 + $1.text.utf8.count } }
    var imageCount: Int { messages.reduce(0) { $0 + $1.carriedImageCount } }
}

/// No credentials or private model state. A target is prepared, not presumed
/// to have answered merely because its terminal was opened.
struct MigrationRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let logicalConversationID: UUID
    let createdAt: Date
    let source: MigrationSource
    let sourceFingerprint: String
    let target: MigrationTarget
    let targetSessionID: String
    let nativePath: String
    let messageCount: Int
    let omissions: [String]
    let model: String
    let providerKey: String
    let configurationFingerprint: String?
    let executablePath: String
    var bridgeProviderID: UUID? = nil
    var formatVersion = 1

    var desktopTitle: String { "ClaudeBar · 迁移 · " + String(targetSessionID.prefix(8)) }

    var targetSource: MigrationSource {
        .init(client: target.client, sessionID: targetSessionID,
              cwd: source.cwd, title: source.title)
    }
}

enum MigrationFailure: LocalizedError {
    case restricted, busy, unsupported(String), missing, changed, tooLarge
    case invalidHistory, pendingPersistence, unavailable(String), storage
    case sizeLimit(String)

    var errorDescription: String? {
        switch self {
        case .restricted: return "开发版仅验证转换逻辑；实际会话迁移请使用正式版。"
        case .busy: return "请等当前回合结束，并处理待确认操作后再迁移。"
        case .unsupported(let reason): return reason
        case .missing: return "找不到完整的本地会话历史。"
        case .changed: return "来源或目标配置已变化，请重新准备迁移。"
        case .tooLarge: return "历史或附件超出迁移容量限制，请关闭工具或图片选项，或在来源客户端整理交接上下文。"
        case .sizeLimit(let reason): return reason
        case .pendingPersistence: return "Cursor 正在保存会话，请稍后重试。"
        case .invalidHistory: return "历史不完整或格式无法识别，未创建目标会话。"
        case .unavailable(let client): return "未找到 " + client + "，请先安装对应客户端。"
        case .storage: return "会话写入失败，来源会话未被修改。"
        }
    }
}
