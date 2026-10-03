#!/usr/bin/env python3
"""A failed quota poll must not erase the allowance reading or the rollover watch.

`CodexProviderStore.refreshQuota` used to publish whatever the fetcher returned,
including the empty window list of a failure. Two things broke at once, both
invisible in review because the assignment reads like the obvious thing to do:

  * the popup's allowance row went blank and its tooltip claimed the account has
    no windows, when in truth the read simply did not happen;
  * `IslandLiveModel` feeds every distinct `$quotaWindows` value to
    `QuotaResetDetector`, whose `seen`/`announced` maps are pruned to the windows
    *present in the record*. An empty record wipes them, so the next successful
    reading only *seeds* — and a rollover that happened across the failed poll is
    never announced, which is the one alert this whole path exists for.

The fix is a distinction the fetch result has to carry itself: a failure is not an
authoritative "this account has no windows". This suite drives the production
`refreshQuota` / `applyQuotaSchedule` bodies (sliced verbatim) against a stubbed
fetcher, with the production `QuotaResetDetector` wired the way `IslandLiveModel`
wires it, and asserts both halves of the behaviour — including that an *answered*
empty reading still clears the row, because a store that keeps a stale reading
forever is the other way to get this wrong.

No app, no network, no Codex runtime.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
models = root / 'Sources/ClaudeBar/Models'
utils = root / 'Sources/ClaudeBar/Utils'

store_source = (models / 'CodexProviderStore.swift').read_text()
detector_source = (models / 'IdleTransitionDetector.swift').read_text()
fetcher_source = (utils / 'CodexQuotaFetcher.swift').read_text()
config = (models / 'AppConfig.swift').read_text()


def braced(text, signature):
    """The whole declaration starting at `signature`, matched to its closing brace."""
    start = text.index(signature)
    i = text.index('{', start)
    depth = 0
    j = i
    while True:
        if text[j] == '{':
            depth += 1
        elif text[j] == '}':
            depth -= 1
            if depth == 0:
                break
        j += 1
    return text[start:j + 1]


def config_constant(name):
    match = re.search(rf'static let {name}: TimeInterval = ([0-9_]+)', config)
    assert match, f'AppConfig.{name} is no longer a static let TimeInterval — rewire this suite'
    return float(match.group(1).replace('_', ''))


# Functionality is sliced; tuning comes from the shipped constants so a retune
# moves the assertions instead of silently invalidating them.
tuning = {name: config_constant(name) for name in
          ('quotaPollInterval', 'quotaResetGrace', 'quotaResetHorizon', 'quotaResetDueWindow')}

# The window type and the snapshot type come from production, not a stand-in:
# `Snapshot.failed` is the field this behaviour turns on, and a fixture that
# declared its own copy would let the production flag be renamed away.
window_type = fetcher_source[:fetcher_source.index('enum CodexQuotaFetcher {')]
snapshot_type = braced(fetcher_source, '    struct Snapshot: Equatable {')
# Both halves of the alert path: the detector that decides *whether* a rollover
# happened, and the scheduler that decides *when* the poll looks for one. They
# are separate types in one file with another detector between them, so each is
# sliced on its own braces rather than to the end of the file.
detector = detector_source[detector_source.index('struct QuotaResetDetector {'):]
detector = detector[:detector.index('\n}\n') + 3]
scheduler = braced(detector_source, 'struct QuotaPollScheduler {')

refresh = braced(store_source, '    func refreshQuota(manual: Bool = false) {')
schedule = braced(store_source, '    private func applyQuotaSchedule(from windows: [CodexQuotaWindow]) {')

swift = f'''
import Foundation

enum AppConfig {{
    static let quotaPollInterval: TimeInterval = {tuning['quotaPollInterval']}
    static let quotaResetGrace: TimeInterval = {tuning['quotaResetGrace']}
    static let quotaResetHorizon: TimeInterval = {tuning['quotaResetHorizon']}
    static let quotaResetDueWindow: TimeInterval = {tuning['quotaResetDueWindow']}
}}

{window_type}

{detector}

{scheduler}

/// The fetcher, stubbed at its boundary: `fetch()` hands back queued readings in
/// order, and what the store does with each is the thing under test.
@MainActor enum CodexQuotaFetcher {{
    {snapshot_type}

    static var queued: [Snapshot] = []
    static var fetches = 0
    static var invalidations = 0

    static func fetch() async -> Snapshot {{
        fetches += 1
        return queued.removeFirst()
    }}

    static func invalidateCache() {{ invalidations += 1 }}
}}

/// The store's quota half: the production method bodies, plus the fields they
/// touch. Everything else about `CodexProviderStore` is irrelevant here.
@MainActor final class QuotaStore {{
    var quotaWindows: [CodexQuotaWindow] = []
    var quotaLoading = false
    var quotaNote: String?
    var creditBalance: String?
    private var quotaTask: Task<Void, Never>?
    private var quotaTimer: Timer?
    private var quotaPreviousResets: [String: Date?] = [:]
    /// Read the schedule the way a reader watches it: `fireDate` is what the
    /// run loop was actually handed.
    var nextFire: Date? {{ quotaTimer?.fireDate }}
    var previousResets: [String: Date?] {{ quotaPreviousResets }}

    func refreshConfiguredModel() {{}}

    private static let quotaScheduler = QuotaPollScheduler(
        fallback: AppConfig.quotaPollInterval,
        grace: AppConfig.quotaResetGrace,
        horizon: AppConfig.quotaResetHorizon,
        dueWindow: AppConfig.quotaResetDueWindow)

{refresh}

{schedule}

    /// Settle the refresh `refreshQuota` just started.
    func settle() async {{
        if let task = quotaTask {{ await task.value }}
    }}
}}

@main struct Regression {{
    @MainActor static func main() async {{
        let now = Date()
        let resetSoon = now.addingTimeInterval(40)
        let weekly = now.addingTimeInterval(7 * 86_400)

        func window(_ slot: String, _ label: String, _ used: Double,
                    resets: Date? = nil) -> CodexQuotaWindow {{
            CodexQuotaWindow(slot: slot, label: label, usedPercent: used, resetsAt: resets)
        }}

        // The detector, wired the way `IslandLiveModel` wires it: one record per
        // *distinct* publication of `$quotaWindows` (`removeDuplicates` there),
        // so an unchanged list is simply never re-read.
        var detector = QuotaResetDetector()
        var lastPublished: [CodexQuotaWindow] = []
        var alerts: [CodexQuotaWindow] = []
        func publish(_ store: QuotaStore) {{
            guard store.quotaWindows != lastPublished else {{ return }}
            lastPublished = store.quotaWindows
            alerts.append(contentsOf: detector.record(store.quotaWindows))
        }}

        // 1. A real reading lands: windows and credits are published, the note
        //    clears, and the poll is re-armed at the reset instant + grace.
        let store = QuotaStore()
        CodexQuotaFetcher.queued = [
            CodexQuotaFetcher.Snapshot(
                windows: [window("primary", "5 小时", 50, resets: resetSoon),
                          window("secondary", "7 天", 20, resets: weekly)],
                creditBalance: "12 Credits"),
        ]
        store.refreshQuota()
        await store.settle()
        publish(store)
        precondition(store.quotaWindows.count == 2, "a reading must be published")
        precondition(store.creditBalance == "12 Credits" && store.quotaNote == nil)
        precondition(store.previousResets.keys.sorted() == ["primary", "secondary"],
                     "the schedule must be keyed by slot, not label; got \\(store.previousResets.keys.sorted())")
        let aimed = store.nextFire?.timeIntervalSinceNow ?? 0
        precondition(abs(aimed - (resetSoon.timeIntervalSinceNow + AppConfig.quotaResetGrace)) < 2,
                     "an imminent reset must be aimed at; got \\(aimed)")

        // 2. The window is now nearly spent, and the poll that follows fails.
        //    The reading must survive: the row keeps its figures, the credits
        //    keep their value, and the detector is not fed an empty record (no
        //    publication at all).
        CodexQuotaFetcher.queued = [
            CodexQuotaFetcher.Snapshot(windows: [window("primary", "5 小时", 97, resets: resetSoon),
                                                 window("secondary", "7 天", 20, resets: weekly)],
                                       creditBalance: "12 Credits"),
        ]
        store.refreshQuota()
        await store.settle()
        publish(store)
        precondition(alerts.isEmpty, "a window filling up is not a rollover; got \\(alerts.map(\\.id))")
        let good = store.quotaWindows
        CodexQuotaFetcher.queued = [
            CodexQuotaFetcher.Snapshot(note: "Codex 额度查询失败", failed: true),
        ]
        store.refreshQuota()
        await store.settle()
        publish(store)
        precondition(store.quotaWindows == good, "a failed poll must not replace the reading")
        precondition(store.creditBalance == "12 Credits", "a failed poll must not blank the credits")
        precondition(store.quotaNote == "Codex 额度查询失败", "a failed poll must say so")
        precondition(!store.quotaLoading, "the spinner must stop even on a failure")
        let afterFailure = store.nextFire?.timeIntervalSinceNow ?? 0
        precondition(abs(afterFailure - AppConfig.quotaPollInterval) < 2,
                     "a failure must fall back to the heartbeat, not chase a stored instant; got \\(afterFailure)")

        // 3. The rollover the failed poll straddled. The detector still holds the
        //    pre-failure state, so the drop to ~0 with a fresh instant is the
        //    announced edge. (With the assignment unguarded the failure wiped the
        //    detector and this reading would only seed — no alert, ever.)
        CodexQuotaFetcher.queued = [
            CodexQuotaFetcher.Snapshot(windows: [window("primary", "5 小时", 0, resets: resetSoon.addingTimeInterval(5 * 3_600)),
                                                 window("secondary", "7 天", 20, resets: weekly)]),
        ]
        store.refreshQuota()
        await store.settle()
        publish(store)
        precondition(alerts.count == 1 && alerts[0].id == "primary",
                     "the rollover across a failed poll must still be announced; got \\(alerts.map(\\.id))")

        // 4. The other direction: an *answered* payload with no windows is the
        //    truth about the account, so the row clears rather than holding a
        //    reading that no longer describes it. (Cursor's store draws the same
        //    line — an empty reading is an answer, a failure is not.)
        CodexQuotaFetcher.queued = [
            CodexQuotaFetcher.Snapshot(note: "当前账户没有 Codex 额度窗口"),
        ]
        store.refreshQuota()
        await store.settle()
        publish(store)
        precondition(store.quotaWindows.isEmpty, "an answered empty reading must clear the row")
        precondition(store.quotaNote == "当前账户没有 Codex 额度窗口")
        let cleared = store.nextFire?.timeIntervalSinceNow ?? 0
        precondition(abs(cleared - AppConfig.quotaPollInterval) < 2, "no windows means the heartbeat")

        // 5. A manual press drops the fetcher's cache first; an automatic poll
        //    does not.
        CodexQuotaFetcher.queued = [CodexQuotaFetcher.Snapshot(note: "当前账户没有 Codex 额度窗口")]
        store.refreshQuota(manual: true)
        await store.settle()
        precondition(CodexQuotaFetcher.invalidations == 1,
                     "a manual refresh must ask for a new reading; got \\(CodexQuotaFetcher.invalidations)")

        // 6. Overlapping refreshes are still refused — a second tap while a probe
        //    is in flight must not spawn a second app server behind it.
        let before = CodexQuotaFetcher.fetches
        CodexQuotaFetcher.queued = [CodexQuotaFetcher.Snapshot(note: "当前账户没有 Codex 额度窗口"),
                                    CodexQuotaFetcher.Snapshot(note: "当前账户没有 Codex 额度窗口")]
        store.refreshQuota()
        store.refreshQuota()
        await store.settle()
        precondition(CodexQuotaFetcher.fetches == before + 1,
                     "a refresh already in flight must absorb the next call; got \\(CodexQuotaFetcher.fetches - before)")

        print("PASS: a failed poll keeps the reading, the credits and the rollover watch (heartbeat, "
              + "not a chase); an answered empty payload clears the row; a manual press drops the cache; "
              + "overlapping refreshes stay single-file")
    }}
}}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-quota-store-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
