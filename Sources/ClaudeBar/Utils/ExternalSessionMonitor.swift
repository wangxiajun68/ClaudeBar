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
    let startedAt: Double        // epoch ms (first record or file birth)
    let updatedAt: Double        // epoch ms (file mtime)
    let model: String            // model declared by the tool ("" if unknown)
    var isAlive: Bool
    var isActive: Bool           // touched within busyWindow → working
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
    /// Spawn depth from `source.subagent.thread_spawn.depth` (0 when absent).
    var spawnDepth: Int = 0

    var isSubagent: Bool { parentThreadId != nil || threadSource == "subagent" }

    /// Card title: the sub-agent's nickname when there is one, else the
    /// project folder.
    var displayName: String {
        if !agentNickname.isEmpty { return agentNickname }
        return projectFolder.isEmpty ? kind.displayName : projectFolder
    }

    var projectFolder: String { (cwd as NSString).lastPathComponent }

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

    var rootDir: String {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        return URL(fileURLWithPath: home).appendingPathComponent("sessions").path
    }

    /// Bound only the legacy fallback scan when no readable index exists.
    var recencyWindow: TimeInterval { 24 * 3600 }

    /// Codex appends token_count events continuously while a turn is in
    /// flight — they land within seconds of each other.
    var busyWindow: TimeInterval { 90 }
}

// MARK: - Monitor

/// Scans Codex rollout JSONLs and reports recent sessions. Pure file
/// metadata + a bounded head/tail read per file, run off-main by
/// `ProviderStore`.
struct ExternalSessionMonitor {

