#!/usr/bin/env python3
"""Exercise the production Cursor monitor against a temporary SQLite DB + JSONL.

Only FilePaths' home directory is redirected. No copied state predicates, Cursor
account data, app build, installation, or live database writes are involved.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
utils = root / 'Sources/ClaudeBar/Utils'
swift = r'''
import Foundation
import SQLite3
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
let fixtureHome = URL(fileURLWithPath: CommandLine.arguments[1])

func runTests() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: FilePaths.cursorStateDB.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    precondition(sqlite3_open(FilePaths.cursorStateDB.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    precondition(sqlite3_exec(db, "CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, recency INTEGER, checkpointAt INTEGER, isArchived INTEGER, isSubagent INTEGER, value TEXT)", nil, nil, nil) == SQLITE_OK)
    let now = Date().timeIntervalSince1970 * 1000
    let cwd = "/fixture/project"
    let user = #"{"role":"user","message":{"content":[{"type":"text","text":"Continue"}]}}"# + "\n"
    let assistant = #"{"role":"assistant","message":{"content":[{"type":"text","text":"Working"}]}}"# + "\n"
    let success = #"{"type":"turn_ended","status":"success"}"# + "\n"
    let error = #"{"type":"turn_ended","status":"error"}"# + "\n"
    var failures: [String] = []
    var checks = 0
    func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures.append(message); print("FAIL: \(message)") }
    }
    func reset() {
        precondition(sqlite3_exec(db, "DELETE FROM composerHeaders", nil, nil, nil) == SQLITE_OK)
        try? fm.removeItem(at: FilePaths.cursorProjectsDir)
    }
    func add(_ id: String, headAge: Double = 1, recencyAge: Double? = nil, checkpointAge: Double? = nil,
             unfinishedAge: Double? = nil, transcript: String? = nil,
             transcriptAge: Double = 1, locationActive: Bool = true,
             archived: Bool = false, parent: String? = nil, rootParent: String? = nil,
             pendingPlan: Bool = false, blocking: Bool = false) throws {
        var obj: [String: Any] = ["composerId": id, "name": id,
            "createdAt": now - headAge * 1000, "lastUpdatedAt": now - headAge * 1000,
            "workspaceIdentifier": ["uri": ["fsPath": cwd]],
            "agentLocation": ["status": locationActive ? "active" : "idle"]]
        if let parent {
            obj["subagentInfo"] = ["parentComposerId": parent, "rootParentConversationId": rootParent ?? parent,
                                   "subagentTypeName": "explore"]
        }
        if let unfinishedAge { obj["unfinishedRunAt"] = now - unfinishedAge * 1000 }
        if pendingPlan { obj["hasPendingPlan"] = true }
        if blocking { obj["hasBlockingPendingActions"] = true }
        if let checkpointAge { obj["conversationCheckpointLastUpdatedAt"] = now - checkpointAge * 1000 }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        var stmt: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, "INSERT INTO composerHeaders VALUES (?, ?, ?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, now - (recencyAge ?? headAge) * 1000)
        if let checkpointAge { sqlite3_bind_double(stmt, 3, now - checkpointAge * 1000) }
        sqlite3_bind_int(stmt, 4, archived ? 1 : 0)
        sqlite3_bind_int(stmt, 5, parent == nil ? 0 : 1)
        sqlite3_bind_text(stmt, 6, json, -1, SQLITE_TRANSIENT)
        precondition(sqlite3_step(stmt) == SQLITE_DONE)
        if let transcript {
            let url: URL
            if let parent {
                url = FilePaths.cursorTranscriptURL(cwd: cwd, composerId: rootParent ?? parent)
                    .deletingLastPathComponent().appendingPathComponent("subagents/\(id).jsonl")
            } else {
                url = FilePaths.cursorTranscriptURL(cwd: cwd, composerId: id)
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try transcript.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: now / 1000 - transcriptAge)], ofItemAtPath: url.path)
        }
    }
    func session(_ id: String) -> CursorSessionInfo? {
        CursorSessionMonitor.fetchActive().first { $0.composerId == id }
    }
    // Production `isBusy` (not a local re-derivation): the monitor's own
    // `status == .active || toolPending` pair *is* what `isBusy` means, so
    // reading the published property keeps this helper from drifting from the
    // predicate the whole app filters on.
    func busy(_ id: String) -> Bool {
        guard let s = session(id) else { return false }
        return s.isAlive && s.isBusy
    }
    /// The third state: parked on the user. Cursor writes it into the head's
    /// own flags (`hasPendingPlan` / `hasBlockingPendingActions`), which the
    /// monitor used to ignore entirely — a plan waiting to be applied read as
    /// 运行中 on every surface.
    func parked(_ id: String) -> Bool {
        guard let s = session(id) else { return false }
        return s.isAlive && s.isWaiting && !s.isBusy
    }
    func waiting(_ id: String, pendingPlan: Bool = false, blocking: Bool = false) throws {
        try add(id, headAge: 1, pendingPlan: pendingPlan, blocking: blocking)
    }

    // Observed failure: SQLite checkpoints keep moving for a 16-minute run,
    // while JSONL is still at its user message. Header submission time is old.
    try add("checkpoint-live", headAge: 1000, checkpointAge: 5, unfinishedAge: 1000,
            transcript: assistant + success + user, transcriptAge: 980)
    check(busy("checkpoint-live"), "a fresh checkpoint must keep a long run visible while JSONL lags")
    try add("missing-transcript", headAge: 1000, checkpointAge: 5, unfinishedAge: 1000)
    check(busy("missing-transcript"), "checkpoint evidence must work without a transcript")
    try add("waiting-first-token", headAge: 180, transcript: user, transcriptAge: 180, locationActive: false)
    check(busy("waiting-first-token"), "a recent user message starts a turn before the first assistant block")
    // Cursor reports the composer "active" the moment a turn is submitted,
    // while its JSONL has not been written yet. For the first two minutes that
    // location is the only evidence a run exists, and without it a just-sent
    // prompt showed as idle. No transcript and no checkpoint here: the grace
    // period is what the check isolates.
    try add("startup-grace", headAge: 30, locationActive: true)
    check(busy("startup-grace"), "a just-submitted turn is busy before any write")
    try add("fresh-stream", headAge: 3600, transcript: user + assistant, transcriptAge: 5)
    check(busy("fresh-stream"), "a recent assistant write must keep an old header live")
    try add("quiet-tool", headAge: 3600, transcript: user + assistant, transcriptAge: 480)
    check(busy("quiet-tool"), "a tool quiet for eight minutes stays live")
    try add("frozen", headAge: 16 * 3600, checkpointAge: 16 * 3600,
            unfinishedAge: 16 * 3600, transcript: user + assistant, transcriptAge: 16 * 3600)
    check(!busy("frozen"), "an abandoned run must expire despite sticky active and unfinished flags")
    try add("expired", headAge: 3600, transcript: user + assistant, transcriptAge: 630)
    check(!busy("expired"), "a frozen transcript past the ten-minute window must expire")
    try add("completed", headAge: 1200, checkpointAge: 1, transcript: user + assistant + success)
    check(!busy("completed"), "a completed turn with a fresh checkpoint and sticky location is idle")
    check(session("completed")?.completionID != nil, "successful final text keeps its completion key")
    check(now - (session("completed")?.lastUpdatedAt ?? 0) < 5000,
          "completion freshness uses the write clock, not submission time")
    try add("ended-sticky", headAge: 100, checkpointAge: 1, unfinishedAge: 100,
            transcript: user + assistant + success)
    check(!busy("ended-sticky"), "a current terminal marker beats a stale unfinished flag")
    try add("error", headAge: 100, checkpointAge: 1, unfinishedAge: 100,
            transcript: user + assistant + error)
    check(!busy("error"), "a current error marker ends the run too")
    check(session("error")?.completionID == nil, "an error cannot announce successful completion")
    try add("new-run-old-answer", headAge: 180, checkpointAge: 5, unfinishedAge: 180,
            transcript: user + assistant + success, transcriptAge: 600)
    check(busy("new-run-old-answer"), "an old answer cannot cancel a newer unfinished run")
    check(session("new-run-old-answer")?.completionID == nil,
          "a resumed run must not publish the previous answer's completion key")
    try add("archived", headAge: 1, checkpointAge: 1, unfinishedAge: 1, archived: true)
    check(session("archived") == nil, "archived sessions stay hidden")

    reset()
    for n in 0..<90 { try add("idle-\(n)", headAge: Double(n + 1), transcript: assistant + success) }
    try add("below-80", headAge: 3600, checkpointAge: 2, unfinishedAge: 3600,
            transcript: user, transcriptAge: 3600)
    check(busy("below-80"), "a running session below the old 80-row query limit must be discovered")
    check(CursorSessionMonitor.fetchActive().first?.composerId == "below-80",
          "busy ordering must happen before the display cap")

    reset()
    for n in 0..<20 { try add("live-\(n)", transcript: user + assistant) }
    check(CursorSessionMonitor.fetchActive().filter { $0.status == .active }.count == 20,
          "the 14-session display budget must not discard running sessions")

    reset()
    // The 2026-09-28 investigation's composer had a *submission* clock 21
    // minutes old when the checkpoint was 30 seconds old — the case the
    // checkpoint-augmented `inFlight` clock exists for (and still handles:
    // `checkpointAt` is still selected and still feeds `inFlight`). What
    // changed is the SQL *prefilter*, and the investigated composer's own
    // final row shows why it is safe: its recency (09-29 21:34) ended up
    // *later* than its checkpoint (09-28 21:28), because Cursor advances
    // recency on every composer write. Measured across all 611 real rows that
    // carry both clocks, a checkpoint leads its recency by at most 34 min.
    // The fixture models that: submission four days old, recency fresh.
    try add("checkpoint-live-old-submission", headAge: 4 * 86400, recencyAge: 5,
            checkpointAge: 5, unfinishedAge: 4 * 86400)
    check(busy("checkpoint-live-old-submission"),
          "a fresh checkpoint must keep a long run visible although the submission is four days old")

    reset()
    try add("parent", headAge: 1000, checkpointAge: 5, unfinishedAge: 1000)
    try add("child", headAge: 1000, transcript: user + assistant, parent: "parent")
    try add("nested-child", headAge: 1000, transcript: user + assistant,
            parent: "child", rootParent: "parent")
    try add("child-checkpoint", headAge: 1000, checkpointAge: 5, unfinishedAge: 1000,
            parent: "parent")
    try add("child-frozen", headAge: 3600, transcript: user + assistant,
            transcriptAge: 3600, parent: "parent")
    try add("child-done", headAge: 100, checkpointAge: 1, unfinishedAge: 100,
            transcript: user + assistant + success, parent: "parent")
    let children = session("parent")?.subagents ?? []
    check(children.first { $0.id == "child" }?.status == .running,
          "subagent transcripts are under the parent's subagents directory")
    check(children.first { $0.id == "nested-child" }?.status == .running,
          "nested subagents attach to the visible root when their direct parent is a helper")
    check(children.first { $0.id == "child-checkpoint" }?.status == .running,
          "subagents use unfinished checkpoints when JSONL is missing too")
    check(children.first { $0.id == "child-frozen" }?.status == .done,
          "abandoned child transcripts still expire")
    check(children.first { $0.id == "child-done" }?.status == .done,
          "a current child terminal marker beats sticky unfinished metadata")
    let named = session("parent")?.displayActivity ?? ""
    check(named.contains("child") && named.contains("nested-child") && named.contains("child-checkpoint"),
          "running children are named on the parent activity line, got \\(named)")
    check(!named.contains("child-frozen") && !named.contains("child-done"),
          "finished children stay off the activity line")

    // A plan waiting to be applied, or a blocking action: Cursor's own signal
    // that the run is held up on a human. It used to be ignored, so such a
    // composer read as 运行中 on every surface while nothing was running.
    reset()
    try waiting("pending-plan", pendingPlan: true)
    check(parked("pending-plan"), "a pending plan is parked on the user, not running")
    check(!busy("pending-plan"), "a pending plan must not count as running")
    try waiting("blocking-action", blocking: true)
    check(parked("blocking-action"), "a blocking pending action parks the run on the user")
    try add("plain-idle", headAge: 600, locationActive: false)
    check(!parked("plain-idle") && !busy("plain-idle"),
          "a composer with neither flag is plain idle")

    // The workspace-name encoding rule, pinned on its own (finding 90/92).
    // f1c1921 fixed "replace only /" — which left underscore and dot names
    // unresolvable, so every Cursor transcript lookup for `/Project/my_app.v2`
    // missed and the card degraded to no-activity. The fixtures above use a
    // clean ASCII path, which passed under the broken rule too, so the rule
    // itself needs its own assertions.
    check(FilePaths.cursorProjectName(for: "/Project/prompt_engineering")
              == "Project-prompt-engineering",
          "an underscore becomes a dash (the f1c1921 regression)")
    check(FilePaths.cursorProjectName(for: "/openclaw-2026.5.7")
              == "openclaw-2026-5-7",
          "a dot becomes a dash")
    check(FilePaths.cursorProjectName(for: "/fixture/my_project.v2")
              == "fixture-my-project-v2",
          "underscore and dot together")
    check(FilePaths.cursorProjectName(for: "/Users/me/项目")
              == "Users-me---",
          "a CJK scalar is outside the whitelist and becomes one dash per scalar")

    print("\(checks - failures.count)/\(checks) Cursor monitor checks passed")
    if !failures.isEmpty { exit(1) }
}
try runTests()
'''

with tempfile.TemporaryDirectory(prefix='claudebar-cursor-monitor-') as folder:
    folder = Path(folder)
    support = folder / 'support'
    support.mkdir()
    # **Both** roots have to be redirected. `homeDirectoryForCurrentUser` covers
    # the release paths; `applicationSupportDirectory` covers the dev ones —
    # since the channel split, `FilePaths.cursorStateDB` / `cursorProjectsDir`
    # resolve under the app's own Application Support directory when the channel
    # is dev, which is what an unlabelled compile of this slice is. Without the
    # second substitution the fixture writes its SQLite file into the *real*
    # `~/Library/Application Support/ClaudeBar Dev/` and the next run fails on
    # `CREATE TABLE` (the table is still there) — the test was both leaking a
    # file out of its temporary directory and not idempotent.
    file_paths = (utils / 'FilePaths.swift').read_text()
    file_paths = file_paths.replace(
        'FileManager.default.homeDirectoryForCurrentUser', 'fixtureHome')
    file_paths = file_paths.replace(
        'FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]',
        'fixtureSupport')
    source = folder / 'Regression.swift'
    source.write_text('\n'.join([
        (root / 'Sources/Shared/BuildChannel.swift').read_text(),
        file_paths,
        # Declared here rather than at the top: `import Foundation` and the
        # sliced sources come first, and the fixture's own `fixtureHome` (from
        # `CommandLine.arguments[1]`) is declared further down with the rest of
        # the probe.
        'let fixtureSupport = URL(fileURLWithPath: CommandLine.arguments[2])',
        (utils / 'SessionTitle.swift').read_text(),
        (utils / 'CursorDB.swift').read_text(),
        (utils / 'CursorSessionMonitor.swift').read_text(),
        swift,
    ]))
    # Run a standalone fixture with Swift's interpreter; never build the app.
    subprocess.run(['swift', str(source), str(folder / 'home'), str(support)], check=True)
