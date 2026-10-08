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
production notification service:

  1. the strip-carries-it predicate is true only with the island on, alerts on,
     and the strip not expanded;
  2. every other combination falls back to the banner — including the two the
     old code silently dropped (expanded strip, island off);
  3. the banner's *delivery stack*: the shipped `notifyNeedsInput` → `post` →
     `ensureCategory`/`requestAuthorizationIfNeeded`/`submit` run verbatim
     against a stub `UNUserNotificationCenter`. The parked fallback fires even
     with the 「空闲通知」 switch off (it is the sole signal for that edge) and
     never raises the authorization prompt; a **completion** banner still
     requires the switch and still asks while the status is undetermined;
  4. the banner's own content: a waiting title, the reason as the body, and an
     identifier keyed on the session so a re-park replaces rather than stacks.

The banner message and the whole post path are *sliced from production* and
executed, not restated: an earlier version of this harness retyped the
title/body/subtitle by hand, so the suite stayed green while the shipped wording
— and everything inside `post` — could drift away from it.
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

# The fixture below restates two strings the assertions and the stub center
# compare against — the stub answers the *production* status read, and the
# controller's fallback path is what these cases exercise — so pin both to
# production's own literals. Renaming either on one side would otherwise let the
# fixture assert against itself and stay green.
assert 'private static let categoryID = "IDLE_SESSION"' in service.read_text()
assert 'private static let waitingCategoryID = "NEEDS_INPUT"' in service.read_text()
assert 'BuildChannel.promptsForSystemPermissions' in (
    service.read_text()[service.read_text().index('func requestAuthorizationIfNeeded'):]), \
    'the parked fallback must not be the path that can raise the prompt'

