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
    'guard useDatabase, let db = connection() else { return }', 'guard let db = Self.db else { return }')
exec_raw = method('execRaw(_ sql: String)').replace(
    'guard let db else { return }', 'guard let db = Self.db else { return }')
# The `Bind` helper the sliced `exec` calls. Darwin also exports a `bind`, so
# without the production one spliced in the call resolves to the socket call.
bind_helper = method('bind(_ stmt: OpaquePointer?, _ idx: Int32, _ text: String)')
live_ids = method('loadListIDs(_ db: OpaquePointer)')
sweep = method('sweepOrphanMedia()').replace(
    'let live = Set(currentLiveIDs())', 'let live = Set(Self.loadListIDs(Self.db!) ?? [])')

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
    static var lastMediaSweep = Date.distantPast
    static var db: OpaquePointer?

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

source = ('import Foundation\nimport SQLite3\n' + harness).replace(
    'PLACEHOLDER',
    '\n'.join([bind_helper, prune, exec_body, exec_raw, live_ids, sweep]))

with tempfile.TemporaryDirectory(prefix='claudebar-capture-') as tmp:
    folder = Path(tmp)
    (folder / 'captures').mkdir()
    swift = folder / 'Regression.swift'
    swift.write_text(source)
    binary = folder / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder / 'captures'), str(folder / 'capture.db')], check=True)
