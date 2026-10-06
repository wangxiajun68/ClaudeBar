import Darwin
import Foundation
import SQLite3

// MARK: - Model

/// A retained Codex CLI/Desktop session. Archive membership comes from the
/// desktop index; the latest rollout lifecycle event separately tracks busy
/// state. Without an index, recent rollout files are the compatibility fallback.
///
/// Codex fans work out to **sub-agents**: each gets its own rollout file whose
/// first `session_meta` record carries `parent_thread_id` + `thread_source:
/// "subagent"` + an `agent_nickname`. Those files are otherwise
/// indistinguishable from a user session (same cwd, same model), which is why
/// an ungrouped list shows dozens of near-identical cards.
struct ExternalSessionInfo: Identifiable, Equatable {
    var id: String { "\(kind.rawValue):\(sessionId)" }
    let kind: ExternalAgentKind
    let sessionId: String
    let cwd: String
    let updatedAt: Double        // epoch ms (file mtime)
    let model: String            // model declared by the tool ("" if unknown)
    /// Retained in the unarchived thread index; in the legacy fallback, live.
    /// This is visibility, not evidence that a turn is currently running.
    var isAlive: Bool
    var isActive: Bool           // an open turn that is still being written
    /// An open turn that stopped advancing — the writer is gone (crashed, or
    /// parked on an approval Codex never journals). Such a thread is listed but
    /// not running, and this is what offers it for cleanup; see
    /// `ExternalAgentKind.codex.runningWindow` for the measurement.
    var hasStalledTurn = false
    var completionID: String? = nil // completed turn id with a final assistant message
    var contextTokens: Int = 0
    var contextLimit: Int = 0

    /// Parent thread id when this rollout is a sub-agent (nil for user
    /// sessions). Set from `session_meta.parent_thread_id`.
    var parentThreadId: String? = nil
    /// `session_meta.thread_source` — `"user"` or `"subagent"`.
    var threadSource: String = ""
    /// Sub-agent display name (`"Darwin"`, `"Curie"`, …); empty for user
    /// sessions.
    var agentNickname: String = ""
    /// The `codex` process writing this rollout, when one is.
    var holderPID: Int? = nil
    /// The holder is Codex Desktop's bundled app-server, not a terminal CLI.
    var inDesktop = false
    var title: String = ""
    /// Last tool the open turn called (`exec`, `apply_patch`, …). Empty when
    /// the tail and the lookback behind it carry no call. Surfaces that only
    /// showed the model name were reading this as absent.
    var currentActivity: String = ""

    var isSubagent: Bool { parentThreadId != nil || threadSource == "subagent" }

    /// Parked on the user — always `false` for Codex today, deliberately.
    ///
    /// Claude Code writes its park into the session record (`"status":
    /// "waiting"`), Cursor writes it into the composer head
    /// (`hasPendingPlan` / `hasBlockingPendingActions`), and each has a real
    /// `isWaiting` to read. **Codex publishes no such thing on disk**, and this
    /// property exists so that fact is stated once instead of being assumed
    /// away by every surface.
    ///
    /// Verified against the installed `codex-cli 0.159.0` and this machine's
    /// rollout corpus, not assumed:
    ///
    ///   * Codex raises approvals over the **app-server JSON-RPC** protocol
    ///     (`ServerRequest::CommandExecutionRequestApproval` /
    ///     `FileChangeRequestApproval` / `PermissionsRequestApproval`), which is
    ///     a live connection, not a file — nothing about an open prompt is ever
    ///     journaled;
    ///   * across every `event_msg` in `~/.codex/sessions`, the only lifecycle
    ///     events are `task_started` / `task_complete` / `turn_aborted`; the
    ///     `item_started` event that would bracket an in-flight call is emitted
    ///     to the app-server and **never written to a rollout** (0 occurrences
    ///     in the whole corpus);
    ///   * every journaled `item_completed` carries `completed` or `failed` —
    ///     there is no `in_progress` / `pending` / `awaiting_approval` status to
    ///     read;
    ///   * the desktop index (`threads`) has an `approval_mode` column, but that
    ///     is the *policy* for the thread, not whether it is currently held.
    ///
    /// So a Codex thread parked on an approval is, from this app's point of
    /// view, indistinguishable from one whose writer simply went quiet: the
    /// rollout stops advancing and `updatedAt` ages out. That is why the park is
    /// not fabricated here — but it *is* why an open turn is only evidence of a
    /// run while it keeps being written (see
    /// `ExternalAgentKind.codex.runningWindow`). A parked thread therefore ages
    /// out on the rollout's own silence and reads idle, no matter how long
    /// Codex's app-server keeps its file open. When Codex journals a park (or
    /// exposes one over the app-server the way it does approvals), this is the
    /// one place to teach it — every surface already reads `isWaiting`.
    var isWaiting: Bool { false }

    /// Prefer the indexed task title; legacy rollouts fall back to the project.
    var displayName: String {
        if !agentNickname.isEmpty { return agentNickname }
        let indexedTitle = SessionTitle.condense(title)
        if !indexedTitle.isEmpty { return SessionTitle.shorten(indexedTitle) }
        return projectFolder.isEmpty ? kind.displayName : SessionTitle.condense(projectFolder)
    }

