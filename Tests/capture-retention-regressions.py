#!/usr/bin/env python3
"""The capture store's page reclamation, against a real SQLite file.

`pruneLocked()` deletes everything past the newest 120 captures and then, past a
freelist threshold, runs `VACUUM` to give those pages back to the filesystem.
The pragma that measures the freelist used to be read *inside* an open statement
whose `defer { sqlite3_finalize }` had not run yet, and SQLite refuses `VACUUM`
while any statement is open — "cannot VACUUM - SQL statements in progress",
reproduced with the raw C API before this fix. `execRaw` discards the return
code, so every attempt was a silent no-op and the file grew forever:
`proxy-capture.db` measured 84 MB with 20,581 freelist pages and two live rows.

This suite slices the **production** `pruneLocked`, `exec`, `execRaw` and
`loadListIDs`, runs them against a temporary database, and asserts the pages
come back. A regression here is invisible in every other way: the deletes still
work, the list still renders, and only the file on disk tells the story.

No app, no network, no real user data: the database is created in a temp dir.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
store = (root / 'Sources/ClaudeBar/Utils/ProxyCaptureStore.swift').read_text()


def method(signature):
    """One production method, verbatim, with `private` dropped and `static` added."""
    start = store.index('    private func ' + signature)
    end = store.index('\n    }', start) + len('\n    }')
    return store[start:end].replace('private func', 'static func', 1)


prune = method('pruneLocked()')
exec_body = method('exec(_ sql: String, args: [Bind])').replace(
    'lock.lock(); defer { lock.unlock() }\n        ', '').replace(
    'guard let db = connection() else { return false }', 'guard let db = Self.db else { return false }').replace(
    '@discardableResult\n    static func', 'static func')
exec_raw = method('execRaw(_ sql: String)').replace(
    'guard let db else { return }', 'guard let db = Self.db else { return }')
# The `Bind` helper the sliced `exec` calls. Darwin also exports a `bind`, so
# without the production one spliced in the call resolves to the socket call.
bind_helper = method('bind(_ stmt: OpaquePointer?, _ idx: Int32, _ text: String)')
live_ids = method('loadListIDs(_ db: OpaquePointer)')
sweep = method('sweepOrphanMedia()').replace(
    'let live = Set(currentLiveIDs())', 'let live = Set(Self.loadListIDs(Self.db!) ?? [])')
# `connection()` keeps its production shape — the two migration ALTERs included
# — with the opened path supplied by the fixture. The migration is the only
# writer of the `payloads.request_headers` schema, so a database file is the
# only place its two rules can actually be observed.
connection_open = method('openConnectionLocked()').replace(
    'if let db { return db }\n        if let failedAt = openFailedAt, Date().timeIntervalSince(failedAt) < Self.openRetryInterval { return nil }\n        guard sqlite3_open_v2(Self.dbURL.path, &db,',
    'if let db { return db }\n        guard sqlite3_open_v2(PruneHarness.dbPath, &db,').replace(
    'Self.openRetryInterval', 'PruneHarness.openRetryInterval').replace(
    'Self.dbURL.path', 'PruneHarness.dbPath').replace(
    'openFailedAt = Date()', 'openFailedAt = nil').replace(
    '    private func openConnectionLocked', '    static func openConnectionLocked').replace(
    '    private func hasColumn', '    static func hasColumn').replace(
    'private static let openRetryInterval', 'static let openRetryInterval').replace(
    'sqlite3_exec(db, "ALTER TABLE payloads ADD COLUMN request_headers TEXT DEFAULT \'\'", nil, nil, nil)',
    'PruneHarness.alter(db, "ALTER TABLE payloads ADD COLUMN request_headers TEXT DEFAULT \'\'")').replace(
    'sqlite3_exec(db, "ALTER TABLE captures ADD COLUMN cache_write_tokens INTEGER", nil, nil, nil)',
    'PruneHarness.alter(db, "ALTER TABLE captures ADD COLUMN cache_write_tokens INTEGER")')
assert 'SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX' in connection_open
assert 'hasColumn(db, table: "payloads", column: "request_headers")' in connection_open, \
    'the migration guard must be part of the spliced connection()'
has_column = method('hasColumn(_ db: OpaquePointer?, table: String, column: String)').replace(
    '    private func hasColumn', '    static func hasColumn')

# The status writes are the ones whose silent failure forks the list from the
# database (a row the UI shows as done while SQLite still says pending, with the
# interrupt button then doing nothing). `exec` reports whether the statement
# landed; the call sites that write state must act on that report — a log line
# is the store's only surface, so one is what this pins.
assert 'if !exec("UPDATE captures SET' in store, \
    'a failed state write must be reported, not discarded'
assert 'if !exec("""' in store and 'UPDATE payloads SET response_json' in store, \
    'a failed payload write must be reported, not discarded'
