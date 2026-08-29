import Foundation
import Combine

class ProviderStore: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var activeProviderID: UUID? = nil
    @Published var currentEnv: EnvConfig? = nil
    @Published var hasSettingsFile: Bool = false
    @Published var errorMessage: String? = nil
    @Published var balanceText: String? = nil
    @Published var balanceLoading: Bool = false
    @Published var collapsedProviderIDs: Set<UUID> = []
    @Published var usageStats: [ModelUsage] = []
    @Published var usageLoading: Bool = false
    @Published var usagePeriod: UsagePeriod = .month {
        didSet { if usagePeriod != oldValue { refreshUsage() } }
    }
    @Published var usageReferenceDate: Date = Date() {
        didSet { if usageReferenceDate != oldValue { refreshUsage() } }
    }

    // Live Claude Code sessions
    @Published var sessions: [SessionInfo] = []
    @Published var expandedSessionPIDs: Set<Int> = []
    /// Per-session busy heartbeat — the last `AppConfig.heartbeatLength`
    /// polls, oldest first. `true` = the session was busy at that sample.
    /// Published so cards can draw an EKG-style sparkline from polling we
    /// were doing anyway.
    @Published var heartbeats: [Int: [Bool]] = [:]
    static let heartbeatLength = AppConfig.heartbeatLength
    private var sessionTimer: Timer?
    /// Last serialized snapshot payload — `writeWidgetSnapshot()` skips the
    /// file writes + widget reload when the data is unchanged (see
    /// `WidgetSnapshotWriter.write`).
    private var lastSnapshotData: Data?

    // Idle-notification edge detection, one detector per session flavor.
    // Main-actor confined; see IdleTransitionDetector.
    @Published var anySessionBusy = false   // drives the menu-bar icon
    private var claudeIdleDetector = IdleTransitionDetector<Int>()
    private var cursorIdleDetector = IdleTransitionDetector<String>()

    // Live Cursor (IDE) sessions
    @Published var cursorSessions: [CursorSessionInfo] = []
    @Published var cursorExpanded: Set<String> = []

    // Live sessions from external agent tools (Codex / WorkBuddy / OpenClaw)
    @Published var externalSessions: [ExternalSessionInfo] = []
    private var externalIdleDetector = IdleTransitionDetector<String>()

    /// Initial state is populated by the AppDelegate once the status item and
    /// main window are wired up — calling `refresh()` here would run file I/O
    /// and spawn background tasks before the UI surfaces exist, and the
    /// delegate calls `refresh()` again anyway (which would duplicate that).
    init() {}

    deinit { sessionTimer?.invalidate() }

    // MARK: - Refresh

    func refresh() {
        hasSettingsFile = FileManager.default.fileExists(atPath: FilePaths.settingsFile.path)
        currentEnv = SettingsManager.readSettings()
        loadProviders()
        refreshBalance()
        refreshUsage()
        refreshSessions()
        startSessionPolling()
        writeWidgetSnapshot()
    }

    // MARK: - Sessions

    func refreshSessions() {
        // The scan reads session JSONs + transcript tails + subagent dirs —
        // pure file I/O. Run it off the main thread and only hop back to
        // publish the parsed results, so the poll never blocks the UI.
        let contextLimits = currentContextLimits
        Task.detached(priority: .utility) { [weak self] in
            // `let scanned` (not var) so the capture is an immutable
            // sendable value — no concurrent-mutation warning.
            let enriched = Self.enrich(SessionMonitor.fetchActive(), limits: contextLimits)
            let samples = Self.heartbeatSamples(from: enriched)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Skip the publish when nothing changed. Equatable payloads +
                // an unchanged-published-value check mean the 2.5s poll only
                // invalidates SwiftUI when a session actually moved — the
                // single biggest win for UI stutter, since an idle system
                // otherwise re-renders every observing view every poll.
                if self.sessions == enriched { return }
                self.sessions = enriched
                self.recordHeartbeats(samples)
                self.detectIdleTransitions(enriched)
                self.refreshCursorSessions()
                self.refreshExternalSessions()
            }
        }
    }

    /// pid → was-busy for this poll (alive sessions only).
    private static func heartbeatSamples(from sessions: [SessionInfo]) -> [Int: Bool] {
        var out: [Int: Bool] = [:]
        for s in sessions where s.isAlive {
            out[s.pid] = s.status == .busy || s.toolPending
        }
        return out
    }

    /// Append one sample per session to its ring buffer, dropping dead
    /// sessions' trails and pruning to `heartbeatLength`. Returns early when
    /// the map is unchanged, so idle sessions don't publish every poll.
    private func recordHeartbeats(_ samples: [Int: Bool]) {
        guard !samples.isEmpty else {
            if !heartbeats.isEmpty { heartbeats = [:] }
            return
        }
        var changed = false
        for (pid, busy) in samples {
            var trail = heartbeats[pid] ?? []
            trail.append(busy)
            if trail.count > Self.heartbeatLength { trail.removeFirst(trail.count - Self.heartbeatLength) }
            if trail != heartbeats[pid] { changed = true }
            heartbeats[pid] = trail
        }
        // Prune trails for sessions that have died.
        let live = Set(samples.keys)
        let pruned = heartbeats.filter { live.contains($0.key) }
        if pruned.count != heartbeats.count { changed = true }
        if changed { heartbeats = pruned }
    }

    /// Diff this poll's busy states against the last poll's. A session that
    /// was busy and is now idle-and-alive just finished its turn — notify.
    /// Edge bookkeeping lives in `IdleTransitionDetector`; dead sessions are
    /// pruned there, never notified.
    private func detectIdleTransitions(_ fresh: [SessionInfo]) {
        let alive = fresh.filter(\.isAlive)
        let busyIDs = Set(alive.filter { $0.status == .busy || $0.toolPending }.map(\.pid))
        let (newlyIdle, busyNow) = claudeIdleDetector.record(busyIDs: busyIDs)
        for pid in newlyIdle {
            if let session = alive.first(where: { $0.pid == pid }) {
                NotificationService.shared.notifyIdle(session: session)
            }
        }
        if anySessionBusy != busyNow { anySessionBusy = busyNow }
    }

    /// Cursor flavor of the same edge detection (see `detectIdleTransitions`).
    private func detectIdleTransitionsCursor(_ fresh: [CursorSessionInfo]) {
        let busyIDs = Set(fresh.filter { $0.status == .active || $0.toolPending }.map(\.composerId))
        let (newlyIdle, busyNow) = cursorIdleDetector.record(busyIDs: busyIDs)
        for id in newlyIdle {
            if let session = fresh.first(where: { $0.composerId == id }) {
                NotificationService.shared.notifyIdle(cursor: session)
            }
        }
        if anySessionBusy != busyNow { anySessionBusy = busyNow }
    }

    /// Enrich alive sessions with transcript context + subagents. Pure
    /// function so it can run wholly off-main.
    private static func enrich(_ sessions: [SessionInfo], limits: [String: Int]) -> [SessionInfo] {
        var result = sessions
        for i in result.indices where result[i].isAlive {
            let ctx = SessionMonitor.fetchContext(for: result[i])
            result[i].contextTokens = ctx.tokens
            result[i].model = ctx.model
            result[i].messageCount = ctx.count
            result[i].currentActivity = ctx.activity
            result[i].toolPending = ctx.toolPending
            // A pending tool call means the session is actively working even
            // if the session-json status hasn't flipped to "busy" yet.
            if ctx.toolPending { result[i].status = .busy }
            // Resolve the context limit from the matching provider's model config.
            result[i].contextLimit = limits[result[i].model.lowercased()] ?? 0
            // Live subagents + workflows spawned by this session.
            let subs = SessionMonitor.fetchSubagents(for: result[i])
            result[i].subagents = subs.direct
            result[i].workflows = subs.workflows
        }
        return result
    }

    /// Case-insensitive model name → configured context-token limit. Captured
    /// on the calling thread before the detached scan (providers is main-thread
    /// state); the lookup itself then runs off-main.
    private var currentContextLimits: [String: Int] {
        var limits: [String: Int] = [:]
        for provider in providers {
            for m in provider.models {
                if let n = Int(m.contextTokens), n > 0 {
                    limits[m.name.lowercased()] = n
                }
            }
        }
        return limits
    }

    // MARK: - Cursor Sessions

    /// Read Cursor composer sessions from its state.vscdb. Run off the main
    /// thread — the DB is large, and transcript-tail scans do file I/O.
    func refreshCursorSessions() {
        Task.detached(priority: .utility) {
            let result = CursorSessionMonitor.fetchActive()
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Same unchanged-publish skip as the Claude poll: Cursor
                // sessions are Equatable, so an unchanged scan never touches
                // the widget snapshot or SwiftUI.
                if self.cursorSessions == result { return }
                self.cursorSessions = result
                self.detectIdleTransitionsCursor(result)
                // Cursor session changes (new/ended/busy flip) should reach the
                // widget on the same poll — refreshCursorSessions runs on the 2.5s
                // timer but does not otherwise call writeWidgetSnapshot.
                self.writeWidgetSnapshot()
            }
        }
    }

    /// Scan external agent tools (Codex / WorkBuddy / OpenClaw). Same
    /// off-main scan + unchanged-publish skip as the other two sources.
    func refreshExternalSessions() {
        Task.detached(priority: .utility) {
            let result = ExternalSessionMonitor.fetchActive()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.externalSessions == result { return }
                self.externalSessions = result
                // Busy-edge notifications reuse the same detector machinery:
                // a session that leaves the busy window just finished a turn.
                let busyIDs = Set(result.filter(\.isActive).map(\.id))
                let (newlyIdle, _) = self.externalIdleDetector.record(busyIDs: busyIDs)
                for id in newlyIdle {
                    if let session = result.first(where: { $0.id == id }) {
                        NotificationService.shared.notifyIdle(external: session)
                    }
                }
            }
        }
    }

    private func startSessionPolling() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.sessionPollInterval, repeats: true) { [weak self] _ in
            self?.refreshSessions()
        }
    }
    // Note: the timer only *triggers* on the main run loop; the actual scan
    // runs inside a detached task (see refreshSessions) — the main thread
    // merely receives parsed results.

    // MARK: - Load / Save

    func loadProviders() {
        guard FileManager.default.fileExists(atPath: FilePaths.presetsFile.path),
              let data = try? Data(contentsOf: FilePaths.presetsFile),
              let file = try? JSONDecoder().decode(ProvidersFile.self, from: data) else {
            providers = []; activeProviderID = nil; return
        }
        providers = file.providers
        activeProviderID = file.activeProviderID

        // Detect current provider from settings.json. When the settings file
        // matches a configured provider, adopt it as active and persist the
        // reconciled state (a single save, after all mutations below).
        guard let env = currentEnv else { return }
        for provider in providers {
            let a = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let b = env.ANTHROPIC_BASE_URL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard a == b else { continue }
            activeProviderID = provider.id
            // Match active model (case-insensitive)
            if let idx = providers.firstIndex(where: { $0.id == provider.id }),
               let model = provider.models.first(where: {
                   $0.name.caseInsensitiveCompare(env.ANTHROPIC_MODEL) == .orderedSame
               }) {
                providers[idx].activeModelID = model.id
            }
            saveProviders()
            break
        }
    }

    func saveProviders() {
        let file = ProvidersFile(providers: providers, activeProviderID: activeProviderID)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: FilePaths.claudeDir, withIntermediateDirectories: true)
        try? data.write(to: FilePaths.presetsFile, options: .atomic)
    }

    // MARK: - Activate

    func activateModel(providerID: UUID, modelID: UUID) {
        guard let provider = providers.first(where: { $0.id == providerID }),
              let model = provider.models.first(where: { $0.id == modelID }) else { return }

        let env = buildEnv(from: provider, model: model)
        do {
            try SettingsManager.writeSettings(env: env)
        } catch {
            // The settings file may now hold a partially-updated env (the
            // write itself is atomic, but sibling fields written by an
            // earlier activation could differ). Re-read from disk so the
            // in-memory state always mirrors reality, and leave the old
            // provider/model active since nothing was switched.
            currentEnv = SettingsManager.readSettings()
            errorMessage = "Failed to write settings: \(error.localizedDescription)"
            return
        }
        // Settings written successfully — now commit the UI state. Mutations
        // are ordered so a hypothetical crash mid-way leaves at most a stale
        // activeModelID on disk, never a settings file pointing at a model
        // the store doesn't know about.
        activeProviderID = providerID
        currentEnv = env

        if let idx = providers.firstIndex(where: { $0.id == providerID }) {
            providers[idx].activeModelID = modelID
        }
        saveProviders()
        refreshBalance()
    }

    /// Maps a provider/model pair onto the `settings.json` env block. All
    /// `ANTHROPIC_DEFAULT_*_MODEL` aliases carry the chosen model name so
    /// subagent/background traffic is routed to the same endpoint.
    private func buildEnv(from provider: Provider, model: ModelConfig) -> EnvConfig {
        EnvConfig(
            ANTHROPIC_AUTH_TOKEN: provider.authToken,
            ANTHROPIC_BASE_URL: provider.baseURL,
            ANTHROPIC_MODEL: model.name,
            CLAUDE_CODE_MAX_CONTEXT_TOKENS: model.contextTokens,
            DISABLE_COMPACT: model.disableCompact ? "1" : "",
            GITHUB_PERSONAL_ACCESS_TOKEN: "",
            CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: model.disableExperimentalBetas ? "1" : "",
            ANTHROPIC_DEFAULT_OPUS_MODEL: model.name,
            ANTHROPIC_DEFAULT_OPUS_MODEL_NAME: model.name,
            ANTHROPIC_DEFAULT_SONNET_MODEL: model.name,
            ANTHROPIC_DEFAULT_SONNET_MODEL_NAME: model.name,
            ANTHROPIC_DEFAULT_HAIKU_MODEL: model.name,
            ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME: model.name,
            ANTHROPIC_DEFAULT_FABLE_MODEL: model.name,
            ANTHROPIC_DEFAULT_FABLE_MODEL_NAME: model.name,
            CLAUDE_CODE_AUTO_COMPACT_WINDOW: model.autoCompactWindow
        )
    }

    // MARK: - CRUD

    func saveCurrentAsProvider(name: String) {
        guard let env = currentEnv else { return }
        let model = ModelConfig(
            name: env.ANTHROPIC_MODEL.isEmpty ? "default" : env.ANTHROPIC_MODEL,
            contextTokens: env.CLAUDE_CODE_MAX_CONTEXT_TOKENS,
            disableCompact: env.DISABLE_COMPACT == "1",
            disableExperimentalBetas: env.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS == "1",
            autoCompactWindow: env.CLAUDE_CODE_AUTO_COMPACT_WINDOW
        )
        let provider = Provider(
            name: name,
            authToken: env.ANTHROPIC_AUTH_TOKEN,
            baseURL: env.ANTHROPIC_BASE_URL,
            models: [model],
            activeModelID: model.id
        )
        providers.append(provider)
        if activeProviderID == nil { activeProviderID = provider.id }
        saveProviders()
    }

    func deleteProvider(_ provider: Provider) {
        providers.removeAll { $0.id == provider.id }
        if activeProviderID == provider.id { activeProviderID = providers.first?.id }
        if collapsedProviderIDs.contains(provider.id) { collapsedProviderIDs.remove(provider.id) }
        saveProviders()
    }

    func duplicateProvider(_ provider: Provider) {
        let copy = Provider(
            name: "\(provider.name) Copy",
            authToken: provider.authToken,
            baseURL: provider.baseURL,
            models: provider.models,
            activeModelID: provider.activeModelID
        )
        providers.append(copy)
        saveProviders()
    }

    func updateProvider(_ provider: Provider) {
        guard let idx = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[idx] = provider
        saveProviders()
    }

    // MARK: - Balance

    func refreshBalance() {
        guard let env = currentEnv else { balanceText = nil; return }
        balanceLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { balanceLoading = false }
            if let result = await BalanceFetcher.fetch(authToken: env.ANTHROPIC_AUTH_TOKEN, baseURL: env.ANTHROPIC_BASE_URL) {
                balanceText = "\(result.balance) \(result.currency)"
            } else {
                balanceText = nil
            }
        }
    }

    // MARK: - Usage Stats

    /// Coalesces rapid `refreshUsage()` calls (period flips, date arrows, the
    /// manual refresh button) into one background scan — a scan can take a
    /// moment on a large transcript tree, so back-to-back requests collapse
    /// instead of queueing duplicate work.
    private var usageRefreshPending = false
    private var usageRefreshQueued = false

    func refreshUsage() {
        // Runs entirely on the main actor: the state below is only touched
        // here, so plain boolean fields need no lock. The heavy scan happens
        // inside `Task.detached`, and this call returns immediately.
        if usageRefreshPending {
            usageRefreshQueued = true
            return
        }
        usageRefreshPending = true
        usageLoading = true

        Task.detached(priority: .utility) { [weak self] in
            while true {
                guard let self else { return }
                // Capture the caller's requested period/date on the main actor.
                let interval = await MainActor.run {
                    UsageStats.interval(for: self.usagePeriod, reference: self.usageReferenceDate)
                }

                var result = UsageStats.fetch(in: interval)
                // Cursor's token history is a stable full-scan total (Cursor
                // stopped writing tokens after ~2026-03), so it is appended to
                // every period rather than interval-filtered. The fetch is
                // TTL-cached inside CursorUsageStats, so repeated period/date
                // switches don't rescan the multi-GB Cursor DB.
                if let cursor = CursorUsageStats.fetch() {
                    result.append(cursor)
                }
                // External agent tools (Codex / WorkBuddy / OpenClaw) parse
                // the same way — JSONL transcripts, per-record timestamps —
                // so their usage folds into the same per-model aggregate and
                // the interval filter applies identically.
                let external = ExternalUsageStats.fetch(in: interval)
                if !external.isEmpty {
                    result.append(contentsOf: external)
                }
                result = ModelUsage.merged(result).sorted { $0.totalTokens > $1.totalTokens }
                let final = result

                // If another refresh was requested while scanning, loop and
                // re-run with the latest period; otherwise publish and finish.
                let shouldContinue: Bool = await MainActor.run {
                    if self.usageRefreshQueued {
                        self.usageRefreshQueued = false
                        return true
                    }
                    self.usageRefreshPending = false
                    return false
                }
                if shouldContinue { continue }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.usageStats = final
                    self.usageLoading = false
                    self.writeWidgetSnapshot()
                }
                return
            }
        }
    }

    // MARK: - Widget Snapshot

    func writeWidgetSnapshot() {
        lastSnapshotData = WidgetSnapshotWriter.write(buildSnapshot(), deduplicatingAgainst: lastSnapshotData)
    }

    private func buildSnapshot() -> WidgetSnapshot {
        let alive = sessions.filter(\.isAlive)
        return WidgetSnapshot(
            todayTotalTokens: usageStats.reduce(0) { $0 + $1.totalTokens },
            modelBreakdown: usageStats.prefix(5).map {
                WidgetSnapshot.ModelTokenUsage(model: $0.model, totalTokens: $0.totalTokens)
            },
            activeProviderName: providers.first(where: { $0.id == activeProviderID })?.name ?? "",
            activeModelName: currentEnv?.ANTHROPIC_MODEL ?? "",
            balanceText: balanceText,
            totalSessionCount: alive.count,
            busySessionCount: alive.filter { $0.status == .busy }.count,
            sessions: alive.prefix(5).map { s in
                WidgetSnapshot.SessionSummary(
                    pid: s.pid,
                    status: s.status.label,
                    model: s.model,
                    contextTokens: s.contextTokens,
                    contextLimit: s.contextLimit,
                    contextRatio: s.contextRatio,
                    projectFolder: s.projectFolder,
                    currentActivity: s.currentActivity
                )
            },
            cursorSessions: cursorSessions.prefix(5).map { s in
                WidgetSnapshot.CursorSessionSummary(
                    composerId: s.composerId,
                    status: s.status.label,
                    contextRatio: s.contextRatio,
                    contextPercent: s.contextPercent,
                    projectFolder: s.projectFolder,
                    currentActivity: s.currentActivity,
                    relativeUpdated: s.relativeUpdated
                )
            },
            updatedAt: Date()
        )
    }
}
