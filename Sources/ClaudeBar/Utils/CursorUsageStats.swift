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
        guard let db = CursorDB.open() else { return nil }
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
            guard let raw = CursorDB.textColumn(stmt, 0),
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tc = obj["tokenCount"] as? [String: Any] else { continue }
            let input = JSONCoerce.intVal(tc["inputTokens"])
            let output = JSONCoerce.intVal(tc["outputTokens"])
            if input == 0 && output == 0 { continue }
            usage.calls += 1
            usage.inputTokens += input
            usage.outputTokens += output
        }
        return usage.totalTokens > 0 ? usage : nil
    }
}