harness = r'''
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

    // 3. The banner's content and delivery, produced by the shipped
    //    notifyNeedsInput → post → submit stack against the stubbed center.
    let center = NotificationCenterStub.shared
    let probe = BannerProbe()
    func park(pid: Int = 42, reason: String = "等待你确认 · Bash") {
        probe.notifyNeedsInput(session: SessionInfo(projectFolder: "ClaudeBar",
                                                    waitingReason: reason, pid: pid,
                                                    sessionId: "6f2a-session", cwd: "/Users/me/ClaudeBar"))
    }

    NotificationCenterStub.status = .authorized
    AppPreferences.shared.idleNotifyEnabled = false
    center.reset()
    park()
    let waiting = center.added.last
    // The parked fallback is not gated by 「空闲通知」: with the switch off and
    // the strip unable to carry the park, this banner is the only signal left.
    check(center.added.count == 1, "the parked fallback must post with 空闲通知 off; got \(center.added.count)")
    check(waiting?.title == "Claude 需要你确认", "the park banner leads with the agent + ask")
    check(waiting?.body == "ClaudeBar · 等待你确认 · Bash",
          "the body is project · reason; got \(waiting?.body ?? "nil")")
    check(waiting?.identifier == "waiting-42", "the identifier is keyed on the session for replace-not-stack")
    check(waiting?.category == "NEEDS_INPUT",
          "the banner carries the parked-on-you category, so its 去确认 action is offered")
    check(waiting?.agent == "claude", "the route names the agent, so the tap knows where to go")
    check(waiting?.sessionId == "6f2a-session",
          "the route carries the session key — every agent can be resumed by key, not only by pid")
    check(waiting?.cwd == "/Users/me/ClaudeBar", "the route carries the project directory")
    check(waiting?.pid == 42, "the pid rides along as the shortcut to a live window")
    check(center.categories == ["IDLE_SESSION", "NEEDS_INPUT"],
          "the posted banner registered both categories first; got \(center.categories)")

    // A session that re-parks must replace its pending banner, not stack one.
    park()
    check(center.added.count == 2 && center.added[0].identifier == center.added[1].identifier,
          "a re-park must reuse the identifier so the banner is replaced, not stacked")

    // The reason shapes: empty falls back to the generic ask, a plan carries its own.
    probe.notifyNeedsInput(session: SessionInfo(projectFolder: "p", waitingReason: "", pid: 7,
                                                sessionId: "s7", cwd: "/tmp/p"))
    check(center.added.last?.body == "p · 等待你确认", "an empty reason falls back to the generic ask")
    probe.notifyNeedsInput(session: SessionInfo(projectFolder: "p", waitingReason: "等待确认计划", pid: 9,
                                                sessionId: "s9", cwd: "/tmp/p"))
    check(center.added.last?.body == "p · 等待确认计划", "a plan approval carries its own reason")

    // 4. A *completion* banner keeps its own gate, exactly as before.
    center.reset()
    AppPreferences.shared.idleNotifyEnabled = false
    probe.notifyIdle(session: SessionInfo(projectFolder: "ClaudeBar", waitingReason: "",
                                          pid: 42, sessionId: "6f2a-session", cwd: "/Users/me/ClaudeBar"))
    check(center.added.isEmpty, "a completion banner must stay silent with 空闲通知 off")
    AppPreferences.shared.idleNotifyEnabled = true
    probe.notifyIdle(session: SessionInfo(projectFolder: "ClaudeBar", waitingReason: "",
                                          pid: 42, sessionId: "6f2a-session", cwd: "/Users/me/ClaudeBar"))
    check(center.added.count == 1 && center.added.last?.identifier == "session-42"
          && center.added.last?.category == "IDLE_SESSION",
          "with the switch on the completion banner posts under IDLE_SESSION; got \(center.added)")

    // 5. Denied: macOS would drop the banner, so the fallback does not spend an
    //    XPC round trip on it — but registration is not a post and still ran.
    NotificationCenterStub.status = .denied
    center.reset()
    park()
    check(center.added.isEmpty, "with notifications denied the parked fallback must not post")
    check(center.categories == ["IDLE_SESSION", "NEEDS_INPUT"],
          "ensureCategory still runs on the denied path; got \(center.categories)")

    // 6. Provisional counts as granted (the macOS 允许安静通知 state).
    NotificationCenterStub.status = .provisional
    center.reset()
    park()
    check(center.added.count == 1, "provisional authorization may post the parked fallback")

    // 7. Not determined: the user never opted in to notifications at all — this
    //    is a build-channel question on the other side, so the fallback must
    //    post nothing *and* never be the call that raises the prompt
    //    (`BuildChannel.promptsForSystemPermissions` is the first gate on that
    //    API; the fallback path does not reach it).
    NotificationCenterStub.status = .notDetermined
    center.reset()
    AppPreferences.shared.idleNotifyEnabled = false
    park()
    check(center.added.isEmpty, "with notifications undetermined the parked fallback posts nothing")
    check(center.requestAuthorizationCalls == 0,
          "the parked fallback must never raise the authorization prompt")

    // …while the completion path keeps its old shape: ask once, then submit.
    center.reset()
    AppPreferences.shared.idleNotifyEnabled = true
    probe.notifyIdle(session: SessionInfo(projectFolder: "ClaudeBar", waitingReason: "",
                                          pid: 42, sessionId: "6f2a-session", cwd: "/Users/me/ClaudeBar"))
    check(center.requestAuthorizationCalls == 1,
          "the completion path still asks for authorization while undetermined")
    check(center.added.count == 1, "and submits as it did before")

    center.reset()
    AppPresentation.performanceMode = true
    park()
    probe.notifyIdle(session: SessionInfo(projectFolder: "ClaudeBar", waitingReason: "",
                                          pid: 42, sessionId: "6f2a-session", cwd: "/Users/me/ClaudeBar"))
    check(center.added.isEmpty, "performance mode suppresses banners")
    check(center.requestAuthorizationCalls == 0, "performance mode never prompts for notifications")
    AppPresentation.performanceMode = false

    print("\(checks - failures.count)/\(checks) waiting-notify checks passed")
    if !failures.isEmpty { exit(1) }
}
run()
'''

# The predicate's *body*, so the production expression is what runs.
predicate_body = predicate[predicate.index('{') + 1:predicate.rindex('}')].strip()
harness = harness.replace('PREDICATE_BODY', predicate_body)

# Every piece below is sliced verbatim out of `NotificationService`; the only
# rewrite is the center itself, so the shipped gates, wording, categories and
# identifier rule are what run. `Self.logger`, `Self.categoryID`,
# `Self.waitingCategoryID` and `Self.userInfo` all resolve on the fixture class.
def sliced(signature):
    return slice_method(service, signature).replace(
        'UNUserNotificationCenter.current()', 'NotificationCenterStub.shared')