    static func fetchActive() -> [ExternalSessionInfo] {
        fetchCodex().sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Codex

    /// Codex writes rollout JSONLs under `~/.codex/sessions/YYYY/MM/DD/`:
    /// `rollout-<ts>-<uuid>.jsonl`. Line 1 is `session_meta` (cwd), and
    /// `turn_context` records carry the model. The transcript filename
    /// embeds the session UUID.
    /// Parsed head/tail fields for one rollout file, keyed by mtime+size.
    /// The 32 KB head read + 48 KB tail read + JSON scan ran for every file
    /// inside the 30-day window on every 2.5s poll, even though a file being
    /// appended to keeps everything before its last line unchanged. An
    /// untouched file now costs one `attributesOfItem` call.
    private struct CodexFileCache {
        var mtime: TimeInterval
        var size: Int
        var cwd: String
        var model: String
        var contextUsed: Int
        var contextLimit: Int
        var parentThreadId: String?
        var threadSource: String
        var agentNickname: String
        var spawnDepth: Int
        var hasOpenTask: Bool?
    }
    private static var codexFileCache: [String: CodexFileCache] = [:]
    /// `fetchActive` is called from detached tasks and polls can overlap, so
    /// every cache access goes through this.
    private static let codexCacheLock = NSLock()

    private static func fetchCodex() -> [ExternalSessionInfo] {
        let root = ExternalAgentKind.codex.rootDir
        let now = Date().timeIntervalSince1970
        if let indexed = indexedCodexSessions(now: now) { return indexed }
        // A session is only surfaced if its file was touched within the
        // recency window. Codex nests by year/month/day; cap the walk at the
        // 3 most recent months so a long Codex history never walks the whole
        // tree.
        let cutoff = now - ExternalAgentKind.codex.recencyWindow

        // Files that aged out of the window can never be reported again.
        codexCacheLock.lock()
        if !codexFileCache.isEmpty {
            codexFileCache = codexFileCache.filter { $0.value.mtime >= cutoff }
        }
        codexCacheLock.unlock()

        var results: [ExternalSessionInfo] = []
        let fm = FileManager.default
        guard let yearDirs = try? fm.contentsOfDirectory(atPath: root).sorted().reversed() else { return [] }
        yearLoop: for year in yearDirs {
            let yearPath = "\(root)/\(year)"
            guard let months = try? fm.contentsOfDirectory(atPath: yearPath).sorted().reversed() else { continue }
            for month in months {
                let monthPath = "\(yearPath)/\(month)"
                guard let days = try? fm.contentsOfDirectory(atPath: monthPath).sorted().reversed() else { continue }
                for day in days {
                    let dayPath = "\(monthPath)/\(day)"
                    guard let files = try? fm.contentsOfDirectory(atPath: dayPath) else { continue }
                    for file in files where file.hasSuffix(".jsonl") {
                        let path = "\(dayPath)/\(file)"
                        guard let meta = fileMeta(path: path, cutoff: cutoff) else { continue }
                        let parsed = codexFields(path: path, meta: meta)
                        guard parsed.parentThreadId == nil, parsed.threadSource != "subagent",
                              parsed.spawnDepth == 0 else { continue }
                        // `task_complete` is the authoritative end of a Codex
                        // task, including dispatched sub-agents. Old rollout
                        // formats without lifecycle events get only the brief
                        // writer-recency fallback instead of lingering for days.
                        let isRunning = parsed.hasOpenTask
                            ?? (now - meta.mtime <= ExternalAgentKind.codex.busyWindow)
                        let base = (file as NSString).deletingPathExtension
                        let sessionId = String(base.suffix(36))
                        results.append(ExternalSessionInfo(
                            kind: .codex,
                            sessionId: sessionId,
                            cwd: parsed.cwd,
                            startedAt: meta.mtime * 1000,
                            updatedAt: meta.mtime * 1000,
                            model: parsed.model,
                            isAlive: true,
                            isActive: isRunning,
                            contextTokens: parsed.contextUsed,
                            contextLimit: parsed.contextLimit,
                            parentThreadId: parsed.parentThreadId,
                            threadSource: parsed.threadSource,
                            agentNickname: parsed.agentNickname,
                            spawnDepth: parsed.spawnDepth
                        ))
                    }
                }
            }
            // History is capped: once a year's scan has crossed the window,
            // older years cannot qualify. Stop after 2 years max walk.
            if results.count > 400 { break yearLoop }
        }
        return results
    }

    private struct IndexedThread {
        let id: String
        let path: String
        let cwd: String
        let created: Double
        let updated: Double
    }
    private static let indexLock = NSLock()
    private static var indexReadAt = Date.distantPast
    private static var indexRows: [IndexedThread]?

    /// Archive membership comes from the desktop index, not rollout recency.
    /// Cache only membership; the rollout cache still updates live turn state.
    private static func indexedCodexSessions(now: TimeInterval) -> [ExternalSessionInfo]? {
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
        return rows.compactMap { row -> ExternalSessionInfo? in
            let meta = fileMeta(path: row.path, cutoff: 0)
            let parsed = meta.map { codexFields(path: row.path, meta: $0) }
            guard parsed?.parentThreadId == nil, parsed?.threadSource != "subagent",
                  (parsed?.spawnDepth ?? 0) == 0 else { return nil }
            let updated = meta?.mtime ?? row.updated
            return ExternalSessionInfo(
                kind: .codex, sessionId: row.id,
                cwd: parsed.map { $0.cwd.isEmpty ? row.cwd : $0.cwd } ?? row.cwd,
                startedAt: row.created * 1000, updatedAt: updated * 1000,
                model: parsed?.model ?? "", isAlive: true,
                isActive: parsed?.hasOpenTask ?? (now - updated <= ExternalAgentKind.codex.busyWindow),
                contextTokens: parsed?.contextUsed ?? 0, contextLimit: parsed?.contextLimit ?? 0,
                parentThreadId: parsed?.parentThreadId, threadSource: parsed?.threadSource ?? "",
                agentNickname: parsed?.agentNickname ?? "", spawnDepth: parsed?.spawnDepth ?? 0)
        }
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
        var stmt: OpaquePointer?
        let sql = "SELECT id, rollout_path, cwd, created_at, updated_at, source FROM threads WHERE archived = 0 ORDER BY updated_at DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var rows: [IndexedThread] = []
        func string(_ column: Int32) -> String {
            guard let value = sqlite3_column_text(stmt, column) else { return "" }
            return String(cString: value)
        }
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            // The indexed source survives large/truncated session_meta lines.
            let source = string(5)
            let object = source.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let isChild = source.lowercased().contains("subagent")
                || (object as? [String: Any])?["subagent"] != nil
            if isChild { step = sqlite3_step(stmt); continue }
            rows.append(IndexedThread(id: string(0), path: string(1), cwd: string(2),
                                      created: sqlite3_column_double(stmt, 3), updated: sqlite3_column_double(stmt, 4)))
            step = sqlite3_step(stmt)
        }
        return step == SQLITE_DONE ? rows : nil
    }

    /// Head/tail fields for `path`, re-reading only when mtime or size moved.
    private static func codexFields(path: String, meta: (mtime: TimeInterval, size: Int)) -> CodexFileCache {
        codexCacheLock.lock()
        let hit = codexFileCache[path].flatMap { cached -> CodexFileCache? in
            cached.mtime == meta.mtime && cached.size == meta.size ? cached : nil
        }
        codexCacheLock.unlock()
        if let hit { return hit }
        let head = readHead(path: path, bytes: 32_000)
        let ctx = readCodexContext(path: path)
        let spawn = codexSpawnInfo(head: head)
        let entry = CodexFileCache(
            mtime: meta.mtime,
            size: meta.size,
            cwd: head.field(forKey: "\"cwd\":\""),
            // Prefer the turn_context model; fall back to any "model"
            // occurrence (session_meta has none, turn_context always
            // appears within the first turns).
            model: head.field(forKey: "\"model\":\""),
            contextUsed: ctx.used,
            contextLimit: ctx.limit,
            parentThreadId: spawn.parentThreadId,
            threadSource: spawn.threadSource,
            agentNickname: spawn.nickname,
            spawnDepth: spawn.depth,
            hasOpenTask: ctx.hasOpenTask)
        codexCacheLock.lock()
        codexFileCache[path] = entry
        codexCacheLock.unlock()
        return entry
    }

