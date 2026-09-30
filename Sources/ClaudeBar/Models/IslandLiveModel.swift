import Foundation
import Combine
import SwiftUI

/// What the island's alert strip is showing.
///
/// A session finishing, a session parked on the user, and a quota window
/// rolling over are all "something you were waiting for just became true", so
/// they share one strip, one timer and one dismissal path. They carry different
/// payloads, hence a sum type rather than a widened session struct.
enum IslandAlert: Equatable, Identifiable {
    case finished(IslandSession)
    /// The turn is parked on the user: a permission prompt or an
    /// `AskUserQuestion` dialog is on screen. This is the state that used to be
    /// indistinguishable from 运行中 — nothing is running, and the user is the
    /// one being waited on, so it is the alert that matters most.
    case needsInput(IslandSession)
    case quotaReset(CodexQuotaWindow)

    /// Identity decides when the strip is replaced mid-animation: a newer
    /// alert of either kind takes over the one on screen.
    var id: String {
        switch self {
        case .finished(let session): return "finished:\(session.id)"
        case .needsInput(let session): return "needsInput:\(session.id)"
        case .quotaReset(let window): return "quota:\(window.label)"
        }
    }

    var agent: IslandAgent {
        switch self {
        case .finished(let session): return session.agent
        case .needsInput(let session): return session.agent
        case .quotaReset: return .codex
        }
    }
}

/// The three agent families ClaudeBar watches.
enum IslandAgent: String, Equatable, CaseIterable {
    case claude, codex, cursor

    /// The island's own instrument vocabulary for this family, so a session
    /// module on a glance card uses the same drawing family as the rest of the
    /// app instead of a one-off SF Symbol.
    var markKind: InstrumentGlyph.Kind {
        switch self {
        case .claude: return .sessions
        case .codex: return .config
        case .cursor: return .overview
        }
    }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
}

/// One live agent session, flattened to what the island draws.
struct IslandSession: Identifiable, Equatable {
    let id: String
    let agent: IslandAgent
    let project: String
    /// Current tool / step while busy ("Bash", "Read · Foo.swift"); empty idle.
    let activity: String
    let model: String
    let isBusy: Bool
    /// The turn is parked on the user, waiting on a permission prompt or an
    /// `AskUserQuestion` dialog. Not busy and not idle: nothing is running, and
    /// the next move is the user's. Carried alongside `isBusy` rather than
    /// folded into it because the two are mutually exclusive states of the same
    /// session — one has work in flight, the other has *none*.
    var isWaiting = false
    /// One sentence for what the user is being asked for, e.g.
    /// "等待你确认 · Bash". See `SessionInfo.waitingReason`.
    var waitingReason = ""
    /// Context-window fill, 0...1; 0 when the limit is unknown.
    let contextRatio: Double
    let updatedAt: Date
    let cwd: String
    let sessionId: String
    /// Unique proof that the most recent turn delivered a final answer; also
    /// the turn *key* the completion detector de-duplicates on. Claude sessions
    /// hand in `turnCount|uuid` (see `ProviderStore.detectIdleTransitions`),
    /// Codex its `task_complete` turn id, Cursor its `turn-<offset>`.
    var completionID: String? = nil
    /// The live process to reveal on click (Claude pid / Codex holder).
    var pid: Int? = nil
    /// A Codex thread loaded in Codex Desktop.
    var inDesktop = false
}

/// One local day of tokens for the usage scrubber.
struct IslandDay: Equatable, Identifiable {
    let date: Date
    let tokens: Int
    var cost = ModelPricing.Estimate()
    var id: Date { date }
}

/// Usage glance: today / month with pace, source split, 30-day series.
struct IslandUsage: Equatable {
    var today = 0
    var todayCalls = 0
    var todayCost = ModelPricing.Estimate()
    var yesterday = 0
    var month = 0
    var lastMonthSameSpan = 0
    /// Month-to-date tokens, in `UsageSource.allCases` order.
    var monthBySource: [Int] = Array(repeating: 0, count: UsageSource.allCases.count)
    /// Oldest first; the last element is today.
    var days: [IslandDay] = []

    /// `current / previous`, nil when there is nothing to compare against.
    static func pace(_ current: Int, _ previous: Int) -> Double? {
        previous > 0 ? Double(current) / Double(previous) : nil
    }
}

