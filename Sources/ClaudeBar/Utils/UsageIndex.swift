import Foundation
import SQLite3

#if canImport(Glibc)
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#else
let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
#endif

/// Persistent usage index. Each transcript is parsed once into per-(file,
/// day, model) rollup rows; queries are a GROUP BY over those rows.
///
/// Storage is SQLite: `~/Library/Application Support/ClaudeBar/usage-index.db`.
/// (A JSON/JSONL backend lived here until the settings switch that selected
/// it was removed; every profile without the leftover default has been on
/// SQLite since, so the second implementation was deleted rather than kept
/// as an unreachable branch.)
///
/// `files` tracks mtime/size/`offset` (bytes through the last complete
/// newline) and, for Codex, last cumulative totals plus the live model slug.
/// `rollup` is (path, day, model) in the user's local timezone.
///
/// Incremental maintenance:
///   - Files unchanged in mtime, size *and* first-256-byte hash are skipped.
///   - Append-only growth parses only the new bytes from `offset`; the new
///     rows are *added* to the existing rollup (upsert-with-add).
///   - Shrink/rewrite (size decreased or new file) re-parses from byte 0 and
///     replaces the path's rollup rows — stale data can never survive.
///   - Files that vanished are pruned with their rollup rows.
///
/// Codex note: per-turn usage is `last_token_usage` on `token_count`.
/// The upstream model slug is on `turn_context` (carried across appends
/// via `cx_model`). Cumulative snapshots dedupe events and provide deltas
/// when an older log omits `last_token_usage`.
struct UsageIndex {

    // MARK: - Schema / connection

    /// Under the app's own support root, from `FilePaths` — see the note on
    /// `ProxyCaptureStore.dbURL` (findings 91/400).
    private static let dbURL = FilePaths.appSupportDir.appendingPathComponent("usage-index.db")

    private static let lock = NSLock()
    private static let flagLock = NSLock()
    private static var db: OpaquePointer?
    /// When the last `sqlite3_open_v2` failed. A failed open is retried after
    /// a short cooldown rather than latched for the life of the process: the
    /// failure modes (disk full, a lock held by a crashed sibling, first-run
    /// permissions) are transient, and this used to stay broken until a
    /// relaunch because the only reset lived on the removed settings path.
    private static var openFailedAt: Date?
    private static let openRetryInterval: TimeInterval = 5
    private static var _initialBuildDone = false
    private static var _hasCachedData: Bool?

