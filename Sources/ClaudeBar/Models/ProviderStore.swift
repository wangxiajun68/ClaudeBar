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
        didSet { refreshUsage() }
    }

    // Live Claude Code sessions
    @Published var sessions: [SessionInfo] = []
    @Published var expandedSessionPIDs: Set<Int> = []
    private var sessionTimer: Timer?

    // Live Cursor (IDE) sessions
    @Published var cursorSessions: [CursorSessionInfo] = []
    @Published var cursorExpanded: Set<String> = []

    init() { refresh() }

    // MARK: - Refresh

    func refresh() {
        hasSettingsFile = FileManager.default.fileExists(atPath: FilePaths.settingsFile.path)
        let (env, _) = SettingsManager.readSettings()
        currentEnv = env
        loadProviders()
        refreshBalance()
        refreshUsage()
        refreshSessions()
        startSessionPolling()
        writeWidgetSnapshot()
    }

    // MARK: - Sessions

    func refreshSessions() {
        var sessions = SessionMonitor.fetchActive()
        // Enrich alive sessions with context-window usage from their transcripts.
        for i in sessions.indices where sessions[i].isAlive {
            let ctx = SessionMonitor.fetchContext(for: sessions[i])
            sessions[i].contextTokens = ctx.tokens
            sessions[i].model = ctx.model
            sessions[i].messageCount = ctx.count
            sessions[i].currentActivity = ctx.activity
            sessions[i].toolPending = ctx.toolPending
            // A pending tool call means the session is actively working even
            // if the session-json status hasn't flipped to "busy" yet.
            if ctx.toolPending { sessions[i].status = .busy }
            // Resolve the context limit from the matching provider's model config.
            sessions[i].contextLimit = resolveContextLimit(for: sessions[i])
            // Live subagents + workflows spawned by this session.
            let subs = SessionMonitor.fetchSubagents(for: sessions[i])
            sessions[i].subagents = subs.direct
            sessions[i].workflows = subs.workflows
        }
        self.sessions = sessions
        refreshCursorSessions()
    }

    // MARK: - Cursor Sessions

    /// Read Cursor composer sessions from its state.vscdb. Run off the main
    /// thread — the DB is large, and transcript-tail scans do file I/O.
    func refreshCursorSessions() {
        Task.detached(priority: .utility) {
            let result = CursorSessionMonitor.fetchActive()
            await MainActor.run {
                self.cursorSessions = result
                // Cursor session changes (new/ended/busy flip) should reach the
                // widget on the same poll — refreshCursorSessions runs on the 2.5s
                // timer but does not otherwise call writeWidgetSnapshot.
                self.writeWidgetSnapshot()
            }
        }
    }

    /// Find the provider/model matching a session's actual model name and
    /// return its configured context-token limit (0 if unknown).
    private func resolveContextLimit(for session: SessionInfo) -> Int {
        guard !session.model.isEmpty else { return 0 }
        for provider in providers {
            for m in provider.models where m.name.caseInsensitiveCompare(session.model) == .orderedSame {
                return Int(m.contextTokens) ?? 0
            }
        }
        return 0
    }

    private func startSessionPolling() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.refreshSessions()
        }
    }

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
        if activeProviderID == provider.id { activeProviderID = provider.id }
        saveProviders()
    }

    // MARK: - Balance

    func refreshBalance() {
        guard let env = currentEnv else { balanceText = nil; return }
        balanceLoading = true
        Task { @MainActor in
            defer { balanceLoading = false }
            if let result = await BalanceFetcher.fetch(authToken: env.ANTHROPIC_AUTH_TOKEN, baseURL: env.ANTHROPIC_BASE_URL) {
                balanceText = "\(result.balance)"
            } else {
                balanceText = nil
            }
        }
    }

    // MARK: - Usage Stats

    func refreshUsage() {
        usageLoading = true
        let interval = UsageStats.interval(for: usagePeriod, reference: usageReferenceDate)
        Task.detached(priority: .utility) {
            var result = UsageStats.fetch(in: interval)
            // Cursor's token history is a stable full-scan total (Cursor
            // stopped writing tokens after ~2026-03), so it is appended to
            // every period rather than interval-filtered. See CursorUsageStats.
            if let cursor = CursorUsageStats.fetch() {
                result.append(cursor)
                result.sort { $0.totalTokens > $1.totalTokens }
            }
            let final = result
            await MainActor.run {
                self.usageStats = final
                self.usageLoading = false
                self.writeWidgetSnapshot()
            }
        }
    }

    // MARK: - Widget Snapshot

    func writeWidgetSnapshot() {
        let alive = sessions.filter(\.isAlive)
        let snapshot = WidgetSnapshot(
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
        // Write to multiple locations for maximum widget compatibility
        if let data = try? JSONEncoder().encode(snapshot) {
            // 1. App Group container
            try? data.write(to: FilePaths.widgetSnapshotFile, options: .atomic)
            // 2. ~/.claude/
            let claudeFile = FilePaths.claudeDir.appendingPathComponent("claude-bar-widget-data.json")
            try? data.write(to: claudeFile, options: .atomic)
            // 3. Widget's own sandbox container (sandboxed widget can read this)
            let widgetContainer = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.claudebar.app.widget/Data/claude-bar-widget-data.json")
            try? data.write(to: widgetContainer, options: .atomic)
            // 4. UserDefaults (App Group)
            if let shared = UserDefaults(suiteName: FilePaths.appGroupID) {
                shared.set(data, forKey: "widgetSnapshot")
                shared.synchronize()
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
