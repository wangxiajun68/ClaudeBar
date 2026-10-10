import Foundation
import CoreFoundation

enum GatewayTaskDifficulty: String, Codable, CaseIterable, Sendable {
    case low, medium, high
    var title: String {
        switch self { case .low: return "低（low）"; case .medium: return "中（medium）"; case .high: return "高（high）" }
    }
}

/// Gateway settings contain provider references, never credentials or prompts.
struct FreeModelPool: Codable, Equatable, Sendable {
    var version = 1
    var enabled = false
    var interceptAll = false
    var discoveryEnabled = true
    var automaticallyJoin = false
    var refreshHours = 6
    var strategy = Strategy.balanced
    var maxAttempts = 3
    var maxConcurrent = 4
    var defaultProviderConcurrent = 2
    var providerConcurrent: [String: Int] = [:]
    var maxQueued = 32
    var providerQueueCapacity = 8
    var queueTimeoutSeconds = 30
    var requestsPerMinute = 20
    var openRouterProviderID: UUID?
    var members: [Member] = []
    var catalog: [CatalogModel] = []
    var discoveredAt: Date?

    enum Strategy: String, Codable, CaseIterable, Sendable {
        case balanced, priority, latency
        var title: String {
            switch self { case .balanced: return "均衡轮转"; case .priority: return "池内顺序"; case .latency: return "低延迟优先" }
        }
    }

    struct Member: Codable, Equatable, Identifiable, Sendable {
        var providerID: UUID
        var model: String
        var name: String
        var enabled = true
        var contextLength: Int
        var supportsTools: Bool
        var supportsImages: Bool
        var supportsJSON: Bool
        /// OpenRouter entries must remain in a fresh, zero-priced catalog.
        var discovered = false
        var difficulties = GatewayTaskDifficulty.allCases
        var id: String { providerID.uuidString + ":" + model }
    }

    struct CatalogModel: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var contextLength: Int
        var supportsTools: Bool
        var supportsImages: Bool
        var supportsJSON: Bool
        var maxOutput: Int?

