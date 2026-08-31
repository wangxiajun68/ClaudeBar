import Foundation
import SQLite3

#if canImport(Glibc)
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#else
let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
#endif

/// Persistent usage index — the single source of truth for usage aggregation.
///
/// Scanning transcripts on every query (the old design) is O(corpus size):
/// each day/month/year switch re-enumerated and re-merged thousands of JSONL
/// files. This index inverts that: every transcript is parsed **once** into
/// per-(file, day, model) rollup rows in a small SQLite DB; any query then
/// becomes a single GROUP BY over a few hundred rows — milliseconds.
///
/// DB layout (`~/Library/Application Support/ClaudeBar/usage-index.db`):
///   files  — one row per known transcript: prefixed path, mtime, size, and
///            `offset` (bytes fully parsed: index after the last complete
///            newline). Trailing bytes beyond `offset` are an unparsed
///            partial line; the next append completes it and it is parsed
///            then. For Codex files the row also holds the last-seen
///            cumulative token totals (`cx_*`), used to derive deltas.
///   rollup — per-(path, day, model) token aggregates, `day` in the user's
///            local timezone so interval filtering matches the UI.
///
/// Incremental maintenance:
///   - Unchanged files (mtime+size match) are skipped entirely.
///   - Append-only growth parses only the new bytes from `offset`; the new
///     rows are *added* to the existing rollup (upsert-with-add).
///   - Shrink/rewrite (size decreased or new file) re-parses from byte 0 and
///     replaces the path's rollup rows — stale data can never survive.
///   - Files that vanished are pruned with their rollup rows.
///
/// Codex note: Codex reports *cumulative* per-file totals in each
/// `token_count` record. A full parse stores only the last total; an append
/// parse stores the new last total and inserts the *delta* (new − old,
/// clamped at 0) as usage. All other sources report per-record deltas.
struct UsageIndex {

    // MARK: - Schema / connection