    var projectFolder: String { (cwd as NSString).lastPathComponent }

    /// Two-part card header: `folder · threads.title`.
    var cardLabel: SessionTitle.Label {
        // A subagent's nickname is its whole identity — the parent thread's
        // title would be misleading on the child's own card.
        SessionTitle(authored: agentNickname.isEmpty ? title : agentNickname,
                     folder: projectFolder).cardLabel
    }

    var contextRatio: Double {
        guard contextLimit > 0 else { return 0 }
        return min(1, Double(contextTokens) / Double(contextLimit))
    }

    var contextLabel: String {
        guard contextLimit > 0 || contextTokens > 0 else { return kind.displayName }
        let used = UsageStats.formatContext(contextTokens)
        if contextLimit > 0 { return "\(used) / \(UsageStats.formatContext(contextLimit))" }
        return used
    }

    /// Short "5m ago" style label since last update.
    var relativeUpdated: String {
        let secs = max(0, (Date().timeIntervalSince1970 * 1000 - updatedAt) / 1000)
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86400))d"
    }
}

/// The external agent tools we recognize, with their on-disk homes.
enum ExternalAgentKind: String, CaseIterable {
    case codex

    var displayName: String { "Codex" }

    var icon: String { "chevron.left.forwardslash.chevron.right" }

    /// Draw the client's bundled mark instead of `icon` — `true` is
    /// `ProductBrandMark`'s Codex half. A call site that positions a factor
    /// glyph says "a tool"; the page headers and section titles that *name* the
    /// client read this, so Codex is spelled the same way here as it is in the
    /// widget, the island and the popup.
    var brand: Bool { true }

    var rootDir: String {
        // Channel-split like the paths `FilePaths` hands out. Codex is the one
        // client whose root is not read from `FilePaths` — `CODEX_HOME` comes
        // first, which is how the CLI itself is relocated — so the gate has to
        // live here, and it defers to the same `codexDir` the rest of the app
        // uses. On dev that directory is inside the app's own support folder
        // and does not exist, so the scan finds nothing rather than reading the
        // user's real sessions.
        guard BuildChannel.allowsSystemIntegration else {
            return FilePaths.codexDir.appendingPathComponent("sessions").path
        }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        return URL(fileURLWithPath: home).appendingPathComponent("sessions").path
    }

    /// Bound only the legacy fallback scan when no readable index exists.
    var recencyWindow: TimeInterval { 24 * 3600 }

    /// Codex appends token_count events continuously while a turn is in
    /// flight — they land within seconds of each other.
    var busyWindow: TimeInterval { 90 }

    /// An open turn with no process holding the rollout (a crash mid-turn
    /// leaves `task_started` without `task_complete`) stops counting as live
    /// after this long without a write.
    var orphanedTurnWindow: TimeInterval { 10 * 60 }

    /// How recently a rollout must have been written for its *open turn* to
    /// still count as a run in progress.
    ///
    /// A rollout stops advancing for two very different reasons, and only one
    /// of them is a crash: the writer died mid-turn, or Codex parked the thread
    /// on an approval it never journals (see `ExternalSessionInfo.isWaiting`).
    /// Both leave `task_started` without `task_complete`, and neither is
    /// distinguishable from the other on disk — so the only honest reading of
    /// an open turn is "it was advancing a moment ago".
    ///
    /// Codex appends `token_count` within seconds of every model or tool step,
    /// so a gap this long means nothing is driving the turn. Measured across
    /// 6142 in-turn gaps in this machine's corpus: median 0 s, p99 86 s, and
    /// the two worst (3.19 h, 0.52 h) are both pre-approval stalls, not work.
    /// Deliberately below those, and it is the single knob for the trade:
    /// raising it tolerates a slower approval round trip at the cost of
    /// showing a parked thread as running for longer.
    var runningWindow: TimeInterval { 5 * 60 }

    /// How recently a sub-agent must have been written to be returned.
    ///
    /// A sub-agent is a *child of a live session*, so only a currently-running
    /// fan-out matters; unlike a main thread it is never something the user
    /// resumes, so holding its rollout open after the run ends buys nothing.
    /// Bounded well inside `busyWindow`/`orphanedTurnWindow`, which is what
    /// makes the tree's `⋯N` badge mean "running now" rather than "ran
    /// sometime today".
    var subagentRecencyWindow: TimeInterval { 5 * 60 }
}

/// Which Codex rollouts a running `codex` process holds open right now.
///
/// Both the CLI (`codex`, `codex resume`) and Codex Desktop's bundled
/// `codex app-server` keep a thread's rollout JSONL open for as long as the
/// thread is loaded. That is a statement about *where the thread lives*, not
/// about whether a turn is running: the CLI holds it for exactly as long as it
/// is running, but the managed app-server holds it while the thread is merely
/// loaded, and it never unloads a thread that is parked on an unanswered
/// approval — the observed case kept a rollout open for hours after the turn
/// died. So the holder decides resume routing (`holderPID` / `inDesktop`) and
/// nothing else; liveness comes from whether the rollout is still being written.
///
/// Listing every pid costs a few syscalls each; descriptors are read only for
/// the one or two `codex` executables — about 4 ms per scan in total.
enum CodexProcessScan {
    struct Holder: Equatable {
        let pid: Int
        /// Executable inside an app bundle (Codex Desktop's app-server).
        let inDesktop: Bool
    }

