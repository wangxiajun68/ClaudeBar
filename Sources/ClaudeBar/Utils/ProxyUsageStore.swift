import Foundation
import SQLite3
import os

/// Per-(day, model) token aggregate for **third-party** traffic only.
///
/// Claude Code and Codex usage is read from their own transcripts by
/// `UsageIndex`, which is a complete record. Everything else reaches us only
/// through the local proxy, and its per-request token counts live on the
/// capture rows — which are capped at the most recent 120 entries and carry no
/// period breakdown. This table is the durable, period-queryable rollup for
/// that third source, so the usage ring's third-party slice is a real token
/// share rather than a guess from a truncated list.
///
/// Storage is SQLite (`proxy-usage.db`). A JSONL backend lived here until the
/// settings switch that selected it was removed; it is gone rather than kept
/// as an unreachable branch.
final class ProxyUsageStore {
    static let shared = ProxyUsageStore()
    static let didChange = Notification.Name("ClaudeBar.proxyUsageDidChange")

    private static let logger = Logger(subsystem: "com.claudebar.app", category: "ProxyUsage")

    /// One (day, model) bucket. Disjoint by construction: `input` is fresh
    /// input only — `TokenTotals` folds the cache hit out of the upstream's
    /// prompt count before this row is ever written, because DeepSeek's
    /// `prompt_tokens` (like OpenAI's `input_tokens`) already contains it.
    /// Storing the raw prompt count here billed the cached part twice and
    /// double-counted it in `totalTokens`.
    struct Row {
        var day: String
        var model: String
        var calls: Int
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
    }

    private let lock = NSLock()
    private var db: OpaquePointer?
    /// When the last `sqlite3_open_v2` failed; retried after a cooldown so a
    /// transient failure (disk full, a lock held by a crashed sibling) does
    /// not disable the rollup for the rest of the process.
    private var openFailedAt: Date?
    private static let openRetryInterval: TimeInterval = 5

    /// Under the app's own support root, from `FilePaths` — see the note on
    /// `ProxyCaptureStore.dbURL` (findings 91/400).
    private static let dbURL = FilePaths.appSupportDir.appendingPathComponent("proxy-usage.db")

    /// `SQLITE_TRANSIENT` equivalent — the constant in `UsageIndex.swift` is
    /// module-wide, but naming it here keeps this file independent of that
    /// file's declaration order.
    private static let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    private init() {}

    // MARK: - Write

