import Foundation
import SQLite3

/// Aggregates Cursor's historical token usage from `state.vscdb`.
///
/// Cursor stores per-message ("bubble") token counts in the `cursorDiskKV`
/// table, keyed `bubbleId:<composerId>:<bubbleId>`. The data is a historical
/// snapshot — Cursor stopped writing token counts after ~2026-03 — so a
/// full `json_extract` pass over a multi-GB DB is paid **once**, then persisted
/// in `usage-index.db`. Period chips never open `state.vscdb`.
struct CursorUsageStats {

    private static var cachedUsage: ModelUsage?
    private static var cachedStamp: (version: Int32, pages: Int64)?
    private static let cacheLock = NSLock()

    /// In-memory / persisted aggregate. Never scans `state.vscdb`.
    static func fetch() -> ModelUsage? {
        cacheLock.lock()
        if let hit = cachedUsage {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        guard let row = UsageIndex.loadCursorTotals() else { return nil }
        let usage = usage(from: row)
        cacheLock.lock()
        cachedUsage = usage
        cachedStamp = (row.dbVersion, row.pageCount)
        cacheLock.unlock()
        return usage
    }

    /// Compare the Cursor DB header to the persisted stamp. Scan only when
    /// the bubble set could have changed (or we have never scanned).
    static func refreshIfNeeded() {
        let stamp = dbStamp()
        cacheLock.lock()
        let known = cachedStamp
        cacheLock.unlock()

        if let stamp, let known, stamp.version == known.version, stamp.pages == known.pages {
            if cachedUsage == nil { _ = fetch() }
            return
        }
        if let row = UsageIndex.loadCursorTotals(),
           let stamp,
           row.dbVersion == stamp.version, row.pageCount == stamp.pages {
            let usage = usage(from: row)
            cacheLock.lock()
            cachedUsage = usage
            cachedStamp = stamp
            cacheLock.unlock()
            return
        }
        guard let fresh = scan(), let stamp else { return }
        UsageIndex.saveCursorTotals(.init(
            input: fresh.inputTokens,
            output: fresh.outputTokens,
            calls: fresh.calls,
            dbVersion: stamp.version,
            pageCount: stamp.pages))
        cacheLock.lock()
        cachedUsage = fresh
        cachedStamp = stamp
        cacheLock.unlock()
    }

    private static func usage(from row: UsageIndex.CursorRow) -> ModelUsage {
        var usage = ModelUsage(model: "Cursor")
        usage.calls = row.calls
        usage.inputTokens = row.input
        usage.outputTokens = row.output
        return usage
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

    private static func scan() -> ModelUsage? {
        guard let db = CursorDB.open() else { return nil }
        defer { sqlite3_close(db) }

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