    static func openRollouts() -> [String: Holder] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [:] }

        var result: [String: Holder] = [:]
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let executable = String(cString: pathBuffer)
            guard (executable as NSString).lastPathComponent == "codex" else { continue }
            let holder = Holder(pid: Int(pid), inDesktop: executable.contains(".app/Contents/"))
            for path in openFiles(pid) where path.hasSuffix(".jsonl") && path.contains("/sessions/") {
                // A CLI holder is the more specific answer when both hold it.
                if result[path] == nil || result[path]?.inDesktop == true { result[path] = holder }
            }
        }
        return result
    }

    private static func openFiles(_ pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            paths.append(path)
        }
        return paths
    }
}

// MARK: - Monitor

/// Lists unarchived interactive Codex threads and reads live rollout state.
/// Membership matches Codex's own default thread list: `archived = 0` and a
/// session source of `cli`, `vscode`, `atlas`, or `chatgpt`. `codex exec` and
/// MCP one-shots (`exec`, `mcp`) stay out. Pure file metadata + a bounded
/// head/tail read per file, run off-main by `ProviderStore`.
///
/// Sub-agents are returned *alongside* the main threads rather than filtered
/// out, because the session page groups them under the thread that spawned
/// them (`ProviderStore.externalSessionTree` builds its `childrenOf` from rows
/// where `isSubagent`). They are never roots: `roots()` drops them, so an
/// orphaned helper cannot become a card. `fetchActive()` is the flat,
/// main-threads-only view of the same scan.
struct ExternalSessionMonitor {

    /// Main threads plus the sub-agent rows the tree needs to attach them.
    /// `fetchActive` clients want `main` only; the two are separated here so
    /// neither has to re-derive which rows are which.
    struct Scan {
        var main: [ExternalSessionInfo] = []
        var subagents: [ExternalSessionInfo] = []
    }

    static func scan() -> Scan {
        fetchCodex()
    }

