import Foundation
import Combine

class ProviderStore: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var activeProviderID: UUID? = nil
    @Published var currentEnv: EnvConfig? = nil
    @Published var hasSettingsFile: Bool = false
    @Published var errorMessage: String? = nil
    @Published var importSummary: String? = nil
    @Published var balanceText: String? = nil
    @Published var balanceLoading: Bool = false
    @Published var collapsedProviderIDs: Set<UUID> = []
    @Published var usageStats: [ModelUsage] = []
    @Published var usageDays: [DayUsage] = []
    /// Cursor bubbles have no timestamps (upstream stopped writing after ~2026-03).
    /// Shown separately so they never inflate the selected day/month total.
    @Published var cursorLifetimeUsage: ModelUsage?
    @Published var usageLoading: Bool = false
    @Published var usagePeriod: UsagePeriod = .month {
        didSet { if usagePeriod != oldValue { refreshUsage(rescan: false) } }
    }
    @Published var usageReferenceDate: Date = Date() {
        didSet { if usageReferenceDate != oldValue { refreshUsage(rescan: false) } }
    }

    /// Codex projection of this list. Add/edit/delete/activate write both
    /// `settings.json` and `~/.codex/config.toml`. Weak: AppDelegate owns both.
    /// Isolated at the call sites (`@MainActor` CRUD); the stored reference is
    /// only ever used on the main thread.
    nonisolated(unsafe) weak var peer: CodexProviderStore?

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

    // Live Codex sessions
    @Published var externalSessions: [ExternalSessionInfo] = []
    private var externalIdleDetector = IdleTransitionDetector<String>()

    /// Initial state is populated by the AppDelegate once the status item and
    /// main window are wired up — calling `refresh()` here would run file I/O
    /// and spawn background tasks before the UI surfaces exist, and the
    /// delegate calls `refresh()` again anyway (which would duplicate that).
    init() {}

    deinit { sessionTimer?.invalidate() }

    // MARK: - Refresh

    @MainActor
    func refresh() {
        hasSettingsFile = FileManager.default.fileExists(atPath: FilePaths.settingsFile.path)
        currentEnv = SettingsManager.readSettings()
        loadProviders()
        unifyWithPeer()
        refreshBalance()
        refreshUsage(rescan: true)
        refreshSessions()
        startSessionPolling()
        ProcessSampler.shared.start()
        startUsageWatcher()
        writeWidgetSnapshot()
    }

    // MARK: - Sessions

    func refreshSessions() {
        // The scan reads session JSONs + transcript tails + subagent dirs —
        // pure file I/O. Run it off the main thread and only hop back to
        // publish the parsed results, so the poll never blocks the UI.
        let contextLimits = currentContextLimits
        let previous = sessions
        Task.detached(priority: .utility) {
            let enriched = Self.enrich(SessionMonitor.fetchActive(), previous: previous, limits: contextLimits)
            let samples = Self.heartbeatSamples(from: enriched)
            let pids = enriched.filter(\.isAlive).map(\.pid)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.recordHeartbeats(samples)
                if self.sessions != enriched {
                    self.sessions = enriched
                    self.detectIdleTransitions(enriched)
                }
                ProcessSampler.shared.setAgentPIDs(pids)
                // Cursor / Codex must poll even when Claude is idle.
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
        let (newlyIdle, _) = claudeIdleDetector.record(busyIDs: busyIDs)
        for pid in newlyIdle {
            if let session = alive.first(where: { $0.pid == pid }) {
                NotificationService.shared.notifyIdle(session: session)
            }
        }
        refreshAnyBusy()
    }

    /// Cursor flavor of the same edge detection (see `detectIdleTransitions`).
    private func detectIdleTransitionsCursor(_ fresh: [CursorSessionInfo]) {
        let busyIDs = Set(fresh.filter { $0.status == .active || $0.toolPending }.map(\.composerId))
        let (newlyIdle, _) = cursorIdleDetector.record(busyIDs: busyIDs)
        for id in newlyIdle {
            if let session = fresh.first(where: { $0.composerId == id }) {
                NotificationService.shared.notifyIdle(cursor: session)
            }
        }
        refreshAnyBusy()
    }

    /// Menu-bar icon: any Claude / Cursor / Codex session mid-turn.
    private func refreshAnyBusy() {
        let claude = sessions.contains { $0.isAlive && ($0.status == .busy || $0.toolPending) }
        let cursor = cursorSessions.contains { $0.status == .active || $0.toolPending }
        let external = externalSessions.contains { $0.isActive }
        let busy = claude || cursor || external
        if anySessionBusy != busy {
            anySessionBusy = busy
            startSessionPolling()
        }
    }

    /// Enrich alive sessions with transcript context + subagents. Pure
    /// function so it can run wholly off-main.
    private static func enrich(_ sessions: [SessionInfo], previous: [SessionInfo], limits: [String: Int]) -> [SessionInfo] {
        let prior = Dictionary(uniqueKeysWithValues: previous.map { ($0.pid, $0) })
        var result = sessions
        for i in result.indices where result[i].isAlive {
            let size = SessionMonitor.transcriptSize(for: result[i])
            if let old = prior[result[i].pid], old.transcriptSize == size, size > 0 {
                result[i].contextTokens = old.contextTokens
                result[i].model = old.model
                result[i].messageCount = old.messageCount
                result[i].currentActivity = old.currentActivity
                result[i].toolPending = old.toolPending
                result[i].contextLimit = old.contextLimit
                result[i].subagents = old.subagents
                result[i].workflows = old.workflows
                result[i].transcriptSize = size
                if old.toolPending { result[i].status = .busy }
                continue
            }
            let ctx = SessionMonitor.fetchContext(for: result[i])
            result[i].contextTokens = ctx.tokens
            result[i].model = ctx.model
            result[i].messageCount = ctx.count
            result[i].currentActivity = ctx.activity
            result[i].toolPending = ctx.toolPending
            result[i].transcriptSize = size
            if ctx.toolPending { result[i].status = .busy }
            result[i].contextLimit = limits[result[i].model.lowercased()] ?? 0
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

    /// Scan Codex sessions. Same
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
                self.refreshAnyBusy()
            }
        }
    }

    private func startSessionPolling() {
        sessionTimer?.invalidate()
        let interval = anySessionBusy ? AppConfig.sessionPollInterval : AppConfig.sessionPollIdleInterval
        sessionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshSessions()
        }
    }
    // Note: the timer only *triggers* on the main run loop; the actual scan
    // runs inside a detached task (see refreshSessions) — the main thread
    // merely receives parsed results.

    // MARK: - Load / Save

    func loadProviders() {
        if FileManager.default.fileExists(atPath: FilePaths.presetsFile.path),
           let data = try? Data(contentsOf: FilePaths.presetsFile),
           let file = try? JSONDecoder().decode(ProvidersFile.self, from: data) {
            providers = file.providers
            activeProviderID = file.activeProviderID
        } else {
            providers = []
            activeProviderID = nil
        }

        if providers.isEmpty {
            let codex = ProviderBridge.readCodexProviders()
            if !codex.isEmpty {
                let converted = codex.map { ProviderBridge.toClaude($0) }
                let result = ProviderBridge.merge(into: &providers, from: converted)
                if !result.isEmpty {
                    importSummary = "已从 Codex 导入 · \(result.summary)"
                    saveProviders()
                }
            }
        }

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
        projectToPeer()
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
        activatePeer(provider: provider, model: model)
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
        projectToPeer()
    }

    func deleteProvider(_ provider: Provider) {
        providers.removeAll { $0.id == provider.id }
        if activeProviderID == provider.id { activeProviderID = providers.first?.id }
        if collapsedProviderIDs.contains(provider.id) { collapsedProviderIDs.remove(provider.id) }
        saveProviders()
        projectToPeer()
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
        projectToPeer()
    }

    /// Import Codex providers. Matching is by name or rewritten Anthropic URL.
    @discardableResult
    func importFromCodex(_ source: [CodexProvider]? = nil) -> ProviderBridge.ImportResult {
        let incoming = source ?? ProviderBridge.readCodexProviders()
        let converted = incoming.map { ProviderBridge.toClaude($0) }
        let result = ProviderBridge.merge(into: &providers, from: converted)
        importSummary = result.summary
        if !result.isEmpty { saveProviders() }
        return result
    }

    func updateProvider(_ provider: Provider, extras: ProviderBridge.CodexExtras? = nil) {
        guard let idx = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[idx] = provider
        saveProviders()
        projectToPeer(extras: extras.map { (provider, $0) })
    }

    /// One Claude list, two live configs. Missing Claude rows are imported
    /// from Codex; Codex is then rewritten as a projection so extras survive.
    @MainActor
    func unifyWithPeer() {
        guard let peer, !didUnifyWithPeer else { return }
        didUnifyWithPeer = true
        if !peer.providers.isEmpty {
            _ = importFromCodex(peer.providers)
        }
        projectToPeer()
    }

    private var didUnifyWithPeer = false

    /// Drop a Claude-shaped preset (from `CodexPreset`) into the unified list.
    @MainActor
    func addFromCodexPreset(_ preset: CodexProvider) {
        var claude = ProviderBridge.toClaude(preset)
        claude.id = UUID()
        if claude.models.isEmpty {
            claude.models = [ModelConfig(name: "default")]
            claude.activeModelID = claude.models.first?.id
        }
        providers.append(claude)
        saveProviders()
        projectToPeer(extras: (claude, ProviderBridge.extras(from: preset)))
    }

    private func projectToPeer(extras: (Provider, ProviderBridge.CodexExtras)? = nil) {
        let snapshot = providers
        let extra = extras
        Task { @MainActor [weak self] in
            self?.peer?.project(from: snapshot, extras: extra)
        }
    }

    private func activatePeer(provider: Provider, model: ModelConfig) {
        Task { @MainActor [weak self] in
            self?.peer?.activateMatching(claude: provider, model: model)
        }
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
    /// manual refresh button) into one background pass. Period chips query
    /// the rollup only; launch / Refresh / FSEvents pass `rescan: true`.
    private var usageRefreshPending = false
    private var usageRefreshQueued = false
    private var usageRefreshQueuedRescan = false

    func refreshUsage(rescan: Bool = true) {
        if usageRefreshPending {
            usageRefreshQueued = true
            usageRefreshQueuedRescan = usageRefreshQueuedRescan || rescan
            return
        }
        usageRefreshPending = true
        usageLoading = !UsageIndex.hasCachedData && UsageIndex.needsInitialBuild

        Task.detached(priority: .utility) { [weak self] in
            var wantRescan = rescan
            while true {
                guard let self else { return }
                let interval = await MainActor.run {
                    UsageStats.interval(for: self.usagePeriod, reference: self.usageReferenceDate)
                }

                if UsageIndex.hasCachedData {
                    let quick = Self.queryUsage(in: interval)
                    let days = UsageIndex.fetchDaily(in: interval)
                    let cursor = CursorUsageStats.fetch()
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.usageStats = quick
                        self.usageDays = days
                        self.cursorLifetimeUsage = cursor
                        self.usageLoading = false
                    }
                }

                if wantRescan {
                    UsageIndex.updateIndex()
                    CursorUsageStats.refreshIfNeeded()
                }
                let final = Self.queryUsage(in: interval)
                let days = UsageIndex.fetchDaily(in: interval)
                let cursor = CursorUsageStats.fetch()

                let next: (again: Bool, rescan: Bool) = await MainActor.run {
                    if self.usageRefreshQueued {
                        self.usageRefreshQueued = false
                        let nextRescan = self.usageRefreshQueuedRescan
                        self.usageRefreshQueuedRescan = false
                        return (true, nextRescan)
                    }
                    self.usageRefreshPending = false
                    return (false, false)
                }
                if next.again {
                    wantRescan = next.rescan
                    continue
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.usageStats = final
                    self.usageDays = days
                    self.cursorLifetimeUsage = cursor
                    self.usageLoading = false
                    self.writeWidgetSnapshot()
                }
                return
            }
        }
    }

    private static func queryUsage(in interval: DateInterval) -> [ModelUsage] {
        UsageIndex.fetch(in: interval)
    }

    private var usageWatcherStarted = false

    private func startUsageWatcher() {
        guard !usageWatcherStarted else { return }
        usageWatcherStarted = true
        UsageFSWatcher.start(paths: [
            FilePaths.claudeDir.appendingPathComponent("projects").path,
            FilePaths.codexDir.appendingPathComponent("sessions").path,
        ]) { [weak self] in
            DispatchQueue.main.async { self?.refreshUsage(rescan: true) }
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
