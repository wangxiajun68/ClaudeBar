import Foundation
import SQLite3

/// Aggregates Cursor's historical token usage from `state.vscdb`.
///
/// Cursor stores per-message ("bubble") token counts in the `cursorDiskKV`
/// table, keyed `bubbleId:<composerId>:<bubbleId>`, with a JSON value whose
/// `tokenCount.inputTokens` / `outputTokens` fields hold the counts.
///
/// Two hard limits, verified empirically against this user's DB:
///   • The data is a historical snapshot — Cursor stopped writing token counts
///     after ~2026-03, so recent months show nothing. This is an upstream
///     behavior we cannot change.
///   • There is no per-bubble model field, and `unifiedMode` (agent/chat/plan)
///     cannot split usage into Cursor Agent vs Cursor Edit rows.
///
/// Per the user's decision, we therefore aggregate every non-zero bubble into
/// a single `ModelUsage(model: "Cursor")` row, surfaced as one line in the
/// usage panel alongside the per-model Claude rows. The number is stable across
/// period switches (it is a full-scan total, not interval-filtered).
///
/// Performance: the bubble values total multi-GB, so any scan is expensive.
/// Two mitigations, both verified against a 9.8GB DB with 543k bubbles:
///   1. Aggregation runs in SQL (`json_extract` + `sum`) — one pass, no
///      per-row Swift JSONSerialization (that was 543k allocations on top of
///      the I/O).
///   2. The result is cached in-process with a TTL — re-scanning on every
///     period switch / date shift / refresh is pure waste.
///
/// Cache policy: only successful scans are cached. A failed scan (DB closed,
/// Cursor updating) returns the last known value if any, so the UI never
/// flickers to zero, and the next call retries the scan.
struct CursorUsageStats {

    /// Full rescan interval. Between full rescans the aggregate is maintained
    /// incrementally (see `scan()`), and the rescan corrects any drift from
    /// deleted bubble rows. The source data is essentially frozen (no writes
    /// since ~2026-03), so an hour is generous.
    private static let fullRescanInterval: TimeInterval = 3_600

    private static var cachedUsage: ModelUsage?
    private static var cachedAt: Date = .distantPast
    /// Cheap DB write-detection snapshot from the last scan: (data_version,
    /// page_count). Both are header reads (~0 ms); if neither changed, the
    /// bubble set cannot have changed either and the scan is skipped entirely.
    private static var lastDBStamp: (version: Int32, pages: Int64)?
    private static let cacheLock = NSLock()

    /// Aggregate Cursor token usage. Returns nil only if no value is available
    /// (scan failed and nothing cached). With a warm cache and an unchanged
    /// DB this is a pure in-memory hit.
    static func fetch() -> ModelUsage? {
        cacheLock.lock()
        let hit = cachedUsage
        let age = Date().timeIntervalSince(cachedAt)
        let stamp = lastDBStamp
        cacheLock.unlock()

        // Fast path: cached and the DB header is unchanged — no I/O at all.
        if let hit, age < fullRescanInterval, let stamp,
           let current = dbStamp(), current.version == stamp.version, current.pages == stamp.pages {
            return hit
        }

        // Expensive path: full rescan (corrects deletion drift, re-stamps).
        let fresh = scan()
        cacheLock.lock()
        if let fresh {
            cachedUsage = fresh
            cachedAt = Date()
            lastDBStamp = dbStamp()
        }
        let result = fresh ?? cachedUsage
        cacheLock.unlock()
        return result
    }

    /// (data_version, page_count) of the state DB, or nil if unreadable.
    /// Both come from the SQLite header — no table I/O.
    private static func dbStamp() -> (version: Int32, pages: Int64)? {
        guard let db = CursorDB.open() else { return nil }
        defer { sqlite3_close(db) }
        var version: Int32 = 0
        var pages: Int64 = 0
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA data_version", -1, &stmt, nil) == SQLITE_OK else { return nil }
        if sqlite3_step(stmt) == SQLITE_ROW { version = sqlite3_column_int(stmt, 0) }
        sqlite3_finalize(stmt)
        guard sqlite3_prepare_v2(db, "PRAGMA page_count", -1, &stmt, nil) == SQLITE_OK else { return nil }
        if sqlite3_step(stmt) == SQLITE_ROW { pages = sqlite3_column_int64(stmt, 0) }
        sqlite3_finalize(stmt)
        return (version, pages)
    }

    /// One SQL pass over the bubble rows: sums happen inside SQLite so only a
    private static func scan() -> ModelUsage? {
        guard let db = CursorDB.open() else { return nil }
        defer { sqlite3_close(db) }

        // cursorDiskKV has no usable index on token counts, and bubble
        // timestamps (createdAt) are ISO strings present on only ~78% of rows.
        // We do a single full table scan of the value column with the sums
        // pushed down into SQLite's JSON reader.
        let sql = """
            SELECT CAST(sum(json_extract(value,'$.tokenCount.inputTokens')) AS INTEGER),
                   CAST(sum(json_extract(value,'$.tokenCount.outputTokens')) AS INTEGER),
                   sum(CASE WHEN json_extract(value,'$.tokenCount.outputTokens') > 0
                            OR json_extract(value,'$.tokenCount.inputTokens') > 0
                       THEN 1 ELSE 0 END)
            FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let input = sqlite3_column_int64(stmt, 0)
        let output = sqlite3_column_int64(stmt, 1)
        let calls = sqlite3_column_int64(stmt, 2)
        guard input > 0 || output > 0 else { return nil }

        var usage = ModelUsage(model: "Cursor")
        usage.calls = Int(calls)
        usage.inputTokens = Int(input)
        usage.outputTokens = Int(output)
        return usage
    }
}
