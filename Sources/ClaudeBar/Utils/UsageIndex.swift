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
/// Backends (Settings → 开启数据库), independent, no migration either way:
///   SQLite  `~/Library/Application Support/ClaudeBar/usage-index.db`
///   JSON    `.../ClaudeBar/logs/usage-files.json` + `usage-rollup.jsonl`
///
/// `files` tracks mtime/size/`offset` (bytes through the last complete
/// newline) and, for Codex, last cumulative totals plus the live model slug.
/// `rollup` is (path, day, model) in the user's local timezone.
///
/// Incremental maintenance:
///   - Unchanged files (mtime+size match) are skipped entirely.
///   - Append-only growth parses only the new bytes from `offset`; the new
///     rows are *added* to the existing rollup (upsert-with-add).
///   - Shrink/rewrite (size decreased or new file) re-parses from byte 0 and
///     replaces the path's rollup rows — stale data can never survive.
///   - Files that vanished are pruned with their rollup rows.
///
/// Codex note: per-turn usage is `last_token_usage` on `token_count`.
/// The upstream model slug is on `turn_context` (carried across appends
/// via `cx_model`). Cumulative `total_token_usage` is only a rewrite stamp.
struct UsageIndex {

    // MARK: - Schema / connection

    private static let dbURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-index.db")
    }()

    private static let lock = NSLock()
    private static let flagLock = NSLock()
    private static var db: OpaquePointer?
    private static var openFailed = false
    private static var _initialBuildDone = false
    private static var _hasCachedData: Bool?

    private static func connection() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        if !DiskPersistence.useDatabase { return nil }
        if let db { return db }
        if openFailed { return nil }
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            openFailed = true
            return nil
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-2000", nil, nil, nil)
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
    /// Schema version is stamped at the latest step (currently 6).
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
    }

    // MARK: - Public API

    /// Close SQLite (if open) and drop in-memory JSON caches so the next
    /// query / updateIndex uses the backend selected in Settings.
    static func reloadPersistence() {
        lock.lock()
        if let handle = db {
            sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            sqlite3_close(handle)
            db = nil
        }
        openFailed = false
        lock.unlock()
        UsageJSONStore.shared.reset()
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
        if !DiskPersistence.useDatabase {
            let hit = UsageJSONStore.shared.hasRows()
            flagLock.lock(); _hasCachedData = hit; flagLock.unlock()
            return hit
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
    /// unchanged files are skipped (mtime+size); cost is changed bytes, not
    /// corpus size.
    static func updateIndex() {
        let candidates = collectTranscripts()
        if !DiskPersistence.useDatabase {
            updateIndexJSON(candidates)
            return
        }
        guard let db = connection() else { return }
        lock.lock()
        defer { lock.unlock() }

        let known = currentFiles(db)

        _ = exec(db, "BEGIN")
        var seen = Set<String>()
        for file in candidates {
            guard !seen.contains(file.key) else { continue }
            seen.insert(file.key)
            sync(file: file, prior: known[file.key], backend: .sqlite(db))
        }
        for key in known.keys where !seen.contains(key) {
            delete(db, "DELETE FROM rollup WHERE path = ?", key)
            delete(db, "DELETE FROM files WHERE path = ?", key)
        }
        _ = exec(db, "COMMIT")
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        flagLock.lock()
        _initialBuildDone = true
        _hasCachedData = true
        flagLock.unlock()
    }

    private static func updateIndexJSON(_ candidates: [Candidate]) {
        UsageJSONStore.shared.load()
        let known = knownFromJSON()
        var seen = Set<String>()
        for file in candidates {
            guard !seen.contains(file.key) else { continue }
            seen.insert(file.key)
            sync(file: file, prior: known[file.key], backend: .json)
        }
        for key in known.keys where !seen.contains(key) {
            UsageJSONStore.shared.deletePath(key)
        }
        UsageJSONStore.shared.save()
        flagLock.lock()
        _initialBuildDone = true
        _hasCachedData = true
        flagLock.unlock()
    }

    /// Aggregate per-model usage within `interval` (day/month/year/custom).
    /// Does **not** walk transcripts — call `updateIndex()` separately when
    /// the corpus may have changed.
    static func fetch(in interval: DateInterval) -> [ModelUsage] {
        let startDay = dayString(interval.start)
        // DateInterval.end is exclusive; include the last local day that
        // actually belongs to the period.
        let lastIncluded = interval.end.addingTimeInterval(-1)
        let endDay = dayString(lastIncluded)
        if !DiskPersistence.useDatabase {
            return UsageJSONStore.shared.fetch(startDay: startDay, endDay: endDay)
        }
        guard let db = connection() else { return [] }
        lock.lock(); defer { lock.unlock() }

        var stmt: OpaquePointer?
        let sql = """
            SELECT model, sum(calls), sum(input), sum(output), sum(cache_read), sum(cache_create)
            FROM rollup
            WHERE day BETWEEN ?1 AND ?2 AND path NOT LIKE 'openclaw%'
            GROUP BY model
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
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
        return out.sorted { $0.totalTokens > $1.totalTokens }
    }

    /// Per-day totals for the river chart. Same interval rules as `fetch`.
    static func fetchDaily(in interval: DateInterval) -> [DayUsage] {
        let startDay = dayString(interval.start)
        let lastIncluded = interval.end.addingTimeInterval(-1)
        let endDay = dayString(lastIncluded)
        if !DiskPersistence.useDatabase {
            return UsageJSONStore.shared.fetchDaily(startDay: startDay, endDay: endDay)
        }
        guard let db = connection() else { return [] }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = """
            SELECT day, sum(input), sum(output), sum(cache_read), sum(cache_create)
            FROM rollup
            WHERE day BETWEEN ?1 AND ?2 AND path NOT LIKE 'openclaw%'
            GROUP BY day ORDER BY day
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
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
        return out
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

    private enum Backend {
        case sqlite(OpaquePointer)
        case json
    }

    /// Parse one file's new bytes and fold them into the index.
    private static func sync(file: Candidate, prior: KnownFile?, backend: Backend) {
        let kind = file.key.prefix(while: { $0 != ":" })
        let isCodex = kind == "codex"

        if let prior, prior.mtime == file.mtime, prior.size == file.size, prior.offset <= file.size {
            return
        }

        let storedHash = prior?.headHash ?? 0
        let currentHash = (prior != nil && file.size >= prior!.size) ? headHash(file.path, length: 256) : 0
        let headMatches = storedHash != 0 && currentHash == storedHash

        // Claude assistant lines can rewrite the same message.id (partial then
        // final). Incremental add would double-count; only Codex is append-delta.
        if isCodex, let prior, file.size > prior.size, prior.offset <= file.size,
           storedHash == 0 || headMatches {
            let chunk = readBytes(file.path, from: prior.offset)
            guard !chunk.isEmpty else { return }
            // Parse complete lines only; the trailing partial line (if any)
            // is left for the next append to complete. `chunkFrom` marks the
            // start of the first *new complete* line within the chunk.
            let (lines, consumed) = completeLines(chunk)
            guard consumed > 0 else { return }

            let parsed = parseCodex(lines, previousModel: prior.cxModel)
            if parsed.entries.isEmpty {
                upsertFile(backend, file, prior.offset + consumed,
                           cxIn: prior.cxIn, cxOut: prior.cxOut, cxCached: prior.cxCached,
                           cxModel: parsed.model)
                return
            }
            addRollup(backend, file.key, parsed.entries)
            let last = parsed.last
            upsertFile(backend, file, prior.offset + consumed,
                       cxIn: last?.input ?? prior.cxIn,
                       cxOut: last?.output ?? prior.cxOut,
                       cxCached: last?.cached ?? prior.cxCached,
                       cxModel: parsed.model)
            return
        }

        // Full (re)parse: brand-new file, or it shrank / was rewritten.
        guard let data = FileManager.default.contents(atPath: file.path) else { return }
        let (lines, consumed) = completeLines(data)
        if prior != nil { deleteRollup(backend, file.key) }

        if isCodex {
            let parsed = parseCodex(lines, previousModel: "")
            if !parsed.entries.isEmpty { replaceRollup(backend, file.key, parsed.entries) }
            let last = parsed.last
            upsertFile(backend, file, consumed,
                       cxIn: last?.input ?? 0, cxOut: last?.output ?? 0, cxCached: last?.cached ?? 0,
                       cxModel: parsed.model)
        } else {
            replaceRollup(backend, file.key, parse(kind, lines))
            upsertFile(backend, file, consumed, cxIn: 0, cxOut: 0, cxCached: 0)
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

    private static func stat(_ path: String) -> (mtime: TimeInterval, size: Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return (mtime.timeIntervalSince1970, (attrs[.size] as? Int) ?? 0)
    }

    private static func collectClaude() -> [Candidate] {
        let projectsDir = FilePaths.claudeDir.appendingPathComponent("projects").path
        guard let en = FileManager.default.enumerator(atPath: projectsDir) else { return [] }
        var out: [Candidate] = []
        while let item = en.nextObject() as? String {
            guard item.hasSuffix(".jsonl") else { continue }
            let p = projectsDir + "/" + item
            if let s = stat(p) {
                out.append(Candidate(key: "claude:" + p, path: p, mtime: s.mtime, size: s.size))
            }
        }
        return out
    }

    /// Walk an external tool's directory tree. Codex nests year/month/day;
    /// files may also sit directly in upper levels.
    private static func collectExternal(kind: ExternalAgentKind) -> [Candidate] {
        let fm = FileManager.default
        let root = kind.rootDir

        var out: [Candidate] = []
        func walk(_ dir: String, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries {
                if entry.hasSuffix(".jsonl") && !entry.contains(".trajectory") {
                    let p = dir + "/" + entry
                    if let s = stat(p) {
                        out.append(Candidate(key: "\(kind.rawValue):\(p)", path: p, mtime: s.mtime, size: s.size))
                    }
                } else if depth < 3, entryIsDir(at: dir + "/" + entry) {
                    walk(dir + "/" + entry, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return out
    }

    private static func entryIsDir(at path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - DB helpers

    private static func knownFromJSON() -> [String: KnownFile] {
        var out: [String: KnownFile] = [:]
        for (path, rec) in UsageJSONStore.shared.currentFiles() {
            out[path] = KnownFile(
                mtime: rec.mtime, size: rec.size, offset: rec.offset,
                headHash: rec.headHash, cxIn: rec.cxIn, cxOut: rec.cxOut, cxCached: rec.cxCached,
                cxModel: rec.cxModel)
        }
        return out
    }

    private static func currentFiles(_ db: OpaquePointer) -> [String: KnownFile] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path, mtime, size, offset, head_hash, cx_in, cx_out, cx_cached, cx_model FROM files", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: KnownFile] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            let modelPtr = sqlite3_column_text(stmt, 8)
            out[path] = KnownFile(
                mtime: sqlite3_column_double(stmt, 1),
                size: Int(sqlite3_column_int64(stmt, 2)),
                offset: Int(sqlite3_column_int64(stmt, 3)),
                headHash: sqlite3_column_int64(stmt, 4),
                cxIn: Int(sqlite3_column_int64(stmt, 5)),
                cxOut: Int(sqlite3_column_int64(stmt, 6)),
                cxCached: Int(sqlite3_column_int64(stmt, 7)),
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

    private static func deleteRollup(_ backend: Backend, _ path: String) {
        switch backend {
        case .sqlite(let db):
            delete(db, "DELETE FROM rollup WHERE path = ?", path)
        case .json:
            break
        }
    }

    private static func upsertFile(_ backend: Backend, _ file: Candidate, _ offset: Int,
                                   cxIn: Int, cxOut: Int, cxCached: Int, cxModel: String = "") {
        switch backend {
        case .sqlite(let db):
            upsertFileSQL(db, file, offset, cxIn: cxIn, cxOut: cxOut, cxCached: cxCached, cxModel: cxModel)
        case .json:
            UsageJSONStore.shared.upsertFile(key: file.key, rec: .init(
                mtime: file.mtime, size: file.size, offset: offset,
                headHash: headHash(file.path, length: 256),
                cxIn: cxIn, cxOut: cxOut, cxCached: cxCached, cxModel: cxModel))
        }
    }

    private static func upsertFileSQL(_ db: OpaquePointer, _ file: Candidate, _ offset: Int,
                                      cxIn: Int, cxOut: Int, cxCached: Int, cxModel: String) {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO files(path,mtime,size,offset,head_hash,cx_in,cx_out,cx_cached,cx_model) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, file.key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, file.mtime)
        sqlite3_bind_int64(stmt, 3, Int64(file.size))
        sqlite3_bind_int64(stmt, 4, Int64(offset))
        sqlite3_bind_int64(stmt, 5, headHash(file.path, length: 256))
        sqlite3_bind_int64(stmt, 6, Int64(cxIn))
        sqlite3_bind_int64(stmt, 7, Int64(cxOut))
        sqlite3_bind_int64(stmt, 8, Int64(cxCached))
        sqlite3_bind_text(stmt, 9, cxModel, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// Full replacement of a path's rollup (used on full reparse; caller has
    /// already deleted old rows).
    private static func replaceRollup(_ backend: Backend, _ path: String, _ entries: [ParsedEntry]) {
        switch backend {
        case .sqlite(let db):
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO rollup(path,day,model,calls,input,output,cache_read,cache_create) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            bindAndRun(stmt, path, ParsedEntry.aggregated(entries))
        case .json:
            UsageJSONStore.shared.replaceRollup(path: path, rows: rollupRecs(path, entries))
        }
    }

    /// Additive fold of appended bytes into the existing rollup rows.
    private static func addRollup(_ backend: Backend, _ path: String, _ entries: [ParsedEntry]) {
        switch backend {
        case .sqlite(let db):
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
        case .json:
            UsageJSONStore.shared.addRollup(path: path, rows: rollupRecs(path, entries))
        }
    }

    private static func rollupRecs(_ path: String, _ entries: [ParsedEntry]) -> [UsageJSONStore.RollupRec] {
        ParsedEntry.aggregated(entries).map {
            .init(path: path, day: $0.day, model: $0.model, calls: $0.calls,
                  input: $0.input, output: $0.output, cacheRead: $0.cacheRead, cacheCreate: $0.cacheCreate)
        }
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
        let date: Date
        let input: Int
        let output: Int
        let cached: Int
    }

    /// Codex usage is on `event_msg` / `token_count`. Those records have no
    /// `payload.model` — the upstream slug (`glm-5.3-flash`, not the product
    /// name "codex") is on `turn_context` / `world_state` / `thread_settings`.
    /// Incremental appends are often token_count-only, so `previousModel` is
    /// the last slug stored on the file row (`cx_model`).
    private static func parseCodex(_ lines: [Data], previousModel: String) -> (entries: [ParsedEntry], last: CodexTotal?, model: String) {
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
        var model = previousModel.isEmpty ? (firstSlug ?? "") : previousModel
        var out: [ParsedEntry] = []
        var last: CodexTotal?
        for obj in objects {
            if let next = codexModel(in: obj) { model = next }
            guard obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let date = isoDate(obj["timestamp"]) else { continue }
            if let total = info["total_token_usage"] as? [String: Any] {
                last = CodexTotal(date: date,
                                  input: JSONCoerce.intVal(total["input_tokens"]),
                                  output: JSONCoerce.intVal(total["output_tokens"]),
                                  cached: JSONCoerce.intVal(total["cached_input_tokens"]))
            }
            let turn = (info["last_token_usage"] as? [String: Any])
                ?? (last == nil ? info["total_token_usage"] as? [String: Any] : nil)
            guard let turn, !model.isEmpty else { continue }
            var e = record(dayString(date), model,
                           input: JSONCoerce.intVal(turn["input_tokens"]),
                           output: JSONCoerce.intVal(turn["output_tokens"])
                                + JSONCoerce.intVal(turn["reasoning_output_tokens"]),
                           read: JSONCoerce.intVal(turn["cached_input_tokens"]),
                           create: JSONCoerce.intVal(turn["cache_write_input_tokens"]))
            e.calls = 1
            out.append(e)
        }
        if out.isEmpty, let last, !model.isEmpty {
            var e = record(dayString(last.date), model,
                           input: last.input, output: last.output, read: last.cached)
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

    private static func parse(_ kind: Substring, _ lines: [Data]) -> [ParsedEntry] {
        switch kind {
        case "claude": return parseClaude(lines)
        default: return []
        }
    }

    /// Local-timezone "yyyy-MM-dd" for a date (matching how the user reads
    /// the panel). Built from calendar components — no DateFormatter on the
    /// hot path.
    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
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
            let e = record(dayString(date), model,
                           input: JSONCoerce.intVal(usage["input_tokens"]),
                           output: JSONCoerce.intVal(usage["output_tokens"]),
                           read: JSONCoerce.intVal(usage["cache_read_input_tokens"]),
                           create: create)
            if let id = message["id"] as? String, !id.isEmpty {
                lastByID[id] = e
            } else {
                anonymous.append(e)
            }
        }
        return Array(lastByID.values) + anonymous
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFrac = ISO8601DateFormatter()

    private static func isoDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return isoFormatter.date(from: s) ?? isoFormatterNoFrac.date(from: s)
    }
}
