#!/usr/bin/env python3
"""The third session state: parked on the user.

Measured against the live CLI (2.1.285), not assumed. A Bash approval prompt
and an `AskUserQuestion` dialog both used to read as **运行中** on every surface
of the app, and produced no notification, while the session was in fact doing
nothing and the user was the one being waited on. The two causes, each verified
by driving a real interactive `claude` in a terminal and watching the files it
writes:

  * the session record flips to `"status": "waiting"`, and the app's
    `SessionStatus` had no such case, so it fell through to `unknown` and the
    transcript's dangling `tool_use` marked it busy;
  * the transcript's last record is an assistant `tool_use` with no
    `tool_result` — identical in shape to a tool that is genuinely executing —
    and `ProviderStore.enrich` turned `toolPending` into `status = .busy`
    unconditionally.

There is also no completion to announce, which is why the idle notification
stayed silent: no new answer exists, so the turn key stays nil for as long as
the prompt is up. `WaitingStateDetector` (exercised in
`completion-notify-regressions.py`) is the edge that covers it.

The full vocabulary is the CLI's own, read out of the 2.1.285 binary rather
than assumed — the writer is
`CRe({status, waitingFor})` with
`status ∈ ["busy","shell","idle","waiting"]` (its own `dM = {running:"busy",
requires_action:"waiting", idle:"idle"}` map) and
`waitingFor = status != "waiting" ? nil : (tool == "AskUserQuestion" ||
tool.startsWith("dialog:") ? "input needed" : "permission prompt")`,
so the dialog descriptors behind `"input needed"` also carry `"dialog open"`,
`"sandbox request"` and `"goal proposal"`. `"shell"` is a fourth status the
app used to drop into `unknown`.

What this file pins, against the production monitor with a redirected home:

  1. `status: "waiting"` is parsed, not swallowed into `unknown`;
  2. `waitingFor` is only read for a waiting session;
  3. `isBusy` is false while waiting even though a tool is pending;
  4. `waitingReason` names the trailing tool (`ExitPlanMode` → the plan case,
     `Bash` → "等待你确认 · Bash");
  5. a dangling `tool_use` still means busy when the CLI says nothing at all —
     the fallback older CLIs depend on;
  6. `status: "shell"` is its own case, counted as working, never as parked;
  7. a CLI-raised `dialog:` pseudo-tool/`"dialog open"` bucket never leaks the
     raw `dialog:` prefix into the user-facing reason.
"""
from pathlib import Path
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
utils = root / 'Sources/ClaudeBar/Utils'

