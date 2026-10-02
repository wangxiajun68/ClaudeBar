#!/usr/bin/env python3
"""The island's session pipeline: a real session → the needs-input edge.

`Tests/session-waiting-regressions.py` pins the *parsing* of the parked state
and `Tests/completion-notify-regressions.py` pins the two edge detectors in
isolation. Neither exercises the path between them — the one the user actually
sees — so a session could parse as parked and still never raise the island's
alert, which is exactly the class of bug this whole state machine keeps
regressing into.

This file closes that gap. It slices the **production** `IslandLiveModel`.
`flatten` (the only place the three agent kinds are reduced to the island's own
snapshot) and drives the **production** `WaitingStateDetector` over its output,
across the same three transitions a live CC session makes:

    busy (a tool running) → waiting (a prompt) → busy (answered) → waiting again

The assertions are the island's own contract:

  1. `flatten` carries `isWaiting` + a non-empty `waitingReason` for a parked
     Claude session, and stamps the right agent / id prefix;
  2. a parked session sorts above a merely-busy one (the strip's whole point);
  3. the edge fires on *entering* waiting, not on the state — once per prompt;
  4. it re-arms after the prompt is answered, so a second prompt is a second
     alert;
  5. the first snapshot only seeds, so an island that starts while a session is
     already parked does not fire a banner at launch;
  6. a Cursor composer parked on a plan and a Codex thread both flow through
     the same pipeline (`Codex` today never reports a park — that absence is
     pinned by `ExternalSessionInfo.isWaiting`'s own doc, and the pipeline
     simply stays silent for it).

Only `SessionInfo`'s transcript half is stubbed (the scan is file I/O); the
status enum, the derived `isWaiting`/`isBusy`/`waitingReason`, `flatten` and the
detector are the shipped ones.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
utils = root / 'Sources/ClaudeBar/Utils'
models = root / 'Sources/ClaudeBar/Models'


def slice_method(path, signature):
    """Return one production method's source, verbatim, with `private` dropped."""
    source = path.read_text()
    start = source.index(signature)
    body = source.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('nonisolated private static func', 'static func').replace('private static func', 'static func')


island_src = (models / 'IslandLiveModel.swift').read_text()


def block(start_marker, end_marker):
    a = island_src.index(start_marker)
    b = island_src.index(end_marker)
    return island_src[a:b]


# `IslandSession` + `IslandAgent`: the snapshot type and the family enum. Taken
# from the shipped file so a field added there is a field this test sees.
island_agent = block('/// The three agent families ClaudeBar watches.', '/// One live agent session, flattened')
island_session = block('/// One live agent session, flattened to what the island draws.',
                       '/// One local day of tokens for the usage scrubber.')
flatten = slice_method(models / 'IslandLiveModel.swift',
                       'nonisolated private static func flatten(claude:')

harness = r'''
func run() throws {
    var checks = 0
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures.append(message); print("FAIL: \(message)") }
    }

    let nowMs = Date().timeIntervalSince1970 * 1000

    /// A Claude session in a given state; only the transcript scan is synthetic.
    func claude(_ pid: Int, status: SessionStatus, toolPending: Bool,
                pendingTool: String = "", waitingFor: String = "") -> SessionInfo {
        var s = SessionInfo(pid: pid, sessionId: "s-\(pid)", cwd: "/tmp/proj",
                            startedAt: 1, name: "n", status: status,
                            updatedAt: nowMs, isAlive: true, waitingFor: waitingFor)
        s.toolPending = toolPending
        s.pendingTool = pendingTool
        return s
    }

    // 1. `flatten` carries the parked state and identifies the family.
    let parked = claude(1, status: .waiting, toolPending: true,
                        pendingTool: "Bash", waitingFor: "permission prompt")
    let flat = IslandLiveModelProbe.flatten(claude: [parked], cursor: [], external: [])
    check(flat.count == 1, "one alive session flattens to one island session")
    check(flat[0].id == "cc:1" && flat[0].agent == .claude, "the id/agent identify the Claude session")
    check(flat[0].isWaiting && !flat[0].isBusy, "a parked session is waiting, not busy")
    check(flat[0].waitingReason == "等待你确认 · Bash",
          "the island carries the reason; got \(flat[0].waitingReason)")

    // 2. Parked floats above busy — the strip's ordering contract.
    let busy = claude(2, status: .busy, toolPending: true, pendingTool: "Bash")
    let mixed = IslandLiveModelProbe.flatten(claude: [busy, parked], cursor: [], external: [])
    check(mixed.first?.isWaiting == true, "a parked session sorts above a busy one")

    // 3-5. The edge, over the busy → waiting → busy → waiting cycle, with the
    //      island watching the whole time (it sees every snapshot).
    var detector = WaitingStateDetector<String>()
    func poll(_ sessions: [SessionInfo]) -> Set<String> {
        let fresh = IslandLiveModelProbe.flatten(claude: sessions, cursor: [], external: [])
        return detector.record(fresh.map { (id: $0.id, isWaiting: $0.isWaiting) })
    }
    let running = claude(3, status: .busy, toolPending: true, pendingTool: "Bash")
    let firstPrompt = claude(3, status: .waiting, toolPending: true,
                             pendingTool: "Bash", waitingFor: "permission prompt")
    let secondPrompt = claude(3, status: .waiting, toolPending: true,
                              pendingTool: "AskUserQuestion", waitingFor: "input needed")

    check(poll([running]).isEmpty, "a busy poll raises nothing")
    check(poll([firstPrompt]) == ["cc:3"], "entering the park raises the needs-input edge")
    check(poll([firstPrompt]).isEmpty, "staying parked does not re-raise it")
    check(poll([running]).isEmpty, "answering lowers it silently")
    check(poll([secondPrompt]) == ["cc:3"], "a second prompt re-arms and raises again")

    // 5. First sighting seeds: an island that starts while a session is already
    //    parked must not fire a banner for a prompt the user already sees.
    var coldDetector = WaitingStateDetector<String>()
    let cold = IslandLiveModelProbe.flatten(claude: [firstPrompt], cursor: [], external: [])
    check(coldDetector.record(cold.map { (id: $0.id, isWaiting: $0.isWaiting) }).isEmpty,
          "the first sighting of a parked session only seeds")

    // 6. Cursor and Codex flow through the same pipeline.
    var cursor = CursorSessionInfo(composerId: "c-1", name: "t", cwd: "/tmp/proj",
                                   lastUpdatedAt: nowMs, contextPercent: 10,
                                   status: .idle, isAlive: true)
    cursor.hasPendingDecision = true
    let codex = ExternalSessionInfo(kind: .codex, sessionId: "x-1", cwd: "/tmp/proj",
                                    startedAt: 1, updatedAt: nowMs, model: "gpt",
                                    isAlive: true, isActive: true)
    let all = IslandLiveModelProbe.flatten(claude: [], cursor: [cursor], external: [codex])
    let cursorFlat = all.first { $0.agent == .cursor }
    let codexFlat = all.first { $0.agent == .codex }
    check(cursorFlat?.isWaiting == true && cursorFlat?.waitingReason == "等待你确认计划",
          "a Cursor plan awaiting 应用 is a park on the island")
    check(codexFlat?.isWaiting == false && codexFlat?.isBusy == true,
          "Codex journals no park, so its thread stays busy — never falsely parked")
    check(codex.isWaiting == false, "ExternalSessionInfo.isWaiting is the documented empty case")

    print("\(checks - failures.count)/\(checks) island session-alert checks passed")
    if !failures.isEmpty { exit(1) }
}
try run()
'''