        func member(providerID: UUID) -> Member {
            .init(providerID: providerID, model: id, name: name, contextLength: contextLength,
                  supportsTools: supportsTools, supportsImages: supportsImages,
                  supportsJSON: supportsJSON, discovered: true)
        }
    }

    var validationError: String? {
        guard version == 1 else { return "网关配置版本不受支持，原文件已保留。" }
        guard [1, 6, 24].contains(refreshHours), (1...5).contains(maxAttempts),
              (1...8).contains(maxConcurrent), (1...8).contains(defaultProviderConcurrent),
              providerConcurrent.count <= 200,
              providerConcurrent.allSatisfy({ UUID(uuidString: $0.key)?.uuidString == $0.key && (1...8).contains($0.value) }),
              (0...128).contains(maxQueued), (1...128).contains(providerQueueCapacity), (1...120).contains(queueTimeoutSeconds),
              (1...60).contains(requestsPerMinute),
              members.count <= 200, catalog.count <= 1000,
              Set(members.map(\.id)).count == members.count else { return "网关配置超出允许范围。" }
        guard members.allSatisfy({ !$0.model.isEmpty && $0.model.utf8.count <= 200 && $0.contextLength > 0
            && Set($0.difficulties).count == $0.difficulties.count }) else {
            return "模型 ID 或上下文长度无效。"
        }
        return nil
    }

    func concurrentLimit(for providerID: UUID) -> Int {
        providerConcurrent[providerID.uuidString] ?? defaultProviderConcurrent
    }

    static func isOpenRouter(_ base: String) -> Bool {
        guard let url = URLComponents(string: base) else { return false }
        return url.scheme == "https" && url.host?.lowercased() == "openrouter.ai"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && ["/api/v1", "/api/v1/"].contains(url.path)
    }

    /// Price strings must be present, numeric and exactly zero. A :free suffix
    /// alone is not proof; unknown/additional charge dimensions fail closed.
    static func parseCatalog(_ data: Data, now: Date = Date()) throws -> [CatalogModel] {
        guard data.count <= 8 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]], rows.count <= 10_000 else {
            throw GatewayFailure.invalidCatalog
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 200,
                  let prices = row["pricing"] as? [String: Any],
                  prices["prompt"] != nil, prices["completion"] != nil,
                  prices.values.allSatisfy({ value in
                      if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return false }
                      let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
                      return text.range(of: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
                          && Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) == .zero
                  }),
                  let context = row["context_length"] as? Int, context > 0,
                  let architecture = row["architecture"] as? [String: Any],
                  (architecture["output_modalities"] as? [String] ?? []).contains("text") else { return nil }
            if let expiration = row["expiration_date"] as? String,
               let date = ISO8601DateFormatter().date(from: expiration + "T00:00:00Z"), date <= now { return nil }
            guard seen.insert(id).inserted else { return nil }
            let parameters = row["supported_parameters"] as? [String] ?? []
            let provider = row["top_provider"] as? [String: Any]
            return CatalogModel(id: id, name: row["name"] as? String ?? id, contextLength: context,
                supportsTools: parameters.contains("tools"),
                supportsImages: (architecture["input_modalities"] as? [String] ?? []).contains("image"),
                supportsJSON: parameters.contains("response_format") || parameters.contains("structured_outputs"),
                maxOutput: provider?["max_completion_tokens"] as? Int)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum GatewayFailure: Error, LocalizedError, Equatable {
    case disabled, emptyPool, noCompatibleModel, coolingDown, busy, rateLimited, queueFull, queueTimedOut
    case invalidCatalog, discoveryFailed(Int), upstream(Int), interrupted, incomplete, invalidRequest, invalidDifficulty
    var errorDescription: String? {
        switch self {
        case .disabled: return "自动网关未启用，请在「模型 → 自动网关」开启。"
        case .emptyPool: return "模型池没有可用模型，请加入免费模型并检查供应商凭据。"
        case .noCompatibleModel: return "模型池中没有符合任务难度、工具、图片或上下文要求的模型。"
        case .coolingDown: return "候选模型正在冷却，稍后重试或调整模型池。"
        case .busy: return "网关并发已满，请稍后重试。"
        case .queueFull: return "网关等待队列已满，请稍后重试。"
        case .queueTimedOut: return "网关排队等待超时，请稍后重试。"
        case .rateLimited: return "网关每分钟请求额度已用完，请稍后重试。"
        case .invalidCatalog: return "免费模型目录无效，已保留上次成功发现的结果。"
        case .discoveryFailed(let code): return "OpenRouter 模型发现失败（HTTP \(code)），请检查网络和凭据。"
        case .upstream(let code): return "模型上游暂不可用（HTTP \(code)）。"
        case .interrupted: return "请求已中断。"
        case .incomplete: return "模型响应未完整结束，请重试。"
        case .invalidRequest: return "请求格式或能力暂不受网关支持。"
        case .invalidDifficulty: return "task_difficulty 必须为 low、medium 或 high。"
        }
    }
    var code: String {
        switch self {
        case .queueFull: return "gateway_queue_full"
        case .queueTimedOut: return "gateway_queue_timeout"
        case .busy: return "gateway_busy"
        case .rateLimited: return "gateway_rate_limited"
        default: return "gateway_error"
        }
    }
    var retryAfter: Int? {
        switch self {
        case .busy, .queueFull, .queueTimedOut: return 1
        case .rateLimited, .coolingDown: return 60
        default: return nil
        }
    }
    var status: Int {
        switch self {
        case .rateLimited, .busy, .queueFull: return 429
        case .queueTimedOut: return 504
        case .invalidRequest, .invalidDifficulty, .noCompatibleModel: return 400
        case .disabled, .emptyPool, .coolingDown: return 503
        case .upstream(let code): return code
        default: return 502
        }
    }
}

struct GatewayRequirements: Sendable {
    var routing: GatewayTaskRouting
    var difficulty: GatewayTaskDifficulty { routing.difficulty }
    var tools: Bool
    var images: Bool
    var json: Bool
    var context: Int
    var output: Int

