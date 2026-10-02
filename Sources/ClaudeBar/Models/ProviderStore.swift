import Foundation
import Combine

class ProviderStore: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var activeProviderID: UUID? = nil
    @Published var currentEnv: EnvConfig? = nil
    @Published var hasSettingsFile: Bool = false
    @Published var errorMessage: String? = nil
    @Published var importSummary: String? = nil
    /// Provider id → display amount. Both client stacks share this map.
    @Published var balanceAmounts: [UUID: String] = [:]
    @Published var balanceText: String? = nil
    private var balanceTask: Task<Void, Never>?
    @Published var balanceLoading: Bool = false
    @Published var collapsedProviderIDs: Set<UUID> = []
    @Published var usageStats: [ModelUsage] = []
    @Published var usageDays: [DayUsage] = []
    /// The week containing `usageReferenceDate`, always.
    ///
    /// The popup always draws a **week** strip (日 period), but `usageDays`
    /// holds only the selected period — one day when 日 is selected, a month
    /// otherwise. The strip painted six of its seven cells from an array that
    /// never contained them and reported 无用量 for days the app had never
    /// asked about. Fetched in the same detached pass as everything else, from
    /// the same index, so this is one more range scan rather than a second
    /// scan path.
    @Published var usageWeekDays: [DayUsage] = []
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
    @Published private(set) var usageEstimate = ModelPricing.Estimate()
    @Published var usageLoading: Bool = false
    @Published private(set) var usagePublishedInterval: DateInterval?
    /// Today's totals, independent of `usagePeriod`.
    ///
    /// The dashboard's 今日花费 / 今日 Token cards are a fixed window while
    /// everything else on the usage surfaces follows the period chips, so they
    /// cannot read `usageStats` — that is the *selected* period (default 当前月),
    /// and a card labelled 今日 showing a month's total is exactly the kind of
    /// confidently wrong number this app's cost rules exist to avoid. Queried
    /// alongside the period in the same detached pass, so no second timer and no
    /// second scan runs for it.
    @Published private(set) var todayUsage = TodayUsage()

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
    /// One-shot re-arm for a deferred scan (see `scheduleDeferredSessionPoll`).
    private var deferredPollTimer: Timer?
    // Main-thread gates keep each scanner single-flight and preserve result order.
    private var sessionScanPending = false
    private var cursorScanPending = false
    private var externalScanPending = false
    /// One cleanup at a time: it spawns a `codex app-server`, and two of them
    /// racing would each try to delete the same fork.
    private var externalCleanupPending = false
    /// Per-pid transcript stamps for `enrich`'s session cache — main-thread
    /// state, captured before the detached scan like `currentContextLimits`
    /// and replaced when that scan publishes. See `TranscriptStamp`.
    private var transcriptStamps: [Int: TranscriptStamp] = [:]

    /// Poll cadence to fall back to when a scan has to be deferred because the
    /// previous one is still running. Only reached when a scan outlives its
    /// own interval, which is exactly when the app is busiest.
    private static let deferredPollRetry: TimeInterval = 1.5

    /// How recent an agent session's own last write must be for its completed
    /// turn to be announced. Several hidden-tier poll intervals, so a normal
    /// end-of-turn is always inside it, while a turn that ended while nobody
    /// was polling (asleep, relaunched, hidden for a long stretch) is not
    /// announced late. See `ConfirmedCompletionDetector`.
    private static let completionFreshness: TimeInterval = 60

    // Only a new transcript-confirmed final answer may produce an idle banner.
    @Published var anySessionBusy = false   // status pill, busy/idle poll tier + visibility-gated sampler rate
    private var claudeCompletionDetector = ConfirmedCompletionDetector<Int>()
    private var cursorCompletionDetector = ConfirmedCompletionDetector<String>()

    // Live Cursor (IDE) sessions
    @Published var cursorSessions: [CursorSessionInfo] = []

    // Live Codex sessions
    @Published var externalSessions: [ExternalSessionInfo] = [] {
        didSet { externalTreeCache.removeAll(keepingCapacity: true) }
    }
    var externalTreeCache: [ExternalAgentKind: [ExternalSessionNode]] = [:]
    private var externalCompletionDetector = ConfirmedCompletionDetector<String>()

    /// Remove a Codex thread whose open turn stopped advancing — the state that
    /// would otherwise be listed forever as a session that is neither running
    /// nor resumable (see `ExternalSessionInfo.hasStalledTurn`).
    ///
    /// Only ever called from an explicit user action: the app never deletes a
    /// thread on its own. `CodexAppServerClient` owns the protocol, including
    /// deleting the target's forks first, because Codex refuses to delete a
    /// thread that forked history still references.
    ///
    /// The monitor does not re-check the stall here — the caller passed the
    /// confirmation dialog with the session's name and directory in front of
    /// them, and a rule that quietly changed its mind between prompt and
    /// confirmation would be worse than one that answers to the button.
    func cleanUpExternalSession(_ session: ExternalSessionInfo) {
        guard !externalCleanupPending else { return }
        externalCleanupPending = true
        Task.detached(priority: .userInitiated) {
            _ = try? CodexAppServerClient.remove(threadId: session.sessionId)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.externalCleanupPending = false
                // Re-scan now rather than waiting for the 5 s idle poll: the row
                // is still on screen, and it should leave with the action.
                self.refreshExternalSessions()
            }
        }
    }

    /// Cross-surface page requests, relayed to whoever currently owns the main
    /// window's content. Posted by the menu-bar popup and by other pages
    /// (设置 → 打开 VPN 页, the Wi-Fi permission chip) through
    /// `MainWindowController.showWindow(on:)`.
    ///
    /// This lives on the store — the one object every surface already holds a
    /// reference to — rather than being threaded through `MainWindowView`'s
    /// initializer: `installContent` rebuilds that view on every reopen, and a
    /// view-typed property would have made `ProviderStore` depend on it.
    /// `@Published` means a request outlives the window's teardown and is
    /// replayed to the next subscriber.
    @Published private(set) var navigationRequest: NavigationRequest?

    /// A page a caller asked for before the window could route it.
    ///
    /// These used to be `NotificationCenter` posts, which do not survive a
    /// window that had to be built first: a freshly installed `NSHostingView`
    /// subscribes to the center only when its first display pass runs —
    /// measured at ~50 ms, exactly the 50–150 ms `installContent` costs — so
    /// the page post was published before `MainWindowView` existed and the
    /// window opened on the page it had last remembered. A published value is
    /// replayed instead of missed.
    ///
    /// The token makes repeated requests distinguishable, so asking for the
    /// same page twice still routes twice.
    struct NavigationRequest: Equatable {
        let destination: Destination
        let token: Int

        enum Destination: Equatable {
            case page(AppPage)
            /// Same page, plus "open the editor for the active provider" —
            /// what the popup's 「管理模型」 and its empty-state 「去添加供应商」
            /// actually mean.
            case editor(AppPage)
        }
    }

    private var navigationCounter = 0

    /// Ask for a page to be shown. Applied by whoever owns the main window's
    /// content at the time this is watched; see `MainWindowView`.
    func requestNavigation(_ destination: NavigationRequest.Destination) {
        navigationCounter += 1
        navigationRequest = NavigationRequest(destination: destination, token: navigationCounter)
    }

    /// Marks a request as handled. The window's shell is its only consumer —
    /// an editor request is handed to the page as a `@State` flag — so the
    /// request can be dropped as soon as it has been routed, and a later
    /// reopen (or a revisit of the page) cannot replay it.
    func clearNavigation(_ taken: NavigationRequest) {
        guard navigationRequest == taken else { return }
        navigationRequest = nil
    }

    /// Initial state is populated by the AppDelegate once the status item and
    /// main window are wired up — calling `refresh()` here would run file I/O
    /// and spawn background tasks before the UI surfaces exist, and the
    /// delegate calls `refresh()` again anyway (which would duplicate that).
    init() {}

    deinit {
        sessionTimer?.invalidate()
        deferredPollTimer?.invalidate()
    }

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
        // The Cursor ledger reads on its own clock (a network round trip for
        // whichever window the usage page has selected), so it is kicked here
        // rather than awaited: the usage page opens on the persisted reading
        // and this only makes the next one land.
        requestSettlement()
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
        // A scan that outlives its interval (a 96 KB tail per session on a cold
        // cache) would otherwise drop every poll that lands while it runs — and
        // the dropped polls are the ones the completion detectors read. Re-arm
        // a short timer instead of waiting out the next interval.
        guard !sessionScanPending else { scheduleDeferredSessionPoll(); return }
        sessionScanPending = true
        // The scan reads session JSONs + transcript tails + subagent dirs —
        // pure file I/O. Run it off the main thread and only hop back to
        // publish the parsed results, so the poll never blocks the UI.
        let contextLimits = currentContextLimits
        let previous = sessions
        let stamps = transcriptStamps
        Task.detached(priority: .utility) {
            let scan = Self.enrich(SessionMonitor.fetchActive(), previous: previous,
                                   stamps: stamps, limits: contextLimits)
            let enriched = scan.sessions
            let samples = Self.heartbeatSamples(from: enriched)
            let pids = enriched.filter(\.isAlive).map(\.pid)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sessionScanPending = false
                self.transcriptStamps = scan.stamps
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
            out[s.pid] = s.isBusy
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

    /// "A turn just delivered its answer": a new turn key on a session whose
    /// transcript was just written — see `ConfirmedCompletionDetector`. The key
    /// mixes the turn counter with the answer id so a turn that produces no
    /// transcript change cannot re-announce the previous answer.
    private func detectIdleTransitions(_ fresh: [SessionInfo]) {
        let alive = fresh.filter(\.isAlive)
        let now = Date().timeIntervalSince1970 * 1000
        // `updatedAt` is the session file's own clock (the CLI writes it on
        // every status change), which is the timestamp that moves when a turn
        // ends — the transcript's mtime can be a minute older.
        let completed = claudeCompletionDetector.record(alive.map { session in
            (id: session.pid,
             isBusy: session.isBusy,
             turnKey: session.completionID.map { "\(session.turnCount)|\($0)" },
             fresh: now - session.updatedAt <= Self.completionFreshness * 1000)
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
        // Cursor's `turn-<byte offset>` id is already unique per delivered
        // answer, so it is its own turn key. Cursor's transcript was just read
        // (its `lastUpdatedAt` is only refreshed on a write), so freshness is
        // the runtime's own clock against that field.
        let now = Date().timeIntervalSince1970 * 1000
        let completed = cursorCompletionDetector.record(fresh.map {
            (id: $0.composerId, isBusy: $0.isBusy,
             turnKey: $0.completionID,
             fresh: now - $0.lastUpdatedAt <= Self.completionFreshness * 1000)
        })
        for id in completed {
            if let session = fresh.first(where: { $0.composerId == id }) {
                NotificationService.shared.notifyIdle(cursor: session)
            }
        }
        refreshAnyBusy()
    }

    /// Any Claude / Cursor / Codex session mid-turn: drives the main window's
    /// status pill and the busy/idle poll cadence.
    ///
    /// Deliberately **not** "any session that is not idle": a session parked on
    /// a permission prompt (`SessionStatus.waiting`) has nothing in flight, so
    /// it must not count as busy or keep the poll on the busy-tier cadence.
    /// What the user is waiting for in that state is their own input, and the
    /// card says so.
    private func refreshAnyBusy() {
        let claude = sessions.contains { $0.isAlive && $0.isBusy }
        let cursor = cursorSessions.contains { $0.isBusy }
        // Roots only: a helper is a child of a session that is itself in this
        // array, so counting it would double-report the same run and make the
        // poll cadence flip on a fan-out that the user's own turn already
        // accounts for.
        let external = activeExternalCount > 0
        let busy = claude || cursor || external
        if anySessionBusy != busy {
            anySessionBusy = busy
            startSessionPolling()
            // The 1 Hz tier exists to make the popup's resource strip feel
            // live, and Codex "active" is pure recency (a 90 s window off the
            // rollout file's mtime) that a long turn keeps refreshed — so a
            // single Codex run pinned the sampler at 1 Hz for the whole turn
            // with nothing on screen watching it. Keep `anySessionBusy`
            // accurate for the status pill and the poll cadence; only the
            // 1 Hz *sampling* rate follows visibility.
            ProcessSampler.shared.setLive(busy && UIWakePolicy.hasVisibleWindow)
        }
    }

    /// Transcript identity for one session as `enrich` last saw it: its byte
    /// size and modification date.
    ///
    /// `SessionInfo` is a value the scan builds fresh from the session file,
    /// which carries no file-system facts about the transcript — so the
    /// previous poll's numbers cannot ride on it, and reading them off
    /// `previous` (which is `sessions`, itself already stripped) would compare
    /// a transcript against itself. The store holds them instead, captured on
    /// the main thread with the limits and handed to the detached scan.
    private struct TranscriptStamp: Sendable {
        var size: UInt64
        var mtime: Double
    }

    /// One stat for both halves of the transcript identity: `transcriptSize`
    /// plus the file's own modification date. `attributesOfItem` returns both,
    /// so this is the same single stat the size check already paid for.
    private static func transcriptStamp(for session: SessionInfo) -> TranscriptStamp {
        let path = SessionMonitor.transcriptURL(for: session).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber,
              let mtime = attrs[.modificationDate] as? Date else {
            return TranscriptStamp(size: 0, mtime: 0)
        }
        return TranscriptStamp(size: size.uint64Value, mtime: mtime.timeIntervalSince1970)
    }

    /// Enrich alive sessions with transcript context + subagents. Pure
    /// function so it can run wholly off-main.
    ///
    /// The previous poll is a cache of *derived* state, so each piece names its
    /// own dependency instead of inheriting a whole record from one signal:
    ///
    ///   * cached context is keyed by the session's **identity** (a reused pid
    ///     must not donate another session's answer) and by the parent
    ///     transcript's identity — **size *and* mtime**, never size alone. A
    ///     rewrite that lands on exactly the old byte count (a replaced answer
    ///     of the same length, a compaction that pads to the same total) keeps
    ///     the size and still changes the transcript, and the mtime is the
    ///     file's own word for that; size 0 (missing or still empty) never
    ///     caches anything.
    ///   * `contextLimit` is re-derived from the live provider configuration
    ///     rather than carried with the cached tokens, because the user can
    ///     change the window while the transcript sits untouched.
    ///   * subagents and workflows are re-scanned from their own files: a child
    ///     writes its own `agent-*.jsonl`, so the parent file standing still
    ///     says nothing about whether the tree below it moved.
    private static func enrich(_ sessions: [SessionInfo], previous: [SessionInfo],
                               stamps: [Int: TranscriptStamp],
                               limits: [String: Int]) -> (sessions: [SessionInfo], stamps: [Int: TranscriptStamp]) {
        let prior = Dictionary(uniqueKeysWithValues: previous.map { ($0.pid, $0) })
        var freshStamps: [Int: TranscriptStamp] = [:]
        var result = sessions
        for i in result.indices where result[i].isAlive {
            let stamp = Self.transcriptStamp(for: result[i])
            freshStamps[result[i].pid] = stamp
            if let old = prior[result[i].pid], old.sessionId == result[i].sessionId,
               let previousStamp = stamps[result[i].pid],
               previousStamp.size == stamp.size, previousStamp.mtime == stamp.mtime, stamp.size > 0 {
                result[i].contextTokens = old.contextTokens
                result[i].model = old.model
                result[i].messageCount = old.messageCount
                result[i].currentActivity = old.currentActivity
                result[i].toolPending = old.toolPending
                result[i].pendingTool = old.pendingTool
                result[i].completionID = old.completionID
                result[i].turnCount = old.turnCount
                result[i].firstPrompt = old.firstPrompt
                result[i].contextLimit = limits[result[i].model.lowercased()] ?? 0
                result[i].transcriptSize = stamp.size
                Self.applyTranscriptBusyFallback(&result[i])
                // Children move on their own clock; see the doc comment.
                let subs = SessionMonitor.fetchSubagents(for: result[i])
                result[i].subagents = subs.direct
                result[i].workflows = subs.workflows
                continue
            }
            let ctx = SessionMonitor.fetchContext(for: result[i])
            result[i].contextTokens = ctx.tokens
            result[i].model = ctx.model
            result[i].messageCount = ctx.count
            result[i].currentActivity = ctx.activity
            result[i].toolPending = ctx.toolPending
            result[i].pendingTool = ctx.pendingTool
            result[i].completionID = ctx.completionID
            // The counter is read from a sliding transcript window, so letting
            // it fall would put the key back to a value that was already
            // announced and re-fire a completion. Clamped, not replaced: the
            // previous poll's published value is the floor, so a window shift
            // can only repeat a key, never regress one.
            let priorCount = prior[result[i].pid]?.turnCount ?? ctx.turnCount
            result[i].turnCount = max(priorCount, ctx.turnCount)
            result[i].firstPrompt = ctx.title
            result[i].transcriptSize = stamp.size
            Self.applyTranscriptBusyFallback(&result[i])
            result[i].contextLimit = limits[result[i].model.lowercased()] ?? 0
            let subs = SessionMonitor.fetchSubagents(for: result[i])
            result[i].subagents = subs.direct
            result[i].workflows = subs.workflows
        }
        return (result, freshStamps)
    }

    /// Older CLIs have no `status` field, so a dangling `tool_use` is the only
    /// evidence that the turn is still live — that is what this keeps.
    ///
    /// Older *builds of this app* also used it unconditionally, and that is the
    /// bug the `waiting` state exists to fix: a session parked on a permission
    /// prompt has a dangling `tool_use` too (the tool has not run yet), so
    /// `toolPending` alone said "busy" and the island kept saying 运行中 while
    /// the user was the one being waited on. The CLI's own `status` now
    /// distinguishes the two cases — `waiting` for parked, `busy` for actually
    /// working — so the transcript fallback is only consulted when that field
    /// is absent.
    private static func applyTranscriptBusyFallback(_ session: inout SessionInfo) {
        guard session.status == .unknown, session.toolPending else { return }
        session.status = .busy
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
        guard !cursorScanPending else { scheduleDeferredSessionPoll(); return }
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
    ///
    /// Publishes main threads *and* the sub-agents the swarm tree attaches to
    /// them. The publish set is therefore not what any counter means: every
    /// surface that answers "how many Codex sessions / how many are running"
    /// reads `ProviderStore+Derived` (`aliveExternalSessions`,
    /// `activeExternalCount`, `anyExternalBusy`, `externalSessionTree`), and
    /// each of them drops helpers or counts only the roots — single place, so
    /// the two populations cannot drift apart again. Publishing helpers also
    /// keeps `isSubagent`-aware consumers correct by construction rather than
    /// depending on the monitor having filtered them out upstream.
    private func refreshExternalSessions() {
        guard !externalScanPending else { scheduleDeferredSessionPoll(); return }
        externalScanPending = true
        Task.detached(priority: .utility) {
            let scan = ExternalSessionMonitor.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.externalScanPending = false
                var seen = Set<String>()
                let result = (scan.main + scan.subagents)
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .filter { seen.insert($0.id).inserted }
                if self.externalSessions == result { return }
                self.externalSessions = result
                // `updatedAt` is the rollout file's mtime, i.e. when Codex last
                // wrote to the thread; a `task_complete` is always the last
                // thing written before the writer goes quiet.
                let now = Date().timeIntervalSince1970 * 1000
                let completed = self.externalCompletionDetector.record(result.map {
                    (id: $0.id, isBusy: $0.isActive, turnKey: $0.completionID,
                     fresh: now - $0.updatedAt <= Self.completionFreshness * 1000)
                })
                for id in completed {
                    // Only roots have anything to resume, and "a Codex run
                    // finished" is a claim about the user's own turn, so a
                    // helper's completion is not a notification.
                    if let session = result.first(where: { $0.id == id && !$0.isSubagent }) {
                        NotificationService.shared.notifyIdle(external: session)
                    }
                }
                self.refreshAnyBusy()
            }
        }
    }

    /// Re-run the poll shortly when one had to be deferred. Deliberately cheap:
    /// the timer is one-shot, and `refreshSessions` re-kicks Cursor and Codex
    /// itself, so a single re-arm covers all three scans.
    private func scheduleDeferredSessionPoll() {
        guard deferredPollTimer == nil else { return }
        deferredPollTimer = Timer.scheduledTimer(withTimeInterval: Self.deferredPollRetry,
                                                 repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deferredPollTimer = nil
            self.refreshSessions()
        }
    }

    private func startSessionPolling() {
        sessionTimer?.invalidate()
        deferredPollTimer?.invalidate()
        deferredPollTimer = nil
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
                    self.writeWidgetSnapshot(force: true)
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
        for url in [FilePaths.settingsFile, FilePaths.codexProvidersFile] {
            PrivateFileWriter.harden(url)
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
            CLAUDE_CODE_AUTO_COMPACT_WINDOW: model.autoCompactWindow,
            CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS: model.maxConcurrentSubagents.trimmingCharacters(in: .whitespacesAndNewlines),
            CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS: model.workflowMaxConcurrentAgents.trimmingCharacters(in: .whitespacesAndNewlines)
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
            var ordered: [(name: String, amount: String)] = []
            var amounts: [UUID: String] = [:]
            for provider in groups.values {
                guard !Task.isCancelled else { return }
                let result = await BalanceFetcher.fetch(authToken: provider.token, baseURL: provider.base)
                guard !Task.isCancelled else { return }
                guard let result else { continue }
                for (id, name) in provider.ids {
                    amounts[id] = result.display
                    ordered.append((name, result.display))
                }
            }
            if balanceAmounts != amounts { balanceAmounts = amounts }
            let display = ordered.map { "\($0.name) · \($0.amount)" }.joined(separator: " / ")
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
                let (interval, weekReference) = await MainActor.run {
                    (UsageStats.interval(for: self.usagePeriod, reference: self.usageReferenceDate),
                     self.usageReferenceDate)
                }

                if wantRescan && UsageIndex.hasCachedData {
                    let quick = Self.queryUsage(in: interval)
                    let quickSources = Self.queryUsageBySource(in: interval)
                    let days = UsageIndex.fetchDaily(in: interval)
                    let weekDays = Self.queryWeekDays(reference: weekReference)
                    let dailyModels = Self.queryDailyModels(in: interval)
                    let today = Self.queryTodayUsage()
                    await MainActor.run { [weak self] in
                        guard let self, !self.usageRefreshQueued else { return }
                        self.publishTodayUsage(today)
                        self.publishUsage(quick, quickSources, days, dailyModels: dailyModels, interval: interval)
                        if self.usageWeekDays != weekDays { self.usageWeekDays = weekDays }
                    }
                }

                if wantRescan {
                    UsageIndex.updateIndex()
                }
                let final = Self.queryUsage(in: interval)
                let finalSources = Self.queryUsageBySource(in: interval)
                let days = UsageIndex.fetchDaily(in: interval)
                let weekDays = Self.queryWeekDays(reference: weekReference)
                let dailyModels = Self.queryDailyModels(in: interval)
                let today = Self.queryTodayUsage()

                let next: (again: Bool, rescan: Bool) = await MainActor.run {
                    if self.usageRefreshQueued {
                        self.usageRefreshQueued = false
                        let nextRescan = self.usageRefreshQueuedRescan
                        self.usageRefreshQueuedRescan = false
                        return (true, nextRescan)
                    }
                    // Publish and release the gate in one main-actor transaction.
                    // A new refresh cannot start between these operations.
                    self.publishTodayUsage(today)
                    self.publishUsage(final, finalSources, days, dailyModels: dailyModels, interval: interval)
                    if self.usageWeekDays != weekDays { self.usageWeekDays = weekDays }
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
                              _ days: [DayUsage],
                              dailyModels: [String: [ModelUsage]], interval: DateInterval) {
        func same(_ a: [ModelUsage], _ b: [ModelUsage]) -> Bool {
            a.count == b.count && Set(a) == Set(b)
        }
        if !same(usageStats, stats) {
            usageStats = stats
        }
        // Prices can change without tokens changing; an equal period total
        // can also have a different distribution across historical rate days.
        publishPrices(dailyModels: dailyModels)
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
        if usagePublishedInterval != interval { usagePublishedInterval = interval }
        if usageLoading { usageLoading = false }
    }

    /// Rebuild the period's cost lines and total, **day by day**.
    ///
    /// The period's tokens could be priced in one pass, and until the price
    /// table became editable that was correct. It is not any more: a user who
    /// changes a price on the 20th must not have the 1st–19th re-costed at the
    /// new rate, and the only way to hold that line is to price each day at the
    /// rate in force on that day and add the days up. The rollup already stores
    /// exactly that granularity, so this costs one extra query per publish, not
    /// a new table or a migration.
    ///
    /// Lines are still merged by recorded slug, so the card shows one line per
    /// model across the period; the split lives in the arithmetic.
    private func publishPrices(dailyModels: [String: [ModelUsage]]) {
        let estimate = ModelPricing.estimate(days: dailyModels)
        var lines: [String: ModelPricing.Estimate.Line] = [:]
        for line in estimate.lines { lines[line.model] = line }
        if usageCostLines != lines { usageCostLines = lines }
        if usageEstimate != estimate { usageEstimate = estimate }
    }

    /// Per-day, per-model aggregates for the interval — third-party rows
    /// included, so a relay-priced model is split across a price change the same
    /// way a transcript one is.
    private static func queryDailyModels(in interval: DateInterval) -> [String: [ModelUsage]] {
        UsageIndex.fetchDailyModels(in: interval)
    }

    private static func queryUsage(in interval: DateInterval) -> [ModelUsage] {
        UsageIndex.fetch(in: interval)
    }

    private static func queryUsageBySource(in interval: DateInterval) -> [UsageSource: [ModelUsage]] {
        UsageIndex.fetchBySource(in: interval)
    }

    /// The seven days of the week holding `reference`. The popup's strip is a
    /// week even when the selected period is a day, and a day-scoped
    /// `usageDays` cannot fill it.
    private static func queryWeekDays(reference: Date) -> [DayUsage] {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: reference) else { return [] }
        return UsageIndex.fetchDaily(in: week)
    }

    /// Cursor's actual charges for whatever window that store currently has,
    /// plus the window and truncation flag. Read from memory (the ledger store
    /// keeps its reading and rehydrates it from disk at launch) — **no network
    /// here.** The usage page must render from cache instantly; the ledger
    /// store does its own reading behind it and publishes when it lands.
    @MainActor
    /// Ask the ledger for the window the period chips currently describe.
    ///
    /// **Fire-and-forget and not awaited** — the page renders from whatever
    /// reading is already in memory, and this only makes the *next* one land.
    /// Called when the period changes and when the window is first shown; the
    /// ledger store owns the coalescing, the freshness window and the retry, so
    /// calling it eagerly costs nothing and a duplicate call is a no-op.
    ///
    /// The billing cycle is handed over as the fallback for a period Cursor
    /// will not answer for (年 / 全部): the ledger narrows to it and flags the
    /// reading as truncated rather than returning a slice of a year that would
    /// look like a total.
    func requestSettlement(force: Bool = false) {
        let window = UsageStats.interval(for: usagePeriod, reference: usageReferenceDate)
        // `billingCycle()` is `@MainActor` and this type is not, so the hop is
        // explicit rather than implicit: the cycle is one `PlanUsage` read off
        // an observable on the main actor.
        Task { @MainActor in
            let cycle = CursorUsageFetcher.billingCycle()
            CursorLedgerStore.shared.refresh(window: window, billingCycle: cycle, force: force)
        }
    }

    /// Today's fixed-window totals, read where the period aggregates are read.
    ///
    /// Two day bounds, not one: the pace caption ("昨日的 96%") is the only
    /// thing that makes a single day's figure readable, and querying yesterday
    /// here costs one more indexed range scan instead of a second pass over the
    /// same rollup from the view.
    private static func queryTodayUsage(now: Date = Date(), calendar: Calendar = .current) -> TodayUsage {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart

        let today = UsageIndex.fetch(in: DateInterval(start: dayStart, end: dayEnd))
        var out = TodayUsage()
        out.tokens = today.reduce(0) { $0 + $1.totalTokens }
        out.calls = today.reduce(0) { $0 + $1.calls }
        // Today is one day, so the dated form and the plain one agree — but say
        // so explicitly, because a card labelled 今日 that priced itself at some
        // other day's rate is exactly the confidently-wrong number this module's
        // rules exist to avoid.
        out.cost = ModelPricing.estimate(today, on: ModelPricing.dayKey(dayStart))
        out.yesterdayTokens = UsageIndex.fetch(in: DateInterval(start: yesterdayStart, end: dayStart))
            .reduce(0) { $0 + $1.totalTokens }
        return out
    }

    /// Same assign-only-what-changed rule as `publishUsage`: an FSEvents
    /// rescan that finds the same day totals must not re-render the dashboard
    /// cards or the popup for it.
    private func publishTodayUsage(_ fresh: TodayUsage) {
        if todayUsage != fresh { todayUsage = fresh }
    }

    private var usageWatcherStarted = false
    private var usageWatcherStoppedAt: Date?
    private var persistenceObserver: NSObjectProtocol?
    private var settlementObserver: NSObjectProtocol?
    private var priceObserver: NSObjectProtocol?
    private var proxyUsageObserver: NSObjectProtocol?

    private func startUsageWatcher() {
        guard !usageWatcherStarted else { return }
        usageWatcherStarted = true
        UsageFSWatcher.start(paths: [
            FilePaths.claudeDir.appendingPathComponent("projects").path,
            URL(fileURLWithPath: ExternalAgentKind.codex.rootDir).deletingLastPathComponent().path, // Includes archive moves.
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
        // The Cursor ledger reads on its own schedule (it is a network read for
        // whichever window the usage page has selected) and announces itself
        // when a reading lands. `rescan: false` is the point: nothing on disk
        // changed, only the money map, so the transcripts must not be walked
        // again for it.
        if settlementObserver == nil {
            settlementObserver = NotificationCenter.default.addObserver(
                forName: .cursorLedgerDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.refreshUsage(rescan: false)
            }
        }
        if proxyUsageObserver == nil {
            proxyUsageObserver = NotificationCenter.default.addObserver(
                forName: ProxyUsageStore.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.refreshUsage(rescan: false)
            }
        }
        // A price edit changes every cost line without changing one token, so
        // the cached estimate has to be rebuilt while the transcripts stay put.
        if priceObserver == nil {
            priceObserver = NotificationCenter.default.addObserver(
                forName: .modelPriceDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.refreshUsage(rescan: false)
            }
        }
    }

    // MARK: - Widget Snapshot

    /// Builds the snapshot here (it reads model state) and lets
    /// `WidgetSnapshotWriter` encode, dedupe and write it off the main thread —
    /// unchanged payloads are still skipped there.
    func writeWidgetSnapshot(force: Bool = false) {
        WidgetSnapshotWriter.submit(buildSnapshot(), force: force)
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
            busySessionCount: alive.filter(\.isBusy).count,
            sessions: alive.prefix(5).map { s in
                WidgetSnapshot.SessionSummary(
                    pid: s.pid,
                    status: s.isWaiting ? "waiting" : s.status.label,
                    model: s.model,
                    contextTokens: s.contextTokens,
                    contextLimit: s.contextLimit,
                    contextRatio: s.contextRatio,
                    projectFolder: s.projectFolder,
                    currentActivity: s.isWaiting ? s.waitingReason : s.displayActivity,
                    waiting: s.isWaiting
                )
            },
            cursorSessions: cursorSessions.prefix(5).map { s in
                WidgetSnapshot.CursorSessionSummary(
                    composerId: s.composerId,
                    status: s.isWaiting ? "waiting" : s.status.label,
                    contextRatio: s.contextRatio,
                    contextPercent: s.contextPercent,
                    projectFolder: s.projectFolder,
                    currentActivity: s.isWaiting ? "等待你确认计划" : s.displayActivity,
                    relativeUpdated: s.relativeUpdated,
                    waiting: s.isWaiting
                )
            },
            // `aliveExternalSessions`, not the raw array: since the swarm tree
            // landed, `externalSessions` carries sub-agents as well (they have
            // to be there for `externalSessionTree` to attach them), and a
            // helper is not a session the widget should list or count. This
            // read was `externalSessions.prefix(5)` while the array was
            // main-only; it is the one call site outside `ProviderStore+Derived`
            // that reads the array for a *count*, which is why it is called out.
            externalSessions: aliveExternalSessions.prefix(5).map { s in
                WidgetSnapshot.ExternalSessionSummary(
                    id: s.id,
                    status: s.isWaiting ? "waiting" : (s.isActive ? "busy" : "idle"),
                    model: s.model,
                    contextTokens: s.contextTokens,
                    contextLimit: s.contextLimit,
                    contextRatio: s.contextRatio,
                    projectFolder: s.displayName,
                    relativeUpdated: s.relativeUpdated,
                    currentActivity: s.currentActivity,
                    waiting: s.isWaiting
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