/// Feeds the notch island from the stores the rest of the app already keeps.
///
/// Everything is reduced to small `Equatable` snapshots and de-duplicated
/// before it is published, so a `ProviderStore` poll that changes nothing the
/// island shows (heartbeats, subagent trees, other windows' figures) never
/// re-renders it.
@MainActor
final class IslandLiveModel: ObservableObject {
    @Published private(set) var sessions: [IslandSession] = []
    @Published private(set) var sessionCosts: [String: ModelPricing.Estimate] = [:]
    @Published private(set) var usage = IslandUsage()
    @Published private(set) var claudeRoute = ""
    @Published private(set) var codexRoute = ""
    @Published private(set) var vpnRunning = false
    /// A session whose turn just delivered an answer. Fires once per turn —
    /// see `ConfirmedCompletionDetector`. The publisher name is historical: it
    /// is "delivered", not "went idle", and the distinction is the whole point
    /// of the rule.
    let finished = PassthroughSubject<IslandSession, Never>()

    /// A session that just parked on the user — a permission prompt or an
    /// `AskUserQuestion` dialog came up. Edge-detected on entering the waiting
    /// state, so a session that sits at a prompt for an hour announces itself
    /// once, not once per poll. See `WaitingStateDetector`.
    let needsInput = PassthroughSubject<IslandSession, Never>()

    /// A Codex quota window that just rolled over. Fires once per rollover —
    /// see `QuotaResetDetector`, which is what keeps a 4.2 s glance from
    /// re-announcing the same reset.
    let quotaReset = PassthroughSubject<CodexQuotaWindow, Never>()

    /// How recent a session's own last write must be for the alert strip to
    /// show its completed turn — the same intent as `ProviderStore`'s banner
    /// rule, kept beside the strip that reads it.
    private static let alertFreshness: TimeInterval = 60

    var busySessions: [IslandSession] { sessions.filter(\.isBusy) }

    /// Sessions parked on the user (a permission prompt or a question dialog).
    var waitingSessions: [IslandSession] { sessions.filter(\.isWaiting) }

    private weak var providerStore: ProviderStore?
    private var cancellables: Set<AnyCancellable> = []
    private var completionDetector = ConfirmedCompletionDetector<String>()
    private var waitingDetector = WaitingStateDetector<String>()
    private var quotaResetDetector = QuotaResetDetector()
    private var usageRefreshPending = false
    private var usageRefreshQueued = false
    private var sessionCostGeneration = 0
    private var lastRescan: Date = .distantPast
    private var periodicTimer: Timer?

    init(providerStore: ProviderStore, codexStore: CodexProviderStore) {
        self.providerStore = providerStore

        Publishers.CombineLatest3(providerStore.$sessions, providerStore.$cursorSessions, providerStore.$externalSessions)
            .map { claude, cursor, external in Self.flatten(claude: claude, cursor: cursor, external: external) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                MainActor.assumeIsolated { self?.apply(sessions) }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(providerStore.$providers, providerStore.$activeProviderID, providerStore.$currentEnv)
            .receive(on: DispatchQueue.main)
            .map { [weak providerStore] _, _, _ in
                guard let provider = providerStore?.activeProvider else { return "" }
                return Self.route(provider.name, provider.activeModel?.name)
            }
            .removeDuplicates()
            .sink { [weak self] in self?.claudeRoute = $0 }
            .store(in: &cancellables)

        Publishers.CombineLatest(codexStore.$providers, codexStore.$activeProviderID)
            .receive(on: DispatchQueue.main)
            .map { [weak codexStore] _, _ in
                guard let provider = codexStore?.activeProvider else { return "" }
                return Self.route(provider.name, provider.activeModel?.name)
            }
            .removeDuplicates()
            .sink { [weak self] in self?.codexRoute = $0 }
            .store(in: &cancellables)

        codexStore.$quotaWindows
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windows in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Edge-detect before publishing, so a poll that merely
                    // re-reports a window that stayed low cannot re-announce it.
                    for window in self.quotaResetDetector.record(windows) {
                        self.quotaReset.send(window)
                    }
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(VpnManager.shared.$state, AppPreferences.shared.$vpnEnabled)
            .map { state, enabled in enabled && state == .running }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.vpnRunning = $0 }
            .store(in: &cancellables)

        // Republished after every index pass — exactly when the rollup
        // under the usage queries has changed.
        providerStore.$usageStats
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadUsage()
                self?.reloadSessionCosts()
            }
            .store(in: &cancellables)

