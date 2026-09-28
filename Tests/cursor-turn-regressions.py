#!/usr/bin/env python3
"""A Cursor turn that was abandoned must stop reading as "running".

Cursor writes no closing `turn_ended` when a turn is aborted or crashes, so
`scanTail`'s predicate — "an assistant message came after the last
`turn_ended`" — is satisfied by such a turn **forever**. The transcript stops
changing, the poll re-derives the same `true` from the same frozen bytes, and
the session reads busy for the rest of its life.

That is not hypothetical: on 2026-09-28 one composer did exactly this and pinned
the notch island's busy badge — a spinning Cursor orbit for a session whose last
write was 16 hours earlier — along with the 2.5 s poll tier and the 1 Hz sampler
tier. `Tests/` had no Cursor coverage, so nothing caught it.

This pins the two halves of the bound and, just as importantly, the reason it is
a bound on the **transcript's write clock** and not on the head's
`lastUpdatedAt`: that field is stamped when the user submits and is not
rewritten during the turn, so gating on it would mean "only show turns shorter
than the window" — measured on this machine's own history it would have hidden
7 of the 25 most recent composers, two of them mid-edit.

Compiles the production `scanTail` and the two gates around it. The tail bytes
below reproduce the real artifact line for line.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
monitor = (root / 'Sources/ClaudeBar/Utils/CursorSessionMonitor.swift').read_text()

# `scanTail` is private; take it, and the constant it is bounded by, verbatim.
start = monitor.index('    private static func scanTail(')
end = monitor.index('\n    }\n', start) + len('\n    }\n')
scan_tail = monitor[start:end].replace('private static func scanTail(',
                                       'static func scanTail(', 1)
window_start = monitor.index('    private static let turnLiveWindowMs')
window = monitor[window_start:monitor.index('\n\n', window_start)].replace(
    'private static let turnLiveWindowMs', 'static let turnLiveWindowMs', 1)

swift = r'''
import Foundation

/// Stands in for the monitor's own activity describer, which the extracted
/// `scanTail` calls. Its output is not what this test asserts — the `pending`
/// flag is computed from line order alone — so a no-op keeps the slice
/// self-contained without changing any decision under test.
func describeActivity(in message: [String: Any]) -> String? { nil }

enum Gate {
WINDOW

    /// The bound as `fetchActive` applies it — one expression, read by both the
    /// published `toolPending` and the `.active` branch.
    static func inFlight(_ scan: (count: Int, activity: String, pending: Bool,
                                  completionID: String?, modifiedAt: Double)) -> Bool {
        let nowMs = Date().timeIntervalSince1970 * 1000
        return scan.pending && scan.modifiedAt > 0
            && (nowMs - scan.modifiedAt) < Self.turnLiveWindowMs
    }
}

enum Probe {
SCAN_TAIL
}

@main struct Regression {
    static func main() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-turn-regression")
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        /// The real artifact: an aborted run, then a re-prompt that was itself
        /// cut off mid-stream — `input: {}` is Cursor writing the assistant
        /// header before it had the tool arguments.
        let abandoned = """
        {"role":"assistant","message":{"content":[{"type":"text","text":"步骤"}]}}
        {"type":"turn_ended","status":"success"}
        {"type":"turn_ended","status":"error","error":"User aborted request"}
        {"role":"user","message":{"content":[{"type":"text","text":"整理文件"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"正在整理"},{"type":"tool_use","name":"Write","input":{}}]}}

        """

        func write(_ name: String, _ body: String, ageSeconds: Double) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-ageSeconds)],
                ofItemAtPath: url.path)
            return url
        }

        func inFlight(_ url: URL) -> (Bool, Bool) {
            let scan = Probe.scanTail(url: url, readSize: 96_000)
            return (scan.pending, Gate.inFlight(scan))
        }

        // 1. THE BUG. Same bytes, written 16 hours ago: the raw predicate is
        //    still true — that is what made this permanent — but the bounded
        //    value is not, so nothing downstream reads it as busy.
        let stale = try write("stale.jsonl", abandoned, ageSeconds: 16 * 3600)
        let (staleRaw, staleBounded) = inFlight(stale)
        precondition(staleRaw, "the raw predicate must still be true here — that is the bug being bounded, not removed")
        precondition(!staleBounded, "an abandoned turn from 16 h ago must not read as in flight")

        // 2. POSITIVE CONTROL. The identical line order with a fresh write is a
        //    turn that IS running, and must still say so. If this fails the
        //    bound is hiding real work, which is worse than the bug.
        let live = try write("live.jsonl", abandoned, ageSeconds: 5)
        precondition(inFlight(live) == (true, true), "a turn writing 5 s ago is in flight")

        // 3. The window is minutes, not seconds: turns on this machine measure
        //    p50 240 s and p90 1000 s, and a long tool call streams nothing.
        let long = try write("long.jsonl", abandoned, ageSeconds: 8 * 60)
        precondition(inFlight(long).1, "a turn quiet for 8 minutes is still inside the window")

        // 4. Just past the window it stops — the bound is real, not decorative.
        let over = try write("over.jsonl", abandoned, ageSeconds: 10 * 60 + 30)
        precondition(!inFlight(over).1, "past the window an unwritten transcript is not in flight")

        // 5. A turn that DID close is not in flight at any age, and needs no
        //    bound to say so.
        let ended = try write("ended.jsonl",
                              abandoned + "{\"type\":\"turn_ended\",\"status\":\"success\"}\n",
                              ageSeconds: 5)
        precondition(inFlight(ended) == (false, false), "a closed turn is idle even when freshly written")

        // 6. A missing transcript cannot read as busy: no file, no write clock.
        let missing = dir.appendingPathComponent("not-there.jsonl")
        precondition(inFlight(missing) == (false, false), "a composer with no transcript is idle")

        // One line: Swift has no adjacent-literal concatenation, so a wrapped
        // `print("…" "…")` is a syntax error rather than a joined message.
        print("PASS: an abandoned Cursor turn stops reading as running once its transcript goes quiet (\(Int(Gate.turnLiveWindowMs / 60_000)) min), while a turn still writing stays busy — including one quiet for 8 minutes")
    }
}
'''.replace('WINDOW', window).replace('SCAN_TAIL', scan_tail)

with tempfile.TemporaryDirectory(prefix='claudebar-cursor-turn-') as folder:
    folder = Path(folder)
    source = folder / 'Regression.swift'
    source.write_text(swift)
    binary = folder / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)],
                   check=True, capture_output=True, text=True)
    subprocess.run([str(binary)], check=True)

# --- The production gate is the thing under test ----------------------------
#
# Everything above validates the *shape* of the bound against real tail bytes,
# but it does so with its own copy of the expression. That is a hole: strip the
# bound out of `fetchActive` and every assertion above still passes, because the
# fixture never read it. Confirmed by negative control — deleting these three
# lines from the monitor left this file green.
#
# So assert the production expression directly: the bounded value must be what
# both the published field and the status branch read.
fetch_active = monitor[monitor.index('    static func fetchActive()'):
                      monitor.index('    // MARK: - Subagents')]
required = [
    ('let turnInFlight = scan.toolPending', 'the bound must start from the raw predicate'),
    ('scan.modifiedAt > 0', 'a composer whose transcript could not be read must not read as busy'),
    ('(nowMs - scan.modifiedAt) < Self.turnLiveWindowMs',
     'the bound must be on the transcript write clock'),
    ('shown[i].toolPending = turnInFlight',
     'the *published* field must be the bounded value — `isBusy` ORs it in independently of `status`'),
    ('if turnInFlight {', 'the status branch must read the bounded value too'),
]
for needle, why in required:
    assert needle in fetch_active, (
        f'{needle!r} is missing from `fetchActive` — {why}. '
        'Without it the notch island keeps a spinning badge on an abandoned turn, '
        'and this test would not notice: its own assertions use a local copy of the '
        'expression, not this one.')

# The last branch must NOT re-test the raw predicate. Doing so is the exact
# shape that pinned the reported session: a stale-pending composer with Cursor's
# sticky `agentLocation` flag could then never reach `.idle`.
assert '!scan.toolPending' not in fetch_active, (
    'the fall-through branch still consults the raw `scan.toolPending` — a '
    'stale-pending session with a sticky active flag can then never resolve to '
    'idle, which is the bug this file exists to pin')

print('PASS: `fetchActive` bounds `toolPending` on the transcript write clock and '
      'publishes that same value to both consumers')

