#!/usr/bin/env python3
"""The quota-rollover alert must fire once, on real rollovers only.

The glance reel polls Codex every 4.2 s, so the alert sits on a very hot path:
a detector that fires on "usedPercent < 5" would re-announce a depleted window
dozens of times an hour, and one that fires on any increase in remaining quota
would fire on provider rounding. Both failure modes are invisible in review
because the code reads plausibly — so drive the production detector through
simulated poll sequences and assert the edges.

Extracts `QuotaResetDetector` from the production source, no app launch.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Models/IdleTransitionDetector.swift').read_text()
start = source.index('struct QuotaResetDetector {')
body = source[start:]

swift = r'''
import Foundation

/// Minimal stand-in for the production `CodexQuotaWindow` — only the fields
/// the detector reads.
struct CodexQuotaWindow: Equatable {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
}

DETECTOR

@main struct Regression {
    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t5h = t0.addingTimeInterval(5 * 3600)

        func window(_ used: Double, resets: Date? = nil, label: String = "5 小时")
            -> CodexQuotaWindow {
            CodexQuotaWindow(label: label, usedPercent: used, resetsAt: resets)
        }

        // 1. Launch must not announce whatever state it inherits. A window
        //    that is already near-empty is exactly what a first poll sees.
        var d = QuotaResetDetector()
        precondition(d.record([window(98, resets: t5h)]).isEmpty, "first sighting must only seed")
        precondition(d.record([window(97, resets: t5h)]).isEmpty, "seeded state must not re-fire")
        // A hard drop to zero right after launch: this is a *real* rollover,
        // and it must fire — the seed is not a mute button.
        let fired = d.record([window(0, resets: t5h.addingTimeInterval(5 * 3600))])
        precondition(fired.count == 1, "a genuine drop must fire; got \(fired.count)")

        // 2. The same rollover must never be announced twice, however many
        //    polls observe it (this is the anti-nag guarantee).
        d = QuotaResetDetector()
        _ = d.record([window(99, resets: t5h)])
        let first = d.record([window(0, resets: t5h.addingTimeInterval(5 * 3600))])
        precondition(first.count == 1, "rollover must fire")
        for _ in 0..<50 {
            precondition(d.record([window(0, resets: t5h.addingTimeInterval(5 * 3600))]).isEmpty,
                         "repeated polls of a near-empty window must stay silent")
        }

        // 3. Rounding is not a rollover. Small dips must stay silent, which is
        //    what the drop threshold buys.
        d = QuotaResetDetector()
        _ = d.record([window(90, resets: t5h)])
        for used in [89.0, 88.5, 84.0, 79.0] {
            precondition(d.record([window(used, resets: t5h)]).isEmpty,
                         "a \(90 - used)-point dip must not read as a reset")
        }
        // But a large drop does.
        precondition(d.record([window(2, resets: t5h.addingTimeInterval(5 * 3600))]).count == 1,
                     "a large drop must fire")

        // 4. A window that had nothing to refresh must not announce: a reset
        //    from 2% to 0% tells the user nothing.
        d = QuotaResetDetector()
        _ = d.record([window(2, resets: t5h)])
        precondition(d.record([window(0, resets: t5h.addingTimeInterval(5 * 3600))]).isEmpty,
                     "a reset below the used floor must stay silent")

        // 5. Codex sometimes rolls the reset instant forward before the
        //    percentage catches up. That alone is a rollover.
        d = QuotaResetDetector()
        _ = d.record([window(60, resets: t5h)])
        precondition(d.record([window(60, resets: t5h.addingTimeInterval(5 * 3600))]).count == 1,
                     "a forward reset instant must be treated as a rollover")

        // 6. Independent per-window state: the weekly window must not be
        //    dragged along by the 5-hour one.
        d = QuotaResetDetector()
        _ = d.record([window(95, resets: t5h, label: "5 小时"),
                      window(80, resets: t0.addingTimeInterval(7 * 86_400), label: "7 天")])
        let mixed = d.record([window(0, resets: t5h.addingTimeInterval(5 * 3600), label: "5 小时"),
                              window(80, resets: t0.addingTimeInterval(7 * 86_400), label: "7 天")])
        precondition(mixed.count == 1, "only the rolled window may fire; got \(mixed.count)")
        precondition(mixed[0].label == "5 小时", "the wrong window fired: \(mixed[0].label)")

        // 7. A vanished window (account or provider swap) must not leave state
        //    behind that fires on its return.
        d = QuotaResetDetector()
        _ = d.record([window(99, resets: t5h)])
        precondition(d.record([]).isEmpty, "no windows means no alert")
        precondition(d.record([window(99, resets: t5h)]).isEmpty,
                     "a reappearing window must re-seed, not fire")

        // 8. No reset instant at all must not crash or fire.
        d = QuotaResetDetector()
        _ = d.record([window(90, resets: nil)])
        precondition(d.record([window(1, resets: nil)]).count == 1,
                     "a drop with no reset time still counts as a rollover")

        print("PASS: quota rollover fires exactly once — seed-safe, dip-safe, floor-safe, "
              + "per-window, forward-instant aware, no state leak across disappearances")
    }
}
'''.replace('DETECTOR', body)
with tempfile.TemporaryDirectory(prefix='claudebar-quota-tests-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
