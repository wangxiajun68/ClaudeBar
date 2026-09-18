import Foundation
import SQLite3

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
/// Backends mirror `UsageIndex`: SQLite when 存储 → SQLite is on, JSONL
/// otherwise. Never migrated between them.
final class ProxyUsageStore {
    static let shared = ProxyUsageStore()

    /// One (day, model) bucket. Disjoint by construction: `input` is fresh
    /// input only (cached input is reported separately by the upstreams and
    /// stored in `cacheRead`).
    struct Row {
        var day: String
        var model: String
        var calls: Int
        var input: Int
        var output: Int
        var cacheRead: Int
    }

    private let lock = NSLock()
    private var db: OpaquePointer?
    private var openFailed = false
    private var rows: [String: Row] = [:]
    private var loaded = false

    private static let dbURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("proxy-usage.db")
    }()

    private var useDatabase: Bool { DiskPersistence.useDatabase }
    private var jsonURL: URL { FilePaths.logsDir.appendingPathComponent("usage-third-party.jsonl") }

    /// `SQLITE_TRANSIENT` equivalent — the constant in `UsageIndex.swift` is
    /// module-wide, but naming it here keeps this file independent of that
    /// file's declaration order.
    private static let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    private init() {}

    // MARK: - Write

    /// Fold one finished proxied request into the rollup. Additive: repeat
    /// calls for the same (day, model) accumulate.
    func record(model: String, at date: Date, input: Int, output: Int, cacheRead: Int) {
        let name = model.isEmpty ? "unknown" : model
        let day = Self.dayString(date)
        guard input > 0 || output > 0 || cacheRead > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if useDatabase {
            guard let db = connectionLocked() else { return }
            upsertSQL(db, day: day, model: name, input: input, output: output, cacheRead: cacheRead)
        } else {
            loadJSONLocked()
            var row = rows[Self.key(day, name)] ?? Row(day: day, model: name, calls: 0,
                                                       input: 0, output: 0, cacheRead: 0)
            row.calls += 1
            row.input += input
            row.output += output
            row.cacheRead += cacheRead
            rows[Self.key(day, name)] = row
            persistJSONLocked()
        }
    }

    // MARK: - Read

    /// Per-model third-party usage in `[startDay, endDay]`.
    func fetch(startDay: String, endDay: String) -> [ModelUsage] {
        var byModel: [String: ModelUsage] = [:]
        for row in allRows() where row.day >= startDay && row.day <= endDay {
            var usage = byModel[row.model] ?? ModelUsage(model: row.model)
            usage.calls += row.calls
            usage.inputTokens += row.input
            usage.outputTokens += row.output
            usage.cacheReadTokens += row.cacheRead
            byModel[row.model] = usage
        }
        return byModel.values.filter { $0.totalTokens > 0 }.sorted { $0.totalTokens > $1.totalTokens }
    }

    /// Per-day totals, for the usage river.
    func fetchDaily(startDay: String, endDay: String) -> [DayUsage] {
        var byDay: [String: DayUsage] = [:]
        for row in allRows() where row.day >= startDay && row.day <= endDay {
            var day = byDay[row.day] ?? DayUsage(day: row.day)
            day.inputTokens += row.input
            day.outputTokens += row.output
            day.cacheReadTokens += row.cacheRead
            byDay[row.day] = day
        }
        return byDay.values.filter { $0.totalTokens > 0 }.sorted { $0.day < $1.day }
    }

    private func allRows() -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        if !useDatabase {
            loadJSONLocked()
            return Array(rows.values)
        }
        guard let db = connectionLocked() else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT day, model, calls, input, output, cache_read FROM usage"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Row(
                day: String(cString: sqlite3_column_text(stmt, 0)),
                model: String(cString: sqlite3_column_text(stmt, 1)),
                calls: Int(sqlite3_column_int64(stmt, 2)),
                input: Int(sqlite3_column_int64(stmt, 3)),
                output: Int(sqlite3_column_int64(stmt, 4)),
                cacheRead: Int(sqlite3_column_int64(stmt, 5))))
        }
        return out
    }

    /// Drop everything (used when the persistence backend switches).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        if let handle = db {
            sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            sqlite3_close(handle)
            db = nil
        }
        openFailed = false
        rows = [:]
        loaded = false
    }

    // MARK: - SQLite

    private func connectionLocked() -> OpaquePointer? {
        if let db { return db }
        if openFailed { return nil }
        guard sqlite3_open_v2(Self.dbURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            openFailed = true
            return nil
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-500", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS usage (
                day TEXT NOT NULL,
                model TEXT NOT NULL,
                calls INTEGER NOT NULL DEFAULT 0,
                input INTEGER NOT NULL DEFAULT 0,
                output INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (day, model)
            ) WITHOUT ROWID;
            """, nil, nil, nil)
        return db
    }

    private func upsertSQL(_ db: OpaquePointer, day: String, model: String,
                           input: Int, output: Int, cacheRead: Int) {
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO usage(day, model, calls, input, output, cache_read)
            VALUES(?1, ?2, 1, ?3, ?4, ?5)
            ON CONFLICT(day, model) DO UPDATE SET
                calls = calls + 1,
                input = input + excluded.input,
                output = output + excluded.output,
                cache_read = cache_read + excluded.cache_read
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, day, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, model, -1, Self.transient)
        sqlite3_bind_int64(stmt, 3, Int64(input))
        sqlite3_bind_int64(stmt, 4, Int64(output))
        sqlite3_bind_int64(stmt, 5, Int64(cacheRead))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - JSON backend

    private func loadJSONLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: jsonURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let row = try? dec.decode(JSONRow.self, from: Data(line.utf8)) else { continue }
            rows[Self.key(row.day, row.model)] = Row(day: row.day, model: row.model,
                                                     calls: row.calls, input: row.input,
                                                     output: row.output, cacheRead: row.cacheRead)
        }
    }

    private struct JSONRow: Codable {
        var day: String
        var model: String
        var calls: Int
        var input: Int
        var output: Int
        var cacheRead: Int
    }

    private func persistJSONLocked() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var body = ""
        for row in rows.values.sorted(by: { $0.day == $1.day ? $0.model < $1.model : $0.day < $1.day }) {
            let jsonRow = JSONRow(day: row.day, model: row.model, calls: row.calls,
                                  input: row.input, output: row.output, cacheRead: row.cacheRead)
            guard let data = try? enc.encode(jsonRow), let line = String(data: data, encoding: .utf8) else { continue }
            body += line + "\n"
        }
        try? Data(body.utf8).write(to: jsonURL, options: .atomic)
    }

    // MARK: - Helpers

    private static func key(_ day: String, _ model: String) -> String {
        day + "\u{1F}" + model
    }

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