    /// Fold one finished proxied request into the rollup. Additive: repeat
    /// calls for the same (day, model) accumulate.
    func record(model: String, at date: Date, input: Int, output: Int,
                cacheRead: Int, cacheWrite: Int = 0) {
        let name = model.isEmpty ? "unknown" : model
        let day = ModelPricing.dayKey(date)
        guard input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 else { return }
        var stored = false
        lock.lock()
        if let db = connectionLocked() {
            stored = upsertSQL(db, day: day, model: name, input: input, output: output,
                               cacheRead: cacheRead, cacheWrite: cacheWrite)
        }
        lock.unlock()
        // Transcript watchers cannot see third-party requests. Refresh the
        // cached usage snapshot when this independent rollup advances — and
        // only then: the observer's `refreshUsage(rescan: false)` walks ~14
        // tables, and a write that never landed has nothing new to show.
        guard stored else {
            Self.logger.error("token rollup write failed; this request's usage was not recorded")
            return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    // MARK: - Read

    /// Per-model third-party usage in `[startDay, endDay]`.
    func fetch(startDay: String, endDay: String) -> [ModelUsage] {
        var byModel: [String: ModelUsage] = [:]
        for row in allRows(startDay: startDay, endDay: endDay) {
            var usage = byModel[row.model] ?? ModelUsage(model: row.model)
            usage.calls += row.calls
            usage.inputTokens += row.input
            usage.outputTokens += row.output
            usage.cacheReadTokens += row.cacheRead
            usage.cacheCreationTokens += row.cacheWrite
            byModel[row.model] = usage
        }
        return byModel.values.filter { $0.totalTokens > 0 }.sorted { $0.totalTokens > $1.totalTokens }
    }

    func fetchDailyModels(startDay: String, endDay: String) -> [String: [ModelUsage]] {
        var days: [String: [ModelUsage]] = [:]
        for row in allRows(startDay: startDay, endDay: endDay) {
            days[row.day, default: []].append(ModelUsage(model: row.model, calls: row.calls,
                inputTokens: row.input, outputTokens: row.output,
                cacheReadTokens: row.cacheRead, cacheCreationTokens: row.cacheWrite))
        }
        return days.mapValues { ModelUsage.merged($0) }
    }

    /// Per-day totals, for the usage river.
    func fetchDaily(startDay: String, endDay: String) -> [DayUsage] {
        var byDay: [String: DayUsage] = [:]
        for row in allRows(startDay: startDay, endDay: endDay) {
            var day = byDay[row.day] ?? DayUsage(day: row.day)
            day.inputTokens += row.input
            day.outputTokens += row.output
            day.cacheReadTokens += row.cacheRead
            day.cacheCreationTokens += row.cacheWrite
            byDay[row.day] = day
        }
        return byDay.values.filter { $0.totalTokens > 0 }.sorted { $0.day < $1.day }
    }

    private func allRows(startDay: String, endDay: String) -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = connectionLocked() else { return [] }
        var stmt: OpaquePointer?
        // The table is WITHOUT ROWID with `PRIMARY KEY (day, model)`, so this
        // range is the primary key's own order — the window is an index scan
        // over exactly the days asked for. Selecting the whole table and
        // filtering in Swift made every query O(all history) instead of
        // O(days × models).
        let sql = """
            SELECT day, model, calls, input, output, cache_read, cache_write
            FROM usage WHERE day BETWEEN ?1 AND ?2
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, startDay, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, endDay, -1, Self.transient)
        var out: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Row(
                day: String(cString: sqlite3_column_text(stmt, 0)),
                model: String(cString: sqlite3_column_text(stmt, 1)),
                calls: Int(sqlite3_column_int64(stmt, 2)),
                input: Int(sqlite3_column_int64(stmt, 3)),
                output: Int(sqlite3_column_int64(stmt, 4)),
                cacheRead: Int(sqlite3_column_int64(stmt, 5)),
                cacheWrite: Int(sqlite3_column_int64(stmt, 6))))
        }
        return out
    }

    /// Close SQLite (if open). Used by the regression harness between
    /// scenarios; production has no backend to switch any more.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        if let handle = db {
            sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            sqlite3_close(handle)
            db = nil
        }
        openFailedAt = nil
    }

    // MARK: - SQLite

    private func connectionLocked() -> OpaquePointer? {
        if let db { return db }
        if let failedAt = openFailedAt, Date().timeIntervalSince(failedAt) < Self.openRetryInterval { return nil }
        guard sqlite3_open_v2(Self.dbURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let handle = db else {
            // `open_v2` hands back a handle even when it fails, and that
            // handle keeps the file lock. Clear it, or the next call returns
            // it before the cooldown is consulted.
            sqlite3_close(db)
            db = nil
            openFailedAt = Date()
            return nil
        }
        openFailedAt = nil
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-500", nil, nil, nil)
        sqlite3_busy_timeout(handle, 2000)
        sqlite3_exec(handle, """
            CREATE TABLE IF NOT EXISTS usage (
                day TEXT NOT NULL,
                model TEXT NOT NULL,
                calls INTEGER NOT NULL DEFAULT 0,
                input INTEGER NOT NULL DEFAULT 0,
                output INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL DEFAULT 0,
                cache_write INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (day, model)
            ) WITHOUT ROWID;
            """, nil, nil, nil)
        migrateLocked(handle)
        return handle
    }

    /// v1: rows written before the proxy folded the cache hit out of the
    /// upstream's prompt count.
    ///
    /// DeepSeek documents it (`prompt_tokens` equals `prompt_cache_hit_tokens`
    /// plus `prompt_cache_miss_tokens`) and OpenAI nests `cached_tokens` inside
    /// `input_tokens` — so on the Chat and Responses routes the old writer
    /// stored the hit twice: once inside `input` at the miss rate, once in
    /// `cache_read` at the hit rate. The repair is exact arithmetic on sums, so
    /// it is done in place rather than by rebuilding (a rebuild would drop
    /// everything older than the 120-entry capture window, which is all of it).
    ///
    /// **Known limit.** A row's shape was never recorded, and one case reports
    /// Anthropic-shaped usage into this table: a *third-party* client routed to
    /// the Anthropic passthrough (`forwardAnthropic`), where `input_tokens`
    /// already excludes the cache buckets. For those rows the subtraction is
    /// wrong by exactly `cache_read` in the low direction. Nothing in the table
    /// can tell them apart after the fact — the write path now can, and does
    /// (see `TokenTotals.setPrompt`), so this stays a one-time repair of the
    /// rows written before that distinction existed.
    private func migrateLocked(_ db: OpaquePointer) {
        var stmt: OpaquePointer?
        var version: Int32 = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { version = sqlite3_column_int(stmt, 0) }
            sqlite3_finalize(stmt)
        }
        guard version < 1 else { return }
        // A database created by this build already has the column; the ALTER
        // then fails as a duplicate and is ignored.
        sqlite3_exec(db, "ALTER TABLE usage ADD COLUMN cache_write INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        sqlite3_exec(db, "UPDATE usage SET input = MAX(0, input - cache_read) WHERE cache_read > 0", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA user_version = 1", nil, nil, nil)
    }

    /// Write one bucket, reporting whether the statement reached `SQLITE_DONE`.
    /// The result used to be dropped, which made a `prepare` or `step` failure
    /// indistinguishable from a landed write at every caller.
    private func upsertSQL(_ db: OpaquePointer, day: String, model: String,
                           input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Bool {
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO usage(day, model, calls, input, output, cache_read, cache_write)
            VALUES(?1, ?2, 1, ?3, ?4, ?5, ?6)
            ON CONFLICT(day, model) DO UPDATE SET
                calls = calls + 1,
                input = input + excluded.input,
                output = output + excluded.output,
                cache_read = cache_read + excluded.cache_read,
                cache_write = cache_write + excluded.cache_write
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, day, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, model, -1, Self.transient)
        sqlite3_bind_int64(stmt, 3, Int64(input))
        sqlite3_bind_int64(stmt, 4, Int64(output))
        sqlite3_bind_int64(stmt, 5, Int64(cacheRead))
        sqlite3_bind_int64(stmt, 6, Int64(cacheWrite))
        let stepped = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return stepped
    }

    // MARK: - Helpers
}