    /// Receives the normalized Chat body, so every supported protocol uses the
    /// same capability filter. Image bytes never masquerade as text tokens.
    init(chat: [String: Any]) throws {
        let override: GatewayTaskDifficulty?
        if let supplied = chat["task_difficulty"] {
            guard let text = supplied as? String, let value = GatewayTaskDifficulty(rawValue: text) else { throw GatewayFailure.invalidDifficulty }
            override = value
        } else { override = nil }
        tools = !(chat["tools"] as? [Any] ?? []).isEmpty
        images = false
        json = chat["response_format"] != nil
        guard let messages = chat["messages"] as? [[String: Any]], !messages.isEmpty else { throw GatewayFailure.invalidRequest }
        var bytes = 0
        for message in messages {
            if message["tool_calls"] != nil || message["role"] as? String == "tool" {
                tools = true
                if let calls = message["tool_calls"] { bytes += (try JSONSerialization.data(withJSONObject: calls)).count }
            }
            if let text = message["content"] as? String { bytes += text.utf8.count }
            else if let parts = message["content"] as? [[String: Any]] {
                for part in parts {
                    switch part["type"] as? String {
                    case "text": bytes += (part["text"] as? String ?? "").utf8.count
                    case "image_url": images = true
                    default: throw GatewayFailure.invalidRequest
                    }
                }
            }
        }
        if let declarations = chat["tools"] { bytes += (try JSONSerialization.data(withJSONObject: declarations)).count }
        output = chat["max_completion_tokens"] as? Int ?? chat["max_tokens"] as? Int ?? 4096
        guard output > 0, output <= 200_000, bytes <= 16 * 1024 * 1024 else { throw GatewayFailure.invalidRequest }
        context = bytes / 2 + output + 1024 + (images ? 4096 : 0)
        routing = GatewayTaskRouter.analyze(messages: messages, tools: tools, images: images, override: override)
    }

    func accepts(_ member: FreeModelPool.Member, difficulty selected: GatewayTaskDifficulty? = nil) -> Bool {
        member.difficulties.contains(selected ?? difficulty) && (!tools || member.supportsTools) && (!images || member.supportsImages)
            && (!json || member.supportsJSON) && context <= member.contextLength
    }
}

/// Pools saved before task tiers apply to every tier until the user narrows them.
extension FreeModelPool.Member {
    private enum CodingKeys: String, CodingKey {
        case providerID, model, name, enabled, contextLength, supportsTools, supportsImages, supportsJSON, discovered, difficulties
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(providerID: try container.decode(UUID.self, forKey: .providerID),
                  model: try container.decode(String.self, forKey: .model),
                  name: try container.decode(String.self, forKey: .name),
                  enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                  contextLength: try container.decode(Int.self, forKey: .contextLength),
                  supportsTools: try container.decode(Bool.self, forKey: .supportsTools),
                  supportsImages: try container.decode(Bool.self, forKey: .supportsImages),
                  supportsJSON: try container.decode(Bool.self, forKey: .supportsJSON),
                  discovered: try container.decodeIfPresent(Bool.self, forKey: .discovered) ?? false,
                  difficulties: try container.decodeIfPresent([GatewayTaskDifficulty].self, forKey: .difficulties) ?? GatewayTaskDifficulty.allCases)
    }
}

/// Existing version-one pools keep their settings and gain bounded admission defaults.
extension FreeModelPool {
    private enum CodingKeys: String, CodingKey {
        case version, enabled, interceptAll, discoveryEnabled, automaticallyJoin, refreshHours, strategy
        case maxAttempts, maxConcurrent, requestsPerMinute, openRouterProviderID, members, catalog, discoveredAt
        case defaultProviderConcurrent, providerConcurrent, maxQueued, providerQueueCapacity, queueTimeoutSeconds
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        interceptAll = try c.decode(Bool.self, forKey: .interceptAll)
        discoveryEnabled = try c.decode(Bool.self, forKey: .discoveryEnabled)
        automaticallyJoin = try c.decode(Bool.self, forKey: .automaticallyJoin)
        refreshHours = try c.decode(Int.self, forKey: .refreshHours)
        strategy = try c.decode(Strategy.self, forKey: .strategy)
        maxAttempts = try c.decode(Int.self, forKey: .maxAttempts)
        maxConcurrent = try c.decode(Int.self, forKey: .maxConcurrent)
        requestsPerMinute = try c.decode(Int.self, forKey: .requestsPerMinute)
        openRouterProviderID = try c.decodeIfPresent(UUID.self, forKey: .openRouterProviderID)
        members = try c.decode([Member].self, forKey: .members)
        catalog = try c.decode([CatalogModel].self, forKey: .catalog)
        discoveredAt = try c.decodeIfPresent(Date.self, forKey: .discoveredAt)
        defaultProviderConcurrent = try c.decodeIfPresent(Int.self, forKey: .defaultProviderConcurrent) ?? 2
        providerConcurrent = try c.decodeIfPresent([String: Int].self, forKey: .providerConcurrent) ?? [:]
        maxQueued = try c.decodeIfPresent(Int.self, forKey: .maxQueued) ?? 32
        providerQueueCapacity = try c.decodeIfPresent(Int.self, forKey: .providerQueueCapacity) ?? 8
        queueTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .queueTimeoutSeconds) ?? 30
    }
}
