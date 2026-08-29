import Foundation
import SQLite3

/// Shared helpers for reading Cursor's `state.vscdb` (SQLite). Both the session
/// monitor and the usage-stats monitor open the same DB read-only with the same
/// flags and read TEXT columns the same way, so the open + column-read logic
/// lives here once. `FULLMUTEX` makes the handle thread-safe; `READONLY` + WAL
/// means we never contend with Cursor's writer.
enum CursorDB {
    /// Open Cursor's state DB read-only. Returns nil (and cleans up) if the DB
    /// file is missing or can't be opened. Caller owns the handle and must
    /// `sqlite3_close` it.
    static func open() -> OpaquePointer? {
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

    /// Read a TEXT column using its byte length — needed for the large JSON
    /// `value` column so embedded / multi-byte UTF-8 round-trips correctly
    /// (a plain `String(cString:)` would truncate at the first NUL).
    static func textColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let bytes = sqlite3_column_text(stmt, idx) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, idx))
        return String(bytes: UnsafeBufferPointer(start: bytes, count: len), encoding: .utf8)
    }

    /// Read a TEXT column as a Swift String via `cString` — safe for plain
    /// ASCII text like the composerId UUID column, where NUL-termination is
    /// fine and the byte-length dance is unnecessary overhead.
    static func cString(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let cs = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: cs)
    }
}
