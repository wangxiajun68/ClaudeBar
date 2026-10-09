import Foundation

/// Owns admission, selection and circuit breakers; no main-thread or UI work.
actor FreeModelGateway {
    static let shared = FreeModelGateway()

    struct Endpoint: Equatable, Sendable {
        var id: UUID
        var name: String
        var baseURL: String
        var apiKey: String
    }
    struct Candidate: Sendable {
        var member: FreeModelPool.Member
        var endpoint: Endpoint
    }
    struct Plan: Sendable {
        var id: UUID
        var revision: UInt
        var candidates: [Candidate]
        var routing: GatewayTaskRouting
        var difficulty: GatewayTaskDifficulty { routing.difficulty }
        var selection: String
    }
    struct Health: Equatable, Sendable {
        var successes = 0
        var failures = 0
        var consecutiveFailures = 0
        var cooldownUntil: Date?
        var lastStatus: Int?
        var latency: Double?
        var lastUsed: Date?
    }
    struct Route: Equatable, Identifiable, Sendable {
        var id = UUID()
        var date: Date
        var model: String
        var provider: String
        var status: Int
        var latency: Double
        var routing: GatewayTaskRouting
        var difficulty: GatewayTaskDifficulty { routing.difficulty }
        var selection: String
    }
    struct Snapshot: Equatable, Sendable {
        var health: [String: Health] = [:]
        var active = 0
        var requests = 0
        var routes: [Route] = []
    }

    private var pool = FreeModelPool()
    private var endpoints: [UUID: Endpoint] = [:]
    private var health: [String: Health] = [:]
    private var providerCooldown: [UUID: Date] = [:]
    private var admitted: [Date] = []
    private var active = Set<UUID>()
    private var attempts: [UUID: Int] = [:]
    private var requestCount = 0
    private var routes: [Route] = []
    private var revision: UInt = 0

    func configure(_ pool: FreeModelPool, endpoints: [Endpoint]) {
        guard pool.validationError == nil else { return }
        let next = Dictionary(endpoints.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guard self.pool != pool || self.endpoints != next else { return }
        for member in pool.members where self.endpoints[member.providerID] != next[member.providerID] {
            health[member.id] = nil
            providerCooldown[member.providerID] = nil
        }
        health = health.filter { key, _ in pool.members.contains { $0.id == key } }
        self.pool = pool
        self.endpoints = next
        revision &+= 1
    }

    /// `auto` is reserved even while disabled, so it cannot accidentally reach
    /// a paid upstream. Explicit model names retain normal routing by default.
    func handles(model: String, thirdParty: Bool) -> Bool {
        thirdParty && (["auto", "claudebar/auto"].contains(model.lowercased()) || (pool.enabled && pool.interceptAll))
    }

    func begin(_ requirements: GatewayRequirements, now: Date = Date()) throws -> Plan {
        guard pool.enabled else { throw GatewayFailure.disabled }
        var routing = requirements.routing
        let levels = routing.source == .explicit ? [routing.difficulty]
            : Array(GatewayTaskDifficulty.allCases.drop { $0 != routing.difficulty })
        var free: [(Int, Candidate)] = []
        // Automatic estimates may rise to a configured stronger tier when
        // none fits. Explicit client tiers are strict. Admission and every
        // retry stay in the selected tier; never lower the quality estimate.
        for level in levels {
            free = pool.members.enumerated().compactMap { index, member -> (Int, Candidate)? in
                guard member.enabled, let endpoint = endpoints[member.providerID], !endpoint.apiKey.isEmpty else { return nil }
                if FreeModelPool.isOpenRouter(endpoint.baseURL) {
                    guard let discovered = pool.discoveredAt, now.timeIntervalSince(discovered) < 48 * 3600,
                          let catalog = pool.catalog.first(where: { $0.id == member.model }),
                          requirements.output <= (catalog.maxOutput ?? Int.max) else { return nil }
                    var current = catalog.member(providerID: member.providerID)
                    current.difficulties = member.difficulties
                    guard requirements.accepts(current, difficulty: level) else { return nil }
                } else if !requirements.accepts(member, difficulty: level) { return nil }
                return (index, Candidate(member: member, endpoint: endpoint))
            }
            if !free.isEmpty {
                if level != routing.difficulty {
                    routing.reason += " · \(routing.difficulty.rawValue) 无兼容模型，升至 \(level.rawValue)"
                    routing.difficulty = level
                }
                break
            }
        }
        guard !free.isEmpty else {
            if pool.members.contains(where: { $0.enabled && endpoints[$0.providerID] != nil }) {
                throw GatewayFailure.noCompatibleModel
            }
            throw GatewayFailure.emptyPool
        }
        let ready = free.filter { _, candidate in
            (health[candidate.member.id]?.cooldownUntil ?? .distantPast) <= now
                && (providerCooldown[candidate.endpoint.id] ?? .distantPast) <= now
        }.sorted { lhs, rhs in
            let left = health[lhs.1.member.id] ?? Health(), right = health[rhs.1.member.id] ?? Health()
            switch pool.strategy {
            case .priority: return lhs.0 < rhs.0
            case .latency:
                if left.latency != right.latency { return (left.latency ?? 0) < (right.latency ?? 0) }
                fallthrough
            case .balanced:
                if left.consecutiveFailures != right.consecutiveFailures { return left.consecutiveFailures < right.consecutiveFailures }
                if left.lastUsed != right.lastUsed { return (left.lastUsed ?? .distantPast) < (right.lastUsed ?? .distantPast) }
                return lhs.0 < rhs.0
            }
        }
        guard !ready.isEmpty else { throw GatewayFailure.coolingDown }
        guard active.count < pool.maxConcurrent else { throw GatewayFailure.busy }
        admitted.removeAll { now.timeIntervalSince($0) >= 60 }
        guard admitted.count < pool.requestsPerMinute else { throw GatewayFailure.rateLimited }
        let id = UUID()
        admitted.append(now); active.insert(id); requestCount += 1
        let selection: String
        switch pool.strategy {
        case .priority: selection = "同档位 · 池内优先级"
        case .balanced: selection = "同档位 · 故障与使用频率"
        case .latency: selection = "同档位 · 观测响应延迟"
        }
        return Plan(id: id, revision: revision, candidates: Array(ready.prefix(pool.maxAttempts).map(\.1)), routing: routing, selection: selection)
    }

    /// A concurrent request may have put the next model/account into cooldown
    /// since the plan was frozen. Revalidate before spending another request.
    func canAttempt(_ candidate: Candidate, plan: Plan, now: Date = Date()) -> Bool {
        guard active.contains(plan.id), plan.revision == revision, pool.enabled else { return false }
        return (health[candidate.member.id]?.cooldownUntil ?? .distantPast) <= now
            && (providerCooldown[candidate.endpoint.id] ?? .distantPast) <= now
    }

    func started(_ candidate: Candidate, plan: Plan, now: Date = Date()) throws {
        admitted.removeAll { now.timeIntervalSince($0) >= 60 }
        if (attempts[plan.id] ?? 0) > 0 {
            guard admitted.count < pool.requestsPerMinute else { throw GatewayFailure.rateLimited }
            admitted.append(now)
        }
        attempts[plan.id, default: 0] += 1
        var value = health[candidate.member.id] ?? Health()
        value.lastUsed = now
        health[candidate.member.id] = value
    }

    func report(_ candidate: Candidate, plan: Plan, status: Int, latency: Double,
                retryAfter: TimeInterval? = nil, now: Date = Date()) {
        guard plan.revision == revision else { return }
        var value = health[candidate.member.id] ?? Health()
        value.lastStatus = status
        if (200..<300).contains(status) {
            value.successes += 1; value.consecutiveFailures = 0; value.cooldownUntil = nil
            value.latency = value.latency.map { $0 * 0.7 + latency * 0.3 } ?? latency
        } else if status != 0 {
            value.failures += 1; value.consecutiveFailures += 1
            let delay: Double
            switch status {
            case 401, 402, 403:
                delay = 300
                providerCooldown[candidate.endpoint.id] = now.addingTimeInterval(delay)
            case 404, 410: delay = 1800
            case 429: delay = min(3600, max(60, retryAfter ?? 60))
            default: delay = min(300, 15 * pow(2, Double(min(5, value.consecutiveFailures - 1))))
            }
            value.cooldownUntil = now.addingTimeInterval(delay)
        }
        health[candidate.member.id] = value
        routes.insert(.init(date: now, model: candidate.member.model, provider: candidate.endpoint.name,
                            status: status, latency: latency, routing: plan.routing, selection: plan.selection), at: 0)
        if routes.count > 40 { routes.removeLast(routes.count - 40) }
    }

    func finish(_ plan: Plan) { active.remove(plan.id); attempts[plan.id] = nil }
    func snapshot(now: Date = Date()) -> Snapshot {
        for key in health.keys where (health[key]?.cooldownUntil ?? .distantFuture) <= now { health[key]?.cooldownUntil = nil }
        var displayed = health
        for member in pool.members {
            if let until = providerCooldown[member.providerID], until > now {
                var value = displayed[member.id] ?? Health()
                value.cooldownUntil = max(until, value.cooldownUntil ?? .distantPast)
                displayed[member.id] = value
            }
        }
        return .init(health: displayed, active: active.count, requests: requestCount, routes: routes)
    }
    func resetHealth() { health.removeAll(); providerCooldown.removeAll() }

    func advertisedModels() -> [String] {
        guard pool.enabled else { return [] }
        return ["auto", "claudebar/auto"]
    }

    static func retryable(status: Int) -> Bool { [401, 402, 403, 408, 404, 410, 429, 500, 502, 503, 504].contains(status) }

    /// Replace client routing hints, including model fallbacks and paid plugins.
    /// For OpenRouter every price dimension has a hard zero ceiling.
    static func outbound(_ chat: [String: Any], candidate: Candidate, stream: Bool) -> [String: Any] {
        var body = chat
        body["model"] = candidate.member.model
        body["stream"] = stream
        for key in ["models", "route", "provider", "plugins", "transforms", "user", "task_difficulty"] { body.removeValue(forKey: key) }
        if stream { body["stream_options"] = ["include_usage": true] }
        else { body.removeValue(forKey: "stream_options") }
        if body["max_tokens"] == nil && body["max_completion_tokens"] == nil { body["max_tokens"] = 4096 }
        if FreeModelPool.isOpenRouter(candidate.endpoint.baseURL) {
            // OpenRouter always supplies usage. Its deprecated stream_options
            // can wrongly exclude endpoints with require_parameters enabled.
            body.removeValue(forKey: "stream_options")
            body["provider"] = ["max_price": ["prompt": 0, "completion": 0, "request": 0, "image": 0, "audio": 0],
                                "require_parameters": true]
        }
        return body
    }
}

/// Refuse redirects so a provider cannot transfer a credential to another host.
final class GatewayNetwork: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = GatewayNetwork()
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 180
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func catalog(apiKey: String) async throws -> [FreeModelPool.CatalogModel] {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw GatewayFailure.discoveryFailed((response as? HTTPURLResponse)?.statusCode ?? 502)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8 * 1024 * 1024 else { throw GatewayFailure.invalidCatalog }
            data.append(byte)
        }
        return try FreeModelPool.parseCatalog(data)
    }
}

/// File I/O stays serial and off the main actor, including the initial read.
actor FreeModelPoolStorage {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> FreeModelPool {
        guard FileManager.default.fileExists(atPath: url.path) else { return FreeModelPool() }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024 else { throw GatewayFailure.invalidCatalog }
        let value = try JSONDecoder().decode(FreeModelPool.self, from: data)
        guard value.validationError == nil else { throw GatewayFailure.invalidCatalog }
        return value
    }
    func save(_ pool: FreeModelPool) throws {
        guard pool.validationError == nil else { throw GatewayFailure.invalidCatalog }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateFileWriter.write(JSONEncoder().encode(pool), to: url)
    }
}
