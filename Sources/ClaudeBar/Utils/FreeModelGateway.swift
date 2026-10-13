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
        var requestBytes = 0
        var testingMemberID: String? = nil
        var candidates: [Candidate]
        var routing: GatewayTaskRouting
        var difficulty: GatewayTaskDifficulty { routing.difficulty }
        var selection: String
        var firstOutputTimeoutSeconds = 20
        var streamIdleTimeoutSeconds = 30
        var retryBudgetSeconds = 60
        var requestTimeoutSeconds = 180
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
        var requestID: UUID?
        var memberID = ""
        var date: Date
        var model: String
        var provider: String
        var status: Int
        var latency: Double
        var routing: GatewayTaskRouting
        var difficulty: GatewayTaskDifficulty { routing.difficulty }
        var selection: String
    }
    /// Runtime-only, bounded request telemetry. Never contains a prompt, key,
    /// upstream URL or output text. Every phase is driven by transport events.
    struct Flight: Equatable, Identifiable, Sendable {
        enum Phase: String, Sendable {
            case connecting, waiting, streaming, succeeded, failed, cancelled
            var isActive: Bool { self == .connecting || self == .waiting || self == .streaming }
            var title: String {
                switch self {
                case .connecting: return "连接上游"
                case .waiting: return "等待输出"
                case .streaming: return "接收输出"
                case .succeeded: return "已完成"
                case .failed: return "尝试失败"
                case .cancelled: return "已中断"
                }
            }
        }
        var id = UUID()
        var requestID: UUID
        var memberID: String
        var routing: GatewayTaskRouting
        var phase: Phase
        var attempt: Int
        var startedAt: Date
        var updatedAt: Date
        var outputPulses = 0
    }
    struct ProviderLoad: Equatable, Sendable {
        var active = 0
        /// Waiters assigned to this configuration; dispatch may use another compatible provider.
        var queued = 0
        var limit = 2
    }
    /// Bounded, in-memory queue telemetry. No request body or credentials.
    struct QueueEntry: Equatable, Identifiable, Sendable {
        var id: UUID
        var providerID: UUID
        var routing: GatewayTaskRouting
        var enqueuedAt: Date
        var deadline: Date
        var attempt: Int
    }
    struct Snapshot: Equatable, Sendable {
        var health: [String: Health] = [:]
        var active = 0
        var requests = 0
        var queued = 0
        var queuedBytes = 0
        var providers: [UUID: ProviderLoad] = [:]
        var routes: [Route] = []
        var flights: [Flight] = []
        var queue: [QueueEntry] = []
    }

    private var pool = FreeModelPool()
    private var endpoints: [UUID: Endpoint] = [:]
    private var health: [String: Health] = [:]
    private var providerCooldown: [UUID: Date] = [:]
    private struct RateWindow {
        private var values: [Date] = []
        private var head = 0
        var count: Int { values.count - head }
        mutating func prune(now: Date) {
            while head < values.count, now.timeIntervalSince(values[head]) >= 60 { head += 1 }
            if head > 1024 || head == values.count {
                values.removeFirst(head); head = 0
            }
        }
        mutating func append(_ now: Date) { values.append(now) }
    }
    private var admitted = RateWindow()
    private var providerAdmissions: [UUID: RateWindow] = [:]
    private var providerService: [UUID: Double] = [:]
    private var catalogByID: [String: FreeModelPool.CatalogModel] = [:]
    private var providerOccupancy: [UUID: Int] = [:]
    private var memberOccupancy: [String: Int] = [:]
    private var active = Set<UUID>()
    private struct Reservation {
        var providerID: UUID
        var memberID: String
    }
    private struct Waiter {
        enum Work {
            case request(GatewayRequirements, String?, CheckedContinuation<Plan, Error>)
            case attempt([Candidate], Plan, CheckedContinuation<Candidate, Error>)
        }
        var id: UUID
        var providerID: UUID
        var requestBytes = 0
        var routing: GatewayTaskRouting
        var enqueuedAt: Date
        var deadline: Date = .distantFuture
        var work: Work
        var timeout: Task<Void, Never>?
        func fail(_ error: Error) {
            switch work {
            case .request(_, _, let c): c.resume(throwing: error)
            case .attempt(_, _, let c): c.resume(throwing: error)
            }
        }
    }
    private var reservations: [UUID: Reservation] = [:]
    private var waiters: [Waiter] = []
    private var queuedBytes = 0
    private var queuedByProvider: [UUID: Int] = [:]
    private var attempts: [UUID: Int] = [:]
    private var requestCount = 0
    private var routes: [Route] = []
    private var flights: [Flight] = []
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var revision: UInt = 0
    private var outputPublication: Task<Void, Never>?

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
        catalogByID = Dictionary(pool.catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        providerAdmissions = providerAdmissions.filter { next[$0.key] != nil }
        providerService = providerService.filter { next[$0.key] != nil }
        revision &+= 1
        failWaiters(pool.enabled ? GatewayFailure.interrupted : GatewayFailure.disabled)
        // In-flight transports still own their slots until report/finish.
        publish()
    }

    /// `auto` is reserved even while disabled, so it cannot accidentally reach
    /// a paid upstream. Explicit model names retain normal routing by default.
    func handles(model: String, thirdParty: Bool) -> Bool {
        thirdParty && (["auto", "claudebar/auto"].contains(model.lowercased()) || (pool.enabled && pool.interceptAll))
    }

    func begin(_ requirements: GatewayRequirements, requestBytes: Int = 0, now: Date = Date(), testingMemberID: String? = nil,
               requestID: UUID = UUID()) async throws -> Plan {
        try Task.checkCancellation()
        guard (0...64 * 1024 * 1024).contains(requestBytes) else { throw GatewayFailure.invalidRequest }
        drain(now: now)
        var plan = try prepare(requirements, requestBytes: requestBytes, now: now, testingMemberID: testingMemberID)
        plan.id = requestID
        try checkRate(now: now)
        if let admitted = admit(plan, now: now) {
            if Task.isCancelled { finish(admitted); throw CancellationError() }
            publish()
            return admitted
        }
        let queuedFor = try checkQueue(requestBytes: requestBytes, providers: plan.candidates.map { $0.endpoint.id })
        let id = plan.id
        let result: Plan = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                enqueue(.init(id: id, providerID: queuedFor,
                              requestBytes: requestBytes, routing: plan.routing, enqueuedAt: now,
                              work: .request(requirements, testingMemberID, continuation)))
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
        if Task.isCancelled { finish(result); throw CancellationError() }
        return result
    }

    private func prepare(_ requirements: GatewayRequirements, requestBytes: Int, now: Date, testingMemberID: String? = nil) throws -> Plan {
        guard pool.enabled || testingMemberID != nil else { throw GatewayFailure.disabled }
        var routing = requirements.routing
        let levels = routing.source == .explicit ? [routing.difficulty]
            : Array(GatewayTaskDifficulty.allCases.drop { $0 != routing.difficulty })
        // Pin before capability/context/health filtering: a longer input or a
        // missing credential must not silently change the embedding space.
        let pinnedEmbedding = requirements.nativeEndpoint && requirements.media.contains(.embeddings)
            ? pool.members.first { $0.enabled && ($0.mediaCapabilities ?? []).contains(.embeddings) }?.model : nil
        var free: [(Int, Candidate)] = []
        // Automatic estimates may rise to a configured stronger tier when
        // none fits. Explicit client tiers are strict. Admission and every
        // retry stay in the selected tier; never lower the quality estimate.
        for level in levels {
            free = pool.members.enumerated().compactMap { index, member -> (Int, Candidate)? in
                guard testingMemberID == nil || member.id == testingMemberID,
                      pinnedEmbedding == nil || member.model == pinnedEmbedding,
                      member.enabled, let endpoint = endpoints[member.providerID], !endpoint.apiKey.isEmpty else { return nil }
                if FreeModelPool.isOpenRouter(endpoint.baseURL) {
                    guard !requirements.nativeEndpoint,
                          let discovered = pool.discoveredAt, now.timeIntervalSince(discovered) < 48 * 3600,
                          let catalog = catalogByID[member.model],
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
                && providerRateAvailable(candidate.endpoint.id, now: now)
        }.sorted { lhs, rhs in
            let left = health[lhs.1.member.id] ?? Health(), right = health[rhs.1.member.id] ?? Health()
            switch pool.strategy {
            case .priority: return lhs.0 < rhs.0
            case .weighted:
                let a = providerService[lhs.1.endpoint.id] ?? 0, b = providerService[rhs.1.endpoint.id] ?? 0
                if a != b { return a < b }
                fallthrough
            case .latency:
                if pool.strategy == .latency, left.latency != right.latency { return (left.latency ?? 0) < (right.latency ?? 0) }
                fallthrough
            case .balanced:
                if left.consecutiveFailures != right.consecutiveFailures { return left.consecutiveFailures < right.consecutiveFailures }
                if left.lastUsed != right.lastUsed { return (left.lastUsed ?? .distantPast) < (right.lastUsed ?? .distantPast) }
                return lhs.0 < rhs.0
            }
        }
        guard !ready.isEmpty else {
            if free.contains(where: { _, c in
                (health[c.member.id]?.cooldownUntil ?? .distantPast) <= now
                    && (providerCooldown[c.endpoint.id] ?? .distantPast) <= now
                    && !providerRateAvailable(c.endpoint.id, now: now)
            }) { throw GatewayFailure.rateLimited }
            throw GatewayFailure.coolingDown
        }
        let selection: String
        switch pool.strategy {
        case .priority: selection = "同档位 · 池内优先级"
        case .balanced: selection = "同档位 · 故障与使用频率"
        case .latency: selection = "同档位 · 观测响应延迟"
        case .weighted: selection = "同档位 · 供应商权重"
        }
        return Plan(id: UUID(), revision: revision, requestBytes: requestBytes, testingMemberID: testingMemberID,
                    candidates: ready.map(\.1), routing: routing, selection: testingMemberID == nil ? selection : "手动测试 · 指定模型",
                    firstOutputTimeoutSeconds: pool.firstOutputTimeoutSeconds, streamIdleTimeoutSeconds: pool.streamIdleTimeoutSeconds,
                    retryBudgetSeconds: pool.retryBudgetSeconds,
                    requestTimeoutSeconds: pool.requestTimeoutSeconds)
    }

    /// A concurrent request may have put the next model/account into cooldown
    /// since the plan was frozen. Revalidate before spending another request.
    func canAttempt(_ candidate: Candidate, plan: Plan, now: Date = Date()) -> Bool {
        guard active.contains(plan.id), plan.revision == revision, (pool.enabled || plan.testingMemberID != nil),
              (attempts[plan.id] ?? 0) < pool.maxAttempts else { return false }
        return (health[candidate.member.id]?.cooldownUntil ?? .distantPast) <= now
            && (providerCooldown[candidate.endpoint.id] ?? .distantPast) <= now
            && (reservations[plan.id]?.providerID == candidate.endpoint.id || providerRateAvailable(candidate.endpoint.id, now: now))
    }

    func isCurrent(_ plan: Plan) -> Bool { active.contains(plan.id) && plan.revision == revision }

    /// Prefer a free compatible provider over waiting behind a saturated one.
    /// Actual attempt admission remains atomic inside `started`.
    func preferredAttempt(_ candidates: [Candidate], plan: Plan, now: Date = Date()) -> Candidate? {
        let ready = candidates.filter { canAttempt($0, plan: plan, now: now) }
        if let held = reservations[plan.id], !ready.contains(where: { $0.member.id == held.memberID }),
           !flights.contains(where: { $0.requestID == plan.id && $0.phase.isActive }) {
            // Another call can cool the account before this call starts.
            // Drop its unused reservation before selecting a different account.
            reserve(nil, for: plan.id)
            drain(now: now); publish()
        }
        return ready.first { reservations[plan.id]?.memberID == $0.member.id || (hasCapacity($0.endpoint.id) && recoveryAvailable($0)) }
            ?? ready.first
    }

    func started(_ candidate: Candidate, plan: Plan, now: Date = Date(),
                 waitTimeout: TimeInterval? = nil) async throws {
        guard try await acquireAttempt([candidate], plan: plan, now: now, waitTimeout: waitTimeout) != nil else {
            throw GatewayFailure.coolingDown
        }
    }

    /// Reserve the next actual attempt, reconsidering all remaining compatible
    /// providers when a slot opens rather than pinning a retry to a busy one.
    func acquireAttempt(_ candidates: [Candidate], plan: Plan, now: Date = Date(),
                        waitTimeout: TimeInterval? = nil) async throws -> Candidate? {
        try Task.checkCancellation()
        guard pool.enabled || plan.testingMemberID != nil else { throw GatewayFailure.disabled }
        guard active.contains(plan.id), plan.revision == revision else { throw GatewayFailure.interrupted }
        if let waitTimeout, waitTimeout <= 0 { throw GatewayFailure.queueTimedOut }
        drain(now: now)
        guard let candidate = preferredAttempt(candidates, plan: plan, now: now) else { return nil }
        if try startAttempt(candidate, plan: plan, now: now) {
            if Task.isCancelled { finish(plan); throw CancellationError() }
            publish(); return candidate
        }
        let ready = candidates.filter { canAttempt($0, plan: plan, now: now) }
        let queuedFor = try checkQueue(requestBytes: plan.requestBytes, providers: ready.map { $0.endpoint.id })
        let id = UUID()
        let result: Candidate = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                enqueue(.init(id: id, providerID: queuedFor, requestBytes: plan.requestBytes,
                              routing: plan.routing, enqueuedAt: now,
                              work: .attempt(ready, plan, continuation)), timeout: waitTimeout)
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
        if Task.isCancelled { finish(plan); throw CancellationError() }
        return result
    }

    private func hasCapacity(_ providerID: UUID) -> Bool {
        reservations.count < pool.maxConcurrent
            && providerOccupancy[providerID, default: 0] < pool.concurrentLimit(for: providerID)
    }
    private func reserve(_ value: Reservation?, for id: UUID) {
        if let old = reservations[id] {
            providerOccupancy[old.providerID, default: 0] -= 1
            memberOccupancy[old.memberID, default: 0] -= 1
            if providerOccupancy[old.providerID] == 0 { providerOccupancy[old.providerID] = nil }
            if memberOccupancy[old.memberID] == 0 { memberOccupancy[old.memberID] = nil }
        }
        reservations[id] = value
        if let value {
            providerOccupancy[value.providerID, default: 0] += 1
            memberOccupancy[value.memberID, default: 0] += 1
        }
    }
    private func recoveryAvailable(_ candidate: Candidate) -> Bool {
        if providerCooldown[candidate.endpoint.id] != nil, providerOccupancy[candidate.endpoint.id, default: 0] > 0 { return false }
        return (health[candidate.member.id]?.consecutiveFailures ?? 0) == 0 || memberOccupancy[candidate.member.id, default: 0] == 0
    }
    private func providerRateAvailable(_ id: UUID, now: Date) -> Bool {
        guard let limit = pool.providerRequestsPerMinute[id.uuidString] else { return true }
        providerAdmissions[id]?.prune(now: now)
        return (providerAdmissions[id]?.count ?? 0) < limit
    }
    private func debitProvider(_ id: UUID, now: Date) {
        if pool.providerRequestsPerMinute[id.uuidString] != nil {
            providerAdmissions[id, default: RateWindow()].prune(now: now)
            providerAdmissions[id, default: RateWindow()].append(now)
        }
        providerService[id, default: 0] += 1 / Double(pool.providerWeights[id.uuidString] ?? 1)
    }
    private func checkRate(now: Date) throws {
        admitted.prune(now: now)
        guard admitted.count < pool.requestsPerMinute else { throw GatewayFailure.rateLimited }
    }
    private func checkQueue(requestBytes: Int, providers: [UUID]) throws -> UUID {
        guard pool.maxQueued > 0 else { throw GatewayFailure.busy }
        guard waiters.count < pool.maxQueued, requestBytes >= 0,
              requestBytes <= 64 * 1024 * 1024 - queuedBytes else {
            throw GatewayFailure.queueFull
        }
        guard let provider = providers.first(where: { id in
            queuedByProvider[id, default: 0] < pool.providerQueueCapacity
        }) else { throw GatewayFailure.queueFull }
        return provider
    }
    private func admit(_ plan: Plan, now: Date) -> Plan? {
        guard reservations.count < pool.maxConcurrent,
              let index = plan.candidates.firstIndex(where: { hasCapacity($0.endpoint.id) && recoveryAvailable($0) }) else { return nil }
        var result = plan
        let selected = result.candidates.remove(at: index)
        result.candidates.insert(selected, at: 0)
        reserve(.init(providerID: selected.endpoint.id, memberID: selected.member.id), for: result.id)
        debitProvider(selected.endpoint.id, now: now)
        admitted.append(now); active.insert(result.id); requestCount += 1
        return result
    }
    private func startAttempt(_ candidate: Candidate, plan: Plan, now: Date) throws -> Bool {
        guard canAttempt(candidate, plan: plan, now: now),
              plan.candidates.contains(where: { $0.member.id == candidate.member.id }),
              !flights.contains(where: { $0.requestID == plan.id && $0.phase.isActive }) else {
            throw plan.revision == revision && active.contains(plan.id) ? GatewayFailure.coolingDown : .interrupted
        }
        if let held = reservations[plan.id] {
            guard held.memberID == candidate.member.id else { throw GatewayFailure.interrupted }
        } else {
            guard hasCapacity(candidate.endpoint.id), recoveryAvailable(candidate) else { return false }
        }
        if (attempts[plan.id] ?? 0) > 0 { try checkRate(now: now); admitted.append(now) }
        if reservations[plan.id] == nil { debitProvider(candidate.endpoint.id, now: now) }
        reserve(.init(providerID: candidate.endpoint.id, memberID: candidate.member.id), for: plan.id)
        attempts[plan.id, default: 0] += 1
        var value = health[candidate.member.id] ?? Health()
        value.lastUsed = now
        health[candidate.member.id] = value
        flights.insert(.init(requestID: plan.id, memberID: candidate.member.id,
            routing: plan.routing, phase: .connecting, attempt: attempts[plan.id] ?? 1,
            startedAt: now, updatedAt: now), at: 0)
        let live = flights.filter { $0.phase.isActive }
        flights = live + Array(flights.filter { !$0.phase.isActive }.prefix(16))
        return true
    }
    private func enqueue(_ waiter: Waiter, timeout: TimeInterval? = nil) {
        var waiter = waiter
        let seconds = min(Double(pool.queueTimeoutSeconds), max(0, timeout ?? Double(pool.queueTimeoutSeconds)))
        let id = waiter.id
        waiter.deadline = waiter.enqueuedAt.addingTimeInterval(seconds)
        waiter.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.expireWaiter(id)
        }
        waiters.append(waiter)
        queuedBytes += waiter.requestBytes
        queuedByProvider[waiter.providerID, default: 0] += 1
        publish()
    }
    @discardableResult private func removeWaiter(at index: Int) -> Waiter {
        let waiter = waiters.remove(at: index)
        queuedBytes -= waiter.requestBytes
        queuedByProvider[waiter.providerID, default: 0] -= 1
        if queuedByProvider[waiter.providerID] == 0 { queuedByProvider[waiter.providerID] = nil }
        return waiter
    }
    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = removeWaiter(at: i)
        waiter.timeout?.cancel(); waiter.fail(CancellationError())
        drain(); publish()
    }
    private func expireWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = removeWaiter(at: i)
        waiter.fail(GatewayFailure.queueTimedOut)
        drain(); publish()
    }
    private func failWaiters(_ error: Error) {
        let pending = waiters; waiters.removeAll()
        queuedBytes = 0; queuedByProvider.removeAll()
        for waiter in pending { waiter.timeout?.cancel(); waiter.fail(error) }
    }
    /// Oldest runnable request wins. A blocked provider never stops another
    /// provider's independent work. No waiter owns a provider slot or RPM debit.
    private func drain(now: Date = Date()) {
        var i = 0
        var changed = false
        defer { if changed { publish() } }
        while i < waiters.count {
            let waiter = waiters[i]
            do {
                // The timeout task may be waiting for this actor. Never admit
                // expired work just because a permit was released first.
                guard waiter.deadline > now else { throw GatewayFailure.queueTimedOut }
                guard reservations.count < pool.maxConcurrent else { i += 1; continue }
                switch waiter.work {
                case .request(let requirements, let testingMemberID, let continuation):
                    var plan = try prepare(requirements, requestBytes: waiter.requestBytes, now: now, testingMemberID: testingMemberID)
                    plan.id = waiter.id
                    try checkRate(now: now)
                    guard let admitted = admit(plan, now: now) else { i += 1; continue }
                    changed = true
                    removeWaiter(at: i); waiter.timeout?.cancel(); continuation.resume(returning: admitted)
                case .attempt(let candidates, let plan, let continuation):
                    let ready = candidates.filter { canAttempt($0, plan: plan, now: now) }
                    guard let candidate = ready.first(where: { hasCapacity($0.endpoint.id) && recoveryAvailable($0) }) ?? ready.first else {
                        throw plan.revision == revision ? GatewayFailure.coolingDown : .interrupted
                    }
                    guard try startAttempt(candidate, plan: plan, now: now) else { i += 1; continue }
                    changed = true
                    removeWaiter(at: i); waiter.timeout?.cancel(); continuation.resume(returning: candidate)
                }
            } catch {
                changed = true
                removeWaiter(at: i); waiter.timeout?.cancel(); waiter.fail(error)
            }
        }
    }
    func shutdown() {
        pool.enabled = false; revision &+= 1
        failWaiters(GatewayFailure.disabled)
        publish()
    }

    func receivedHeaders(_ candidate: Candidate, plan: Plan, now: Date = Date()) {
        updateFlight(candidate, plan: plan, phase: .waiting, now: now)
    }

    /// Called at the first valid frame, then at most eight times per second by
    /// the wire loop. A paused upstream does not manufacture output pulses.
    func receivedOutput(_ candidate: Candidate, plan: Plan, now: Date = Date()) {
        updateFlight(candidate, plan: plan, phase: .streaming, now: now, output: true)
    }

    private func updateFlight(_ candidate: Candidate, plan: Plan, phase: Flight.Phase,
                              now: Date, output: Bool = false) {
        guard plan.revision == revision, active.contains(plan.id),
              let i = flights.firstIndex(where: { $0.requestID == plan.id && $0.memberID == candidate.member.id && $0.phase.isActive }) else { return }
        if output, flights[i].phase == .streaming, now.timeIntervalSince(flights[i].updatedAt) < 0.125 { return }
        let outputOnly = output && flights[i].phase == .streaming
        flights[i].phase = phase; flights[i].updatedAt = now
        if output { flights[i].outputPulses += 1 }
        publish(outputOnly: outputOnly)
    }

    func report(_ candidate: Candidate, plan: Plan, status: Int, latency: Double,
                retryAfter: TimeInterval? = nil, now: Date = Date()) {
        if let i = flights.firstIndex(where: { $0.requestID == plan.id && $0.memberID == candidate.member.id && $0.phase.isActive }) {
            flights[i].phase = status == 0 ? .cancelled : ((200..<300).contains(status) ? .succeeded : .failed)
            flights[i].updatedAt = now
        }
        // Configuration changes invalidate health writes, but must still end
        // the actual in-flight visualization; otherwise a line would glow forever.
        defer { drain(now: now); publish() }
        if reservations[plan.id]?.memberID == candidate.member.id { reserve(nil, for: plan.id) }
        guard plan.revision == revision, active.contains(plan.id) else { return }
        var value = health[candidate.member.id] ?? Health()
        value.lastStatus = status
        if (200..<300).contains(status) {
            value.successes += 1; value.consecutiveFailures = 0; value.cooldownUntil = nil
            if let until = providerCooldown[candidate.endpoint.id], until <= now { providerCooldown[candidate.endpoint.id] = nil }
            value.latency = value.latency.map { $0 * 0.7 + latency * 0.3 } ?? latency
        } else if status != 0 {
            value.failures += 1; value.consecutiveFailures += 1
            let delay: Double
            switch status {
            case 401, 402, 403:
                delay = 300
                providerCooldown[candidate.endpoint.id] = now.addingTimeInterval(delay)
            case 404, 410: delay = 1800
            case 429:
                delay = min(3600, max(1, retryAfter ?? 60))
                providerCooldown[candidate.endpoint.id] = now.addingTimeInterval(delay)
            default: delay = max(min(300, 15 * pow(2, Double(min(5, value.consecutiveFailures - 1)))), min(3600, max(0, retryAfter ?? 0)))
            }
            value.cooldownUntil = now.addingTimeInterval(delay)
        }
        health[candidate.member.id] = value
        routes.insert(.init(requestID: plan.id, memberID: candidate.member.id, date: now, model: candidate.member.model, provider: candidate.endpoint.name,
                            status: status, latency: latency, routing: plan.routing, selection: plan.selection), at: 0)
        if routes.count > 40 { routes.removeLast(routes.count - 40) }
    }

    func finish(_ plan: Plan) {
        active.remove(plan.id); attempts[plan.id] = nil; reserve(nil, for: plan.id)
        let owned = waiters.filter {
            if case .attempt(_, let owner, _) = $0.work { return owner.id == plan.id }
            return false
        }
        let ownedIDs = Set(owned.map(\.id))
        for i in waiters.indices.reversed() where ownedIDs.contains(waiters[i].id) { removeWaiter(at: i) }
        for waiter in owned { waiter.timeout?.cancel(); waiter.fail(GatewayFailure.interrupted) }
        for i in flights.indices where flights[i].requestID == plan.id && flights[i].phase.isActive {
            flights[i].phase = .cancelled; flights[i].updatedAt = Date()
        }
        drain(); publish()
    }
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
        var loads: [UUID: ProviderLoad] = [:]
        for id in Set(pool.members.map(\.providerID)).union(reservations.values.map(\.providerID)) {
            loads[id] = .init(limit: pool.concurrentLimit(for: id))
        }
        for reservation in reservations.values { loads[reservation.providerID]?.active += 1 }
        var queuedBytes = 0
        let queue = waiters.map { waiter -> QueueEntry in
            loads[waiter.providerID]?.queued += 1
            queuedBytes += waiter.requestBytes
            let requestID: UUID
            let attempt: Int
            switch waiter.work {
            case .request: requestID = waiter.id; attempt = 0
            case .attempt(_, let plan, _): requestID = plan.id; attempt = attempts[plan.id] ?? 0
            }
            return .init(id: requestID, providerID: waiter.providerID, routing: waiter.routing,
                         enqueuedAt: waiter.enqueuedAt, deadline: waiter.deadline, attempt: attempt)
        }
        return .init(health: displayed, active: reservations.count, requests: requestCount, queued: waiters.count, queuedBytes: queuedBytes,
                     providers: loads, routes: routes, flights: flights, queue: queue)
    }
    func resetHealth() { health.removeAll(); providerCooldown.removeAll(); drain(); publish() }

    /// Backpressure is bounded: a slow/hidden UI can retain only the newest
    /// snapshot. Finished flights remain in it, so sub-second requests survive.
    func updates() -> AsyncStream<Snapshot> {
        let id = UUID()
        let pair = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation
        pair.continuation.yield(snapshot())
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) {
        observers[id] = nil
        if observers.isEmpty { outputPublication?.cancel(); outputPublication = nil }
    }
    private func publish(outputOnly: Bool = false) {
        guard !observers.isEmpty else { return }
        if outputOnly {
            guard outputPublication == nil else { return }
            outputPublication = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                await self?.flushOutput()
            }
            return
        }
        outputPublication?.cancel(); outputPublication = nil
        let value = snapshot()
        for observer in observers.values { observer.yield(value) }
    }
    private func flushOutput() {
        guard !Task.isCancelled else { return }
        publish()
    }

    func advertisedModels() -> [String] {
        guard pool.enabled else { return [] }
        return ["auto", "claudebar/auto"]
    }

    func advertisedCapabilities() -> (input: [String], output: [String], features: [String]) {
        guard pool.enabled else { return ([], [], []) }
        let catalogFresh = Date().timeIntervalSince(pool.discoveredAt ?? .distantPast) < 48 * 3600
        let members = pool.members.filter { member in
            guard member.enabled, !member.difficulties.isEmpty,
                  let endpoint = endpoints[member.providerID], !endpoint.apiKey.isEmpty else { return false }
            return !FreeModelPool.isOpenRouter(endpoint.baseURL)
                || catalogFresh && catalogByID[member.model] != nil
        }
        var input = Set<String>(), output = Set<String>(), features = Set<String>()
        for member in members {
            if member.supportsChat { input.insert("text"); output.insert("text") }
            let media = member.mediaCapabilities ?? []
            if member.supportsChat {
                if member.supportsImages { input.insert("image") }
                if media.contains(.audioInput) { input.insert("audio") }
                if media.contains(.videoInput) { input.insert("video") }
                if media.contains(.fileInput) { input.insert("file") }
                if media.contains(.audioOutput) { output.insert("audio") }
                if media.contains(.imageOutput) { output.insert("image") }
            }
            for capability in [GatewayMediaCapability.imageGeneration, .speechSynthesis, .embeddings, .rerank]
                where media.contains(capability) { features.insert(capability.rawValue) }
        }
        return (input.sorted(), output.sorted(), features.sorted())
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
            let hasFiles = (body["messages"] as? [[String: Any]] ?? []).contains {
                ($0["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "file" }
            }
            if hasFiles { body["plugins"] = [["id": "file-parser", "pdf": ["engine": "native"]]] }
        }
        return body
    }
}