    private static let dbURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-index.db")
    }()

    private static let lock = NSLock()
    private static var db: OpaquePointer?
    private static var openFailed = false

    private static func connection() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        if let db { return db }
        if openFailed { return nil }
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            openFailed = true
            return nil
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                offset INTEGER NOT NULL DEFAULT 0,
                head_hash INTEGER NOT NULL DEFAULT 0,
                cx_in INTEGER NOT NULL DEFAULT 0,
                cx_out INTEGER NOT NULL DEFAULT 0,
                cx_cached INTEGER NOT NULL DEFAULT 0
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
            """, nil, nil, nil)
        return db
    }

    // MARK: - Public API

    /// True until the first `updateIndex()` of this app run has completed.
    /// The UI shows a spinner only during this window; afterwards queries are
    /// fast enough that results can update in place.
    private static var initialBuildDone = false
    static var needsInitialBuild: Bool {
        lock.lock(); defer { lock.unlock() }
        return !initialBuildDone
    }

    /// Bring the index up to date with every transcript source. Incremental:
    /// cost is proportional to changed bytes, not corpus size. Cheap enough
    /// to call before every query.
    static func updateIndex() {
        guard let db = connection() else { return }
        lock.lock()
        defer { lock.unlock() }

        let known = currentFiles(db)
        let candidates = collectTranscripts()

        _ = exec(db, "BEGIN")
        var seen = Set<String>()
        for file in candidates {
            guard !seen.contains(file.key) else { continue }
            seen.insert(file.key)
            sync(file: file, prior: known[file.key], db: db)
        }
        // Prune files that vanished (rollup rows cascade).
        for key in known.keys where !seen.contains(key) {
            delete(db, "DELETE FROM rollup WHERE path = ?", key)
            delete(db, "DELETE FROM files WHERE path = ?", key)
        }
        _ = exec(db, "COMMIT")
        lock.lock()
        initialBuildDone = true
        lock.unlock()
    }

    /// Aggregate per-model usage within `interval` (day/month/year/custom).
    static func fetch(in interval: DateInterval) -> [ModelUsage] {
        guard let db = connection() else { return [] }
        let startDay = dayString(interval.start)
        let endDay = dayString(interval.end)

        var stmt: OpaquePointer?
        let sql = """
            SELECT model, sum(calls), sum(input), sum(output), sum(cache_read), sum(cache_create)
            FROM rollup WHERE day BETWEEN ?1 AND ?2 GROUP BY model
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

    // MARK: - Per-file sync

    private struct KnownFile {
        let mtime: TimeInterval
        let size: Int
        let offset: Int
        let headHash: Int
        let cxIn: Int
        let cxOut: Int
        let cxCached: Int
    }

    /// Cheap content-continuity check for the append fast path: hash of the
    /// file's first bytes. A rewritten/rotated file almost certainly differs;
    /// an appended one is byte-identical at the head.
    private static func headHash(_ path: String, length: Int) -> Int {
        guard let data = readBytes(path, from: 0) as NSData? else { return 0 }
        let head = data.subdata(with: NSRange(location: 0, length: min(length, data.count)))
        return head.hashValue
    }

    /// Parse one file's new bytes and fold them into the index.
    private static func sync(file: Candidate, prior: KnownFile?, db: OpaquePointer) {
        let kind = file.key.prefix(while: { $0 != ":" })
        let isCodex = kind == "codex"

        // Append when the file only grew (transcripts are append-only). A
        // grow-with-rewrite (new content at the same path — rotation, session
        // reset) would silently parse the wrong bytes, so verify content
        // continuity: the stored head hash must still match the file's head.
        let headMatches = prior.map { headHash(file.path, length: 256) == $0.headHash } ?? false
        if let prior, headMatches, file.size > prior.size || prior.offset < prior.size {
            let chunk = readBytes(file.path, from: prior.offset)
            guard !chunk.isEmpty else { return }
            // Parse complete lines only; the trailing partial line (if any)
            // is left for the next append to complete. `chunkFrom` marks the
            // start of the first *new complete* line within the chunk.
            let (lines, consumed) = completeLines(chunk)
            guard consumed > 0 else { return }

            if isCodex {
                // Cumulative totals: delta against the stored last totals.
                guard let last = codexLastTotal(lines) else { return }
                let dIn = max(0, last.input - prior.cxIn)
                let dOut = max(0, last.output - prior.cxOut)
                let dCached = max(0, last.cached - prior.cxCached)
                guard dIn > 0 || dOut > 0 || dCached > 0 else {
                    upsertFile(db, file, prior.offset + consumed, cxIn: prior.cxIn, cxOut: prior.cxOut, cxCached: prior.cxCached)
                    return
                }
                addRollup(db, file.key, [ParsedEntry(
                    day: dayString(last.date), model: "codex",
                    calls: 1, input: dIn, output: dOut, cacheRead: dCached, cacheCreate: 0)])
                upsertFile(db, file, prior.offset + consumed, cxIn: last.input, cxOut: last.output, cxCached: last.cached)
            } else {
                let entries = parse(kind, lines)
                guard !entries.isEmpty else {
                    upsertFile(db, file, prior.offset + consumed,
                               cxIn: prior.cxIn, cxOut: prior.cxOut, cxCached: prior.cxCached)
                    return
                }
                addRollup(db, file.key, entries)
                upsertFile(db, file, prior.offset + consumed,
                           cxIn: prior.cxIn, cxOut: prior.cxOut, cxCached: prior.cxCached)
            }
            return
        }

        // Full (re)parse: brand-new file, or it shrank / was rewritten.
        guard let data = FileManager.default.contents(atPath: file.path) else { return }
        let (lines, consumed) = completeLines(data)
        if prior != nil { delete(db, "DELETE FROM rollup WHERE path = ?", file.key) }

        if isCodex {
            if let last = codexLastTotal(lines) {
                replaceRollup(db, file.key, [ParsedEntry(
                    day: dayString(last.date), model: "codex",
                    calls: 1, input: last.input, output: last.output, cacheRead: last.cached, cacheCreate: 0)])
                upsertFile(db, file, consumed, cxIn: last.input, cxOut: last.output, cxCached: last.cached)
            } else {
                upsertFile(db, file, consumed, cxIn: 0, cxOut: 0, cxCached: 0)
            }
        } else {
            replaceRollup(db, file.key, parse(kind, lines))
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
        for kind in ExternalAgentKind.allCases {
            out.append(contentsOf: collectExternal(kind: kind))
        }
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

    /// Walk an external tool's directory tree. The layouts are uniform enough
    /// for one generic 4-level walk: Codex nests year/month/day, WorkBuddy
    /// project/session, OpenClaw agent/session; files may also sit directly
    /// in upper levels (Codex day-dir files).
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

    private static func currentFiles(_ db: OpaquePointer) -> [String: KnownFile] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path, mtime, size, offset, head_hash, cx_in, cx_out, cx_cached FROM files", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: KnownFile] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            out[path] = KnownFile(
                mtime: sqlite3_column_double(stmt, 1),
                size: Int(sqlite3_column_int64(stmt, 2)),
                offset: Int(sqlite3_column_int64(stmt, 3)),
                headHash: Int(sqlite3_column_int64(stmt, 4)),
                cxIn: Int(sqlite3_column_int64(stmt, 5)),
                cxOut: Int(sqlite3_column_int64(stmt, 6)),
                cxCached: Int(sqlite3_column_int64(stmt, 7)))
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

    private static func upsertFile(_ db: OpaquePointer, _ file: Candidate, _ offset: Int, cxIn: Int, cxOut: Int, cxCached: Int) {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO files(path,mtime,size,offset,head_hash,cx_in,cx_out,cx_cached) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, file.key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, file.mtime)
        sqlite3_bind_int64(stmt, 3, Int64(file.size))
        sqlite3_bind_int64(stmt, 4, Int64(offset))
        sqlite3_bind_int64(stmt, 5, Int64(headHash(file.path, length: 256)))
        sqlite3_bind_int64(stmt, 6, Int64(cxIn))
        sqlite3_bind_int64(stmt, 7, Int64(cxOut))
        sqlite3_bind_int64(stmt, 8, Int64(cxCached))
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
        // An append chunk can hold many records for the same (day, model);
        // aggregate so the upsert-add runs once per key, not per record.
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

    private struct CodexTotal {
        let date: Date
        let input: Int
        let output: Int
        let cached: Int
    }

    /// Last cumulative token_count in a set of Codex lines, or nil.
    private static func codexLastTotal(_ lines: [Data]) -> CodexTotal? {
        var last: CodexTotal?
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let date = isoDate(obj["timestamp"]) else { continue }
            last = CodexTotal(date: date,
                              input: JSONCoerce.intVal(total["input_tokens"]),
                              output: JSONCoerce.intVal(total["output_tokens"]),
                              cached: JSONCoerce.intVal(total["cached_input_tokens"]))
        }
        return last
    }

    private static func parse(_ kind: Substring, _ lines: [Data]) -> [ParsedEntry] {
        switch kind {
        case "claude": return parseClaude(lines)
        case "workbuddy": return parseWorkBuddy(lines)
        case "openclaw": return parseOpenClaw(lines)
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
        return e
    }

    /// Claude Code: {"timestamp":"...","type":"assistant","message":{"model":...,"usage":{...}}}
    private static func parseClaude(_ lines: [Data]) -> [ParsedEntry] {
        var out: [ParsedEntry] = []
        for line in lines {
            guard line.count > 2, line.contains(0x22), // cheap non-empty guard
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty, !model.hasPrefix("<"),
                  let usage = message["usage"] as? [String: Any],
                  let date = isoDate(obj["timestamp"]) else { continue }
            out.append(record(dayString(date), model,
                              input: JSONCoerce.intVal(usage["input_tokens"]),
                              output: JSONCoerce.intVal(usage["output_tokens"]),
                              read: JSONCoerce.intVal(usage["cache_read_input_tokens"]),
                              create: JSONCoerce.intVal(usage["cache_creation_input_tokens"])))
        }
        return out
    }

    /// WorkBuddy: {"timestamp":<ms>,"type":"function_call","providerData":{"model":...,"usage":{...}}}
    private static func parseWorkBuddy(_ lines: [Data]) -> [ParsedEntry] {
        var out: [ParsedEntry] = []
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "function_call",
                  let pd = obj["providerData"] as? [String: Any],
                  let usage = pd["usage"] as? [String: Any],
                  let ms = JSONCoerce.doubleVal(obj["timestamp"]) else { continue }
            let model = (pd["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "workbuddy"
            var read = 0
            if let details = usage["inputTokensDetails"] as? [[String: Any]] {
                read = details.reduce(0) { $0 + JSONCoerce.intVal($1["cached_tokens"]) }
            }
            out.append(record(dayString(Date(timeIntervalSince1970: ms / 1000)), model,
                              input: JSONCoerce.intVal(usage["inputTokens"]),
                              output: JSONCoerce.intVal(usage["outputTokens"]),
                              read: read))
        }
        return out
    }

    /// OpenClaw: {"type":"message","timestamp":"...","message":{"model":...,"usage":{"input","output","cacheRead","cacheWrite"}}}
    private static func parseOpenClaw(_ lines: [Data]) -> [ParsedEntry] {
        var out: [ParsedEntry] = []
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "message",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let date = isoDate(obj["timestamp"]) else { continue }
            let model = (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "openclaw"
            out.append(record(dayString(date), model,
                              input: JSONCoerce.intVal(usage["input"]),
                              output: JSONCoerce.intVal(usage["output"]),
                              read: JSONCoerce.intVal(usage["cacheRead"]),
                              create: JSONCoerce.intVal(usage["cacheWrite"])))
        }
        return out
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