delivery = sliced('enum Delivery {')
ensure_category = sliced('private func ensureCategory()')
request_auth = sliced('func requestAuthorizationIfNeeded()')
notify_needs_input = sliced('func notifyNeedsInput(session: SessionInfo)')
notify_idle = sliced('func notifyIdle(session: SessionInfo)')
post_method = sliced('private func post(delivery: Delivery,')
submit_method = sliced('private func submit(title: String,')
user_info = sliced('private static func userInfo(for route: ResumeRoute)')

# The text the assertions compare against is restated here, so it must match
# production's own literals — a renamed category would otherwise make the
# fixture assert against itself.
assert 'private static let categoryID = "IDLE_SESSION"' in service.read_text()
assert 'private static let waitingCategoryID = "NEEDS_INPUT"' in service.read_text()
# The parked fallback must stay outside the 「空闲通知」 gate. The fixture
# restates the shipped expression, so a re-gated production copy must fail here
# rather than let the two drift silently apart.
assert 'if delivery == .idlePreference, !AppPreferences.shared.idleNotifyEnabled' in post_method, \
    'the completion gate must be scoped to the idlePreference delivery'

with tempfile.TemporaryDirectory(prefix='claudebar-waiting-notify-') as folder:
    folder = Path(folder)
    source = folder / 'Regression.swift'
    source.write_text('\n'.join([
        'import Foundation',
        'import UserNotifications',
        'import os',
        '',
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
        '/// The 「空闲通知」 switch the production `post` reads.',
        'final class AppPreferences {',
        '    static let shared = AppPreferences()',
        '    var idleNotifyEnabled = false',
        '}',
        '/// The production prompt gate; the fixture picks which side of it runs.',
        'enum BuildChannel { static var promptsForSystemPermissions = true }',
        (root / 'Sources/Shared/AppPresentation.swift').read_text(),
        '/// What the stubbed center answers `getNotificationSettings` with.',
        'struct NotificationSettingsStub { var authorizationStatus: UNAuthorizationStatus }',
        '',
        '/// Stands in for `UNUserNotificationCenter`: nothing here leaves the',
        '/// process, and `add` reaches the system exactly as far as the stub does.',
        'final class NotificationCenterStub {',
        '    static let shared = NotificationCenterStub()',
        '    static var status: UNAuthorizationStatus = .authorized',
        '    struct Added: Equatable {',
        '        var identifier: String; var title: String; var body: String',
        '        var category: String; var agent: String; var sessionId: String',
        '        var cwd: String; var pid: Int?',
        '    }',
        '    private(set) var categories: [String] = []',
        '    private(set) var requestAuthorizationCalls = 0',
        '    private(set) var added: [Added] = []',
        '    func getNotificationSettings(_ completion: @escaping (NotificationSettingsStub) -> Void) {',
        '        completion(NotificationSettingsStub(authorizationStatus: Self.status))',
        '    }',
        '    func requestAuthorization(options: UNAuthorizationOptions,',
        '                              completionHandler: @escaping (Bool, Error?) -> Void) {',
        '        requestAuthorizationCalls += 1',
        '        completionHandler(true, nil)',
        '    }',
        '    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {',
        '        self.categories = categories.map(\\.identifier).sorted()',
        '    }',
        '    func add(_ request: UNNotificationRequest, withCompletionHandler handler: ((Error?) -> Void)? = nil) {',
        '        let info = request.content.userInfo',
        '        added.append(Added(identifier: request.identifier, title: request.content.title,',
        '                           body: request.content.body,',
        '                           category: request.content.categoryIdentifier,',
        '                           agent: (info["agent"] as? String) ?? "",',
        '                           sessionId: (info["sessionId"] as? String) ?? "",',
        '                           cwd: (info["cwd"] as? String) ?? "",',
        '                           pid: info["pid"] as? Int))',
        '        handler?(nil)',
        '    }',
        '    func reset() { added = []; requestAuthorizationCalls = 0 }',
        '}',
        '',
        '/// The production notification stack with the center stubbed out.',
        'final class BannerProbe {',
        '    static let logger = Logger(subsystem: "com.claudebar.fixture", category: "waiting-notify")',
        '    static let categoryID = "IDLE_SESSION"',
        '    static let waitingCategoryID = "NEEDS_INPUT"',
        delivery,
        notify_needs_input,
        notify_idle,
        ensure_category,
        request_auth,
        post_method,
        submit_method,
        user_info,
        '}',
        harness,
    ]))
    subprocess.run(['swiftc', '-O', str(source), '-o', str(folder / 'regression')], check=True)
    subprocess.run([str(folder / 'regression')], check=True)
