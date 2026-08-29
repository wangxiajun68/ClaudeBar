import Foundation
import Combine
import WidgetKit

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
    /// Per-session busy heartbeat — the last `heartbeatLength` polls, oldest
    /// first. `true` = the session was busy at that sample. Published so cards
    /// can draw an EKG-style sparkline from polling we were doing anyway.
    @Published var heartbeats: [Int: [Bool]] = [:]
    static let heartbeatLength = 24
    private var sessionTimer: Timer?
    /// Last serialized snapshot — `writeWidgetSnapshot()` only writes files +
    /// reloads widget timelines when the payload actually changes, so the 2.5s
    /// poll does not hammer disk / WidgetCenter with identical data.
    private var lastSnapshotData: Data?

    // Live Cursor (IDE) sessions
    @Published var cursorSessions: [CursorSessionInfo] = []
    @Published var cursorExpanded: Set<String> = []

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
        // publish the parsed results, so the 2.5s poll never blocks the UI.
        let contextLimits = currentContextLimits
        Task.detached(priority: .utility) { [weak self] in
            // `let scanned` (not var) so the capture is an immutable
            // sendable value — no concurrent-mutation warning.
            let enriched = Self.enrich(SessionMonitor.fetchActive(), limits: contextLimits)
            let samples = Self.heartbeatSamples(from: enriched)
            await MainActor.run { [weak self] in
                self?.sessions = enriched
                self?.recordHeartbeats(samples)
                self?.refreshCursorSessions()
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
    /// sessions' trails and pruning to `heartbeatLength`.
    private func recordHeartbeats(_ samples: [Int: Bool]) {
        guard !samples.isEmpty else {
            if !heartbeats.isEmpty { heartbeats = [:] }
            return
        }
        for (pid, busy) in samples {
            var trail = heartbeats[pid] ?? []
            trail.append(busy)
            if trail.count > Self.heartbeatLength { trail.removeFirst(trail.count - Self.heartbeatLength) }
            heartbeats[pid] = trail
        }
        // Prune trails for sessions that have died.
        let live = Set(samples.keys)
        heartbeats = heartbeats.filter { live.contains($0.key) }
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
                self.cursorSessions = result
                // Cursor session changes (new/ended/busy flip) should reach the
                // widget on the same poll — refreshCursorSessions runs on the 2.5s
                // timer but does not otherwise call writeWidgetSnapshot.
                self.writeWidgetSnapshot()
            }
        }
    }

    private func startSessionPolling() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.refreshSessions()
        }
    }
    // Note: the timer only *triggers* on the main run loop; the actual scan
    // runs inside a detached task (see refreshSessions) — the main thread
    // merely receives parsed results.

    // MARK: - Load / Save

    func loadProviders() {
        if let migrated = MigrationHelper.migrateIfNeeded() {
            providers = migrated.providers
            activeProviderID = migrated.activeProviderID
            // Multi-model providers display expanded by default (collapsedProviderIDs stays empty)
            saveProviders()
            return
        }

        guard FileManager.default.fileExists(atPath: FilePaths.presetsFile.path),
              let data = try? Data(contentsOf: FilePaths.presetsFile),
              let file = try? JSONDecoder().decode(ProvidersFile.self, from: data) else {
            providers = []; activeProviderID = nil; return
        }
        providers = file.providers
        activeProviderID = file.activeProviderID

        // Detect current provider from settings.json
        if let env = currentEnv {
            for provider in providers {
                let a = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let b = env.ANTHROPIC_BASE_URL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if a == b {
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
            errorMessage = "Failed to write settings: \(error.localizedDescription)"
            return
        }
        activeProviderID = providerID
        currentEnv = env

        if let idx = providers.firstIndex(where: { $0.id == providerID }) {
            providers[idx].activeModelID = modelID
        }
        saveProviders()
        refreshBalance()
    }

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
                // every period rather than interval-filtered. See CursorUsageStats.
                // The fetch is TTL-cached inside CursorUsageStats, so repeated
                // period/date switches don't rescan the multi-GB Cursor DB.
                if let cursor = CursorUsageStats.fetch() {
                    result.append(cursor)
                    result.sort { $0.totalTokens > $1.totalTokens }
                }
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
        let snapshot = buildSnapshot()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // Diff against the last written payload: if nothing changed since the
        // previous poll, skip the 4 file writes + WidgetCenter reload
        // entirely. WidgetCenter.reloadAllTimelines() is expensive and Apple
        // recommends calling it only on meaningful data change.
        guard data != lastSnapshotData else { return }
        lastSnapshotData = data
        persistSnapshot(data)
        WidgetCenter.shared.reloadAllTimelines()
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

    /// Write the snapshot JSON to every location the widget might read from.
    /// Multiple paths maximize compatibility across App Group / sandbox /
    /// fallback setups — see FilePaths.widgetSnapshotFile for the resolution.
    private func persistSnapshot(_ data: Data) {
        // 1. App Group container (or ~/.claude fallback — see FilePaths).
        try? data.write(to: FilePaths.widgetSnapshotFile, options: .atomic)
        // 2. ~/.claude/
        let claudeFile = FilePaths.claudeDir.appendingPathComponent("claude-bar-widget-data.json")
        try? data.write(to: claudeFile, options: .atomic)
        // 3. Widget's own sandbox container (sandboxed widget can read this).
        let widgetContainer = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.claudebar.app.widget/Data/claude-bar-widget-data.json")
        try? data.write(to: widgetContainer, options: .atomic)
        // 4. UserDefaults (App Group). `synchronize()` is a deprecated no-op
        // on modern macOS — UserDefaults flush automatically.
        if let shared = UserDefaults(suiteName: FilePaths.appGroupID) {
            shared.set(data, forKey: "widgetSnapshot")
        }
    }
}