swift = r'''
func runWaitingChecks() throws {
    let sessionsDir = FilePaths.claudeDir.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    var checks = 0
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures.append(message); print("FAIL: \(message)") }
    }

    /// Write one session record and enrich it the way the store does.
    func load(_ pid: Int, status: String?, toolPending: Bool,
              waitingFor: String? = nil, pendingTool: String = "") -> SessionInfo {
        var obj: [String: Any] = [
            "pid": pid,
            "sessionId": "sess-\(pid)",
            "cwd": "/tmp/waiting-fixture",
            "startedAt": 1.0,
            "updatedAt": Date().timeIntervalSince1970 * 1000,
        ]
        if let status { obj["status"] = status }
        if let waitingFor { obj["waitingFor"] = waitingFor }
        let path = sessionsDir.appendingPathComponent("\(pid).json")
        try! JSONSerialization.data(withJSONObject: obj).write(to: path)
        guard var session = SessionMonitor.fetchActive().first(where: { $0.pid == pid }) else {
            fatalError("fixture session \(pid) did not parse")
        }
        session.toolPending = toolPending
        session.pendingTool = pendingTool
        // Exactly the production rule, not a copy of it: older CLIs carry no
        // `status` at all, and there a dangling tool_use is the only evidence
        // a turn is still live.
        if session.status == .unknown, session.toolPending { session.status = .busy }
        return session
    }

    // 1. The CLI's own word is parsed rather than dropped into `unknown`.
    let approval = load(1001, status: "waiting", toolPending: true,
                        waitingFor: "permission prompt", pendingTool: "Bash")
    check(approval.status == .waiting, "status \"waiting\" must parse; got \(approval.status)")
    check(approval.isWaiting, "a waiting status must read as waiting")
    check(!approval.isBusy, "a session at a prompt is not running")
    check(approval.waitingReason == "等待你确认 · Bash",
          "the reason names the parked tool; got \(approval.waitingReason)")

    // 2. The question dialog: the CLI's word is "input needed" and the tool
    //    is what tells the user which transcript decision they are on.
    let question = load(1002, status: "waiting", toolPending: true,
                        waitingFor: "input needed", pendingTool: "AskUserQuestion")
    check(question.isWaiting && !question.isBusy, "a question dialog is a wait, not work")
    check(question.waitingReason == "等待你选择",
          "a question dialog reads as a choice; got \(question.waitingReason)")

    // 3. Plan approval is the case the user described: CC shows the plan
    //    and waits to be told whether to run it. It has no permission
    //    prompt, so the tool name is the only thing that separates it from
    //    an ordinary Bash approval.
    let plan = load(1003, status: "waiting", toolPending: true,
                    waitingFor: "permission prompt", pendingTool: "ExitPlanMode")
    check(plan.isWaiting && !plan.isBusy, "a plan awaiting approval is not running")
    check(plan.waitingReason == "等待确认计划",
          "a parked plan names itself; got \(plan.waitingReason)")

    // 4. The transcript alone cannot distinguish "running a tool" from
    //    "parked on the approval for it" — both leave a dangling tool_use.
    //    Without the CLI's status the fallback must still say busy, or every
    //    older CLI goes silent.
    let legacy = load(1004, status: nil, toolPending: true)
    check(legacy.status == .busy && legacy.isBusy,
          "a dangling tool_use with no status is still busy (legacy CLIs)")

    // 5. And a working CLI that is genuinely mid-tool stays busy: the fix
    //    must not swallow the real case.
    let working = load(1005, status: "busy", toolPending: true, pendingTool: "Bash")
    check(working.isBusy && !working.isWaiting, "status busy with a pending tool is running")

    // 6. `waitingFor` is the CLI's field for the *waiting* session; a
    //    leftover value on a non-waiting record must not leak into the UI.
    let stale = load(1006, status: "busy", toolPending: true, waitingFor: "permission prompt")
    check(stale.waitingReason.isEmpty, "a non-waiting session has no waiting reason")

    // 7. The idle case is untouched: no pending tool, no status → idle.
    let idle = load(1007, status: "idle", toolPending: false)
    check(!idle.isBusy && !idle.isWaiting, "an idle session stays idle")

    // 8. `"shell"` is the CLI's fourth status value (`["busy","shell","idle",
    //    "waiting"]`), written while the user is inside a `/shell` (or `!`)
    //    subprocess. It is work, not a park: nothing is waiting on a decision,
    //    so it must read busy and never trigger the needs-input edge.
    let shell = load(1008, status: "shell", toolPending: false)
    check(shell.status == .shell, "status \"shell\" must parse to its own case; got \(shell.status)")
    check(shell.isBusy && !shell.isWaiting, "a /shell holds the session busy, not parked")
    check(shell.waitingReason.isEmpty, "a shell session has nothing to wait for")

    // 9. Even with a dangling tool_use, `"shell"` stays busy — the transcript
    //    fallback must not run, because the CLI already told us what this is.
    let shellTool = load(1009, status: "shell", toolPending: true, pendingTool: "Bash")
    check(shellTool.isBusy && !shellTool.isWaiting, "shell + dangling tool is still work")

    // 10. A CLI-raised dialog arrives as a `dialog:` pseudo-tool (`AskUserQuestion`
    //     is the only real tool that yields `"input needed"`). Naming it to the
    //     user would read as jargon, so it falls back to the bucket word.
    let dialog = load(1010, status: "waiting", toolPending: true,
                      waitingFor: "input needed", pendingTool: "dialog:something")
    check(dialog.isWaiting && !dialog.isBusy, "a dialog is a wait, not work")
    check(dialog.waitingReason == "等待你选择",
          "a dialog: pseudo-tool must not leak its prefix; got \(dialog.waitingReason)")

    // 11. `"dialog open"` is a bucket the binary emits for a dialog raised
    //     before the model wrote another tool step — the scanned tail has no
    //     trailing tool, so the bucket alone must carry the reason.
    let openDialog = load(1011, status: "waiting", toolPending: true,
                          waitingFor: "dialog open")
    check(openDialog.waitingReason == "等待你确认",
          "an empty-tool dialog falls back to the bucket word; got \(openDialog.waitingReason)")

    // 12. `"sandbox request"` / `"goal proposal"` are the other dialog
    //     descriptors; a real trailing tool still names itself in the reason.
    let sandbox = load(1012, status: "waiting", toolPending: true,
                       waitingFor: "sandbox request", pendingTool: "Bash")
    check(sandbox.waitingReason == "等待你确认 · Bash",
          "a sandbox-request dialog still names its tool; got \(sandbox.waitingReason)")
    let goal = load(1013, status: "waiting", toolPending: true,
                    waitingFor: "goal proposal", pendingTool: "ExitPlanMode")
    check(goal.waitingReason == "等待确认计划",
          "a goal proposal behind ExitPlanMode reads as the plan case; got \(goal.waitingReason)")

    print("\(checks - failures.count)/\(checks) session waiting-state checks passed")
    if !failures.isEmpty { exit(1) }
}
try runWaitingChecks()
'''

with tempfile.TemporaryDirectory(prefix='claudebar-session-waiting-') as folder:
    folder = Path(folder)
    # FilePaths is the only thing redirected; the monitor, the status enum and
    # the derived properties are the shipped ones.
    file_paths = (utils / 'FilePaths.swift').read_text().replace(
        'FileManager.default.homeDirectoryForCurrentUser', 'fixtureHome')
    source = folder / 'Regression.swift'
    source.write_text('\n'.join([
        'import Foundation',
        'let fixtureHome = URL(fileURLWithPath: CommandLine.arguments[1])',
        (root / 'Sources/Shared/BuildChannel.swift').read_text(),
        file_paths,
        (utils / 'SessionTitle.swift').read_text(),
        # `UsageStats` carries the whole usage/period vocabulary and reaches for
        # `AppPreferences`; `SessionMonitor` only needs `formatContext`, so it
        # gets a stub rather than dragging the preferences layer into a fixture.
        'enum UsageStats { static func formatContext(_ n: Int) -> String { String(n) } }',
        (utils / 'JSONCoerce.swift').read_text(),
        (utils / 'SessionMonitor.swift').read_text(),
        swift,
    ]))
    subprocess.run(['swift', str(source), str(folder / 'home')], check=True)