    static func fetchActive() -> [ExternalSessionInfo] {
        scan().main.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Codex

    /// Parsed rollout fields cached by mtime and size. Unchanged files require
    /// only a metadata check; modified files receive bounded head/tail reads.
    private struct CodexFileCache {
        var mtime: TimeInterval
        var size: Int
        var cwd: String
        var metadataKnown: Bool
        var sourceKind: String
        var model: String
        var contextUsed: Int
        var contextLimit: Int
        var parentThreadId: String?
        var threadSource: String
        var agentNickname: String
        var spawnDepth: Int
        var hasOpenTask: Bool?
        var completionID: String?
        var activity: String
    }
    private static var codexFileCache: [String: CodexFileCache] = [:]
    /// `fetchActive` is called from detached tasks and polls can overlap, so
    /// every cache access goes through this.
    private static let codexCacheLock = NSLock()

    private static func fetchCodex() -> Scan {
        let root = ExternalAgentKind.codex.rootDir
        let now = Date().timeIntervalSince1970
        let holders = CodexProcessScan.openRollouts()
        if let indexed = indexedCodexSessions(now: now, holders: holders) { return indexed }
        // A session is only surfaced if its file was touched within the
        // recency window. Codex nests by `YYYY/MM/DD`, so the window also
        // bounds the walk: only the year and month directories it can reach
        // are worth listing at all. Without this the fallback ran a
        // `contentsOfDirectory` over every day of every month of every year on
        // each poll — cheap on a short history, unbounded on a long one, and
        // it is the *fallback* path that runs when the index is unreadable.
        //
        // Both levels are zero-padded, so directory names sort by time; the
        // comparison is still done on parsed integers rather than on the
        // strings, because "9" and "09" are both real names for September in
        // the wild and only the numbers compare correctly.
        let cutoff = now - ExternalAgentKind.codex.recencyWindow
        let cutoffParts = Calendar.current.dateComponents([.year, .month],
                                                         from: Date(timeIntervalSince1970: cutoff))
        let cutoffYear = cutoffParts.year ?? 0
        let cutoffMonth = cutoffParts.month ?? 1

        // Files that aged out of the window can never be reported again.
        codexCacheLock.lock()
        if !codexFileCache.isEmpty {
            codexFileCache = codexFileCache.filter { $0.value.mtime >= cutoff }
        }
        codexCacheLock.unlock()

        var scan = Scan()
        let fm = FileManager.default
        guard let yearDirs = try? fm.contentsOfDirectory(atPath: root).sorted().reversed() else { return Scan() }
        yearLoop: for year in yearDirs {
            guard let yearValue = Int(year) else { continue }
            guard yearValue >= cutoffYear else { break yearLoop }
            let yearPath = "\(root)/\(year)"
            guard let months = try? fm.contentsOfDirectory(atPath: yearPath).sorted().reversed() else { continue }
            for month in months {
                guard let monthValue = Int(month) else { continue }
                if yearValue == cutoffYear && monthValue < cutoffMonth { break }
                let monthPath = "\(yearPath)/\(month)"
                guard let days = try? fm.contentsOfDirectory(atPath: monthPath).sorted().reversed() else { continue }
                for day in days {
                    let dayPath = "\(monthPath)/\(day)"
                    guard let files = try? fm.contentsOfDirectory(atPath: dayPath) else { continue }
                    for file in files where file.hasSuffix(".jsonl") {
                        let path = "\(dayPath)/\(file)"
                        guard let meta = fileMeta(path: path, cutoff: cutoff) else { continue }
                        if holders[path] == nil,
                           now - meta.mtime > ExternalAgentKind.codex.orphanedTurnWindow { continue }
                        let parsed = codexFields(path: path, meta: meta)
                        guard parsed.metadataKnown else { continue }
                        let isHelper = parsed.threadSource == "subagent" || parsed.parentThreadId != nil
                        // A helper is only useful while its fan-out is running —
                        // it is never a card and never resumable — so it ages out
                        // fast; a main thread keeps the session-level window.
                        if isHelper, now - meta.mtime > ExternalAgentKind.codex.subagentRecencyWindow { continue }
                        guard isHelper
                            ? parsed.parentThreadId != nil
                            : isInteractiveMain(source: parsed.sourceKind, threadSource: parsed.threadSource)
                                && parsed.spawnDepth == 0
                        else { continue }
                        let base = (file as NSString).deletingPathExtension
                        let sessionId = String(base.suffix(36))
                        let holder = holders[path]
                        let alive = isLive(holder: holder, openTask: parsed.hasOpenTask, updated: meta.mtime, now: now)
                        guard alive else { continue }
                        let running = isRunning(openTask: parsed.hasOpenTask, updated: meta.mtime, now: now)
                        let info = ExternalSessionInfo(
                            kind: .codex,
                            sessionId: sessionId,
                            cwd: parsed.cwd,
                            updatedAt: meta.mtime * 1000,
                            model: parsed.model,
                            isAlive: alive,
                            isActive: running,
                            hasStalledTurn: parsed.hasOpenTask == true && !running,
                            completionID: parsed.completionID,
                            contextTokens: parsed.contextUsed,
                            contextLimit: parsed.contextLimit,
                            parentThreadId: parsed.parentThreadId,
                            threadSource: parsed.threadSource,
                            agentNickname: parsed.agentNickname,
                            holderPID: holder?.pid,
                            inDesktop: holder?.inDesktop ?? false,
                            currentActivity: parsed.activity
                        )
                        if isHelper { scan.subagents.append(info) } else { scan.main.append(info) }
                    }
                }
            }
            // A runaway history is capped by count as well as by date: the
            // walk stays bounded even if a directory tree is malformed.
            if scan.main.count > 400 { break yearLoop }
        }
        return scan
    }

    private struct IndexedThread {
        let id: String
        let path: String
        let cwd: String
        let updated: Double
        let title: String
        let source: String
        let threadSource: String
        /// The thread's model as the index records it. A long-lived rollout's
        /// first `turn_context` sits past the bounded head read and its newest
        /// sits past the tail window, so for exactly the sessions running right
        /// now neither file route can see it — measured on 7 of 24 rollouts on
        /// this machine, every one of them large and recent.
        let model: String
    }

    /// Whether a thread is a main (user) session, as opposed to a helper or an
    /// excluded one-shot. Expressed through the same classifier the index uses,
    /// so the two paths cannot drift on which source shapes are helpers.
    private static func isInteractiveMain(source: String, threadSource: String) -> Bool {
        threadKind(source: source, threadSource: threadSource) == .main
    }
    private static let indexLock = NSLock()
    private static var indexReadAt = Date.distantPast
    private static var indexRows: [IndexedThread]?

    /// Whether a thread is retained at all, in the legacy fallback scan: a
    /// rollout a process holds open survives until it ages out of
    /// `recencyWindow`, and one nobody holds only while its turn is open *and*
    /// was written within `orphanedTurnWindow`. The indexed path does not ask —
    /// there, archive membership decides and the row is authoritative even for
    /// an idle thread.
    ///
    /// A holder is part of retention, not of liveness. Remaining visible and
    /// currently running are different questions, and only `isRunning` answers
    /// the second; this one decides whether a thread no process has open is
    /// worth walking to at all — a held thread always is.
    private static func isLive(holder: CodexProcessScan.Holder?, openTask: Bool?,
                               updated: TimeInterval, now: TimeInterval) -> Bool {
        if holder != nil { return true }
        return openTask == true && now - updated <= ExternalAgentKind.codex.orphanedTurnWindow
    }

    /// Whether a turn is running: it is open *and* something is still writing
    /// it. The holder says only "a process still has this thread loaded", which
    /// for Codex Desktop's managed app-server is a cache entry that outlives the
    /// turn (an unanswered approval keeps the thread loaded indefinitely), so it
    /// is not consulted — see `ExternalAgentKind.codex.runningWindow`. A legacy
    /// rollout without lifecycle events falls back to writer recency.
    static func isRunning(openTask: Bool?, updated: TimeInterval, now: TimeInterval) -> Bool {
        if let openTask { return openTask && now - updated <= ExternalAgentKind.codex.runningWindow }
        return now - updated <= ExternalAgentKind.codex.busyWindow
    }

    private static func indexedCodexSessions(now: TimeInterval,
                                             holders: [String: CodexProcessScan.Holder]) -> Scan? {
        indexLock.lock()
        defer { indexLock.unlock() }
        if Date().timeIntervalSince(indexReadAt) >= 10 {
            indexRows = readThreadIndex()
            indexReadAt = Date()
        }
        guard let rows = indexRows else { return nil }
        let paths = Set(rows.map(\.path))
        codexCacheLock.lock()
        codexFileCache = codexFileCache.filter { paths.contains($0.key) }
        codexCacheLock.unlock()
        var scan = Scan()
        for row in rows {
            let meta = fileMeta(path: row.path, cutoff: 0)
            // Membership is authoritative even for idle or missing rollouts.
            let parsed = meta.map { codexFields(path: row.path, meta: $0, modelHint: row.model) }
            let updated = meta?.mtime ?? row.updated
            // A rollout is a helper when the index says so or the file header
            // carries a parent; `threadSource` alone is not enough for rows
            // written before that column existed.
            let isHelper = parsed?.threadSource == "subagent" || parsed?.parentThreadId != nil
            if isHelper {
                // Only while its fan-out is live — see `subagentRecencyWindow`.
                guard let parent = parsed?.parentThreadId, !parent.isEmpty,
                      now - updated <= ExternalAgentKind.codex.subagentRecencyWindow else { continue }
            } else {
                guard isInteractiveMain(source: row.source, threadSource: row.threadSource),
                      (parsed?.spawnDepth ?? 0) == 0 else { continue }
            }
            let holder = holders[row.path]
            let running = isRunning(openTask: parsed?.hasOpenTask, updated: updated, now: now)
            let info = ExternalSessionInfo(
                kind: .codex, sessionId: row.id,
                cwd: parsed.map { $0.cwd.isEmpty ? row.cwd : $0.cwd } ?? row.cwd,
                updatedAt: updated * 1000,
                // `codexFields` has already folded the routes — newest
                // `turn_context`, then the deeper head read, then the index row.
                model: parsed?.model ?? row.model,
                isAlive: true,
                isActive: running,
                hasStalledTurn: parsed?.hasOpenTask == true && !running,
                completionID: parsed?.completionID,
                contextTokens: parsed?.contextUsed ?? 0, contextLimit: parsed?.contextLimit ?? 0,
                parentThreadId: parsed?.parentThreadId, threadSource: parsed?.threadSource ?? "",
                agentNickname: parsed?.agentNickname ?? "",
                holderPID: holder?.pid, inDesktop: holder?.inDesktop ?? false, title: row.title,
                currentActivity: parsed?.activity ?? "")
            if isHelper { scan.subagents.append(info) } else { scan.main.append(info) }
        }
        return scan
    }

    private static func readThreadIndex() -> [IndexedThread]? {
        let home = URL(fileURLWithPath: ExternalAgentKind.codex.rootDir).deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let candidates = files.filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        guard let file = candidates.first else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent(file).path, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var info: OpaquePointer?
        var columns: Set<String> = []
        if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &info, nil) == SQLITE_OK {
            while sqlite3_step(info) == SQLITE_ROW {
                if let name = sqlite3_column_text(info, 1) { columns.insert(String(cString: name)) }
            }
        }
        sqlite3_finalize(info)
        let hasThreadSource = columns.contains("thread_source")
        // Optional like `thread_source`: the column is younger than the table,
        // and its absence must not take the whole index path down.
        let hasModel = columns.contains("model")
        var stmt: OpaquePointer?
        let sql = """
        SELECT id, rollout_path, cwd, updated_at, source, title\
        \(hasThreadSource ? ", thread_source" : "") \
        \(hasModel ? ", model" : "") \
        FROM threads WHERE archived = 0 ORDER BY updated_at DESC
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        // The SELECT appends optional columns in a fixed order; the model's
        // ordinal depends on which of the two precede it.
        let modelColumn: Int32 = hasThreadSource ? 7 : 6
        var rows: [IndexedThread] = []
        func string(_ column: Int32) -> String {
            guard let value = sqlite3_column_text(stmt, column) else { return "" }
            return String(cString: value)
        }
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            let source = string(4)
            let threadSource = hasThreadSource ? string(6) : ""
            let kind = threadKind(source: source, threadSource: threadSource)
            if kind != .excluded {
                rows.append(IndexedThread(id: string(0), path: string(1), cwd: string(2),
                                          updated: sqlite3_column_double(stmt, 3),
                                          title: string(5), source: source, threadSource: threadSource,
                                          model: hasModel ? string(modelColumn) : ""))
            }
            step = sqlite3_step(stmt)
        }
        return step == SQLITE_DONE ? rows : nil
    }

    /// What an index row *is*, since the tree needs the helpers as well as the
    /// mains.
    ///
    /// `readThreadIndex` used to keep only rows `isInteractiveMain` accepted,
    /// which by construction is exactly the set that excludes helpers — so no
    /// sub-agent from the index ever reached the tree, and the swarm surfaces
    /// stayed empty even though `state_*.sqlite` has carried 129
    /// `thread_source = 'subagent'` rows with their `parent_thread_id` all
    /// along. The split now happens here and the *consumer*
    /// (`ProviderStore.externalSessionTree`) decides what to do with each.
    enum ThreadKind { case main, helper, excluded }

    /// The single source-shape classifier: `thread/list` sources default to the
    /// interactive set, `exec` and `mcp` are one-shot runs (often under `/tmp`
    /// or `/var/folders`), and anything shaped like a fan-out is a helper. Both
    /// the index walk and the legacy rollout walk call this — directly or via
    /// `isInteractiveMain` — so neither can drift on what a helper looks like.
    private static func threadKind(source: String, threadSource: String) -> ThreadKind {
        let thread = threadSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if thread == "subagent" || thread == "agent_created_thread" || thread.contains("subagent") {
            return .helper
        }
        let raw = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty source is a legacy rollout that predates the field, judged
        // on `thread_source` alone.
        if raw.isEmpty { return thread.isEmpty || thread == "user" ? .main : .excluded }
        if raw.lowercased().contains("subagent") { return .helper }
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if object["subagent"] != nil { return .helper }
            return thread.isEmpty || thread == "user" ? .main : .excluded
        }
        switch raw.lowercased() {
        case "cli", "vscode", "atlas", "chatgpt": return .main
        default: return .excluded
        }
    }

    /// Head/tail fields for `path`, re-reading only when mtime or size moved.
    ///
    /// The model, in precedence order — most current source first:
    ///   1. the newest `turn_context`, from the tail window;
    ///   2. the index row's `model` column (`modelHint`), which Codex keeps at
    ///      the thread's current model;
    ///   3. the *earliest* `turn_context`, from the shallow head read and then
    ///      from the deeper `firstModel` read — historical, but better than
    ///      nothing when the index cannot be read.
    /// Nothing beyond (1) names the model a thread is on *now*; that is why
    /// the index outranks the first `turn_context` rather than the reverse.
    private static func codexFields(path: String, meta: (mtime: TimeInterval, size: Int),
                                    modelHint: String = "") -> CodexFileCache {
        codexCacheLock.lock()
        let hit = codexFileCache[path].flatMap { cached -> CodexFileCache? in
            cached.mtime == meta.mtime && cached.size == meta.size ? cached : nil
        }
        codexCacheLock.unlock()
        if let hit { return hit }
        let head = readHead(path: path, bytes: 32_000)
        let ctx = readCodexContext(path: path)
        let spawn = codexSpawnInfo(head: head)
        var model = ctx.model
        if model.isEmpty { model = modelHint }
        if model.isEmpty { model = headModel(in: head) }
        if model.isEmpty { model = firstModel(path: path) }
        let entry = CodexFileCache(
            mtime: meta.mtime,
            size: meta.size,
            cwd: spawn?.cwd ?? "",
            metadataKnown: spawn != nil,
            sourceKind: spawn?.sourceKind ?? "",
            model: model,
            contextUsed: ctx.used,
            contextLimit: ctx.limit,
            parentThreadId: spawn?.parentThreadId,
            threadSource: spawn?.threadSource ?? "",
            agentNickname: spawn?.nickname ?? "",
            spawnDepth: spawn?.depth ?? 0,
            hasOpenTask: ctx.hasOpenTask,
            completionID: ctx.completionID,
            activity: ctx.activity)
        codexCacheLock.lock()
        codexFileCache[path] = entry
        codexCacheLock.unlock()
        return entry
    }

    /// Only the first session_meta identifies this rollout; later records may
    /// contain copied parent metadata. Invalid metadata is never evidence of a root.
    private static func codexSpawnInfo(head: String) -> (cwd: String, sourceKind: String, parentThreadId: String?, threadSource: String, nickname: String, depth: Int)? {
        guard let firstLine = head.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first,
              firstLine.contains("\"session_meta\""),
              let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any] else { return nil }

        var sourceKind = ""
        var threadSource = (payload["thread_source"] as? String) ?? ""
        if let named = payload["source"] as? String {
            sourceKind = named
        } else if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
            threadSource = "subagent"
        }
        var nickname = (payload["agent_nickname"] as? String) ?? ""
        var depth = 0
        var parent = payload["parent_thread_id"] as? String
        if let source = payload["source"] as? [String: Any],
           let subagent = source["subagent"] as? [String: Any],
           let threadSpawn = subagent["thread_spawn"] as? [String: Any] {
            depth = JSONCoerce.intVal(threadSpawn["depth"])
            if nickname.isEmpty, let n = threadSpawn["agent_nickname"] as? String { nickname = n }
            if parent == nil, let p = threadSpawn["parent_thread_id"] as? String { parent = p }
        }
        if parent?.isEmpty == true { parent = nil }
        return (payload["cwd"] as? String ?? "", sourceKind, parent, threadSource, nickname, depth)
    }

    // MARK: Helpers

    /// mtime of a session file; nil when the file predates `cutoff` (the
    /// dominant case once a tool has a long history — mtime rejects the
    /// file without opening it).
    private static func fileMeta(path: String, cutoff: TimeInterval) -> (mtime: TimeInterval, size: Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let t = mtime.timeIntervalSince1970
        guard t >= cutoff else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return (t, size)
    }

    /// Read enough for the first metadata record, bounded at 2 MiB. The initial
    /// chunk also supplies early turn_context records when metadata is small.
    private static func readHead(path: String, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? handle.close() }
        var data = Data()
        while data.count < 2 * 1024 * 1024 {
            guard let chunk = try? handle.read(upToCount: min(bytes, 2 * 1024 * 1024 - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
            if data.contains(0x0A) { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Bytes of a rollout this monitor parses per poll when the file changed.
    /// Sized to clear a whole turn even when one record is a multi-megabyte
    /// tool output; the first record in the window costs one extra parse and is
    /// dropped, so the window is the part that matters.
    private static let codexTailWindow = 512_000
    /// How far past the window to start reading, so trimming to `codexTailWindow`
    /// leaves the window starting at a record boundary rather than mid-line.
    private static let codexTailLineSlack = 48_000

    /// The *earliest* `turn_context`'s model, from a deeper bounded read.
    ///
    /// Neither the 32 KB head nor the 512 KB tail window can see it on a
    /// long-lived rollout: the first record (`session_meta`) runs to tens of
    /// KB, so the 32 KB read ends mid-line before any `turn_context`, and the
    /// newest `turn_context` sits megabytes before EOF once the session has
    /// written a large tool body. Measured on this machine: for 7 of 24
    /// rollouts — the largest and most recent, i.e. the ones a user is
    /// actually running — the first `turn_context` sits at byte ~102 KB.
    /// 256 KB covers every measured rollout head; a miss here is a miss, not a
    /// scan, and the callers only read when the newer routes came up empty.
    private static let codexModelHeadWindow = 262_144

    private static func firstModel(path: String) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.codexModelHeadWindow),
              !data.isEmpty else { return "" }
        return headModel(in: String(decoding: data, as: UTF8.self))
    }

    private static func headModel(in head: String) -> String {
        for line in head.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "turn_context",
                  let payload = object["payload"] as? [String: Any],
                  let model = payload["model"] as? String else { continue }
            return model
        }
        return ""
    }

    /// Bounded tail parsing tracks lifecycle and current-turn usage. Partial
    /// first lines are ignored; cumulative billing is only a fallback.
    ///
    /// The window has to be able to span a whole turn, because a single record
    /// can swallow it: one local rollout carries an 11 MB `function_call_output`
    /// and a 120 KB read landed entirely inside it, so the loop sees no
    /// lifecycle event at all. A missing lifecycle used to leave `hasOpenTask`
    /// nil and the turn on the 90 s recency clock — an open `exec` that stayed
    /// quiet for two minutes read as idle. When the window itself has no
    /// lifecycle line, a bounded lookback recovers the newest
    /// `task_started` / `task_complete` / `turn_aborted` and the newest tool
    /// name, skipping records too large to be either. Turns themselves are
    /// large (69 of 85 measured root turns wrote more than the old 48 KB), so
    /// the window is sized well above the per-record norm rather than around
    /// it, and the read backs up `codexTailLineSlack` bytes first so the window
    /// can be trimmed to start on a record boundary instead of mid-line.
    private static let codexLifecycleLookback: UInt64 = 24 * 1024 * 1024
    private static let codexLifecycleLineCap = 65_536

    private static func readCodexContext(path: String) -> (used: Int, limit: Int, hasOpenTask: Bool?, model: String, completionID: String?, activity: String) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return (0, 0, nil, "", nil, "") }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // Scan for the window's record boundary in a small probe first: the
        // window has to start *after* the newline, so the probe classifies what
        // byte the cut lands on, and the read below copies the window only.
        var start = size > UInt64(Self.codexTailWindow) ? size - UInt64(Self.codexTailWindow) : 0
        let probeStart = start > UInt64(Self.codexTailLineSlack) ? start - UInt64(Self.codexTailLineSlack) : 0
        try? handle.seek(toOffset: probeStart)
        if probeStart != start, let probe = try? handle.read(upToCount: Self.codexTailLineSlack),
           let newline = probe.firstIndex(of: 0x0A) {
            start = probeStart + UInt64(probe.distance(from: probe.startIndex, to: newline) + 1)
        }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return (0, 0, nil, "", nil, "") }
        let window = Data(data.prefix(Self.codexTailWindow + Int(size - start)))
        let text = String(decoding: window, as: UTF8.self)
        var used = 0, limit = 0
        var model = ""
        var hasOpenTask: Bool?
        var completionID: String?
        var activity = ""
        var finalMessageReady = false
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            if object["type"] as? String == "turn_context" {
                if let current = payload["model"] as? String { model = current }
                continue
            }
            if object["type"] as? String == "response_item" {
                switch (payload["type"] as? String) ?? "" {
                case "message" where (payload["role"] as? String) == "assistant":
                    let phase = payload["phase"] as? String
                    let blocks = payload["content"] as? [[String: Any]] ?? []
                    finalMessageReady = (phase == nil || phase == "final_answer")
                        && blocks.contains { ($0["type"] as? String) == "output_text"
                            && !(($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                case "function_call", "custom_tool_call":
                    finalMessageReady = false
                    if let name = payload["name"] as? String, !name.isEmpty { activity = name }
                default:
                    break
                }
                continue
            }
            guard object["type"] as? String == "event_msg",
                  let eventType = payload["type"] as? String else { continue }
            if eventType == "task_started" {
                hasOpenTask = true
                completionID = nil
                finalMessageReady = false
                continue
            }
            if eventType == "task_complete" {
                hasOpenTask = false
                // `last_agent_message` is Codex's own record of what this turn
                // delivered, and it is exact: across 210 recorded completions it
                // is a non-empty string on every turn that produced a final
                // answer, null on every aborted one (`error` set), and null on
                // both the auto-compaction turn and the sub-agent-notification
                // turns — the two cases where the transcript walk below sees a
                // bare user message and no assistant reply, and would otherwise
                // have to guess. Formats that predate the field (the JSONL
                // fixtures, pre-2026-06 rollouts) fall back to the walk.
                let delivered: Bool
                if let message = payload["last_agent_message"] as? String {
                    delivered = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } else {
                    delivered = finalMessageReady
                }
                if delivered, payload["error"] == nil,
                   let turnID = payload["turn_id"] as? String, !turnID.isEmpty {
                    completionID = turnID
                }
                finalMessageReady = false
                continue
            }
            if eventType == "turn_aborted" {
                hasOpenTask = false
                completionID = nil
                finalMessageReady = false
                continue
            }
            guard eventType == "token_count",
                  let info = payload["info"] as? [String: Any] else { continue }
            if info["model_context_window"] != nil { limit = max(0, JSONCoerce.intVal(info["model_context_window"])) }
            if let last = info["last_token_usage"] as? [String: Any] {
                let total = JSONCoerce.intVal(last["total_tokens"])
                let input = JSONCoerce.intVal(last["input_tokens"])
                used = total > 0 ? total : input
            } else if let cum = info["total_token_usage"] as? [String: Any] {
                // No per-turn record anywhere in the window: fall back to the
                // cumulative total, clipped so a thread that outgrew its
                // window cannot render as "412 %".
                let total = JSONCoerce.intVal(cum["total_tokens"])
                used = limit > 0 ? min(total, limit) : total
            }
        }
        if hasOpenTask == nil, start > 0 {
            let recovered = recoverBeforeTail(handle: handle, before: start)
            hasOpenTask = recovered.open
            if activity.isEmpty { activity = recovered.activity }
        }
        return (max(0, used), limit, hasOpenTask, model, completionID, activity)
    }

    /// Newest lifecycle event and tool name in the bytes the tail window did
    /// not cover. Records larger than `codexLifecycleLineCap` are tool bodies,
    /// not lifecycle lines, and are skipped rather than parsed.
    private static func recoverBeforeTail(handle: FileHandle, before end: UInt64) -> (open: Bool?, activity: String) {
        guard end > 0 else { return (nil, "") }
        let floor = end > Self.codexLifecycleLookback ? end - Self.codexLifecycleLookback : 0
        try? handle.seek(toOffset: floor)
        guard let data = try? handle.read(upToCount: Int(end - floor)), !data.isEmpty else { return (nil, "") }
        // Work on byte boundaries before decoding: a tool output can occupy
        // almost the entire lookback, but cannot be a lifecycle record. Scan
        // backwards and stop once both newest fields have been recovered.
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let lower: Int
            if floor > 0, let newline = bytes.firstIndex(of: 0x0A) {
                lower = newline + 1
            } else {
                lower = 0
            }
            var open: Bool?
            var activity = ""
            var end = bytes.count
            while end > lower {
                var start = end
                while start > lower && bytes[start - 1] != 0x0A { start -= 1 }
                if end - start <= Self.codexLifecycleLineCap, start < end {
                    // Decode only a bounded candidate, preserving the original
                    // replacement behavior for malformed UTF-8. JSON also
                    // accepts the trailing CR in a CRLF record.
                    let line = String(decoding: bytes[start..<end], as: UTF8.self)
                    if line.contains("task_started") || line.contains("task_complete") || line.contains("turn_aborted")
                        || line.contains("function_call") || line.contains("custom_tool_call"),
                       let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                       let payload = object["payload"] as? [String: Any] {
                        if open == nil, object["type"] as? String == "event_msg",
                           let eventType = payload["type"] as? String {
                            switch eventType {
                            case "task_started": open = true
                            case "task_complete", "turn_aborted": open = false
                            default: break
                            }
                        } else if activity.isEmpty, object["type"] as? String == "response_item" {
                            let kind = payload["type"] as? String ?? ""
                            if (kind == "function_call" || kind == "custom_tool_call"),
                               let name = payload["name"] as? String, !name.isEmpty {
                                activity = name
                            }
                        }
                    }
                }
                if open != nil && !activity.isEmpty { break }
                end = start > lower ? start - 1 : lower
            }
            return (open, activity)
        }
    }
}