/// Refuse redirects so a provider cannot transfer a credential to another host.
final class GatewayNetwork: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct ProbeFailure: LocalizedError {
        var status: Int
        var errorDescription: String? {
            switch status {
            case 401, 403: return "HTTP \(status)：鉴权失败，请检查供应商 Key 或模型权限。"
            case 402: return "HTTP 402：免费额度不足，请检查账户额度。"
            case 404, 410: return "HTTP \(status)：找不到模型或兼容接口，请核对模型 ID 与 Base URL。"
            case 429: return "HTTP 429：供应商限流，稍后重试。"
            case 502: return "未收到有效模型输出，请检查接口是否支持 Chat Completions。"
            default: return "HTTP \(status)：供应商未完成测试，请稍后重试。"
            }
        }
    }
    static let shared = GatewayNetwork()
    private(set) var session: URLSession!
    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 1800
        config.httpMaximumConnectionsPerHost = 64
        config.httpCookieStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// Explicit user action; one pinned candidate, zero-price constraints and
    /// the same admission/health telemetry as normal traffic. No prompt/output
    /// or upstream error body is retained by the UI.
    func probe(_ candidate: FreeModelGateway.Candidate, url: URL,
               plan: FreeModelGateway.Plan, gateway: FreeModelGateway) async throws -> TimeInterval {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(candidate.endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: FreeModelGateway.outbound(
            ["messages": [["role": "user", "content": "Reply with OK."]], "max_tokens": 128],
            candidate: candidate, stream: false))
        let started = Date()
        var status = 0
        var latency: TimeInterval = 0
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(max(0.01, 20 - Date().timeIntervalSince(started)))) }
                catch { return }
                bytes.task.cancel()
            }
            defer { deadline.cancel() }
            latency = Date().timeIntervalSince(started)
            await gateway.receivedHeaders(candidate, plan: plan)
            guard let http = response as? HTTPURLResponse else { throw ProbeFailure(status: 502) }
            status = http.statusCode
            guard (200..<300).contains(status) else { throw ProbeFailure(status: status) }
            let data: Data = try await withTaskCancellationHandler {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 64 * 1024 else { throw ProbeFailure(status: 502) }
                    data.append(byte)
                }
                return data
            } onCancel: { bytes.task.cancel() }
            guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = body["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProbeFailure(status: 502)
            }
            try Task.checkCancellation()
            guard await gateway.isCurrent(plan) else { throw GatewayFailure.interrupted }
            await gateway.receivedOutput(candidate, plan: plan)
            bytes.task.cancel()
            await gateway.report(candidate, plan: plan, status: status, latency: latency)
            return latency
        } catch {
            let cancelled = Task.isCancelled
            let failureStatus = (error as? ProbeFailure)?.status ??
                ((error as? URLError)?.code == .timedOut || Date().timeIntervalSince(started) >= 20 ? 504 : 502)
            await gateway.report(candidate, plan: plan, status: cancelled || error as? GatewayFailure == .interrupted ? 0 : failureStatus,
                                 latency: latency > 0 ? latency : Date().timeIntervalSince(started))
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    func catalog(apiKey: String) async throws -> [FreeModelPool.CatalogModel] {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            bytes.task.cancel()
        }
        defer { deadline.cancel() }
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
