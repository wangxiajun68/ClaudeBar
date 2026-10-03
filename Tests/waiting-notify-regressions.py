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

The banner message is *sliced from the production builder* and executed against
a stub `post`, not restated: an earlier version of this harness retyped the
title/body/subtitle by hand, so the suite stayed green while the shipped wording
could drift away from it.
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
// The predicate under test is the production one, spliced in below.
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

    // 3. The banner text, from the production builder itself: the method below
    //    is spliced verbatim out of `NotificationService`, and `post` is the
    //    only member replaced.
    let probe = BannerProbe()
    probe.notifyNeedsInput(session: SessionInfo(projectFolder: "ClaudeBar",
                                                waitingReason: "等待你确认 · Bash", pid: 42,
                                                sessionId: "6f2a-session", cwd: "/Users/me/ClaudeBar"))
    let waiting = probe.posted
    check(waiting?.title == "Claude 需要你确认", "the park banner leads with the agent + ask")
    check(waiting?.body == "ClaudeBar · 等待你确认 · Bash",
          "the body is project · reason; got \(waiting?.body ?? "nil")")
    check(waiting?.subtitle == "waiting-42", "the subtitle is keyed on the session for replace-not-stack")
    check(waiting?.categoryID == BannerProbe.waitingCategoryID,
          "the banner carries the parked-on-you category, so its 去确认 action is offered")
    check(waiting?.route.agent == "claude", "the route names the agent, so the tap knows where to go")
    check(waiting?.route.sessionId == "6f2a-session",
          "the route carries the session key — every agent can be resumed by key, not only by pid")
    check(waiting?.route.cwd == "/Users/me/ClaudeBar", "the route carries the project directory")
    check(waiting?.route.pid == 42, "the pid rides along as the shortcut to a live window")
    probe.notifyNeedsInput(session: SessionInfo(projectFolder: "p", waitingReason: "", pid: 7,
                                                sessionId: "s7", cwd: "/tmp/p"))
    check(probe.posted?.body == "p · 等待你确认", "an empty reason falls back to the generic ask")
    probe.notifyNeedsInput(session: SessionInfo(projectFolder: "p", waitingReason: "等待确认计划", pid: 9,
                                                sessionId: "s9", cwd: "/tmp/p"))
    check(probe.posted?.body == "p · 等待确认计划", "a plan approval carries its own reason")

    print("\(checks - failures.count)/\(checks) waiting-notify checks passed")
    if !failures.isEmpty { exit(1) }
}
run()
'''

# The predicate's *body*, so the production expression is what runs.
predicate_body = predicate[predicate.index('{') + 1:predicate.rindex('}')].strip()
harness = harness.replace('PREDICATE_BODY', predicate_body)

# The Claude park banner, verbatim from `NotificationService`. Only `post` is
# replaced (it is the method that reaches `UNUserNotificationCenter`); the
# wording, the category and the pid all come from the shipped function, so this
# suite moves the day the banner does.
banner_method = slice_method(
    service, 'func notifyNeedsInput(session: SessionInfo)',
)

with tempfile.TemporaryDirectory(prefix='claudebar-waiting-notify-') as folder:
    folder = Path(folder)
    source = folder / 'Regression.swift'
    source.write_text('\n'.join([
        'import Foundation',
        '/// The fields the builder reads, plus an identity for the message.',
        'struct SessionInfo: Equatable {',
        '    let projectFolder: String',
        '    let waitingReason: String',
        '    let pid: Int',
        '    let sessionId: String',
        '    let cwd: String',
        '}',
        '/// The route the production builder hands `post` — the same shape, so a',
        '/// field renamed in `NotificationService` fails to compile here too.',
        'struct ResumeRoute: Equatable {',
        '    var agent: String; var sessionId: String; var cwd: String',
        '    var pid: Int?; var inDesktop: Bool',
        '}',
        '/// The production builder with a stub sink: every argument the shipped',
        '/// `notifyNeedsInput` passes is captured instead of posted.',
        'final class BannerProbe {',
        '    struct Banner: Equatable {',
        '        let title: String; let body: String; let subtitle: String',
        '        let categoryID: String; let route: ResumeRoute',
        '    }',
        '    static let waitingCategoryID = "NEEDS_INPUT"',
        '    private(set) var posted: Banner?',
        '    func post(title: String, body: String, subtitle: String,',
        '              categoryID: String, route: ResumeRoute) {',
        '        posted = Banner(title: title, body: body, subtitle: subtitle,',
        '                        categoryID: categoryID, route: route)',
        '    }',
        banner_method,
        '}',
        harness,
    ]))
    subprocess.run(['swiftc', '-O', str(source), '-o', str(folder / 'regression')], check=True)
    subprocess.run([str(folder / 'regression')], check=True)
