#!/usr/bin/env python3
"""What one transcript scan must get right, driven through the production monitor.

Three separate silent failure modes live in `SessionMonitor`, and each one was
found by reading the transcript corpus rather than the code:

  * **A parallel tool batch reads as nothing pending.** The old rule was line
    order — "the last `tool_use` is after the last `tool_result`" — which is only
    correct for one call at a time. Claude Code packs parallel calls into one
    assistant record (91 of 125 local transcripts hold such a record) and writes
    **one result record per call** (0 of 42,084 local result records carried more
    than one block), so the first result of a four-tool batch already puts the
    last `tool_result` line past the last `tool_use` line. Every surface that
    reads `toolPending` — the busy dot, the island row, the waiting reason that
    names the parked tool — then said the turn had nothing outstanding while
    three tools were still running.

  * **A first prompt longer than the read window silently disappears.** The head
    read was a fixed 16KB and each line was parsed from it whole: a prompt that
    *starts* inside the window but ends past it arrives truncated, fails
    `JSONSerialization`, and is skipped, so the session reported no title at all
    and every card fell back to the folder name.

  * **A pid that does not fit `pid_t` traps the app.** `pid_t(pid)` on an `Int`
    out of range is a runtime trap (verified: a compiled `-O` binary dies with
    SIGTRAP), and the session file is re-read on every poll, so one bad file
    crashes the app repeatedly until someone deletes it by hand. `pid <= 0` is
    the quieter half: `kill(0, 0)` and `kill(-1, 0)` succeed, so a fabricated
    `"pid": 0` reads as a live session.

No app, no launch: the monitor is sliced with a redirected home and driven
against fixture transcripts in a temporary directory.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
utils = root / 'Sources/ClaudeBar/Utils'

swift = r'''
import Foundation

func runScanChecks() throws {
    let fm = FileManager.default
    let cwd = "/fixture/scan-project"
    let projects = FilePaths.claudeDir.appendingPathComponent("projects")
    let dir = projects.appendingPathComponent(SessionMonitor.projectDirName(for: cwd))
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    var checks = 0
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures.append(message); print("FAIL: \(message)") }
    }

    /// A session record plus its transcript, scanned the way the store scans it.
    func scan(_ sessionId: String, transcript: String) -> ContextScan {
        let record: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "sessionId": sessionId,
            "cwd": cwd,
            "startedAt": 1.0,
            "updatedAt": Date().timeIntervalSince1970 * 1000,
            "status": "busy",
        ]
        let sessionsDir = FilePaths.claudeDir.appendingPathComponent("sessions")
        try! fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: record)
            .write(to: sessionsDir.appendingPathComponent("\(sessionId).json"))
        try! transcript.write(to: dir.appendingPathComponent("\(sessionId).jsonl"),
                             atomically: true, encoding: .utf8)
        guard let session = SessionMonitor.fetchActive().first(where: { $0.sessionId == sessionId }) else {
            fatalError("fixture session \(sessionId) did not parse")
        }
        return SessionMonitor.fetchContext(for: session)
    }

    func assistant(_ blocks: String) -> String {
        "{\"type\":\"assistant\",\"uuid\":\"u-\(blocks.hashValue)\",\"message\":{"
            + "\"stop_reason\":\"tool_use\",\"content\":[\(blocks)]}}\n"
    }
    func toolUse(_ id: String, _ name: String) -> String {
        "{\"type\":\"tool_use\",\"id\":\"\(id)\",\"name\":\"\(name)\",\"input\":{}}"
    }
    func result(_ id: String) -> String {
        "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\","
            + "\"tool_use_id\":\"\(id)\",\"content\":\"ok\"}]}}\n"
    }

    // 1. The batch case. Three calls in one step, one result so far: the turn
    //    is still running and two tools are outstanding.
    let batch = scan("batch", transcript:
        assistant(toolUse("t1", "Read") + "," + toolUse("t2", "Bash") + "," + toolUse("t3", "Grep"))
        + result("t1"))
    check(batch.toolPending, "one result of three must leave the batch pending")
    check(batch.pendingTool == "Grep",
          "the outstanding tool is the trailing one; got \(batch.pendingTool)")

    // 2. The last result closes the batch — and only then.
    let closed = scan("closed", transcript:
        assistant(toolUse("t1", "Read") + "," + toolUse("t2", "Bash"))
        + result("t1") + result("t2"))
    check(!closed.toolPending, "every call answered means nothing is pending")
    check(closed.pendingTool.isEmpty, "a settled batch names no tool; got \(closed.pendingTool)")

    // 3. The single-call shape the line-order rule was written for stays right.
    let single = scan("single", transcript: assistant(toolUse("s1", "Bash")))
    check(single.toolPending && single.pendingTool == "Bash", "a lone call is pending")
    let answered = scan("answered", transcript: assistant(toolUse("s1", "Bash")) + result("s1"))
    check(!answered.toolPending, "a lone call with its result is not pending")

    // 4. A *new* step's results must not settle the previous step, and the new
    //    step's own calls are what count.
    let second = scan("second-step", transcript:
        assistant(toolUse("t1", "Read") + "," + toolUse("t2", "Bash"))
        + result("t1") + result("t2")
        + assistant(toolUse("t3", "Write") + "," + toolUse("t4", "Edit"))
        + result("t3"))
    check(second.toolPending && second.pendingTool == "Edit",
          "the newest step's outstanding call decides; got \(second.pendingTool)")

    // 5. Blocks without ids (an older CLI): the line-order rule is the fallback,
    //    and it must still report a trailing unanswered call.
    let legacy = scan("legacy", transcript:
        "{\"type\":\"assistant\",\"message\":{\"stop_reason\":\"tool_use\","
        + "\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}\n")
    check(legacy.toolPending && legacy.pendingTool == "Bash",
          "an id-less call falls back to line order; got pending=\(legacy.toolPending)")

    // 6. An interleaved result for an id this step never called does not settle
    //    the batch (the ids are what is compared, not the count).
    let foreign = scan("foreign", transcript:
        assistant(toolUse("t1", "Read") + "," + toolUse("t2", "Bash"))
        + result("other"))
    check(foreign.toolPending, "a result for another call must not settle the batch")

    // 7. The head read extends past one chunk instead of dropping a long prompt.
    //    The preamble here is a single ~40KB record — bigger than the window —
    //    so the prompt line itself begins past it.
    let filler = String(repeating: "x", count: 40_000)
    let longPrompt = scan("long-prompt", transcript:
        "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"content\":\"\(filler)\"}}\n"
        + "{\"type\":\"user\",\"origin\":{\"kind\":\"human\"},"
        + "\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Fix the flaky test\"}]}}\n")
    check(longPrompt.title == "Fix the flaky test",
          "a prompt past the first chunk must still be found; got \(longPrompt.title)")

    // 8. A prompt line that ends exactly at the chunk boundary: the truncated
    //    form must not be parsed, and the completed read must find it. Here the
    //    opening record is padded so the prompt starts inside the first 16KB and
    //    ends after it.
    let pad = String(repeating: "y", count: 15_800)
    let splitPrompt = scan("split-prompt", transcript:
        "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"content\":\"\(pad)\"}}\n"
        + "{\"type\":\"user\",\"origin\":{\"kind\":\"human\"},"
        + "\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Ship the release\"}]}}\n")
    check(splitPrompt.title == "Ship the release",
          "a prompt spanning the read window must be parsed whole; got \(splitPrompt.title)")

    // 9. No human prompt at all still yields nothing — the folder-name fallback
    //    is `SessionTitle`'s job, not this scanner's.
    let none = scan("none", transcript:
        "{\"type\":\"user\",\"origin\":{\"kind\":\"command\"},"
        + "\"message\":{\"content\":\"/clear\"}}\n")
    check(none.title.isEmpty, "no human prompt means no title; got \(none.title)")

    // 10. A session whose pid cannot be a `pid_t` is skipped, not fatal — and
    //     the valid session next to it still parses.
    let sessionsDir = FilePaths.claudeDir.appendingPathComponent("sessions")
    for (name, pid) in [("huge-pid", 4_294_967_296.0), ("zero-pid", 0.0), ("negative-pid", -1.0),
                        ("real-pid", Double(ProcessInfo.processInfo.processIdentifier))] {
        let record: [String: Any] = ["pid": pid, "sessionId": name, "cwd": cwd,
                                     "startedAt": 1.0, "updatedAt": 1.0]
        try! JSONSerialization.data(withJSONObject: record)
            .write(to: sessionsDir.appendingPathComponent("\(name).json"))
    }
    let live = SessionMonitor.fetchActive()
    check(!live.contains { $0.sessionId == "huge-pid" },
          "an out-of-range pid must be dropped, not converted")
    check(!live.contains { $0.sessionId == "zero-pid" },
          "pid 0 addresses a process group, not a session")
    check(!live.contains { $0.sessionId == "negative-pid" },
          "pid -1 addresses every process the user may signal")
    check(live.contains { $0.sessionId == "real-pid" },
          "an in-range pid still parses alongside the rejected ones")

    print("\(checks - failures.count)/\(checks) session scan checks passed")
    if !failures.isEmpty { exit(1) }
}
try runScanChecks()
'''

with tempfile.TemporaryDirectory(prefix='claudebar-session-scan-') as folder:
    folder = Path(folder)
    # Both roots are redirected (see `session-waiting-regressions.py`): a slice
    # that only replaces `homeDirectoryForCurrentUser` writes its session files
    # into the real `~/Library/Application Support/ClaudeBar Dev/` under the dev
    # channel, which is what an unlabelled compile of this slice is.
    file_paths = (utils / 'FilePaths.swift').read_text().replace(
        'FileManager.default.homeDirectoryForCurrentUser', 'fixtureHome')
    file_paths = file_paths.replace(
        'FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]',
        'fixtureSupport')
    source = folder / 'Regression.swift'
    source.write_text('\n'.join([
        'import Foundation',
        'let fixtureHome = URL(fileURLWithPath: CommandLine.arguments[1])',
        'let fixtureSupport = fixtureHome.appendingPathComponent("Library/Application Support")',
        (root / 'Sources/Shared/BuildChannel.swift').read_text(),
        file_paths,
        (utils / 'SessionTitle.swift').read_text(),
        # `SessionMonitor` reaches `UsageStats.formatContext` from one derived
        # property; the preferences layer behind the real one is irrelevant here.
        'enum UsageStats { static func formatContext(_ n: Int) -> String { String(n) } }',
        (utils / 'JSONCoerce.swift').read_text(),
        (utils / 'WorkflowMonitor.swift').read_text(),
        (utils / 'SessionMonitor.swift').read_text(),
        swift,
    ]))
    subprocess.run(['swift', str(source), str(folder / 'home')], check=True)
