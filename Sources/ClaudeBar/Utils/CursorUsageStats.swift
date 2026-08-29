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
///   2. The result is cached in-process and refreshed at most once per
///     `cacheTTL` — Cursor stopped writing this data, so re-scanning on every
///     period switch / date shift / refresh is pure waste.
struct CursorUsageStats {

    /// How long a computed aggregate stays valid. The source data is frozen
    /// (no writes since ~2026-03), so this only guards against the rare case
    /// of Cursor resuming writes; 10 minutes keeps it fresh without any
    /// realistic cost.
    private static let cacheTTL: TimeInterval = 600

    private static var cachedUsage: ModelUsage?
    private static var cachedAt: Date = .distantPast
    private static let cacheLock = NSLock()

    /// Scan all `bubbleId:*` rows in `cursorDiskKV` and sum their token counts
    /// into one `ModelUsage(model: "Cursor")`. Returns nil if the DB is
    /// unavailable or no tokens are found. Result is cached (see `cacheTTL`).
    static func fetch() -> ModelUsage? {
        cacheLock.lock()
        let hit = cachedUsage
        let age = Date().timeIntervalSince(cachedAt)
        cacheLock.unlock()
        if let hit, age < cacheTTL { return hit }

        let fresh = scan()
        cacheLock.lock()
        if let fresh {
            cachedUsage = fresh
            cachedAt = Date()
        }
        cacheLock.unlock()
        return fresh ?? cachedUsage
    }

    /// One SQL pass over the bubble rows: sums happen inside SQLite so only a
    /// single aggregate row crosses into Swift.
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
