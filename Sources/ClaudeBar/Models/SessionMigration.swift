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

struct MigrationMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let role: Role
    let text: String
}

struct MigrationPreview: Sendable {
    let source: MigrationSource
    let messages: [MigrationMessage]
    let fingerprint: String
    let omissions: [String]
    var completedToolCount = 0
    var textBytes: Int { messages.reduce(0) { $0 + $1.text.utf8.count } }
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

    var errorDescription: String? {
        switch self {
        case .restricted: return "开发版仅验证转换逻辑；实际会话迁移请使用正式版。"
        case .busy: return "请等当前回合结束，并处理待确认操作后再迁移。"
        case .unsupported(let reason): return reason
        case .missing: return "找不到完整的本地会话历史。"
        case .changed: return "来源或目标配置已变化，请重新准备迁移。"
        case .tooLarge: return "历史超出首版支持范围，请先在来源客户端整理交接上下文。"
        case .pendingPersistence: return "Cursor 正在保存会话，请稍后重试。"
        case .invalidHistory: return "历史不完整或格式无法识别，未创建目标会话。"
        case .unavailable(let client): return "未找到 " + client + "，请先安装对应客户端。"
        case .storage: return "会话写入失败，来源会话未被修改。"
        }
    }
}
