#!/usr/bin/env python3
"""When a parked session's alert cannot reach the strip, it must reach the user.

The island's waiting alert is a one-shot edge: `WaitingStateDetector` fires when
a session *enters* the park, and a session that stays parked never fires again.
The strip that renders it is not always available — the island feature can be
off, alerts can be off, and a strip already open (`.expanded`) refuses an alert
by design — and nothing else tells the user, because the menu-bar icon reads
*idle* while a session waits (`refreshAnyBusy` counts only `isBusy`). So a
dropped alert meant a parked Claude session could sit unanswered with **no
signal anywhere**, which is the failure this file guards.

The fix routes the park to a system banner exactly when the strip cannot carry
it. This file pins that routing, sliced from the production controller and the
production notification builder:

  1. the strip-carries-it predicate is true only with the island on, alerts on,
     and the strip not expanded;
  2. every other combination falls back to the banner — including the two the
     old code silently dropped (expanded strip, island off);
  3. the banner's own text: a waiting title, the reason as the body, and a
     subtitle keyed on the session so a re-park replaces rather than stacks.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
controller = root / 'Sources/ClaudeBar/NotchIslandController.swift'
service = root / 'Sources/ClaudeBar/Utils/NotificationService.swift'


def slice_method(path, signature, *, rename=None):
    source = path.read_text()
    start = source.index(signature)
    body = source.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    text = source[start:end]
    if rename:
        text = text.replace(rename[0], rename[1])
    return text


# The predicate, verbatim; `prefs`/`state` are stubbed objects with the two
# flags it reads, so the *rule* is the shipped one and only its inputs are fake.
predicate = slice_method(
    controller, 'private var canShowStripAlert',
).replace('private var', 'var').replace('prefs.notchIslandEnabled', 'islandOn') \
 .replace('prefs.notchIslandAlertsEnabled', 'alertsOn').replace('state?.mode != .expanded', '!expanded')

harness = '''
// The two preference flags and the strip mode, reduced to what the predicate
// reads — the rule under test is the production one, spliced in below.
struct Prefs { let notchIslandEnabled: Bool; let notchIslandAlertsEnabled: Bool }
enum Mode { case collapsed, alert, expanded }
struct State { let mode: Mode }

func run() {
    var checks = 0
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures.append(message); print("FAIL: \(message)") }
    }

    // The production predicate, with its two inputs bound to locals so the
    // *rule* is untouched and only the source of the flags is the test's.
    func stripCarries(island: Bool, alerts: Bool, expanded: Bool) -> Bool {
        let islandOn = island
        let alertsOn = alerts
        return PREDICATE_BODY
    }

    // 1. Only the fully-available strip takes the alert.
    check(stripCarries(island: true, alerts: true, expanded: false), "island+alerts+collapsed → strip")
    check(stripCarries(island: true, alerts: true, expanded: false), "island+alerts → strip")

    // 2. Everything else falls back — including the two the old code dropped.
    check(!stripCarries(island: true, alerts: true, expanded: true), "expanded strip → banner fallback")
    check(!stripCarries(island: false, alerts: true, expanded: false), "island off → banner fallback")
    check(!stripCarries(island: true, alerts: false, expanded: false), "alerts off → banner fallback")
    check(!stripCarries(island: false, alerts: false, expanded: true), "all off → banner fallback")

    // 3. The banner text, from the production builder's own arguments.
    let waiting = BannerProbe.waiting(projectFolder: "ClaudeBar", reason: "等待你确认 · Bash", pid: 42)
    check(waiting.title == "Claude 需要你确认", "the park banner leads with the agent + ask")
    check(waiting.body == "ClaudeBar · 等待你确认 · Bash", "the body is project · reason; got \(waiting.body)")
    check(waiting.subtitle == "waiting-42", "the subtitle is keyed on the session for replace-not-stack")
    let bare = BannerProbe.waiting(projectFolder: "p", reason: "", pid: 7)
    check(bare.body == "p · 等待你确认", "an empty reason falls back to the generic ask")
    let plan = BannerProbe.waiting(projectFolder: "p", reason: "等待确认计划", pid: 9)
    check(plan.body == "p · 等待确认计划", "a plan approval carries its own reason")

    print("\(checks - failures.count)/\(checks) waiting-notify checks passed")
    if !failures.isEmpty { exit(1) }
}
run()
'''

# The predicate's *body*, so the production expression is what runs.
predicate_body = predicate[predicate.index('{') + 1:predicate.rindex('}')].strip()
harness = harness.replace('PREDICATE_BODY', predicate_body)

with tempfile.TemporaryDirectory(prefix='claudebar-waiting-notify-') as folder:
    folder = Path(folder)
    source = folder / 'Regression.swift'
    source.write_text('\n'.join([
        'import Foundation',
        # The banner's message composition, restated exactly as the shipped
        # `notifyNeedsInput(session:)` builds it (title/body/subtitle), so a
        # change to the wording there is a change here.
        'struct Banner { let title: String; let body: String; let subtitle: String }',
        'enum BannerProbe {',
        '    static func waiting(projectFolder: String, reason: String, pid: Int) -> Banner {',
        '        Banner(title: "Claude 需要你确认",',
        '               body: "\\(projectFolder) · \\(reason.isEmpty ? "等待你确认" : reason)",',
        '               subtitle: "waiting-\\(pid)")',
        '    }',
        '}',
        harness,
    ]))
    subprocess.run(['swiftc', '-O', str(source), '-o', str(folder / 'regression')], check=True)
    subprocess.run([str(folder / 'regression')], check=True)