workflow_status = (utils / 'WorkflowMonitor.swift').read_text().split('final class WorkflowMonitor:')[0]
claude_src = (utils / 'SessionMonitor.swift').read_text()
claude_models = workflow_status + claude_src[claude_src.index('/// A live Claude Code session, parsed from'):
                           claude_src.index('/// Reads ~/.claude/sessions/*.json and reports live Claude Code sessions.')]

cursor_src = (utils / 'CursorSessionMonitor.swift').read_text()
cursor_models = cursor_src[cursor_src.index('/// A live Cursor (IDE) agent session'):
                           cursor_src.index('// MARK: - Monitor')]

external_src = (utils / 'ExternalSessionMonitor.swift').read_text()
# `ExternalSessionInfo` + the `ExternalAgentKind` it embeds. The kind's own
# `rootDir` reads `FileManager.default.homeDirectoryForCurrentUser`, which is
# fine to keep — it is a computed property that the flatten path never calls.
external_models = external_src[external_src.index('/// A retained Codex CLI/Desktop session.'):
                               external_src.index('/// Which Codex rollouts a running `codex` process holds open right now.')]

detector_src = (models / 'IdleTransitionDetector.swift').read_text()
waiting_only = detector_src[detector_src.index('/// Edge detector for "a session just parked on the user".'):
                            detector_src.index('/// Decides when the next Codex allowance poll')]

with tempfile.TemporaryDirectory(prefix='claudebar-island-') as folder:
    folder = Path(folder)
    source = folder / 'Regression.swift'
    source.write_text('\n'.join([
        'import Foundation',
        # Minimal stand-ins for what the island's snapshot reads but this slice
        # does not exercise. Only keep a stub that the sliced code *names*: a
        # declaration nothing in the compile reaches is dead weight that makes
        # the fixture look broader than the slice is.
        #
        # `IslandAgent.markKind` names the app's glyph family; the flatten path
        # never reads it, so a stub stands in for the real instrument kit.
        'enum InstrumentGlyph { enum Kind { case sessions, config, overview } }',
        # `ExternalSessionInfo.contextLabel` reaches for `UsageStats`; the
        # instance is only used for its flags, so a stub is enough.
        'enum UsageStats { static func formatContext(_ n: Int) -> String { String(n) } }',
        island_agent,
        island_session,
        'struct IslandLiveModelProbe {',
        flatten,
        '}',
        # `SessionInfo` + `SessionStatus` (the model half of the monitor; the
        # scanner itself is file I/O this path never runs).
        claude_models,
        (utils / 'SessionTitle.swift').read_text(),
        (utils / 'JSONCoerce.swift').read_text(),
        # The two session types the pipeline flattens. Only their model halves
        # are sliced in (the monitors are file/SQLite I/O the flatten path never
        # touches), which keeps this test app-free and import-light.
        cursor_models,
        # `CursorTranscriptScan.inFlight` reads one static from the monitor; the
        # monitor itself is I/O this path never runs, so a stub carries just it.
        'enum CursorSessionMonitor { static let turnLiveWindowMs: Double = 10 * 60 * 1000 }',
        external_models,
        # The detector under test: only `WaitingStateDetector`, sliced from its
        # own doc comment to the start of the next one.
        waiting_only,
        harness,
    ]))
    subprocess.run(['swiftc', '-O', str(source), '-o', str(folder / 'regression')], check=True)
    subprocess.run([str(folder / 'regression')], check=True)
