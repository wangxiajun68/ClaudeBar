import Foundation
import CryptoKit

struct MigrationBridgeEndpoint: Sendable {
    let baseURL: String
    let apiKey: String
    let wireAPI: String
    let model: String
    var reasoningEffort = ""
}

/// Explicit saved-provider selection. Secrets remain in memory, never manifests.
enum MigrationBridgeConfiguration {
    static func fingerprint(_ endpoint: MigrationBridgeEndpoint) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["base":endpoint.baseURL,"key":endpoint.apiKey,
            "wire":endpoint.wireAPI,"model":endpoint.model,"reasoning":endpoint.reasoningEffort],options:.sortedKeys)
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }

    /// The one base-URL join rule, shared by the migration bridge's two wire
    /// paths so they cannot drift. A base that already carries the operation is
    /// used as-is; a base ending in `/openai` or a version segment appends the
    /// operation directly; a bare host gets `/v1`. `nil` becomes
    /// `AgentProtocolBridge.Failure.malformed`, never a request to some
    /// fabricated fallback host.
    static func url(_ base: String, operation: String) -> URL? {
        let trimmed = base.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        if trimmed.hasSuffix(operation) { return URL(string:trimmed) }
        if trimmed.hasSuffix("/openai") || trimmed.range(of:#"/v\d+$"#,options:.regularExpression) != nil {
            return URL(string:trimmed + operation)
        }
        return URL(string:trimmed + "/v1" + operation)
    }

    static func responsesURL(_ base: String) -> URL? {
        url(base, operation: "/responses")
    }

    static func chatCompletionsURL(_ base: String) -> URL? {
        url(base, operation: "/chat/completions")
    }

    static func route(_ path: String) -> (id: UUID, countTokens: Bool)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5 || parts.count == 6, parts[0].isEmpty,
              parts[1] == "migration", let id = UUID(uuidString: String(parts[2])),
              parts[3] == "v1", parts[4] == "messages",
              parts.count == 5 || parts[5] == "count_tokens" else { return nil }
        return (id, parts.count == 6)
    }

    static func endpoint(_ data: Data, providerID: UUID, model: String, localProxyPort: Int = BuildChannel.proxyPort) throws -> MigrationBridgeEndpoint {
        guard data.count <= 16 * 1024 * 1024,
              let file = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = file["providers"] as? [[String: Any]],
              let provider = providers.first(where: { ($0["id"] as? String)?.lowercased() == providerID.uuidString.lowercased() }),
              let models = provider["models"] as? [[String: Any]],
              models.contains(where: { $0["name"] as? String == model }),
              !model.isEmpty, model.utf8.count <= 160,
              !model.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let base = provider["baseURL"] as? String, let url = URLComponents(string: base),
              ["https", "http"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              !(LocalProxyAddress.isLoopback(base) && (url.port ?? (url.scheme == "https" ? 443 : 80)) == localProxyPort),
              let key = provider["apiKey"] as? String, !key.isEmpty,
              !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw MigrationFailure.unsupported("请选择已保存密钥与模型的自定义 Codex 供应商；官方套餐需要独立授权。")
        }
        let wire = provider["wireAPI"] as? String ?? "responses"
        guard ["responses", "chat"].contains(wire) else { throw MigrationFailure.unsupported("尚未验证此供应商协议。") }
        let selected = models.first(where: { $0["name"] as? String == model })!
        let effort = selected["reasoningEffort"] as? String ?? ""
        guard effort.isEmpty || ["minimal","low","medium","high","xhigh"].contains(effort) else {
            throw MigrationFailure.unsupported("此模型的推理强度尚未验证，请使用默认或标准强度。")
        }
        return .init(baseURL: base, apiKey: key, wireAPI: wire, model: model,
            reasoningEffort: effort)
    }
}

struct MigrationBridgeLaunch: Sendable {
    let port: Int
    let token: String

    func settings(record: MigrationRecord) throws -> String {
        guard (1...65535).contains(port), token.count >= 16,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              record.target == .claudeCodexModel else { throw MigrationFailure.changed }
        let base = "http://127.0.0.1:\(port)/migration/" + record.id.uuidString.lowercased()
        // Highest-precedence per-process settings. No global provider activation.
        // Pin all sub-model aliases so CC cannot route a helper to another wallet.
        let environment: [String: String] = [
            "ANTHROPIC_BASE_URL": base, "ANTHROPIC_AUTH_TOKEN": token, "ANTHROPIC_API_KEY": token,
            "ANTHROPIC_MODEL": record.model, "ANTHROPIC_SMALL_FAST_MODEL": record.model,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": record.model, "ANTHROPIC_DEFAULT_SONNET_MODEL": record.model,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": record.model, "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1", "ENABLE_TOOL_SEARCH": "false"
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["env": environment], options: .sortedKeys), as: UTF8.self)
    }
}