assert 'let cleared = exec("DELETE FROM captures", args: [])' in store, \
    'the clear-all DELETE must be read, not discarded'
assert 'exec("DELETE FROM captures", args: [])' not in store.replace(
    'let cleared = exec("DELETE FROM captures", args: [])', ''), \
    'no bare clear-all DELETE may remain'

harness = r'''
import Foundation
import SQLite3
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum FilePaths {
    static let capturesDir = URL(fileURLWithPath: CommandLine.arguments[1])
    static var capturePayloadsDir: URL { capturesDir }
}

/// The production prune path; storage handle and the two tunables are supplied
/// here, everything that decides what to delete and when to VACUUM is shipped.
enum PruneHarness {
    static let listLimit = 120
    static let vacuumThresholdPages: Int64 = 8_192
    static let openRetryInterval: TimeInterval = 5
    static var lastMediaSweep = Date.distantPast
    static var db: OpaquePointer?
    static var openFailedAt: Date?
    /// The file `openConnectionLocked` opens; the cases below point it at a
    /// fresh, a reopened and a pre-column database in turn.
    static var dbPath = CommandLine.arguments[2]

    /// How many statements the spliced `connection()` gave the two migration
    /// ALTERs. The count is what separates "the guard skipped the statement"
    /// from "the statement ran and failed" — both leave the same schema.
    static var alterCount = 0

    /// Issues one migration ALTER and counts it.
    static func alter(_ db: OpaquePointer?, _ sql: String) -> Int32 {
        alterCount += 1
        return sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// The production analyzer's member, so the spliced `connection()` compiles
    /// for diagnostics only — the fixture never reads a log line.
    static let logger = Logger(subsystem: "com.claudebar.fixture", category: "capture-retention")

    static func connection() -> OpaquePointer? { db }

    static func scalar(_ sql: String) -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : -1
    }

    static func freelist() -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA freelist_count", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : -1
    }
}

extension PruneHarness {
    enum Bind {
        case text(String), int(Int64), null
    }

PLACEHOLDER
}

@main struct Regression {
    static func main() throws {
        sqlite3_open(CommandLine.arguments[2], &PruneHarness.db)
        var stmt: OpaquePointer?
        sqlite3_exec(PruneHarness.db, """
            CREATE TABLE captures (id INTEGER PRIMARY KEY, body BLOB);
            CREATE TABLE payloads (capture_id INTEGER PRIMARY KEY, request_json BLOB);
            """, nil, nil, nil)
        // Enough rows that deleting them leaves a freelist above the threshold
        // — the state the real database was found in (8,192 pages ≈ 32 MB).
        sqlite3_exec(PruneHarness.db, "BEGIN", nil, nil, nil)
        sqlite3_prepare_v2(PruneHarness.db, "INSERT INTO captures (id, body) VALUES (?, zeroblob(4096))", -1, &stmt, nil)
        for id in 1...14_000 {
            sqlite3_reset(stmt); sqlite3_bind_int64(stmt, 1, Int64(id)); sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        sqlite3_prepare_v2(PruneHarness.db, "INSERT INTO payloads (capture_id, request_json) VALUES (?, zeroblob(4096))", -1, &stmt, nil)
        for id in 1...14_000 {
            sqlite3_reset(stmt); sqlite3_bind_int64(stmt, 1, Int64(id)); sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        sqlite3_exec(PruneHarness.db, "COMMIT", nil, nil, nil)
        sqlite3_exec(PruneHarness.db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        sqlite3_close(PruneHarness.db)
        PruneHarness.db = nil
        let pruneURL = PruneHarness.dbPath

        // 1. The two column migrations, on the three database shapes they have
        //    to handle — asserted through the production `connection()`, not by
        //    re-stating its SQL. The ALTER count matters because a skipped
        //    ALTER and a failed one leave the same schema: only the count can
        //    tell "the guard avoided the statement" from "the statement ran and
        //    errored invisibly".
        //
        //    (a) a database this build creates: the columns come from the
        //        CREATE TABLEs, so not one ALTER is issued. The ALTER used to
        //        run on every connection open and could only fail with
        //        "duplicate column name" — once per process, invisibly.
        PruneHarness.dbPath = CommandLine.arguments[2] + ".fresh"
        var freshBefore = PruneHarness.alterCount
        precondition(PruneHarness.openConnectionLocked() != nil, "must open a fresh database")
        precondition(PruneHarness.hasColumn(PruneHarness.db, table: "payloads", column: "request_headers"),
                     "the payloads CREATE must carry request_headers")
        precondition(PruneHarness.hasColumn(PruneHarness.db, table: "captures", column: "cache_write_tokens"),
                     "the captures CREATE must carry cache_write_tokens")
        precondition(PruneHarness.alterCount == freshBefore,
                     "a current database must issue no ALTER; issued \(PruneHarness.alterCount - freshBefore)")
        //    (b) the same file reopened: still no ALTER, even though the
        //        columns are now found on an existing table.
        PruneHarness.db = nil
        freshBefore = PruneHarness.alterCount
        precondition(PruneHarness.openConnectionLocked() != nil, "must reopen the database")
        precondition(PruneHarness.hasColumn(PruneHarness.db, table: "payloads", column: "request_headers"),
                     "…and must keep the column")
        precondition(PruneHarness.alterCount == freshBefore,
                     "reopening must issue no ALTER; issued \(PruneHarness.alterCount - freshBefore)")
        PruneHarness.db = nil
        //    (c) a *pre-column* database: the legacy ALTER still runs, once per
        //        column, and the columns come out present.
        let legacyURL = CommandLine.arguments[2] + ".legacy"
        PruneHarness.dbPath = legacyURL
        var legacy: OpaquePointer?
        precondition(sqlite3_open(legacyURL, &legacy) == SQLITE_OK)
        sqlite3_exec(legacy, """
            CREATE TABLE payloads (capture_id INTEGER PRIMARY KEY, request_json TEXT);
            CREATE TABLE captures (id INTEGER PRIMARY KEY, started_at TEXT NOT NULL);
            """, nil, nil, nil)
        sqlite3_close(legacy)
        let legacyBefore = PruneHarness.alterCount
        precondition(PruneHarness.openConnectionLocked() != nil, "must open a pre-column database")
        precondition(PruneHarness.hasColumn(PruneHarness.db, table: "payloads", column: "request_headers"),
                     "a pre-column payloads table must gain request_headers")
        precondition(PruneHarness.hasColumn(PruneHarness.db, table: "captures", column: "cache_write_tokens"),
                     "a pre-column captures table must gain cache_write_tokens")
        precondition(PruneHarness.alterCount == legacyBefore + 2,
                     "each missing column must be added exactly once; issued \(PruneHarness.alterCount - legacyBefore)")
        PruneHarness.db = nil
        //    The prune case runs on the database the launch path created; its
        //    own connection() is not re-run (the rows are inserted by hand).
        PruneHarness.dbPath = pruneURL
        sqlite3_open(pruneURL, &PruneHarness.db)

        // The freelist is only populated *by* the deletes, so the size that
        // matters is measured around them: `page_count` before the prune, and
        // the freelist after it.
        let pagesFull = PruneHarness.scalar("PRAGMA page_count")
        PruneHarness.lastMediaSweep = Date()     // skip the media sweep, not under test
        PruneHarness.pruneLocked()
        let pagesSlim = PruneHarness.scalar("PRAGMA page_count")
        let after = PruneHarness.freelist()
        let live = PruneHarness.loadListIDs(PruneHarness.db!) ?? []
        precondition(live.count == 120, "the prune keeps the newest 120 rows, got \(live.count)")
        precondition(live.first == 13_881 && live.last == 14_000,
                     "it keeps the *newest* 120, got \(live.first ?? -1)…\(live.last ?? -1)")
        precondition(PruneHarness.db != nil)
        var remaining: OpaquePointer?
        var payloads = 0
        if sqlite3_prepare_v2(PruneHarness.db, "SELECT count(*) FROM payloads", -1, &remaining, nil) == SQLITE_OK,
           sqlite3_step(remaining) == SQLITE_ROW {
            payloads = Int(sqlite3_column_int64(remaining, 0))
        }
        sqlite3_finalize(remaining)
        precondition(payloads == 120, "payload rows are pruned with their captures, got \(payloads)")
        precondition(pagesSlim * 2 < pagesFull,
                     "pruneLocked must return the freed pages to the file: \(pagesFull) -> \(pagesSlim) pages")
        precondition(after == 0, "the VACUUM must actually run: freelist after \(after)")
        print("PASS: capture prune keeps the newest 120 rows and returns their pages to the filesystem")
    }
}
'''

source = ('import Foundation\nimport SQLite3\nimport os\n' + harness).replace(
    'PLACEHOLDER',
    '\n'.join([bind_helper, prune, exec_body, exec_raw, live_ids, sweep,
               connection_open, has_column]))

with tempfile.TemporaryDirectory(prefix='claudebar-capture-') as tmp:
    folder = Path(tmp)
    (folder / 'captures').mkdir()
    swift = folder / 'Regression.swift'
    swift.write_text(source)
    binary = folder / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder / 'captures'), str(folder / 'capture.db')], check=True)
