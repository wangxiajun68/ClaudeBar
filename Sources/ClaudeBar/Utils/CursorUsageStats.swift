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
struct CursorUsageStats {

    /// Scan all `bubbleId:*` rows in `cursorDiskKV` and sum their token counts
    /// into one `ModelUsage(model: "Cursor")`. Returns nil if the DB is
    /// unavailable or no tokens are found.
    static func fetch() -> ModelUsage? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }

        // cursorDiskKV has no usable index on token counts, and bubble
        // timestamps (createdAt) are ISO strings present on only ~78% of rows.
        // We do a single full table scan of the value column.
        let sql = "SELECT value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var usage = ModelUsage(model: "Cursor")
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let raw = textColumn(stmt, 0),
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tc = obj["tokenCount"] as? [String: Any] else { continue }
            let input = intVal(tc["inputTokens"])
            let output = intVal(tc["outputTokens"])
            if input == 0 && output == 0 { continue }
            usage.calls += 1
            usage.inputTokens += input
            usage.outputTokens += output
        }
        return usage.totalTokens > 0 ? usage : nil
    }

    // MARK: - SQLite helpers

    /// Open Cursor's state DB read-only. WAL mode allows concurrent readers, so
    /// this never contends with Cursor's writer. Mirrors `CursorSessionMonitor`.
    private static func openDB() -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: FilePaths.cursorStateDB.path) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(FilePaths.cursorStateDB.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
        return db
    }

    /// Read a TEXT/BLOB column using its byte length — needed for the large
    /// JSON `value` column so embedded multi-byte UTF-8 round-trips correctly.
    private static func textColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let bytes = sqlite3_column_text(stmt, idx) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, idx))
        return String(bytes: UnsafeBufferPointer(start: bytes, count: len), encoding: .utf8)
    }

    /// Coerce a JSON number (Int / NSNumber / numeric String) to Int.
    private static func intVal(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let n = Int(s) { return n }
        return 0
    }
}