        reloadUsage()
    }

    // MARK: - Sessions

    private func apply(_ fresh: [IslandSession]) {
        let oldIDs = sessions.map(\.id)
        // The turn key is the snapshot's own identity for "a new answer landed"
        // (`turnCount|uuid` / `turnId` / `turn-<offset>`), so an answer that was
        // already announced never re-fires, and one that lands while the island
        // is watching still does. The island's alert still needs freshness (an
        // answer delivered while the island was off screen must not pop out of
        // the notch when it comes back); the window matches the banner's.
        let now = Date()
        let completed = completionDetector.record(fresh.map {
            (id: $0.id, isBusy: $0.isBusy, turnKey: $0.completionID,
             fresh: now.timeIntervalSince($0.updatedAt) <= Self.alertFreshness)
        })
        for session in fresh where completed.contains(session.id) {
            finished.send(session)
        }
        // Entering the waiting state is an edge of its own: a permission prompt
        // arriving is exactly as much "your move" as an answer arriving, and
        // neither the busy nor the idle edge covers it (the pending tool keeps
        // `isBusy` true through the whole wait). A session already parked when
        // the island first sees it only seeds the detector — the user is
        // looking at the prompt already.
        let parked = waitingDetector.record(fresh.map {
            (id: $0.id, isWaiting: $0.isWaiting)
        })
        for session in fresh where parked.contains(session.id) {
            needsInput.send(session)
        }
        sessions = fresh
        if fresh.map(\.id) != oldIDs { reloadSessionCosts() }
    }

    private func reloadSessionCosts() {
        let requests: [(id: String, source: UsageSource, sessionId: String)] = sessions.compactMap { session in
            let source: UsageSource
            switch session.agent {
            case .claude: source = .claude
            case .codex: source = .codex
            case .cursor: return nil
            }
            return (session.id, source, session.sessionId)
        }
        sessionCostGeneration += 1
        let generation = sessionCostGeneration
        Task { [weak self] in
            let costs = await Task.detached(priority: .utility) {
                var result: [String: ModelPricing.Estimate] = [:]
                for request in requests {
                    let usage = UsageIndex.fetchSession(source: request.source, sessionId: request.sessionId)
                    if !usage.isEmpty { result[request.id] = ModelPricing.estimate(usage) }
                }
                return result
            }.value
            guard let self, generation == self.sessionCostGeneration else { return }
            if costs != self.sessionCosts { self.sessionCosts = costs }
        }
    }

    nonisolated private static func flatten(claude: [SessionInfo], cursor: [CursorSessionInfo],
                                            external: [ExternalSessionInfo]) -> [IslandSession] {
        var out: [IslandSession] = []
        for s in claude where s.isAlive {
            out.append(IslandSession(
                id: "cc:\(s.pid)", agent: .claude, project: s.projectFolder,
                activity: s.currentActivity, model: s.model,
                isBusy: s.isBusy,
                isWaiting: s.isWaiting, waitingReason: s.waitingReason,
                contextRatio: s.contextRatio,
                updatedAt: Date(timeIntervalSince1970: s.updatedAt / 1000),
                cwd: s.cwd, sessionId: s.sessionId, completionID: s.completionID, pid: s.pid))
        }
        for s in cursor where s.isAlive {
            out.append(IslandSession(
                id: "cursor:\(s.composerId)", agent: .cursor, project: s.projectFolder,
                activity: s.currentActivity, model: "",
                isBusy: s.isBusy,
                isWaiting: s.isWaiting,
                waitingReason: s.isWaiting ? "等待你确认计划" : "",
                contextRatio: s.contextRatio,
                updatedAt: Date(timeIntervalSince1970: s.lastUpdatedAt / 1000),
                cwd: s.cwd, sessionId: s.composerId, completionID: s.completionID))
        }
        for s in external where s.isAlive && !s.isSubagent {
            out.append(IslandSession(
                id: "codex:\(s.sessionId)", agent: .codex, project: s.projectFolder,
                activity: "", model: s.model,
                isBusy: s.isActive,
                // Codex journals no park, so this is `false` today; carried
                // through anyway so the island reads one field for every agent
                // and a future signal only has to teach `ExternalSessionInfo`.
                // See its `isWaiting` for the evidence behind the empty case.
                isWaiting: s.isWaiting,
                waitingReason: s.isWaiting ? "等待你确认" : "",
                contextRatio: s.contextRatio,
                updatedAt: Date(timeIntervalSince1970: s.updatedAt / 1000),
                cwd: s.cwd, sessionId: s.sessionId, completionID: s.completionID,
                pid: s.holderPID, inDesktop: s.inDesktop))
        }
        return out.sorted { lhs, rhs in
            // Parked sessions float above merely-busy ones: a session that is
            // waiting on the user is the one that needs an answer, and it would
            // otherwise sink below every session that is happily working away.
            if lhs.isWaiting != rhs.isWaiting { return lhs.isWaiting }
            if lhs.isBusy != rhs.isBusy { return lhs.isBusy }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    nonisolated private static func route(_ provider: String, _ model: String?) -> String {
        guard let model, !model.isEmpty else { return provider }
        return provider + " · " + model
    }

    // MARK: - Actions

    /// Resume / open a session where it lives. Honors the 自动化 switch
    /// through `TerminalLauncher`.
    func open(_ session: IslandSession) {
        switch session.agent {
        case .claude:
            TerminalLauncher.resumeClaudeSession(cwd: session.cwd, sessionId: session.sessionId, pid: session.pid)
        case .codex:
            TerminalLauncher.resumeCodexSession(cwd: session.cwd, sessionId: session.sessionId,
                                                pid: session.pid, inDesktop: session.inDesktop)
        case .cursor: TerminalLauncher.openInCursor(cwd: session.cwd)
        }
    }

    // MARK: - Usage

    func reloadUsage() {
        // A generation check discards stale results but still lets every
        // request run six database queries. Keep at most one pass in flight
        // and one trailing refresh with the latest index contents.
        guard !usageRefreshPending else {
            usageRefreshQueued = true
            return
        }
        usageRefreshPending = true
        Task { [weak self] in
            repeat {
                let fresh = await Task.detached(priority: .utility) {
                    IslandLiveModel.computeUsage(now: Date())
                }.value
                guard let self else { return }
                if self.usageRefreshQueued {
                    self.usageRefreshQueued = false
                    continue
                }
                if fresh != self.usage { self.usage = fresh }
                self.usageRefreshPending = false
                return
            } while true
        }
    }

    /// Ask `ProviderStore` to bring the index up to date; its republished
    /// `usageStats` then triggers `reloadUsage()`. The island never runs
    /// `UsageIndex.updateIndex()` itself, so two scans cannot overlap.
    func requestFreshIndex(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRescan) > 60 else { return }
        lastRescan = Date()
        providerStore?.refreshUsage(rescan: true)
    }

    /// Keeps "today" honest across midnight while the wings show it.
    func setPeriodicRefresh(_ enabled: Bool) {
        periodicTimer?.invalidate()
        periodicTimer = nil
        guard enabled else { return }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadUsage() }
        }
    }

    nonisolated static func computeUsage(now: Date, calendar cal: Calendar = .current) -> IslandUsage {
        let todayStart = cal.startOfDay(for: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? todayStart
        let seriesStart = cal.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart

        let monthSpan = DateInterval(start: monthStart, end: todayEnd)
        let elapsedDays = cal.dateComponents([.day], from: monthStart, to: todayEnd).day ?? 1
        let lastMonthStart = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        let lastMonthEnd = min(cal.date(byAdding: .day, value: elapsedDays, to: lastMonthStart) ?? monthStart, monthStart)

        func total(_ bySource: [UsageSource: [ModelUsage]]) -> Int {
            bySource.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.totalTokens } }
        }

        var usage = IslandUsage()
        let today = UsageIndex.fetchBySource(in: DateInterval(start: todayStart, end: todayEnd))
        usage.today = total(today)
        usage.todayCost = ModelPricing.estimate(today.values.flatMap { $0 })
        usage.todayCalls = today.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.calls } }
        usage.yesterday = total(UsageIndex.fetchBySource(in: DateInterval(start: yesterdayStart, end: todayStart)))
        let month = UsageIndex.fetchBySource(in: monthSpan)
        usage.month = total(month)
        usage.monthBySource = UsageSource.allCases.map { source in
            (month[source] ?? []).reduce(0) { $0 + $1.totalTokens }
        }
        usage.lastMonthSameSpan = total(UsageIndex.fetchBySource(
            in: DateInterval(start: lastMonthStart, end: max(lastMonthEnd, lastMonthStart))))

        // Day keys are local `yyyy-MM-dd`, the same form `UsageIndex` stores.
        let byDay = UsageIndex.fetchDailyModels(in: DateInterval(start: seriesStart, end: todayEnd))
        usage.days = (0..<30).compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: offset, to: seriesStart) else { return nil }
            let c = cal.dateComponents([.year, .month, .day], from: date)
            let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            let models = byDay[key] ?? []
            // Priced at the rate in force on that day, not at today's: the
            // series is a month of history, and a mid-month price change must
            // leave the days before it exactly where they were.
            return IslandDay(date: date, tokens: models.reduce(0) { $0 + $1.totalTokens },
                             cost: ModelPricing.estimate(models, on: key))
        }
        return usage
    }
}