    private static func connection() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        if let db { return db }
        if let failedAt = openFailedAt, Date().timeIntervalSince(failedAt) < openRetryInterval {
            return nil
        }
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            // A failed `open_v2` may still have handed back a handle, and it
            // holds a file lock until it is closed — leaving it here keeps
            // `usage-index.db` locked while the cooldown runs. `CursorDB`
            // closes on the same branch.
            sqlite3_close(db)
            db = nil
            openFailedAt = Date()
            return nil
        }
        openFailedAt = nil
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-2000", nil, nil, nil)
        sqlite3_busy_timeout(db, 2000)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                offset INTEGER NOT NULL DEFAULT 0,
                head_hash INTEGER NOT NULL DEFAULT 0,
                cx_in INTEGER NOT NULL DEFAULT 0,
                cx_out INTEGER NOT NULL DEFAULT 0,
                cx_cached INTEGER NOT NULL DEFAULT 0,
                cx_total INTEGER NOT NULL DEFAULT 0,
                cx_model TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS rollup (
                path TEXT NOT NULL,
                day TEXT NOT NULL,
                model TEXT NOT NULL,
                calls INTEGER NOT NULL,
                input INTEGER NOT NULL,
                output INTEGER NOT NULL,
                cache_read INTEGER NOT NULL,
                cache_create INTEGER NOT NULL,
                PRIMARY KEY (path, day, model)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS rollup_day ON rollup(day);
            """, nil, nil, nil)
        guard let opened = db else { return nil }
        migrateIfNeeded(opened)
        return opened
    }

    /// v3: Codex usage switched from last-cumulative-total (dumped on the
    /// last day) to per-turn `last_token_usage`.
    /// v4: OpenClaw is no longer a usage source — drop leftover rollup rows.
    /// v5: Claude last-wins per message.id (stream partial then final).
    /// v6: Codex model slug moved from `token_count` to `turn_context`.
    /// v7: Codex buckets are now disjoint — `input_tokens` already *includes*
    ///     `cached_input_tokens`, and `output_tokens` already includes
    ///     `reasoning_output_tokens`, so storing them raw double-counted both.
    ///     Re-emitted `token_count` records (identical cumulative total) are
    ///     also skipped now, which the incremental add path had already baked
    ///     into the rollup. Both need a rebuild, not a repair.
    /// v8: v7 shipped `parseCodex` with an ungated cumulative fallback that
    ///     inflated Codex day totals on live appends; rebuild Codex again.
    /// Schema version is stamped at the latest step (currently 10).
    private static func migrateIfNeeded(_ db: OpaquePointer) {
        var stmt: OpaquePointer?
        var version: Int32 = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { version = sqlite3_column_int(stmt, 0) }
            sqlite3_finalize(stmt)
        }
        if version < 3 {
            _ = exec(db, "DELETE FROM rollup WHERE path LIKE 'codex:%' OR path LIKE 'openclaw%';")
            _ = exec(db, "DELETE FROM files WHERE path LIKE 'codex:%' OR path LIKE 'openclaw%';")
        }
        if version < 4 {
            _ = exec(db, "DELETE FROM rollup WHERE path LIKE 'openclaw%';")
            _ = exec(db, "DELETE FROM files WHERE path LIKE 'openclaw%';")
        }
        if version < 5 {
            // Claude assistant rows can repeat the same message.id (stream
            // partial then final). Rebuild so last-wins per id is applied.
            _ = exec(db, "DELETE FROM rollup WHERE path LIKE 'claude:%';")
            _ = exec(db, "DELETE FROM files WHERE path LIKE 'claude:%';")
        }
        if version < 6 {
            // Codex model names live on `turn_context`, not on token_count.
            // Incremental chunks without that record were stored as "codex".
            _ = exec(db, "ALTER TABLE files ADD COLUMN cx_model TEXT NOT NULL DEFAULT ''")
            _ = exec(db, "DELETE FROM rollup WHERE path LIKE 'codex:%';")
            _ = exec(db, "DELETE FROM files WHERE path LIKE 'codex:%';")
            _ = exec(db, "PRAGMA user_version = 6")
        }
        if version < 7 {
            // `cx_total` (last cumulative total_tokens) joins `cx_model` as
            // carried-across-append state; existing rows have neither the
            // column nor the dedupe, so rebuild Codex.
            _ = exec(db, "ALTER TABLE files ADD COLUMN cx_total INTEGER NOT NULL DEFAULT 0")
            _ = exec(db, "DELETE FROM rollup WHERE path LIKE 'codex:%';")
            _ = exec(db, "DELETE FROM files WHERE path LIKE 'codex:%';")
            _ = exec(db, "PRAGMA user_version = 7")
        }
        if version < 8 {
            // v7's rebuild ran `parseCodex` with the ungated cumulative
            // fallback: incremental chunks that were all-duplicates booked the
            // thread's cumulative total as that chunk's usage, inflating live
            // Codex day totals (measured 4x on one rollout). Any DB built by
            // v7 carries those rows, so rebuild Codex once more.
            _ = exec(db, "DELETE FROM rollup WHERE path LIKE 'codex:%';")
            _ = exec(db, "DELETE FROM files WHERE path LIKE 'codex:%';")
            _ = exec(db, "PRAGMA user_version = 8")
        }
        if version < 9 {
            // v9 makes `ModelPricing.canonical` strip a trailing effort tier
            // (`claude-opus-5-5-medium` → `claude-opus-5-5`), so Cursor's model
            // names merge onto the row the local clients already record. That
            // canonical form is baked into `costLine(for:)`'s dictionary and
            // into the usage page's grouping, but **not** into `rollup.model`,
            // which stores the raw recorded name — so no rebuild is needed
            // here. The version bump exists only so a future step that *does*
            // need one can tell this schema from v8.
            _ = exec(db, "PRAGMA user_version = 9")
        }
        if version < 10 {
            // Rebuild cumulative-only Codex events with component deltas.
            _ = exec(db, "DELETE FROM rollup WHERE path LIKE 'codex:%';")
            _ = exec(db, "DELETE FROM files WHERE path LIKE 'codex:%';")
            _ = exec(db, "PRAGMA user_version = 10")
        }
        if version < 11 {
            // v11 claims each Claude `message.id` once for the whole corpus
            // (see `UsageClaims`). Rows written before it hold both copies of
            // every resumed or forked transcript — measured 103M tokens on the
            // two days that produced them on this machine — and no repair can
            // separate them: the duplication is spread across (path, day,
            // model) rows that are individually correct per file. Delete the
            // Claude file rows so the next pass re-parses the corpus under the
            // new rule. Claude files are small and re-parsed on every change
            // anyway; the rebuild is one full corpus read, once.
            _ = exec(db, "DELETE FROM rollup WHERE path LIKE 'claude:%';")
            _ = exec(db, "DELETE FROM files WHERE path LIKE 'claude:%';")
            _ = exec(db, "PRAGMA user_version = 11")
        }
    }

    // MARK: - Public API

    /// Close SQLite (if open) so the next query / updateIndex reopens it.
    /// Used by the regression harness between scenarios; production has no
    /// backend to switch any more.
    static func reloadPersistence() {
        lock.lock()
        if let handle = db {
            sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            sqlite3_close(handle)
            db = nil
        }
        openFailedAt = nil
        lock.unlock()
        UsageClaims.reset()
        officialHeadLock.lock()
        officialHeadVerdicts = [:]
        officialHeadLock.unlock()
        sessionHeaderLock.lock()
        sessionHeaders = [:]
        sessionHeaderLock.unlock()
        flagLock.lock()
        _hasCachedData = nil
        _initialBuildDone = false
        flagLock.unlock()
    }

    /// True until the first `updateIndex()` of this app run has completed.
    /// The UI shows a spinner only when there is also no cached rollup from a
    /// previous run — otherwise period chips query immediately.
    static var needsInitialBuild: Bool {
        flagLock.lock(); defer { flagLock.unlock() }
        return !_initialBuildDone
    }

    /// True when the rollup already has rows (this process or a previous one).
    static var hasCachedData: Bool {
        if let cached = { flagLock.lock(); defer { flagLock.unlock() }; return _hasCachedData }() {
            return cached
        }
        guard let db = connection() else { return false }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM rollup LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        let hit = sqlite3_step(stmt) == SQLITE_ROW
        flagLock.lock(); _hasCachedData = hit; flagLock.unlock()
        return hit
    }

    /// Bring the index up to date with every transcript source. Incremental:
    /// unchanged files are skipped (mtime+size+head hash); cost is changed
    /// bytes, not corpus size.
    static func updateIndex() {
        let candidates = collectTranscripts()
        guard let db = connection() else { return }
        lock.lock()
        defer { lock.unlock() }

        let known = currentFiles(db)
        let live = Set(candidates.map(\.key))
        UsageClaims.begin(owners: live)

        _ = exec(db, "BEGIN")
        var seen = Set<String>()
        for file in candidates {
            guard !seen.contains(file.key) else { continue }
            seen.insert(file.key)
            sync(file: file, prior: known[file.key], db: db)
        }
        for key in known.keys where !seen.contains(key) {
            delete(db, "DELETE FROM rollup WHERE path = ?", key)
            delete(db, "DELETE FROM files WHERE path = ?", key)
        }
        _ = exec(db, "COMMIT")
        UsageClaims.flush()
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        flagLock.lock()
        _initialBuildDone = true
        _hasCachedData = true
        flagLock.unlock()
    }

    /// Aggregate per-model usage within `interval` (day/month/year/custom).
    /// Does **not** walk transcripts — call `updateIndex()` separately when
    /// the corpus may have changed.
    static func fetch(in interval: DateInterval) -> [ModelUsage] {
        let (startDay, endDay) = dayBounds(interval)
        let thirdParty = ProxyUsageStore.shared.fetch(startDay: startDay, endDay: endDay)
        guard let db = connection() else { return thirdParty }
        lock.lock(); defer { lock.unlock() }

        var stmt: OpaquePointer?
        let sql = """
            SELECT model, sum(calls), sum(input), sum(output), sum(cache_read), sum(cache_create)
            FROM rollup
            WHERE day BETWEEN ?1 AND ?2 AND path NOT LIKE 'openclaw%'
            GROUP BY model
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return thirdParty }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, startDay, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, endDay, -1, SQLITE_TRANSIENT)

        var out: [ModelUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var usage = ModelUsage(model: String(cString: sqlite3_column_text(stmt, 0)))
            usage.calls = Int(sqlite3_column_int64(stmt, 1))
            usage.inputTokens = Int(sqlite3_column_int64(stmt, 2))
            usage.outputTokens = Int(sqlite3_column_int64(stmt, 3))
            usage.cacheReadTokens = Int(sqlite3_column_int64(stmt, 4))
            usage.cacheCreationTokens = Int(sqlite3_column_int64(stmt, 5))
            if usage.totalTokens > 0 { out.append(usage) }
        }
        return ModelUsage.merged(out + thirdParty).sorted { $0.totalTokens > $1.totalTokens }
    }

    /// Lifetime usage for each requested session and its descendants. Rollup
    /// rows already own deduplicated calls; never re-add proxy traffic here.
    static func fetchSession(source: UsageSource, sessionId: String) -> [ModelUsage] {
        fetchSessionFamilies(source: source, sessionIds: [sessionId])[sessionId] ?? []
    }

    private struct SessionHeader {
        let mtime: Double
        let size: Int
        let id: String
        let parent: String?
    }
    private static let sessionHeaderLock = NSLock()
    private static var sessionHeaders: [String: SessionHeader] = [:]

    /// One indexed snapshot per client, rather than one corpus scan per island row.
    static func fetchSessionFamilies(source: UsageSource, sessionIds: [String]) -> [String: [ModelUsage]] {
        let ids = Set(sessionIds.filter { !$0.isEmpty && !$0.contains("/") })
        guard !ids.isEmpty, source != .thirdParty else { return [:] }
        let prefix = source == .claude ? "claude:" : "codex:"
        var byPath: [String: [ModelUsage]] = [:]
        var fileMeta: [String: (mtime: Double, size: Int)] = [:]
        guard let db = connection() else { return [:] }
        lock.lock()
        var stmt: OpaquePointer?
        let sql = """
            SELECT f.path, f.mtime, f.size, r.model, sum(r.calls), sum(r.input),
                   sum(r.output), sum(r.cache_read), sum(r.cache_create)
            FROM files f LEFT JOIN rollup r ON r.path = f.path
            WHERE f.path LIKE ?1 GROUP BY f.path, r.model
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { lock.unlock(); return [:] }
        sqlite3_bind_text(stmt, 1, prefix + "%", -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            fileMeta[path] = (sqlite3_column_double(stmt, 1), Int(sqlite3_column_int64(stmt, 2)))
            guard let name = sqlite3_column_text(stmt, 3) else { continue }
            byPath[path, default: []].append(ModelUsage(model: String(cString: name),
                calls: Int(sqlite3_column_int64(stmt, 4)), inputTokens: Int(sqlite3_column_int64(stmt, 5)),
                outputTokens: Int(sqlite3_column_int64(stmt, 6)), cacheReadTokens: Int(sqlite3_column_int64(stmt, 7)),
                cacheCreationTokens: Int(sqlite3_column_int64(stmt, 8))))
        }
        sqlite3_finalize(stmt)
        lock.unlock()
        var parents: [String: String] = [:], pathIDs: [String: String] = [:]
        if source == .codex {
            sessionHeaderLock.lock()
            defer { sessionHeaderLock.unlock() }
            sessionHeaders = sessionHeaders.filter { fileMeta[$0.key] != nil }
            for (path, meta) in fileMeta {
                var header = sessionHeaders[path]
                if header?.mtime != meta.mtime || header?.size != meta.size {
                    header = nil
                    let url = URL(fileURLWithPath: String(path.dropFirst(prefix.count)))
                    if let handle = try? FileHandle(forReadingFrom: url) {
                        let data = try? handle.read(upToCount: 65_536)
                        try? handle.close()
                        if let first = data?.split(separator: 10).first,
                           let row = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
                           row["type"] as? String == "session_meta",
                           let payload = row["payload"] as? [String: Any],
                           let id = payload["id"] as? String ?? payload["session_id"] as? String {
                            let spawn = ((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
                            let parent = payload["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String
                            header = SessionHeader(mtime: meta.mtime, size: meta.size, id: id, parent: parent)
                        }
                    }
                    sessionHeaders[path] = header
                }
                guard let header else { continue }
                pathIDs[path] = header.id
                if let parent = header.parent, !parent.isEmpty { parents[header.id] = parent }
            }
        }
        return sessionFamilyRollups(source: source, ids: ids, byPath: byPath, pathIDs: pathIDs, parents: parents)
    }

    /// Route each transcript once. Memoized requested ancestors eliminate the
    /// per-request corpus scan and repeated parent walks; cycles share a set.
    static func sessionFamilyRollups(source: UsageSource, ids: Set<String>, byPath: [String: [ModelUsage]],
                                     pathIDs: [String: String], parents: [String: String]) -> [String: [ModelUsage]] {
        // Share immutable requested-ancestor links. Copying a Set per node
        // would consume quadratic memory when every node in a deep chain is
        // requested, even if only one leaf has usage.
        final class RequestedAncestors {
            let ids: [String]
            let next: RequestedAncestors?
            init(ids: [String], next: RequestedAncestors? = nil) { self.ids = ids; self.next = next }
        }
        let empty = RequestedAncestors(ids: [])
        var ancestorsByID: [String: RequestedAncestors] = [:]
        func ancestors(of start: String) -> RequestedAncestors {
            if let cached = ancestorsByID[start] { return cached }
            var trail: [String] = [], positions: [String: Int] = [:]
            var current: String? = start
            while let node = current, ancestorsByID[node] == nil, positions[node] == nil {
                positions[node] = trail.count; trail.append(node)
                current = parents[node]
            }
            var matched = current.flatMap { ancestorsByID[$0] } ?? empty
            if let node = current, let cycleStart = positions[node] {
                // Every node in a parent cycle reaches every other cycle node.
                let cycle = trail[cycleStart...]
                matched = RequestedAncestors(ids: cycle.filter { ids.contains($0) })
                for member in cycle { ancestorsByID[member] = matched }
                trail.removeSubrange(cycleStart...)
            }
            for node in trail.reversed() {
                if ids.contains(node) { matched = RequestedAncestors(ids: [node], next: matched) }
                ancestorsByID[node] = matched
            }
            return ancestorsByID[start] ?? matched
        }
        var grouped: [String: [String: ModelUsage]] = [:]
        for (path, rows) in byPath {
            var matched: Set<String> = []
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            if source == .claude {
                if let leaf = components.last, components.count > 1, leaf.hasSuffix(".jsonl") {
                    let id = String(leaf.dropLast(6))
                    if ids.contains(id) { matched.insert(id) }
                }
                // Preserve matching at every /id/subagents/ boundary, including
                // nested workflows and paths with repeated directory names.
                for i in components.indices where i > 1 && i + 1 < components.count && components[i] == "subagents" {
                    let id = String(components[i - 1])
                    if ids.contains(id) { matched.insert(id) }
                }
            } else {
                if let id = pathIDs[path] {
                    var link: RequestedAncestors? = ancestors(of: id)
                    while let node = link {
                        matched.formUnion(node.ids)
                        link = node.next
                    }
                }
                // Filename fallback remains independent of the metadata ID.
                // IDs may themselves contain hyphens: check all suffixes once.
                if let leaf = components.last, leaf.hasSuffix(".jsonl") {
                    let stem = leaf.dropLast(6)
                    for index in stem.indices where stem[index] == "-" {
                        let id = String(stem[stem.index(after: index)...])
                        if ids.contains(id) { matched.insert(id) }
                    }
                }
            }
            for id in matched {
                for row in rows {
                    grouped[id, default: [:]][row.model, default: ModelUsage(model: row.model)].merge(row)
                }
            }
        }
        var result: [String: [ModelUsage]] = [:]
        for id in ids {
            result[id] = (grouped[id].map { Array($0.values) } ?? [])
                .filter { $0.totalTokens > 0 }.sorted { $0.totalTokens > $1.totalTokens }
        }
        return result
    }

    /// Per-model usage within `interval`, tagged by where it came from. Same
    /// interval rules as `fetch`; the Codex/Claude split is the rollup `path`
    /// prefix, third-party comes from the proxy's own rollup.
    static func fetchBySource(in interval: DateInterval) -> [UsageSource: [ModelUsage]] {
        let (startDay, endDay) = dayBounds(interval)
        var out: [UsageSource: [ModelUsage]] = [:]
        out[.claude] = taggedFetch(startDay: startDay, endDay: endDay, prefix: "claude:")
        out[.codex] = taggedFetch(startDay: startDay, endDay: endDay, prefix: "codex:")
        out[.thirdParty] = ProxyUsageStore.shared.fetch(startDay: startDay, endDay: endDay)
        return out
    }

    /// Read-only attribution from indexed period rows and each rollout header.
    /// Called off the main actor; never reads auth/config files or infers from model names.
    static func fetchOfficialCodex(in interval: DateInterval) -> [ModelUsage] {
        let (startDay, endDay) = dayBounds(interval)
        guard let db = connection() else { return [] }
        lock.lock()
        var stmt: OpaquePointer?
        let sql = """
            SELECT r.path, r.model, sum(r.calls), sum(r.input), sum(r.output), sum(r.cache_read), sum(r.cache_create),
                   f.mtime, f.size
            FROM rollup r LEFT JOIN files f ON f.path = r.path
            WHERE r.day BETWEEN ?1 AND ?2 AND r.path LIKE 'codex:%' GROUP BY r.path, r.model
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { lock.unlock(); return [] }
        sqlite3_bind_text(stmt, 1, startDay, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, endDay, -1, SQLITE_TRANSIENT)
        var byPath: [String: [ModelUsage]] = [:]
        var meta: [String: (mtime: Double, size: Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            var usage = ModelUsage(model: String(cString: sqlite3_column_text(stmt, 1)))
            usage.calls = Int(sqlite3_column_int64(stmt, 2))
            usage.inputTokens = Int(sqlite3_column_int64(stmt, 3))
            usage.outputTokens = Int(sqlite3_column_int64(stmt, 4))
            usage.cacheReadTokens = Int(sqlite3_column_int64(stmt, 5))
            usage.cacheCreationTokens = Int(sqlite3_column_int64(stmt, 6))
            byPath[path, default: []].append(usage)
            if sqlite3_column_type(stmt, 7) != SQLITE_NULL {
                meta[path] = (sqlite3_column_double(stmt, 7), Int(sqlite3_column_int64(stmt, 8)))
            }
        }
        sqlite3_finalize(stmt)
        lock.unlock()
        var models: [String: ModelUsage] = [:]
        officialHeadLock.lock()
        defer { officialHeadLock.unlock() }
        // Drop verdicts for paths the period no longer mentions (deleted or
        // pruned rollouts), so the memo cannot grow without bound — the same
        // filter `fetchSessionFamilies` applies to `sessionHeaders`.
        officialHeadVerdicts = officialHeadVerdicts.filter { byPath[$0.key] != nil }
        for (path, rows) in byPath {
            // The verdict only depends on the file's first line, and its
            // `files` row already carries the (mtime, size) that says whether
            // that line could have changed — the same memoization
            // `fetchSessionFamilies` applies to rollout headers. Without it,
            // every republish during an active session re-opened and re-read
            // 64 KiB of *every* Codex rollout in the period (measured: a
            // month window with ~200 rollouts, ~2.5 passes/s struck by the
            // FSEvents watcher).
            let isOfficial: Bool
            if let fileMeta = meta[path], let cached = officialHeadVerdicts[path],
               cached.mtime == fileMeta.mtime, cached.size == fileMeta.size {
                isOfficial = cached.isOfficial
            } else {
                let url = URL(fileURLWithPath: String(path.dropFirst("codex:".count)))
                var verdict = false
                if let handle = try? FileHandle(forReadingFrom: url) {
                    let header = try? handle.read(upToCount: 65_536)
                    try? handle.close()
                    if let header { verdict = UsageProviderAttribution.isOfficialCodex(metadata: header) }
                }
                if let fileMeta = meta[path] {
                    officialHeadVerdicts[path] = OfficialHead(mtime: fileMeta.mtime, size: fileMeta.size, isOfficial: verdict)
                }
                isOfficial = verdict
            }
            guard isOfficial else { continue }
            for row in rows {
                var merged = models[row.model] ?? ModelUsage(model: row.model)
                merged.merge(row)
                models[row.model] = merged
            }
        }
        return models.values.sorted { $0.totalTokens > $1.totalTokens }
    }

    private struct OfficialHead {
        let mtime: Double
        let size: Int
        let isOfficial: Bool
    }
    private static let officialHeadLock = NSLock()
    private static var officialHeadVerdicts: [String: OfficialHead] = [:]

    /// Per-day totals within `interval`, tagged by source (river chart).
    static func fetchDailyBySource(in interval: DateInterval) -> [UsageSource: [DayUsage]] {
        let (startDay, endDay) = dayBounds(interval)
        var out: [UsageSource: [DayUsage]] = [:]
        out[.claude] = taggedDaily(startDay: startDay, endDay: endDay, prefix: "claude:")
        out[.codex] = taggedDaily(startDay: startDay, endDay: endDay, prefix: "codex:")
        out[.thirdParty] = ProxyUsageStore.shared.fetchDaily(startDay: startDay, endDay: endDay)
        return out
    }

    /// One batch for the island's daily tokens and prices; never query on hover.
    static func fetchDailyModels(in interval: DateInterval) -> [String: [ModelUsage]] {
        let (start, end) = dayBounds(interval)
        var days = ProxyUsageStore.shared.fetchDailyModels(startDay: start, endDay: end)
        guard let db = connection() else { return days }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = """
            SELECT day, model, sum(calls), sum(input), sum(output), sum(cache_read), sum(cache_create)
            FROM rollup WHERE day BETWEEN ?1 AND ?2
                AND (path LIKE 'claude:%' OR path LIKE 'codex:%')
            GROUP BY day, model
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return days }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, start, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, end, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let day = String(cString: sqlite3_column_text(stmt, 0))
            let model = String(cString: sqlite3_column_text(stmt, 1))
            days[day, default: []].append(ModelUsage(model: model,
                calls: Int(sqlite3_column_int64(stmt, 2)),
                inputTokens: Int(sqlite3_column_int64(stmt, 3)),
                outputTokens: Int(sqlite3_column_int64(stmt, 4)),
                cacheReadTokens: Int(sqlite3_column_int64(stmt, 5)),
                cacheCreationTokens: Int(sqlite3_column_int64(stmt, 6))))
        }
        return days.mapValues { ModelUsage.merged($0) }
    }

    /// Inclusive local-day bounds for an interval. `DateInterval.end` is
    /// exclusive, so the last day that actually belongs to the period is the
    /// one containing `end - 1s`.
    private static func dayBounds(_ interval: DateInterval) -> (start: String, end: String) {
        (ModelPricing.dayKey(interval.start), ModelPricing.dayKey(interval.end.addingTimeInterval(-1)))
    }

    private static func taggedFetch(startDay: String, endDay: String, prefix: String) -> [ModelUsage] {
        guard let db = connection() else { return [] }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = """
            SELECT model, sum(calls), sum(input), sum(output), sum(cache_read), sum(cache_create)
            FROM rollup
            WHERE day BETWEEN ?1 AND ?2 AND path LIKE ?3
            GROUP BY model
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, startDay, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, endDay, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, prefix + "%", -1, SQLITE_TRANSIENT)
        var out: [ModelUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var usage = ModelUsage(model: String(cString: sqlite3_column_text(stmt, 0)))
            usage.calls = Int(sqlite3_column_int64(stmt, 1))
            usage.inputTokens = Int(sqlite3_column_int64(stmt, 2))
            usage.outputTokens = Int(sqlite3_column_int64(stmt, 3))
            usage.cacheReadTokens = Int(sqlite3_column_int64(stmt, 4))
            usage.cacheCreationTokens = Int(sqlite3_column_int64(stmt, 5))
            if usage.totalTokens > 0 { out.append(usage) }
        }
        return out.sorted { $0.totalTokens > $1.totalTokens }
    }

    private static func taggedDaily(startDay: String, endDay: String, prefix: String) -> [DayUsage] {
        guard let db = connection() else { return [] }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = """
            SELECT day, sum(input), sum(output), sum(cache_read), sum(cache_create)
            FROM rollup
            WHERE day BETWEEN ?1 AND ?2 AND path LIKE ?3
            GROUP BY day ORDER BY day
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, startDay, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, endDay, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, prefix + "%", -1, SQLITE_TRANSIENT)
        var out: [DayUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var day = DayUsage(day: String(cString: sqlite3_column_text(stmt, 0)))
            day.inputTokens = Int(sqlite3_column_int64(stmt, 1))
            day.outputTokens = Int(sqlite3_column_int64(stmt, 2))
            day.cacheReadTokens = Int(sqlite3_column_int64(stmt, 3))
            day.cacheCreationTokens = Int(sqlite3_column_int64(stmt, 4))
            if day.totalTokens > 0 { out.append(day) }
        }
        return out
    }

    /// Per-day totals for the river chart. Same interval rules as `fetch`.
    static func fetchDaily(in interval: DateInterval) -> [DayUsage] {
        let (startDay, endDay) = dayBounds(interval)
        let thirdParty = ProxyUsageStore.shared.fetchDaily(startDay: startDay, endDay: endDay)
        guard let db = connection() else { return thirdParty }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = """
            SELECT day, sum(input), sum(output), sum(cache_read), sum(cache_create)
            FROM rollup
            WHERE day BETWEEN ?1 AND ?2 AND path NOT LIKE 'openclaw%'
            GROUP BY day ORDER BY day
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return thirdParty }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, startDay, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, endDay, -1, SQLITE_TRANSIENT)
        var out: [DayUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var day = DayUsage(day: String(cString: sqlite3_column_text(stmt, 0)))
            day.inputTokens = Int(sqlite3_column_int64(stmt, 1))
            day.outputTokens = Int(sqlite3_column_int64(stmt, 2))
            day.cacheReadTokens = Int(sqlite3_column_int64(stmt, 3))
            day.cacheCreationTokens = Int(sqlite3_column_int64(stmt, 4))
            if day.totalTokens > 0 { out.append(day) }
        }
        return mergedDays(out + thirdParty)
    }

    private static func mergedDays(_ rows: [DayUsage]) -> [DayUsage] {
        var days: [String: DayUsage] = [:]
        for row in rows {
            var day = days[row.day] ?? DayUsage(day: row.day)
            day.inputTokens += row.inputTokens
            day.outputTokens += row.outputTokens
            day.cacheReadTokens += row.cacheReadTokens
            day.cacheCreationTokens += row.cacheCreationTokens
            days[row.day] = day
        }
        return days.values.sorted { $0.day < $1.day }
    }

    // MARK: - Per-file sync

    private struct KnownFile {
        let mtime: TimeInterval
        let size: Int
        let offset: Int
        let headHash: Int64
        let cxIn: Int
        let cxOut: Int
        let cxCached: Int
        let cxTotal: Int
        let cxModel: String
    }

    /// FNV-1a of the first `length` bytes — stable across launches, unlike
    /// `Data.hashValue`. Reads at most `length` bytes, never the whole file.
    private static func headHash(_ path: String, length: Int) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return 0 }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: length)
        var hash: UInt64 = 0xcbf29ce484222325
        for b in data {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return Int64(bitPattern: hash)
    }

    /// Parse one file's new bytes and fold them into the index.
    private static func sync(file: Candidate, prior: KnownFile?, db: OpaquePointer) {
        let kind = file.key.prefix(while: { $0 != ":" })
        let isCodex = kind == "codex"

        let storedHash = prior?.headHash ?? 0
        // A file whose mtime and size are unchanged is normally skipped
        // without opening it, which is what makes a rescan cost one `stat` per
        // transcript. But a restore that preserves both — `cp -p`, `rsync -a`,
        // an unarchive — can still have different bytes, and skipping on the
        // metadata alone would keep its stale rollup rows forever (every later
        // pass takes the same early return). The 256-byte head hash is the
        // tie-breaker; a row written before the column existed (`storedHash`
        // of 0) keeps the old metadata-only behaviour until its next rewrite.
        if let prior, prior.mtime == file.mtime, prior.size == file.size, prior.offset <= file.size,
           storedHash == 0 || headHash(file.path, length: 256) == storedHash {
            return
        }

        let currentHash = (prior != nil && file.size >= prior!.size) ? headHash(file.path, length: 256) : 0
        let headMatches = storedHash != 0 && currentHash == storedHash
        let canAppend = prior != nil && file.size > prior!.size && prior!.offset <= file.size
            && (storedHash == 0 || headMatches)

        if isCodex, canAppend, let prior {
            let chunk = readBytes(file.path, from: prior.offset)
            guard !chunk.isEmpty else { return }
            // Parse complete lines only; the trailing partial line (if any)
            // is left for the next append to complete. `consumed` is the byte
            // count of the complete lines, so the offset stored below stops
            // before the partial one and it is re-read once terminated.
            let (lines, consumed) = completeLines(chunk)
            guard consumed > 0 else { return }

            // `cxTotal` carries the last cumulative total across the append
            // boundary so a re-emitted token_count straddling it is still
            // recognized as a duplicate.
            let parsed = parseCodex(lines, previousModel: prior.cxModel,
                                    previousTotal: prior.cxTotal, previousInput: prior.cxIn,
                                    previousOutput: prior.cxOut, previousCached: prior.cxCached)
            if parsed.entries.isEmpty {
                upsertFile(db, file, prior.offset + consumed,
                           cxIn: parsed.last?.input ?? prior.cxIn, cxOut: parsed.last?.output ?? prior.cxOut,
                           cxCached: parsed.last?.cached ?? prior.cxCached,
                           cxTotal: parsed.last?.total ?? prior.cxTotal,
                           cxModel: parsed.model)
                return
            }
            addRollup(db, file.key, parsed.entries)
            let last = parsed.last
            upsertFile(db, file, prior.offset + consumed,
                       cxIn: last?.input ?? prior.cxIn,
                       cxOut: last?.output ?? prior.cxOut,
                       cxCached: last?.cached ?? prior.cxCached,
                       cxTotal: last?.total ?? prior.cxTotal,
                       cxModel: parsed.model)
            return
        }

        // Claude's assistant stream rewrites the same `message.id` as a call
        // finalizes (partial output 0 → real numbers), so an append can only
        // be folded additively when **none** of its ids is one this file
        // already books — measured on this machine's live transcripts, 64 %
        // of assistant lines reprint an earlier id, almost always the
        // immediately preceding line, which is why this check has to be by id
        // and not by line. A chunk whose ids are all unseen is a pure append:
        // parse the new bytes only and advance the offset, O(new bytes)
        // instead of O(file). A reprint falls through to the full reparse,
        // whose last-wins fold is the only thing that can replace a partial's
        // numbers with the final ones without double counting.
        if canAppend, let prior {
            let chunk = readBytes(file.path, from: prior.offset)
            guard !chunk.isEmpty else { return }
            let (lines, consumed) = completeLines(chunk)
            guard consumed > 0 else { return }
            let parsed = parseClaude(lines)
            let owned = UsageClaims.owned(by: file.key)
            let reprints = parsed.contains { !$0.id.isEmpty && owned.contains($0.id) }
            if !reprints {
                let booked = claimClaudeAppend(parsed, path: file.key)
                if !booked.isEmpty { addRollup(db, file.key, booked) }
                upsertFile(db, file, prior.offset + consumed, cxIn: 0, cxOut: 0, cxCached: 0)
                return
            }
        }

        // Full (re)parse: brand-new file, or it shrank / was rewritten.
        guard let data = FileManager.default.contents(atPath: file.path) else { return }
        let (lines, consumed) = completeLines(data)
        if prior != nil { deleteRollup(db, file.key) }

        if isCodex {
            let parsed = parseCodex(lines, previousModel: "")
            // Replace even when nothing was parsed: `deleteRollup` above is a
            // no-op for the JSON backend, so an unconditional `replaceRollup`
            // is what makes a rewrite-to-empty — or a shrink to a header-only
            // body — drop the path's stale rows there too. SQLite has already
            // deleted them and `bindAndRun` over an empty array adds nothing.
            replaceRollup(db, file.key, parsed.entries)
            let last = parsed.last
            upsertFile(db, file, consumed,
                       cxIn: last?.input ?? 0, cxOut: last?.output ?? 0, cxCached: last?.cached ?? 0,
                       cxTotal: last?.total ?? 0,
                       cxModel: parsed.model)
        } else {
            // Claude: one claim per `message.id` for the whole corpus, so a
            // resumed or forked transcript cannot book its parent's calls a
            // second time. The file's rollup is replaced in full, so dropping
            // a duplicate entry is enough — no stale row survives.
            replaceRollup(db, file.key, claimClaude(parseClaude(lines), path: file.key))
            upsertFile(db, file, consumed, cxIn: 0, cxOut: 0, cxCached: 0)
        }
    }

    // MARK: - File discovery

    private struct Candidate {
        let key: String        // prefixed path, e.g. "claude:/Users/…/x.jsonl"
        let path: String
        let mtime: TimeInterval
        let size: Int
    }

    private static func collectTranscripts() -> [Candidate] {
        var out: [Candidate] = []
        out.append(contentsOf: collectClaude())
        out.append(contentsOf: collectExternal(kind: .codex))
        return out
    }

    /// Every candidate is re-stat'd on every index pass, so this used to be
    /// the hottest syscall in the app: ~1,250 files × 2 calls per rescan, and a
    /// rescan fires on every FSEvents burst. `attributesOfItem` goes through
    /// `getxattr` twice for the resource fork / Finder info, so a project tree
    /// of this size cost thousands of five-syscall round trips off a directory
    /// listing that already has `mtime` and `size` in hand.
    ///
    /// A `subtrees: .files` enumerator yields each entry with its attribute
    /// dictionary already populated — one `getattrlist` for a whole directory
    /// instead of one `stat` + two `getxattr` per file, and it is the same
    /// shape `ExternalSessionMonitor` already uses.
    private static let entryMetaKeys: [URLResourceKey] = [
        .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
    ]

    private static func collectClaude() -> [Candidate] {
        collectFromEnumerator(root: FilePaths.claudeDir.appendingPathComponent("projects"),
                               keyPrefix: "claude:")
    }

    /// Walk an external tool's directory tree. Codex nests year/month/day;
    /// files may also sit directly in upper levels.
    private static func collectExternal(kind: ExternalAgentKind) -> [Candidate] {
        let sessions = URL(fileURLWithPath: kind.rootDir)
        let archive = sessions.deletingLastPathComponent().appendingPathComponent("archived_sessions")
        return collectFromEnumerator(root: sessions, keyPrefix: "\(kind.rawValue):")
            + collectFromEnumerator(root: archive, keyPrefix: "\(kind.rawValue):")
    }

    /// Depth-limited recursive walk over `root`, reading mtime/size from the
    /// enumerator's attributes instead of stat'ing each hit.
    private static func collectFromEnumerator(root: URL, keyPrefix: String) -> [Candidate] {
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: entryMetaKeys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var out: [Candidate] = []
        while let url = en.nextObject() as? URL {
            guard url.pathExtension == "jsonl", !url.lastPathComponent.contains(".trajectory") else { continue }
            guard let meta = meta(of: url) else { continue }
            // The enumerator returns absolute URLs, sometimes resolved through
            // a symlink (/var → /private/var). Rebuilding from the basename
            // discarded nested directories and made those files unreadable.
            out.append(Candidate(key: keyPrefix + url.path, path: url.path,
                                 mtime: meta.mtime, size: meta.size))
        }
        return out
    }

    private static func meta(of url: URL) -> (mtime: TimeInterval, size: Int)? {
        guard let values = try? url.resourceValues(forKeys: Set(entryMetaKeys)),
              values.isRegularFile == true,
              let mtime = values.contentModificationDate else { return nil }
        return (mtime.timeIntervalSince1970, values.fileSize ?? 0)
    }

    // MARK: - DB helpers

    private static func currentFiles(_ db: OpaquePointer) -> [String: KnownFile] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path, mtime, size, offset, head_hash, cx_in, cx_out, cx_cached, cx_total, cx_model FROM files", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: KnownFile] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            let modelPtr = sqlite3_column_text(stmt, 9)
            out[path] = KnownFile(
                mtime: sqlite3_column_double(stmt, 1),
                size: Int(sqlite3_column_int64(stmt, 2)),
                offset: Int(sqlite3_column_int64(stmt, 3)),
                headHash: sqlite3_column_int64(stmt, 4),
                cxIn: Int(sqlite3_column_int64(stmt, 5)),
                cxOut: Int(sqlite3_column_int64(stmt, 6)),
                cxCached: Int(sqlite3_column_int64(stmt, 7)),
                cxTotal: Int(sqlite3_column_int64(stmt, 8)),
                cxModel: modelPtr.map { String(cString: $0) } ?? "")
        }
        return out
    }

    private static func delete(_ db: OpaquePointer, _ sql: String, _ path: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private static func deleteRollup(_ db: OpaquePointer, _ path: String) {
        delete(db, "DELETE FROM rollup WHERE path = ?", path)
    }

    private static func upsertFile(_ db: OpaquePointer, _ file: Candidate, _ offset: Int,
                                   cxIn: Int, cxOut: Int, cxCached: Int,
                                   cxTotal: Int = 0, cxModel: String = "") {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO files(path,mtime,size,offset,head_hash,cx_in,cx_out,cx_cached,cx_total,cx_model) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, file.key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, file.mtime)
        sqlite3_bind_int64(stmt, 3, Int64(file.size))
        sqlite3_bind_int64(stmt, 4, Int64(offset))
        sqlite3_bind_int64(stmt, 5, headHash(file.path, length: 256))
        sqlite3_bind_int64(stmt, 6, Int64(cxIn))
        sqlite3_bind_int64(stmt, 7, Int64(cxOut))
        sqlite3_bind_int64(stmt, 8, Int64(cxCached))
        sqlite3_bind_int64(stmt, 9, Int64(cxTotal))
        sqlite3_bind_text(stmt, 10, cxModel, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// Full replacement of a path's rollup (used on full reparse; caller has
    /// already deleted old rows).
    private static func replaceRollup(_ db: OpaquePointer, _ path: String, _ entries: [ParsedEntry]) {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO rollup(path,day,model,calls,input,output,cache_read,cache_create) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        bindAndRun(stmt, path, ParsedEntry.aggregated(entries))
    }

    /// Additive fold of appended bytes into the existing rollup rows.
    private static func addRollup(_ db: OpaquePointer, _ path: String, _ entries: [ParsedEntry]) {
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO rollup(path,day,model,calls,input,output,cache_read,cache_create)
            VALUES(?1,?2,?3,?4,?5,?6,?7,?8)
            ON CONFLICT(path,day,model) DO UPDATE SET
                calls = calls + excluded.calls,
                input = input + excluded.input,
                output = output + excluded.output,
                cache_read = cache_read + excluded.cache_read,
                cache_create = cache_create + excluded.cache_create
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        bindAndRun(stmt, path, ParsedEntry.aggregated(entries))
    }

    private static func bindAndRun(_ stmt: OpaquePointer, _ path: String, _ entries: [ParsedEntry]) {
        for e in entries {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, e.day, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, e.model, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(e.calls))
            sqlite3_bind_int64(stmt, 5, Int64(e.input))
            sqlite3_bind_int64(stmt, 6, Int64(e.output))
            sqlite3_bind_int64(stmt, 7, Int64(e.cacheRead))
            sqlite3_bind_int64(stmt, 8, Int64(e.cacheCreate))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    // MARK: - Byte/line handling

    /// Read all bytes from `offset` to EOF.
    private static func readBytes(_ path: String, from offset: Int) -> Data {
        guard offset >= 0, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return Data() }
        defer { try? handle.close() }
        if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
        return handle.readDataToEndOfFile()
    }

    /// Split into complete newline-terminated lines. Returns the lines plus
    /// how many bytes they occupy; bytes after the last newline (a partial
    /// trailing line) are excluded and left for the next append.
    private static func completeLines(_ data: Data) -> (lines: [Data], consumed: Int) {
        guard !data.isEmpty else { return ([], 0) }
        var lines: [Data] = []
        var start = data.startIndex
        var lastNL: Data.Index? = nil
        while let nl = data[start...].firstIndex(of: 0x0A) {
            lines.append(Data(data[start..<nl]))
            lastNL = nl
            start = data.index(after: nl)
        }
        let consumed = lastNL.map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        return (lines, consumed)
    }

    // MARK: - Parsing

    private struct ParsedEntry {
        let day: String
        let model: String
        var calls = 0
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreate = 0
        /// Claude `message.id`, empty for a record that carries none (or for
        /// a source that has no such key). The claim ledger keys on it.
        var id = ""

        /// The same entry with every counter flipped, for retiring a booking
        /// another transcript made (see `claimClaude`).
        func negated() -> ParsedEntry {
            var e = self
            e.calls = -calls
            e.input = -input
            e.output = -output
            e.cacheRead = -cacheRead
            e.cacheCreate = -cacheCreate
            return e
        }

        /// Collapse per-record entries into one per (day, model). The rollup
        /// table's PK is (path, day, model), so writing per-record rows with
        /// REPLACE would drop all but the last record of a day.
        static func aggregated(_ entries: [ParsedEntry]) -> [ParsedEntry] {
            var out: [String: ParsedEntry] = [:]
            for e in entries {
                let key = e.day + "\u{1F}" + e.model
                if var cur = out[key] {
                    cur.calls += e.calls; cur.input += e.input; cur.output += e.output
                    cur.cacheRead += e.cacheRead; cur.cacheCreate += e.cacheCreate
                    out[key] = cur
                } else {
                    out[key] = e
                }
            }
            return Array(out.values)
        }
    }

    /// Last cumulative total in a file — used only to stamp `cx_*` so a
    /// rewrite can be detected. Day-level usage comes from `last_token_usage`.
    private struct CodexTotal {
        let input: Int
        let output: Int
        let cached: Int
        /// Cumulative `total_token_usage.total_tokens` — the rewrite stamp and
        /// the dedupe key for re-emitted `token_count` records.
        var total: Int = 0
    }

    /// Codex usage is on `event_msg` / `token_count`. Those records have no
    /// `payload.model` — the upstream slug (`glm-5.3-flash`, not the product
    /// name "codex") is on `turn_context` / `world_state` / `thread_settings`.
    /// Incremental appends are often token_count-only, so `previousModel` is
    /// the last slug stored on the file row (`cx_model`).
    ///
    /// Bucketing: upstream reports `input_tokens` **including**
    /// `cached_input_tokens`, and `output_tokens` **including**
    /// `reasoning_output_tokens`. We store disjoint buckets (fresh input,
    /// cache read, output) so the shared Claude-shaped arithmetic in
    /// `ModelUsage` stays correct for both sources.
    ///
    /// Duplicates: Codex re-emits a `token_count` carrying the same cumulative
    /// total as the previous record (compaction / context accounting). Those
    /// are not additional usage — the cumulative did not advance — so they are
    /// dropped. An identical re-emission inside one chunk is dropped outright;
    /// across an append boundary we compare against the file's last cumulative
    /// (`previousTotal`), which `sync` persists and advances.
    private static func parseCodex(_ lines: [Data], previousModel: String,
                                   previousTotal: Int = 0, previousInput: Int = 0,
                                   previousOutput: Int = 0, previousCached: Int = 0) -> (entries: [ParsedEntry], last: CodexTotal?, model: String) {
        var objects: [[String: Any]] = []
        objects.reserveCapacity(lines.count)
        var firstSlug: String?
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            objects.append(obj)
            if firstSlug == nil { firstSlug = codexModel(in: obj) }
        }
        // Seed from this chunk when the file row has no slug yet, so
        // token_count lines that precede the first turn_context still count.
        // Missing attribution must not erase measured tokens; retain an
        // unknown model so the UI exposes them as unpriced usage.
        var model = previousModel.isEmpty ? (firstSlug ?? "unknown") : previousModel
        var out: [ParsedEntry] = []
        var last: CodexTotal?
        var lastCumulative: Int? = previousTotal > 0 ? previousTotal : nil
        var baselineInput = previousInput
        var baselineOutput = previousOutput
        var baselineCached = previousCached
        for obj in objects {
            if let next = codexModel(in: obj) { model = next }
            guard obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let date = isoDate(obj["timestamp"]) else { continue }
            var cumulativeDelta: [String: Any]?
            if let total = info["total_token_usage"] as? [String: Any] {
                let cumulative = JSONCoerce.intVal(total["total_tokens"])
                last = CodexTotal(input: JSONCoerce.intVal(total["input_tokens"]),
                                  output: JSONCoerce.intVal(total["output_tokens"]),
                                  cached: JSONCoerce.intVal(total["cached_input_tokens"]),
                                  total: cumulative)
                // Same cumulative as the record before it → the upstream
                // re-stated the same usage, not a new turn.
                if cumulative > 0, cumulative == lastCumulative { continue }
                // Older logs may have only the cumulative snapshot. Fold the
                // difference, including across appends, instead of dropping
                // it or booking the whole thread again on its latest day.
                if let last {
                    let reset = last.input < baselineInput || last.output < baselineOutput
                    cumulativeDelta = [
                        "input_tokens": max(0, last.input - (reset ? 0 : baselineInput)),
                        "output_tokens": max(0, last.output - (reset ? 0 : baselineOutput)),
                        "cached_input_tokens": max(0, last.cached - (reset ? 0 : baselineCached))
                    ]
                    baselineInput = last.input
                    baselineOutput = last.output
                    baselineCached = last.cached
                }
                if cumulative > 0 { lastCumulative = cumulative }
            }
            let turn = (info["last_token_usage"] as? [String: Any]) ?? cumulativeDelta
            guard let turn, !model.isEmpty else { continue }
            let cached = JSONCoerce.intVal(turn["cached_input_tokens"])
            var e = record(ModelPricing.dayKey(date), model,
                           input: max(0, JSONCoerce.intVal(turn["input_tokens"]) - cached),
                           output: JSONCoerce.intVal(turn["output_tokens"]),
                           read: cached,
                           create: JSONCoerce.intVal(turn["cache_write_input_tokens"]))
            guard e.input + e.output + e.cacheRead + e.cacheCreate > 0 else { continue }
            e.calls = 1
            out.append(e)
        }
        return (out, last, model)
    }

    /// Live proxy slug. `token_count` has none; never invent `"codex"`.
    private static func codexModel(in obj: [String: Any]) -> String? {
        guard let payload = obj["payload"] as? [String: Any] else { return nil }
        let type = obj["type"] as? String
        if type == "turn_context", let m = nonempty(payload["model"]) { return m }
        if type == "session_meta",
           let provenance = (payload["base_instructions"] as? [String: Any])?["provenance"] as? [String: Any],
           let m = nonempty(provenance["model"]) {
            return m
        }
        if type == "world_state",
           let state = payload["state"] as? [String: Any],
           let m = nonempty(state["model"]) {
            return m
        }
        if let settings = payload["thread_settings"] as? [String: Any],
           let m = nonempty(settings["model"]) {
            return m
        }
        return nil
    }

    private static func nonempty(_ any: Any?) -> String? {
        (any as? String).flatMap { $0.isEmpty ? nil : $0 }
    }


    private static func record(_ day: String, _ model: String, input: Int, output: Int, read: Int = 0, create: Int = 0) -> ParsedEntry {
        var e = ParsedEntry(day: day, model: model)
        e.input = input; e.output = output; e.cacheRead = read; e.cacheCreate = create
        e.calls = 1
        return e
    }

    /// Claude Code: {"timestamp":"...","type":"assistant","message":{"model":...,"usage":{...}}}
    /// Last-wins per `message.id` — the same id is rewritten as the stream
    /// finalizes (partial then complete). There is no on-disk cache-hit rate;
    /// we use Anthropic's fields: cache_read / (input + cache_read + cache_create).
    private static func parseClaude(_ lines: [Data]) -> [ParsedEntry] {
        var lastByID: [String: ParsedEntry] = [:]
        var anonymous: [ParsedEntry] = []
        for line in lines {
            guard line.count > 2, line.contains(0x22),
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty, !model.hasPrefix("<"),
                  let usage = message["usage"] as? [String: Any],
                  let date = isoDate(obj["timestamp"]) else { continue }
            let create = JSONCoerce.intVal(usage["cache_creation_input_tokens"])
            var e = record(ModelPricing.dayKey(date), model,
                           input: JSONCoerce.intVal(usage["input_tokens"]),
                           output: JSONCoerce.intVal(usage["output_tokens"]),
                           read: JSONCoerce.intVal(usage["cache_read_input_tokens"]),
                           create: create)
            if let id = message["id"] as? String, !id.isEmpty {
                e.id = id
                lastByID[id] = e
            } else {
                anonymous.append(e)
            }
        }
        return Array(lastByID.values) + anonymous
    }

    /// Parse one Claude transcript and hand every `message.id` printed in it to
    /// `UsageClaims`, which books each API call exactly once across the whole
    /// corpus. A resumed or forked session copies its parent's assistant
    /// records verbatim into a new file, so the ids in this parse may already
    /// be booked by the transcript that recorded them first.
    ///
    /// Returns only the entries this file books. An id another transcript owns
    /// is dropped — the copy is not a call. Nothing else is needed here: a
    /// Claude path's rollup is *replaced* in full on every parse (unlike
    /// Codex's append path), so a dropped entry leaves no stale row behind,
    /// and an id this file stops printing simply stops being replaced into it.
    ///
    /// Ids the file no longer prints are released so another transcript can
    /// take them. Records without an id are not claims and always book.
    private static func claimClaude(_ parsed: [ParsedEntry], path: String) -> [ParsedEntry] {
        var booked = Set<String>()
        var out: [ParsedEntry] = []
        out.reserveCapacity(parsed.count)
        for e in parsed where !e.id.isEmpty {
            switch UsageClaims.owner(of: e.id) {
            case nil:
                UsageClaims.record(e.id, owner: path)
                booked.insert(e.id)
                out.append(e)
            case path:
                booked.insert(e.id)
                out.append(e)
            default:
                continue    // another transcript books this call
            }
        }
        for id in UsageClaims.owned(by: path) where !booked.contains(id) {
            UsageClaims.release(id)
        }
        return out + parsed.filter { $0.id.isEmpty }
    }

    /// Book a chunk's entries additively — the pure-append half of
    /// `claimClaude`. The caller has already established that none of the
    /// chunk's ids is currently booked by `path` (a reprint hands the file to
    /// the full reparse instead), so ids here are either fresh (claim and
    /// book) or booked by another transcript (drop, exactly as the full path
    /// does). No release pass: an append can only make the file print *more*
    /// ids, never fewer.
    private static func claimClaudeAppend(_ parsed: [ParsedEntry], path: String) -> [ParsedEntry] {
        var out: [ParsedEntry] = []
        out.reserveCapacity(parsed.count)
        for e in parsed where !e.id.isEmpty {
            switch UsageClaims.owner(of: e.id) {
            case nil:
                UsageClaims.record(e.id, owner: path)
                out.append(e)
            default:
                continue
            }
        }
        return out + parsed.filter { $0.id.isEmpty }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFrac = ISO8601DateFormatter()

    /// The UTC calendar `fastStamp` composites in — hoisted because building
    /// one per call was the only allocation left in its 0.27 µs.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func isoDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        if let fast = fastStamp(s) { return fast }
        return isoFormatter.date(from: s) ?? isoFormatterNoFrac.date(from: s)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fff]Z` — the exact stamp shape both clients'
    /// transcripts carry — parsed without `ISO8601DateFormatter`.
    ///
    /// The formatter was the single most expensive thing in `parseClaude`:
    /// measured on this machine, one parse costs ~25.7 µs against ~2.9 µs for
    /// the line's `JSONSerialization` alone, while this path costs 0.16 µs.
    /// On a 13 MB / 30k-line synthetic transcript (the size class of the
    /// largest live sessions) the full reparse fell from 3332 ms to 454 ms
    /// (7.3×) and a first index pass from 3483 ms to 603 ms. The fast path is
    /// exactly equivalent, including the formatter's truncation of fractional
    /// seconds to milliseconds (`.062` and `.0629` both answer `.062` —
    /// verified against the formatter). Any other shape — an offset instead
    /// of `Z`, a 1-digit month, `24:00:00`, four or more fractional digits,
    /// lowercase `t`/`z` — returns nil and falls back to the formatter, so
    /// this can only be a faster route to the same value, never a different
    /// one (`usage-index-regressions.py` diffs the two on 200k random stamps
    /// plus adversarial shapes).
    private static func fastStamp(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count == 20 || b.count == 24 else { return nil }
        guard b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A else { return nil }
        func digit(_ i: Int) -> Int? {
            let v = Int(b[i]) - 0x30
            return (0...9).contains(v) ? v : nil
        }
        func two(_ i: Int) -> Int? {
            guard let a = digit(i), let c = digit(i + 1) else { return nil }
            return a * 10 + c
        }
        guard let d0 = digit(0), let d1 = digit(1), let d2 = digit(2), let d3 = digit(3),
              let month = two(5), let day = two(8), let hour = two(11),
              let minute = two(14), let second = two(17),
              (1...12).contains(month), (1...31).contains(day),
              hour <= 23, minute <= 59, second <= 59 else { return nil }
        let year = d0 * 1000 + d1 * 100 + d2 * 10 + d3
        var nanosecond = 0
        if b.count == 24 {
            guard b[19] == 0x2E, b[23] == 0x5A,
                  let f0 = digit(20), let f1 = digit(21), let f2 = digit(22) else { return nil }
            nanosecond = (f0 * 100 + f1 * 10 + f2) * 1_000_000
        } else {
            guard b[19] == 0x5A else { return nil }
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        return utcCalendar.date(from: components)
    }
}