    /// Parent/child fields from the head's **first** `session_meta` record —
    /// line 1 of every rollout, and the only record that carries the parent
    /// link. A sub-agent rollout embeds its parent's own `session_meta` as
    /// line 2, so this looks **only** at line 1: scanning onward for
    /// `session_meta` would find the parent's record and mistake a sub-agent
    /// for a user session.
    ///
    /// The record can exceed the 32 KB head read (`base_instructions` are
    /// large), in which case it fails to parse and the file reads as a user
    /// session — the same fallback the cwd/model scans already take.
    private static func codexSpawnInfo(head: String) -> (parentThreadId: String?, threadSource: String, nickname: String, depth: Int) {
        let empty: (parentThreadId: String?, threadSource: String, nickname: String, depth: Int) = (nil, "", "", 0)
        guard let firstLine = head.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first,
              firstLine.contains("\"session_meta\""),
              let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any] else { return empty }

        let threadSource = (payload["thread_source"] as? String) ?? ""
        var nickname = (payload["agent_nickname"] as? String) ?? ""
        var depth = 0
        var parent = payload["parent_thread_id"] as? String
        if let source = payload["source"] as? [String: Any],
           let subagent = source["subagent"] as? [String: Any],
           let threadSpawn = subagent["thread_spawn"] as? [String: Any] {
            if let d = threadSpawn["depth"] as? Int { depth = d }
            else if let d = threadSpawn["depth"] as? Double { depth = Int(d) }
            if nickname.isEmpty, let n = threadSpawn["agent_nickname"] as? String { nickname = n }
            if parent == nil, let p = threadSpawn["parent_thread_id"] as? String { parent = p }
        }
        if parent?.isEmpty == true { parent = nil }
        return (parent, threadSource, nickname, depth)
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

    /// Bounded head read of a JSONL file, returned as a String. Only the
    /// first records are needed (session_meta / turn_context / model_change
    /// all appear at the top of the file), so we never read the full
    /// transcript.
    private static func readHead(path: String, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Tail `token_count` — `last_token_usage.total_tokens` vs `model_context_window`.
    /// Latest window fill from the tail of a rollout.
    ///
    /// Two things this has to get right, both learned from the real corpus:
    ///
    /// 1. **`last_token_usage`, not `total_token_usage`.** The monitor used to
    ///    read `total_token_usage.total_tokens` as "context used". That field
    ///    is the thread's *cumulative billing* total — it keeps growing across
    ///    the whole session (measured up to 201 M against a 475 k window) — so
    ///    every long session reported a context ratio far past 100 %. The
    ///    window fill is `last_token_usage.total_tokens`, exactly as
    ///    `UsageIndex.parseCodex` reads it; this now matches
    ///    (`used ≤ limit` on 255/257 files, the other two are at 100 %).
    /// 2. **Lossy decode.** The tail read starts at an arbitrary byte offset,
    ///    so the first character is usually a split multi-byte sequence and
    ///    strict UTF-8 decoding of the whole window fails — which silently
    ///    discarded the newest lines on 59 of 291 local rollouts. Decode
    ///    lossily and let the first (partial) line fail to parse.
    private static func readCodexContext(path: String) -> (used: Int, limit: Int, hasOpenTask: Bool?) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return (0, 0, nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size - min(48_000, size))
        guard let data = try? handle.readToEnd() else { return (0, 0, nil) }
        let text = String(decoding: data, as: UTF8.self)
        var used = 0, limit = 0
        var hasOpenTask: Bool?
        for line in text.split(separator: "\n") {
            guard line.contains("\"type\":\"event_msg\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else { continue }
            if eventType == "task_started" {
                hasOpenTask = true
                continue
            }
            if eventType == "task_complete" || eventType == "turn_aborted" {
                hasOpenTask = false
                continue
            }
            guard eventType == "token_count",
                  let info = payload["info"] as? [String: Any] else { continue }
            if let w = info["model_context_window"] as? Int { limit = w }
            else if let w = info["model_context_window"] as? Double { limit = Int(w) }
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
        return (used, limit, hasOpenTask)
    }
}

// MARK: - Head-field extraction

private extension String {
    /// Value of the first `"key":"value"` occurrence in the head — a cheap
    /// prefix scan instead of parsing every JSONL record. Values are untyped
    /// path/model strings; escaped quotes inside them are impossible for
    /// cwd/model shapes these tools write.
    func field(forKey key: String) -> String {
        guard let r = range(of: key) else { return "" }
        let after = self[r.upperBound...]
        guard let q = after.firstIndex(of: "\"") else { return "" }
        return String(after[..<q])
    }
}
