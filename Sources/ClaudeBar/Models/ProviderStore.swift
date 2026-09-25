import Foundation
import Combine

class ProviderStore: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var activeProviderID: UUID? = nil
    @Published var currentEnv: EnvConfig? = nil
    @Published var hasSettingsFile: Bool = false
    @Published var errorMessage: String? = nil
    @Published var importSummary: String? = nil
    struct SupplierBalance: Identifiable, Equatable {
        let id: UUID
        let name: String
        let amount: String
    }
    @Published var supplierBalances: [SupplierBalance] = []
    /// Provider id → display amount. Both client stacks share this map.
    @Published var balanceAmounts: [UUID: String] = [:]
    @Published var balanceText: String? = nil
    private var balanceTask: Task<Void, Never>?
    @Published var balanceLoading: Bool = false
    @Published var collapsedProviderIDs: Set<UUID> = []
    @Published var usageStats: [ModelUsage] = []
    @Published var usageDays: [DayUsage] = []
    /// The same two aggregates split by origin (Claude Code / Codex /
    /// third-party). Feeds the per-model source ring and the source-tinted
    /// river; `usageStats`/`usageDays` stay the flat totals everything else
    /// already reads.
    @Published var usageBySource: [UsageSource: [ModelUsage]] = [:]
    /// `usageBySource` indexed as source → model → tokens, rebuilt in
    /// `publishUsage`. The ring slices were built by scanning each source's
    /// model *array* once per tile (`first { $0.model == stat.model }`), which
    /// is O(models²) across the usage grid on every publish.
    private(set) var usageTokensByModel: [UsageSource: [String: Int]] = [:]
    /// Per-model cost line, keyed by model, rebuilt with `usageStats`. The
    /// usage grid used to call `costLine(for:)` per tile, and each call ran
    /// `ModelPricing.cost(of:)` — slug normalisation plus a table lookup — from
    /// `body`.
    private(set) var usageCostLines: [String: ModelPricing.Estimate.Line] = [:]
    /// The whole period's estimate, cached with the lines above. `costEstimate`
    /// used to re-run `ModelPricing.estimate(usageStats)` from `body` — slug
    /// canonicalisation (two regex compilations per model) plus a scan of the
    /// price table — on every publish and on every frame of the period-change
    /// animation, defeating the point of `usageCostLines`.
    private(set) var usageEstimate = ModelPricing.Estimate()
    @Published var usageDaysBySource: [UsageSource: [DayUsage]] = [:]
    @Published var usageLoading: Bool = false
    @Published var usagePeriod: UsagePeriod = .month {
        didSet { if usagePeriod != oldValue { refreshUsage(rescan: false) } }
    }
    @Published var usageReferenceDate: Date = Date() {
        didSet { if usageReferenceDate != oldValue { refreshUsage(rescan: false) } }
    }

    /// Codex store lives beside this one; lists are independent. Used to
    /// restart the shared local proxy after Claude capture/routing changes.
    /// Weak: AppDelegate owns both.
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
    // Main-thread gates keep each scanner single-flight and preserve result order.
    private var sessionScanPending = false
    private var cursorScanPending = false
    private var externalScanPending = false
    /// Last serialized snapshot payload — `writeWidgetSnapshot()` skips the
    /// file writes + widget reload when the data is unchanged (see
    /// `WidgetSnapshotWriter.write`).
    private var lastSnapshotData: Data?

    // Only a new transcript-confirmed final answer may produce an idle banner.
    @Published var anySessionBusy = false   // drives the menu-bar icon
    private var claudeCompletionDetector = ConfirmedCompletionDetector<Int>()
    private var cursorCompletionDetector = ConfirmedCompletionDetector<String>()

    // Live Cursor (IDE) sessions
    @Published var cursorSessions: [CursorSessionInfo] = []
    @Published var cursorExpanded: Set<String> = []

    // Live Codex sessions
    @Published var externalSessions: [ExternalSessionInfo] = [] {
        didSet { externalTreeCache.removeAll(keepingCapacity: true) }
    }
    var externalTreeCache: [ExternalAgentKind: [ExternalSessionNode]] = [:]
    private var externalCompletionDetector = ConfirmedCompletionDetector<String>()

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
        if let peer {
            ProviderProfileSync.reconcile(claude: self, codex: peer)
        }
        refreshBalance()
        peer?.refreshQuota()
        refreshUsage(rescan: true)
        refreshSessions()
        startSessionPolling()
        observeVisibility()
        ProcessSampler.shared.start()
        ProcessSampler.shared.setLive(anySessionBusy)
        startUsageWatcher()
        observeAppearance()
        writeWidgetSnapshot()
        refreshSharedProxy()
    }

    // MARK: - Sessions

    func refreshSessions() {
        guard !sessionScanPending else { return }
        sessionScanPending = true
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
                self.sessionScanPending = false
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
        var next = heartbeats
        for (pid, busy) in samples {
            var trail = next[pid] ?? []
            trail.append(busy)
            if trail.count > Self.heartbeatLength { trail.removeFirst(trail.count - Self.heartbeatLength) }
            next[pid] = trail
        }
        let live = Set(samples.keys)
        next = next.filter { live.contains($0.key) }
        // Publish once per changed snapshot, never once per dictionary write.
        if next != heartbeats { heartbeats = next }
    }

    /// A busy → idle edge is only a candidate: wait for a new final-answer
    /// marker from the transcript before notifying.
    private func detectIdleTransitions(_ fresh: [SessionInfo]) {
        let alive = fresh.filter(\.isAlive)
        let completed = claudeCompletionDetector.record(alive.map {
            (id: $0.pid, isBusy: $0.status == .busy || $0.toolPending, completionID: $0.completionID)
        })
        for pid in completed {
            if let session = alive.first(where: { $0.pid == pid }) {
                NotificationService.shared.notifyIdle(session: session)
            }
        }
        refreshAnyBusy()
    }

    /// Cursor flavor of the same edge detection (see `detectIdleTransitions`).
    private func detectIdleTransitionsCursor(_ fresh: [CursorSessionInfo]) {
        let completed = cursorCompletionDetector.record(fresh.map {
            (id: $0.composerId, isBusy: $0.status == .active || $0.toolPending,
             completionID: $0.completionID)
        })
        for id in completed {
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
            // The 1 Hz tier exists to make the popup's resource strip feel
            // live, and Codex "active" is pure recency (a 90 s window off the
            // rollout file's mtime) that a long turn keeps refreshed — so a
            // single Codex run pinned the sampler at 1 Hz for the whole turn
            // with nothing on screen watching it. Keep `anySessionBusy`
            // accurate for the menu-bar icon and the poll cadence; only the
            // 1 Hz *sampling* rate follows visibility.
            ProcessSampler.shared.setLive(busy && UIWakePolicy.hasVisibleWindow)
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
                result[i].completionID = old.completionID
                result[i].firstPrompt = old.firstPrompt
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
            result[i].completionID = ctx.completionID
            result[i].firstPrompt = ctx.title
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
    private func refreshCursorSessions() {
        guard PermissionGate.allows(.cursorData) else {
            if !cursorSessions.isEmpty {
                cursorSessions = []
                refreshAnyBusy()
            }
            return
        }
        guard !cursorScanPending else { return }
        cursorScanPending = true
        Task.detached(priority: .utility) {
            let result = CursorSessionMonitor.fetchActive()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cursorScanPending = false
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
    private func refreshExternalSessions() {
        guard !externalScanPending else { return }
        externalScanPending = true
        Task.detached(priority: .utility) {
            let result = ExternalSessionMonitor.fetchActive()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.externalScanPending = false
                if self.externalSessions == result { return }
                self.externalSessions = result
                let completed = self.externalCompletionDetector.record(result.map {
                    (id: $0.id, isBusy: $0.isActive, completionID: $0.completionID)
                })
                for id in completed {
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
        let interval: TimeInterval
        if !UIWakePolicy.hasVisibleWindow {
            interval = AppConfig.sessionPollHiddenInterval
        } else {
            interval = anySessionBusy ? AppConfig.sessionPollInterval : AppConfig.sessionPollIdleInterval
        }
        sessionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshSessions()
        }
    }

    /// Re-arm the poll timer when a window appears or disappears. Called once
    /// from `refresh()`; `UIWakePolicy` drops duplicate transitions itself.
    private var visibilityCancel: AnyCancellable?

    private func observeVisibility() {
        guard visibilityCancel == nil else { return }
        visibilityCancel = UIWakePolicy.observe { [weak self] in
            guard let self else { return }
            self.startSessionPolling()
            // `setLive` is visibility-gated (see refreshAnyBusy): re-assert it
            // on every transition, or a transition that does not change
            // `anySessionBusy` would leave the sampler at the background tier
            // with the popup now open.
            ProcessSampler.shared.setLive(self.anySessionBusy && UIWakePolicy.hasVisibleWindow)
            // The FSEvents stream feeds the usage index. With no window on
            // screen the re-index is pure background cost; stop the stream
            // and let the next visible poll rescan.
            if UIWakePolicy.hasVisibleWindow {
                if !self.usageWatcherStarted {
                    self.startUsageWatcher()
                    // Catch up on transcripts written while nothing watched.
                    // A brief gap (a notch-island hover) is left to the next
                    // FSEvents append rather than a full rescan per hover.
                    if let stoppedAt = self.usageWatcherStoppedAt, Date().timeIntervalSince(stoppedAt) > 30 {
                        self.refreshUsage(rescan: true)
                    }
                }
            } else if self.usageWatcherStarted {
                UsageFSWatcher.stop()
                self.usageWatcherStarted = false
                self.usageWatcherStoppedAt = Date()
            }
            self.writeWidgetSnapshot()
        }
    }

    /// Republish the snapshot when the user flips light/dark or the token unit
    /// style. Both values ride in the payload (the widget cannot read the
    /// app's `UserDefaults` domain), so without this the widget would keep
    /// rendering the old palette until the next session poll wrote a changed
    /// snapshot — which, when every session is idle, is never.
    private var appearanceCancellables: Set<AnyCancellable> = []

    private func observeAppearance() {
        guard appearanceCancellables.isEmpty else { return }
        NotificationCenter.default.publisher(for: .permissionDidChange)
            .compactMap { $0.object as? AppPermission }
            .receive(on: RunLoop.main)
            .sink { [weak self] permission in
                guard let self else { return }
                switch permission {
                case .widgetData:
                    // Force a write even if the payload is unchanged since the
                    // switch was off — the containers never got it.
                    self.lastSnapshotData = nil
                    self.writeWidgetSnapshot()
                case .cursorData:
                    self.refreshCursorSessions()
                default:
                    break
                }
            }
            .store(in: &appearanceCancellables)
        let prefs = AppPreferences.shared
        for publisher in [prefs.$appearance.map { _ in () }.eraseToAnyPublisher(),
                          prefs.$tokenUnitStyle.map { _ in () }.eraseToAnyPublisher()] {
            publisher
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.writeWidgetSnapshot() }
                .store(in: &appearanceCancellables)
        }
    }


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

        // Detect current provider from settings.json. When the settings file
        // matches a configured provider, adopt it as active and persist the
        // reconciled state (a single save, after all mutations below).
        guard let env = currentEnv else { return }
        if LocalProxyAddress.isLoopback(env.ANTHROPIC_BASE_URL) {
            // A loopback URL is only correct while the active vendor's own
            // 流量记录 switch is on. Anything else (the global 本地代理 toggle,
            // a vendor switched off, a vendor we can no longer resolve) means
            // the real URL belongs back in the file. Mirrors
            // `CodexProviderStore.load()`.
            let active = providers.first { $0.id == activeProviderID }
            let expectedLoopback = active?.captureEnabled ?? false
            if !expectedLoopback, let active, let model = active.activeModel {
                activateModel(providerID: active.id, modelID: model.id)
            }
            return
        }
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

    @discardableResult
    func saveProviders() -> Bool {
        do {
            let data = try JSONEncoder().encode(ProvidersFile(providers: providers, activeProviderID: activeProviderID))
            try FileManager.default.createDirectory(at: FilePaths.claudeDir, withIntermediateDirectories: true)
            try PrivateFileWriter.write(data, to: FilePaths.presetsFile)
            hardenLegacySecretFiles()
            return true
        } catch {
            errorMessage = "保存供应商失败：\(error.localizedDescription)"
            return false
        }
    }

    /// One-shot fix-up for the two files older builds left world-readable.
    /// Cheap enough to run on every save (two `stat`s) and it makes the
    /// narrowing self-healing for anyone upgrading.
    private static var hardenedLegacy = false

    private func hardenLegacySecretFiles() {
        guard !Self.hardenedLegacy else { return }
        Self.hardenedLegacy = true
        let fm = FileManager.default
        for url in [FilePaths.settingsFile, FilePaths.codexProvidersFile] {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mode = attrs[.posixPermissions] as? NSNumber,
                  mode.intValue & 0o077 != 0 else { continue }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: - Activate

    func activateModel(providerID: UUID, modelID: UUID) {
        guard let provider = providers.first(where: { $0.id == providerID }),
              let model = provider.models.first(where: { $0.id == modelID }) else { return }

        let env = buildEnv(from: provider, model: model)
        do {
            try SettingsManager.writeSettings(env: env)
        } catch {
            currentEnv = SettingsManager.readSettings()
            errorMessage = "写入设置失败：\(error.localizedDescription)"
            return
        }
        activeProviderID = providerID
        currentEnv = env

        if let idx = providers.firstIndex(where: { $0.id == providerID }) {
            providers[idx].activeModelID = modelID
        }
        saveProviders()
        refreshBalance()
        refreshSharedProxy()
    }

    /// Re-apply the active Claude vendor (e.g. local-proxy toggle flipped).
    func reactivateActive() {
        guard let p = activeProvider else { return }
        let mid = p.activeModelID ?? p.models.first?.id
        guard let mid else { return }
        activateModel(providerID: p.id, modelID: mid)
    }

    /// Strip the third-party overlay from `settings.json` and clear the
    /// active tile. The vendor list is not deleted — activating a row writes
    /// the overlay back.
    @MainActor
    func restoreOfficial() {
        do {
            try SettingsManager.restoreOfficial()
        } catch {
            errorMessage = "还原官方配置失败：\(error.localizedDescription)"
            return
        }
        errorMessage = nil
        activeProviderID = nil
        currentEnv = SettingsManager.readSettings()
        hasSettingsFile = FileManager.default.fileExists(atPath: FilePaths.settingsFile.path)
        saveProviders()
        refreshSharedProxy()
        refreshBalance()
        writeWidgetSnapshot()
    }

    /// Maps a provider/model pair onto the `settings.json` env block. All
    /// `ANTHROPIC_DEFAULT_*_MODEL` aliases carry the chosen model name so
    /// subagent/background traffic is routed to the same endpoint.
    ///
    /// The address written is the vendor's **original** base URL unless this
    /// vendor's own 流量记录 switch is on. The Anthropic path is a pure
    /// passthrough in the local proxy — it rewrites nothing — so the global
    /// 本地代理 toggle alone is not a reason to put a loopback URL in a
    /// user-visible config file.
    private func buildEnv(from provider: Provider, model: ModelConfig) -> EnvConfig {
        let base = provider.captureEnabled ? LocalProxyAddress.claudeBase : provider.baseURL
        return EnvConfig(
            // When this vendor is routed through the local proxy, the token
            // that reaches the proxy is its bearer token, not the vendor key —
            // the proxy injects the real key upstream. Claude Code reads
            // `ANTHROPIC_AUTH_TOKEN` into `x-api-key`, so this needs no extra
            // config file, unlike Codex.
            ANTHROPIC_AUTH_TOKEN: provider.captureEnabled
                ? CodexProxyServer.configuredToken
                : provider.authToken,
            ANTHROPIC_BASE_URL: base,
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

    func deleteProvider(_ provider: Provider, propagate: Bool = true, reassignActive: Bool = true) {
        let profileID = provider.profileID
        let wasActive = activeProviderID == provider.id
        providers.removeAll { $0.id == provider.id }
        if wasActive {
            activeProviderID = reassignActive ? providers.first?.id : nil
        }
        if collapsedProviderIDs.contains(provider.id) { collapsedProviderIDs.remove(provider.id) }
        saveProviders()
        if propagate, let profileID {
            MainActor.assumeIsolated { ProviderProfileSync.removeCodex(profileID: profileID, store: self) }
        }
    }

    func duplicateProvider(_ provider: Provider) {
        var copy = Provider(
            name: "\(provider.name) 副本",
            authToken: provider.authToken,
            baseURL: provider.baseURL,
            models: provider.models,
            activeModelID: provider.activeModelID,
            captureEnabled: provider.captureEnabled,
            catalogID: provider.catalogID
        )
        copy.profileID = UUID()
        providers.append(copy)
        saveProviders()
        MainActor.assumeIsolated { ProviderProfileSync.pushClaude(copy, store: self) }
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

    /// Quick setup saves a complete record without changing the live client.
    @MainActor
    @discardableResult
    func addConfiguredProvider(_ provider: Provider, propagate: Bool = true) -> Bool {
        var provider = provider
        if provider.profileID == nil { provider.profileID = UUID() }
        providers.append(provider)
        guard saveProviders() else {
            providers.removeAll { $0.id == provider.id }
            return false
        }
        if propagate {
            ProviderProfileSync.pushClaude(provider, store: self)
        }
        return true
    }

    @discardableResult
    func updateProvider(_ provider: Provider, propagate: Bool = true) -> Bool {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return false }
        var provider = provider
        if provider.profileID == nil { provider.profileID = providers[index].profileID ?? UUID() }
        if provider.catalogID == nil { provider.catalogID = providers[index].catalogID }
        let previous = providers[index]
        providers[index] = provider
        guard saveProviders() else {
            providers[index] = previous
            return false
        }
        if propagate {
            MainActor.assumeIsolated { ProviderProfileSync.pushClaude(provider, store: self) }
        }
        return true
    }

    /// Tile-level capture switch. If this vendor is active, rewrite env + proxy.
    func setCaptureEnabled(providerID: UUID, enabled: Bool) {
        guard let idx = providers.firstIndex(where: { $0.id == providerID }) else { return }
        providers[idx].captureEnabled = enabled
        saveProviders()
        if activeProviderID == providerID,
           let modelID = providers[idx].activeModelID ?? providers[idx].models.first?.id {
            activateModel(providerID: providerID, modelID: modelID)
        } else {
            refreshSharedProxy()
        }
        MainActor.assumeIsolated { ProviderProfileSync.pushClaude(providers[idx], store: self) }
    }

    /// Blank Claude provider with one placeholder model — ready to edit and save.
    @MainActor
    @discardableResult
    func addBlankProvider() -> Provider {
        let placeholder = ModelConfig(name: "model-name")
        let p = Provider(name: "新供应商", models: [placeholder], activeModelID: placeholder.id)
        providers.append(p)
        saveProviders()
        return p
    }

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
    }

    /// Keep the shared local proxy's Claude upstream current. This does not
    /// select or write a Codex provider/model.
    private func refreshSharedProxy() {
        Task { @MainActor [weak self] in
            self?.peer?.syncProxyRuntime()
        }
    }

    // MARK: - Balance

    func refreshBalance() {
        balanceTask?.cancel()
        balanceLoading = true
        balanceTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            // Both model stacks may contain independently configured accounts.
            var candidates = providers.map { (id: $0.id, name: $0.name, token: $0.authToken, base: $0.baseURL) }
            candidates += (peer?.providers ?? []).map { (id: $0.id, name: $0.name, token: $0.apiKey, base: $0.baseURL) }
            // One request per key and host; every matching card still gets the amount.
            var groups: [String: (token: String, base: String, ids: [(UUID, String)])] = [:]
            for candidate in candidates {
                let token = candidate.token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard BalanceFetcher.supports(candidate.base), !token.isEmpty else { continue }
                let key = "\(token)\n\(candidate.base)"
                var group = groups[key] ?? (token, candidate.base, [])
                group.ids.append((candidate.id, candidate.name))
                groups[key] = group
            }
            var balances: [SupplierBalance] = []
            var amounts: [UUID: String] = [:]
            for provider in groups.values {
                guard !Task.isCancelled else { return }
                let result = await BalanceFetcher.fetch(authToken: provider.token, baseURL: provider.base)
                guard !Task.isCancelled else { return }
                guard let result else { continue }
                for (id, name) in provider.ids {
                    amounts[id] = result.display
                    balances.append(SupplierBalance(id: id, name: name, amount: result.display))
                }
            }
            if supplierBalances != balances { supplierBalances = balances }
            if balanceAmounts != amounts { balanceAmounts = amounts }
            let display = balances.map { "\($0.name) · \($0.amount)" }.joined(separator: " / ")
            balanceText = display.isEmpty ? nil : display
            writeWidgetSnapshot()
            balanceLoading = false
            balanceTask = nil
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

        Task.detached(priority: .utility) { [weak self] in
            // The first cache probe can open/migrate SQLite or load JSON.
            // Never run it on the interaction thread.
            let initialLoading = !UsageIndex.hasCachedData && UsageIndex.needsInitialBuild
            await MainActor.run { [weak self] in
                if self?.usageLoading != initialLoading { self?.usageLoading = initialLoading }
            }
            var wantRescan = rescan
            while true {
                guard let self else { return }
                let interval = await MainActor.run {
                    UsageStats.interval(for: self.usagePeriod, reference: self.usageReferenceDate)
                }

                if wantRescan && UsageIndex.hasCachedData {
                    let quick = Self.queryUsage(in: interval)
                    let quickSources = Self.queryUsageBySource(in: interval)
                    let days = UsageIndex.fetchDaily(in: interval)
                    let daysBySource = UsageIndex.fetchDailyBySource(in: interval)
                    await MainActor.run { [weak self] in
                        guard let self, !self.usageRefreshQueued else { return }
                        self.publishUsage(quick, quickSources, days, daysBySource)
                    }
                }

                if wantRescan {
                    UsageIndex.updateIndex()
                }
                let final = Self.queryUsage(in: interval)
                let finalSources = Self.queryUsageBySource(in: interval)
                let days = UsageIndex.fetchDaily(in: interval)
                let daysBySource = UsageIndex.fetchDailyBySource(in: interval)

                let next: (again: Bool, rescan: Bool) = await MainActor.run {
                    if self.usageRefreshQueued {
                        self.usageRefreshQueued = false
                        let nextRescan = self.usageRefreshQueuedRescan
                        self.usageRefreshQueuedRescan = false
                        return (true, nextRescan)
                    }
                    // Publish and release the gate in one main-actor transaction.
                    // A new refresh cannot start between these operations.
                    self.publishUsage(final, finalSources, days, daysBySource)
                    self.writeWidgetSnapshot()
                    self.usageRefreshPending = false
                    return (false, false)
                }
                if next.again {
                    wantRescan = next.rescan
                    continue
                }
                return
            }
        }
    }

    /// Assign only what changed: an FSEvents-driven rescan usually finds the
    /// same aggregates, and every assignment would re-render the usage page,
    /// the popup's usage panel and the island.
    ///
    /// Arrays are compared as sets of rows because the SQL grouping gives no
    /// stable order.
    private func publishUsage(_ stats: [ModelUsage], _ bySource: [UsageSource: [ModelUsage]],
                              _ days: [DayUsage], _ daysBySource: [UsageSource: [DayUsage]]) {
        func same(_ a: [ModelUsage], _ b: [ModelUsage]) -> Bool {
            a.count == b.count && Set(a) == Set(b)
        }
        if !same(usageStats, stats) {
            usageStats = stats
            let estimate = ModelPricing.estimate(stats)
            var lines: [String: ModelPricing.Estimate.Line] = [:]
            for line in estimate.lines { lines[line.model] = line }
            usageCostLines = lines
            usageEstimate = estimate
        }
        let sourcesEqual = usageBySource.count == bySource.count
            && bySource.allSatisfy { key, value in usageBySource[key].map { same($0, value) } ?? false }
        if !sourcesEqual {
            usageBySource = bySource
            usageTokensByModel = bySource.mapValues { rows in
                var out: [String: Int] = [:]
                out.reserveCapacity(rows.count)
                for row in rows { out[row.model] = row.totalTokens }
                return out
            }
        }
        if usageDays != days { usageDays = days }
        if usageDaysBySource != daysBySource { usageDaysBySource = daysBySource }
        if usageLoading { usageLoading = false }
    }

    private static func queryUsage(in interval: DateInterval) -> [ModelUsage] {
        UsageIndex.fetch(in: interval)
    }

    private static func queryUsageBySource(in interval: DateInterval) -> [UsageSource: [ModelUsage]] {
        UsageIndex.fetchBySource(in: interval)
    }

    private var usageWatcherStarted = false
    private var usageWatcherStoppedAt: Date?
    private var persistenceObserver: NSObjectProtocol?

    private func startUsageWatcher() {
        guard !usageWatcherStarted else { return }
        usageWatcherStarted = true
        UsageFSWatcher.start(paths: [
            FilePaths.claudeDir.appendingPathComponent("projects").path,
            FilePaths.codexDir.appendingPathComponent("sessions").path,
        ]) { [weak self] in
            DispatchQueue.main.async { self?.refreshUsage(rescan: true) }
        }
        if persistenceObserver == nil {
            persistenceObserver = NotificationCenter.default.addObserver(
                forName: .persistenceModeDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.refreshUsage(rescan: true)
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
            // The number above is the *selected* period's total (default 当前月,
            // and the popup can page back through any month). Hand the widget
            // the label so it does not call a past month "today".
            usagePeriodLabel: usagePeriodLabel,
            unitStyle: AppPreferences.shared.tokenUnitStyle.rawValue,
            isDark: AppPreferences.shared.isDark,
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
            externalSessions: externalSessions.prefix(5).map { s in
                WidgetSnapshot.ExternalSessionSummary(
                    id: s.id,
                    status: s.isActive ? "busy" : "idle",
                    model: s.model,
                    contextTokens: s.contextTokens,
                    contextLimit: s.contextLimit,
                    contextRatio: s.contextRatio,
                    projectFolder: s.displayName,
                    relativeUpdated: s.relativeUpdated
                )
            },
            updatedAt: Date()
        )
    }

    /// "今天" for the current day window, otherwise the period's own label
    /// plus the reference date ("9月" / "2026年"). Matches what the popup and
    /// the usage page title say for the same window. Shared with the
    /// dashboard's cost tile pill, which needs the same short form.
    private var usagePeriodLabel: String {
        UsageStats.compactLabel(for: usagePeriod, reference: usageReferenceDate)
    }
}
