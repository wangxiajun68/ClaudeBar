#!/usr/bin/env python3
"""The quota-rollover alert must fire once, on real rollovers only — and the
poll must look exactly when the window says it will roll.

Two things live here, both driven through the production source:

  * `QuotaResetDetector` decides *whether* a rollover happened. The glance reel
    polls Codex every 4.2 s, so the alert sits on a very hot path: a detector
    that fires on "usedPercent < 5" would re-announce a depleted window dozens
    of times an hour, and one that fires on any increase in remaining quota
    would fire on provider rounding. Both failure modes are invisible in review
    because the code reads plausibly — so drive it through simulated poll
    sequences and assert the edges.

  * `QuotaPollScheduler` decides *when* to poll, which is what the alert's
    latency is made of. The failure it guards against is the old fixed 15-minute
    timer's: a reset landing one second after a poll waited the whole interval,
    and the whole feature's point — "you can start again" — arrived up to a
    quarter hour late. The properties asserted are the ones that make chasing an
    instant safe: it never polls harder than the ladder allows, it always falls
    back when the instant goes stale, and it can never manufacture an alert.

Extracts both types from the production source, no app launch.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Models/IdleTransitionDetector.swift').read_text()
start = source.index('struct QuotaResetDetector {')
body = source[start:]

# The scheduler's tuning is wired from `AppConfig` in `CodexProviderStore`; the
# detector/scheduler slice above carries the *code* but not the *values*, so the
# cross-constant property that keeps a reset from falling between two heartbeats
# is asserted on the shipped constants themselves. That is the point of doing it
# here rather than inside the compiled fixture: a scheduler built from test
# literals asserts `900 >= 900` and cannot fail, while a retune of AppConfig must.
# (`AppConfig.quotaResetHorizon`'s own doc comment makes this promise about
# `Tests/quota-reset-regressions.py`.)
config = (root / 'Sources/ClaudeBar/Models/AppConfig.swift').read_text()


def config_constant(name):
    match = re.search(rf'static let {name}: TimeInterval = ([0-9_]+)', config)
    assert match, f'AppConfig.{name} is no longer a static let TimeInterval — wire the assertion to its new shape'
    return float(match.group(1).replace('_', ''))


fallback = config_constant('quotaPollInterval')
horizon = config_constant('quotaResetHorizon')
assert horizon >= fallback, (
    f'AppConfig.quotaResetHorizon ({horizon}s) is below quotaPollInterval ({fallback}s): a reset '
    'can come inside the aim window and pass between two heartbeats without one landing in it, '
    'so the alert arrives up to a heartbeat late — the latency the scheduler exists to remove')

swift = r'''
import Foundation

/// Minimal stand-in for the production `CodexQuotaWindow` — only the fields
/// the detector reads. `slot` mirrors the production identity: the key the
/// detector must use instead of the label.
struct CodexQuotaWindow: Equatable {
    var slot: String = ""
    var id: String { slot.isEmpty ? label : slot }
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
}

DETECTOR

@main struct Regression {
    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t5h = t0.addingTimeInterval(5 * 3600)

        func window(_ used: Double, resets: Date? = nil, label: String = "5 小时",
                    slot: String = "primary") -> CodexQuotaWindow {
            CodexQuotaWindow(slot: slot, label: label, usedPercent: used, resetsAt: resets)
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
        _ = d.record([window(95, resets: t5h, label: "5 小时", slot: "primary"),
                      window(80, resets: t0.addingTimeInterval(7 * 86_400), label: "7 天", slot: "secondary")])
        let mixed = d.record([window(0, resets: t5h.addingTimeInterval(5 * 3600), label: "5 小时", slot: "primary"),
                              window(80, resets: t0.addingTimeInterval(7 * 86_400), label: "7 天", slot: "secondary")])
        precondition(mixed.count == 1, "only the rolled window may fire; got \(mixed.count)")
        precondition(mixed[0].label == "5 小时", "the wrong window fired: \(mixed[0].label)")

        // 6b. Two windows whose payload omitted `windowDurationMins` share one
        //     label （「额度」）but differ in slot. Keyed by label the secondary's
        //     first sighting was diffed against the primary's percentage and
        //     alerted on the spot, and afterwards neither window's rollover was
        //     seen at all — the collision the slot exists to remove.
        d = QuotaResetDetector()
        let t7d = t0.addingTimeInterval(7 * 86_400)
        precondition(d.record([window(95, resets: t5h, label: "额度", slot: "primary"),
                               window(10, resets: t7d, label: "额度", slot: "secondary")]).isEmpty,
                     "duration-less windows must both seed, not alert against each other")
        precondition(d.record([window(95, resets: t5h.addingTimeInterval(5 * 3600), label: "额度", slot: "primary"),
                               window(10, resets: t7d, label: "额度", slot: "secondary")]).count == 1,
                     "the primary's rollover must still fire when both labels collide")

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

        // ---- QuotaPollScheduler ------------------------------------------
        //
        // The settings mirror `AppConfig`; the numbers the assertions use are
        // read back off this instance so a retune of the constants does not
        // require a retune of the test.
        let s = QuotaPollScheduler(fallback: 900, grace: 5, horizon: 900, dueWindow: 300)
        let prev = { (instant: Date?) -> [String: Date?] in ["5 小时": instant] }
        var plan: TimeInterval = 0

        // 9. The heartbeat is never traded away. A window whose reset is hours
        //    out still gets a reading every `fallback` — the allowance moves on
        //    screen (it is spent), and that is watched independently of any
        //    reset.
        plan = s.nextInterval(now: t0, windows: [window(50, resets: t0.addingTimeInterval(86_400))],
                              previous: [:])
        precondition(plan == s.fallback, "the heartbeat must hold when nothing resets; got \(plan)")

        // 10. A window about to reset is looked at *when* it resets, not at the
        //     next heartbeat: a reset 12 s out must be observed 12 s out, not
        //     15 minutes out. This is the latency the feature is about.
        let soon = t0.addingTimeInterval(12)
        plan = s.nextInterval(now: t0, windows: [window(92, resets: soon)], previous: [:])
        precondition(plan == 17, "an imminent reset must be polled at the instant; got \(plan)")

        // 11. Just outside the aim window is still the heartbeat — but the
        //     heartbeat is *when* the aim window is next evaluated, so a reset
        //     at `horizon` + the fetch interval is never skimmed over: some
        //     heartbeat lands inside the window. (With the shipped constants
        //     horizon == fallback, so this is the tight case.)
        plan = s.nextInterval(now: t0, windows: [window(60, resets: t0.addingTimeInterval(s.horizon + 1))],
                              previous: [:])
        precondition(plan == s.fallback, "past the aim window means the heartbeat; got \(plan)")
        precondition(s.horizon >= s.fallback,
                     "the horizon must be at least the heartbeat, or a reset could fall between two polls")

        // 12. The aim has a floor and a ceiling: a just-passed instant is looked
        //     at now (not clamped up to the heartbeat), and never sooner than
        //     `grace`.
        let justPast = t0.addingTimeInterval(-3)
        plan = s.nextInterval(now: t0, windows: [window(70, resets: justPast)], previous: prev(justPast))
        precondition(plan == s.grace, "a just-passed instant must be looked at; got \(plan)")

        // 13. The bound on chasing. Past `dueWindow` the instant is abandoned —
        //     without this a reset that failed to fetch would be aimed at on
        //     every reading and the app would poll every `grace` indefinitely.
        let longPast = t0.addingTimeInterval(-(s.dueWindow + 10))
        plan = s.nextInterval(now: t0, windows: [window(40, resets: longPast)], previous: [:])
        precondition(plan == s.fallback, "a stale instant must not be chased")
        // Inside the bound it is still worth a look...
        plan = s.nextInterval(now: t0, windows: [window(40, resets: t0.addingTimeInterval(-60))],
                              previous: prev(t0.addingTimeInterval(-60)))
        precondition(plan == s.grace, "an instant inside the due window is still looked at")
        // ...but *only* when the previous reading named it. Otherwise a reading
        // that merely appears (launch, account switch) would probe for a reset
        // that already happened.
        plan = s.nextInterval(now: t0, windows: [window(40, resets: t0.addingTimeInterval(-60))],
                              previous: [:])
        precondition(plan == s.fallback, "a first sighting must not probe a passed instant")
        // And a reading whose schedule has advanced must not either.
        plan = s.nextInterval(now: t0, windows: [window(40, resets: t0.addingTimeInterval(-60))],
                              previous: prev(t0.addingTimeInterval(-3_600)))
        precondition(plan == s.fallback, "a moved schedule must not probe a passed instant")

        // 14. The reset the whole feature is for. A window that rolls at its
        //     instant is observed *at* that instant: the schedule aims there,
        //     the poll runs, and the detector reports it. Assert the pair, not
        //     just one half — a scheduler that aims at the right moment and a
        //     detector that ignores it is the silent regression.
        let rollAt = t0.addingTimeInterval(40)
        plan = s.nextInterval(now: t0, windows: [window(97, resets: rollAt)], previous: [:])
        // Aim at the instant *plus grace*, exactly: `grace` is the clock-skew
        // slack (the server rounds to the minute, the device clock drifts), so
        // a poll at the bare instant reads the old percentage and spends the
        // look on nothing. Tolerating `40` here would accept precisely the
        // regression the constant exists to prevent, and it is unreachable in
        // the formula besides — only dropping the `+ grace` slack yields it.
        precondition(plan == rollAt.timeIntervalSince(t0) + s.grace,
                     "the confirming poll lands at the instant plus grace; got \(plan)")
        var rd = QuotaResetDetector()
        _ = rd.record([window(97, resets: rollAt)])
        let observed = rd.record([window(0, resets: rollAt.addingTimeInterval(5 * 3600))])
        precondition(observed.count == 1,
                     "the reading taken at the aimed instant must report the rollover")

        // 15. The nearest instant wins, and a shared one is a single look:
        //     asking about either is asking about the same moment.
        plan = s.nextInterval(now: t0,
                              windows: [window(30, resets: soon, label: "5 小时", slot: "primary"),
                                        window(30, resets: soon, label: "7 天", slot: "secondary")],
                              previous: [:])
        precondition(plan == 17, "a shared instant must be aimed at once; got \(plan)")
        plan = s.nextInterval(now: t0,
                              windows: [window(30, resets: t0.addingTimeInterval(60), label: "7 天", slot: "secondary"),
                                        window(30, resets: soon, label: "5 小时", slot: "primary")],
                              previous: [:])
        precondition(plan == 17, "the nearest instant wins; got \(plan)")

        // 16. An instant never aimed below the heartbeat — a long-ago reset must
        //     not put the poll on a fast cycle.
        plan = s.nextInterval(now: t0, windows: [window(40, resets: t0.addingTimeInterval(-1_000))],
                              previous: prev(t0.addingTimeInterval(-1_000)))
        precondition(plan == s.fallback && plan >= s.grace, "the poll never spins")

        print("PASS: quota rollover fires exactly once — seed-safe, dip-safe, floor-safe, "
              + "per-window, forward-instant aware, no state leak across disappearances; "
              + "and the poll keeps its heartbeat, aims at the upcoming instant, is never "
              + "steered by a first sighting or an advanced schedule, and never spins")
    }
}
'''.replace('DETECTOR', body)
with tempfile.TemporaryDirectory(prefix='claudebar-quota-tests-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
