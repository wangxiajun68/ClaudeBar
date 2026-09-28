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

// MARK: - Credentials

/// Cursor's signed-in account, read from the same `state.vscdb` the session
/// monitor uses.
///
/// Every field is optional on purpose: Cursor has shipped this row set under
/// `cursorAuth/*` for a long time, but the *shape* of what it stores (and which
/// keys exist at all) has drifted across builds and differs for free / Pro /
/// Ultra / enterprise accounts. A missing key must degrade to "unknown", not
/// crash the read.
///
/// The tokens live in `ItemTable`, a single-column-per-row key/value table.
/// `accessToken` is a **424-byte** JWT, which is why the value is read with
/// `textColumn` and never `cString` — the latter truncates at the first NUL
/// byte and would hand a corrupt token to the API.
struct CursorCredentials: Equatable {
    /// The raw access token, used verbatim as `Authorization: Bearer <jwt>`.
    var accessToken: String?
    /// `sub` from the JWT payload, e.g. `google-oauth2|user_01…`. Only the
    /// cookie-authenticated web endpoints need it, and only percent-encoded.
    var subject: String?
    var email: String?
    /// `pro` / `ultra` / `free`, from `stripeMembershipType`.
    var membershipType: String?
    /// `active` / `canceled`, from `stripeSubscriptionStatus`.
    var subscriptionStatus: String?

    /// Whether there is enough here to call the usage API at all.
    var canQueryUsage: Bool { accessToken?.isEmpty == false }
}

extension CursorDB {
    /// Read the account row set. Returns `nil` when the DB is missing, so the
    /// caller can tell "no Cursor installed" from "installed but signed out"
    /// (which comes back as an all-optional, `canQueryUsage == false` value).
    ///
    /// Read **fresh every time**: Cursor rotates the access token in place
    /// while the IDE runs, so a cached token goes stale within the hour and the
    /// probe starts 401ing. The read is one indexed SELECT against a read-only
    /// WAL handle, so re-reading per refresh is cheap.
    static func readCredentials() -> CursorCredentials? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }

        let wanted: Set<String> = [
            "cursorAuth/accessToken",
            "cursorAuth/cachedEmail",
            "cursorAuth/stripeMembershipType",
            "cursorAuth/stripeSubscriptionStatus",
        ]
        // One statement, keys bound by `IN`, so this is a single scan of
        // `ItemTable`'s primary-key index rather than five round trips.
        let sql = "SELECT key, value FROM ItemTable WHERE key IN (?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (offset, key) in wanted.sorted().enumerated() {
            sqlite3_bind_text(stmt, Int32(offset + 1), key, -1, SQLITE_TRANSIENT)
        }

        var values: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let key = textColumn(stmt, 0), let value = textColumn(stmt, 1) else { continue }
            values[key] = value
        }

        let token = values["cursorAuth/accessToken"]
        return CursorCredentials(
            accessToken: token,
            subject: token.flatMap(jwtSubject),
            email: values["cursorAuth/cachedEmail"],
            membershipType: values["cursorAuth/stripeMembershipType"],
            subscriptionStatus: values["cursorAuth/stripeSubscriptionStatus"]
        )
    }

    /// Decode the `sub` claim from a JWT's payload segment.
    ///
    /// The payload is base64url **without** padding, which both `Data(base64Encoded:)`
    /// and a naive `base64Encoded` round-trip reject — it has to be re-padded and
    /// translated to the standard alphabet first. The signature is never checked:
    /// this is *our own* locally stored session token, and all we need is a
    /// non-secret identifier to percent-encode into the cookie.
    static func jwtSubject(_ token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String,
              !subject.isEmpty else { return nil }
        return subject
    }
}
