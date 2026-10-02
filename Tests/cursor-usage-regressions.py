#!/usr/bin/env python3
"""Cursor's allowance decoder must survive the real payload — and the money trap.

Two things here are one line away from shipping a wrong number, and neither is
visible by reading the Swift:

1. **`totalSpend / limit` is not the plan's used fraction.** `totalSpend` sums
   the purchased spend *and* `bonusSpend`, and the bonus is promotional usage
   the plan does not cap. Measured on a live Pro account the raw ratio was
   **24.6** (`totalSpend` 49245¢ against a 2000¢ limit) — capping it at 1 hides
   the bug behind a plausible "100% full" bar. `includedSpend` is the numerator
   that answers the question, and the `displayMessage` flag is the authority
   when Cursor says the limit is hit.

2. **The two reset formats.** The RPC returns the billing cycle as an epoch-ms
   *string* (`"1790582107000"`), the web endpoints as ISO-8601; a parser that
   accepts only one blanks the reset line on the other surface.

3. **The two named pools.** `autoPercentUsed` is Cursor's "Cursor Models"
   pool and `apiPercentUsed` its "Other Models" pool. They are percentages of
   the plan's single allowance, not money limits of their own — so the chip
   graphs them as fractions and a payload without them must report no pool at
   all (a `nil`), never a 0% bar that reads as "all of it is left".

4. **The cookie spelling.** The web endpoints want `<sub>::<jwt>` percent-encoded
   as the value of `WorkosCursorSessionToken`, while the RPC wants the bare JWT.
   A cookie value with an unencoded `|` or `:` mis-splits — the same 401 the
   field notes record for using one spelling on the other host.

Extracts the real parsing functions from `CursorUsageFetcher` and drives them
with payloads captured from the live endpoints. No network, no app launch.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Utils/CursorUsageFetcher.swift').read_text()

def slice_between(start_marker, end_marker):
    a = source.index(start_marker)
    b = source.index(end_marker, a)
    return source[a:b]

# The popup chip's gauge labels, straight from the header source. Cursor's two
# pools are named "Cursor Models" / "Other Models", but the chip's ~119pt
# allowance row cannot hold two full names (they measure 166pt together and
# clipped to "Cursor Mo…"), so the chip abbreviates each to one word. Asserted
# here rather than left to review: a rename back to "Cursor Models" turns both
# gauges into a truncated mess, and a rename to 「月度」/「Grok」 would restore the
# mislabelling this change removed (「月度」 was the whole month, not a pool).
header = (root / 'Sources/ClaudeBar/Views/Popup/PanelHeader.swift').read_text()
gauge_block = header[header.index('private var cursorGaugeWindows'):
                     header.index('/// The money line under the gauges')]
assert 'label: "Cursor",' in gauge_block,     'the first pool gauge must be labelled "Cursor" (Cursor Models), fitted to the chip'
assert 'label: "Other",' in gauge_block,     'the second pool gauge must be labelled "Other" (Other Models), fitted to the chip'
assert 'cursorModelsFraction' in gauge_block and 'otherModelsFraction' in gauge_block,     'the gauges must read the two named-pool fractions, not the shared monthly bar'
assert '月度' not in gauge_block and '"Grok"' not in gauge_block, \
    'the old 「月度」/「Grok」pair must be gone from the chip (Grok Bot moved to the popover)'
# The popover keeps the full names — it is where the ~4x wider row lives.
panel = (root / 'Sources/ClaudeBar/Views/Shared/VpnTopChrome.swift').read_text()
assert 'subMetric("Cursor Models"' in panel and 'subMetric("Other Models"' in panel, \
    'the popover must still spell both pool names in full'

# Only the types and the pure parsing/cookie helpers — never the async network
# probes (they need a URLSession and would hit the account API for real).
types_and_helpers = slice_between('    struct PlanUsage: Equatable, Codable {',
                                 '    /// How long a reading is served without re-asking.')
snapshot = slice_between('    struct Snapshot: Equatable {',
                         '    /// The monthly plan allowance')
cookie = slice_between('    static func cookieValue(subject: String, token: String) -> String {',
                       '    static func parseGrok(_ data: Data) -> GrokUsage? {')
parse_plan = slice_between('    static func parsePlan(_ data: Data) -> PlanUsage? {',
                           '    // MARK: - Grok Bot weekly window')
# Only the *type* and the two persistence helpers: `fetch()` reaches for
# URLSession and the live account API, so it stays out. The file constant and
# `remember`/`lastKnown` are the launch path the popup opens on, and they are
# exactly what the shape-only round-trip below cannot cover.
known = slice_between('    struct LastKnown: Codable, Equatable {',
                      '    /// Read Cursor\'s allowance.')
# The file URL is rewritten to the fixture home so the suite cannot read or
# truncate a real user's `~/Library/Application Support/ClaudeBar`. The splice
# keeps the production path composition (`FilePaths.appSupportDir`), which the
# FilePaths source injected below then redirects.
known = known.replace(
    'private static let lastKnownFile = FilePaths.appSupportDir\n'
    '        .appendingPathComponent("cursor-allowance.json")',
    'static var lastKnownFileForTesting: URL {\n'
    '        FilePaths.appSupportDir.appendingPathComponent("cursor-allowance.json")\n'
    '    }')
# Production declares `lastKnownFile` as a stored `let`; the harness replaces it
# with a computed URL, so every other use must go through that name too.
known = known.replace('Data(contentsOf: lastKnownFile)', 'Data(contentsOf: lastKnownFileForTesting)')
known = known.replace('data.write(to: lastKnownFile,', 'data.write(to: lastKnownFileForTesting,')
# Production's `remember` is private; the harness renames it and wraps it so the
# scenario can call it, and adds the reset the scenario needs.
known = known.replace('private static func remember(', 'static func rememberSnapshot(')
persisted_helpers = r'''
    static func remember(_ snapshot: Snapshot) { Self.rememberSnapshot(snapshot) }
    static func resetLastKnownForTesting() {
        try? FileManager.default.removeItem(at: lastKnownFileForTesting)
    }
'''
decode_helpers = slice_between('    private static func clampPercent(_ value: Double) -> Double',
                               '    /// Cents → dollars')
parse_grok = slice_between('    static func parseGrok(_ data: Data) -> GrokUsage? {',
                           '    // MARK: - Decoding helpers')
money = slice_between('    static func money(_ cents: Double) -> String {',
                      '\n}')

swift = r'''
import Foundation

enum CursorUsageFetcher {
TYPES
SNAPSHOT
LASTKNOWN
COOKIE
PARSEPLAN
PARSEGROK
HELPERS
MONEY
}

@main struct Regression {
    static func main() {
        // --- 1. The live Pro payload ----------------------------------------
        let planJSON = """
        {"billingCycleStart":"1787903707000","billingCycleEnd":"1790582107000",
         "planUsage":{"totalSpend":49245,"includedSpend":2000,"bonusSpend":47245,
           "limit":2000,"remainingBonus":false,
           "autoPercentUsed":99.42666666666666,"apiPercentUsed":100,"totalPercentUsed":99.48484848484848},
         "spendLimitUsage":{"limitType":"user"},"displayThreshold":200,
         "enabled":true,"displayMessage":"You've hit your usage limit",
         "autoModelSelectedDisplayMessage":"You've used 99% of your included total usage"}
        """
        guard let plan = CursorUsageFetcher.parsePlan(Data(planJSON.utf8)) else {
            preconditionFailure("the live plan payload must decode")
        }
        precondition(plan.hitLimit, "displayMessage must set hitLimit")
        // The trap: totalSpend/limit is 24.6, not a fraction. The answer must be
        // 1.0 (the limit is hit), never 24.6 and never a silent wrong value.
        precondition(plan.usedFraction == 1.0,
                     "usedFraction was \(plan.usedFraction); totalSpend/limit leaks bonus spend")
        precondition(plan.spendText == "$492.45 / $20",
                     "spend text was \(plan.spendText ?? "nil")")
        precondition(plan.apiPercentUsed == 100 && plan.autoPercentUsed != nil,
                     "both sub-percentages must survive")
        // The two *named pools* the popup chip now graphs: autoPercentUsed is
        // "Cursor Models", apiPercentUsed is "Other Models", and each is the
        // reported percentage as a 0-1 fraction — NOT a share of the money
        // fields. The plan carries one `limit`, so a pool is never `nil` here
        // and never derived from `includedSpend`.
        precondition(abs((plan.cursorModelsFraction ?? -1) - 0.9942666666666666) < 0.0001,
                     "Cursor Models must be autoPercentUsed/100, was \(String(describing: plan.cursorModelsFraction))")
        precondition(plan.otherModelsFraction == 1.0,
                     "Other Models must be apiPercentUsed/100 = 1.0, was \(String(describing: plan.otherModelsFraction))")
        precondition(plan.hasNamedPools, "a plan with both percentages must report named pools")
        // epoch-ms *string* reset.
        precondition(plan.resetsAt != nil, "the epoch-ms billing cycle must parse")
        let expectedEnd = Date(timeIntervalSince1970: 1_790_582_107)
        precondition(abs((plan.resetsAt ?? .distantPast).timeIntervalSince(expectedEnd)) < 1,
                     "epoch-ms decode was off: \(String(describing: plan.resetsAt))")

        // --- 2. A fresh account: money present, limit not yet hit ------------
        let freshJSON = """
        {"billingCycleEnd":"1790582107000",
         "planUsage":{"totalSpend":500,"includedSpend":500,"bonusSpend":0,
           "limit":2000,"totalPercentUsed":25}}
        """
        guard let fresh = CursorUsageFetcher.parsePlan(Data(freshJSON.utf8)) else {
            preconditionFailure("a partial payload must still decode")
        }
        precondition(!fresh.hitLimit, "a clean payload must not read as hit")
        precondition(abs(fresh.usedFraction - 0.25) < 0.0001,
                     "included/limit must be 0.25, was \(fresh.usedFraction)")

        // --- 2b. Bonus spend without a hit-limit flag ------------------------
        //    The live payload above carries `displayMessage`, so `hitLimit`
        //    short-circuits `usedFraction` to 1 before the money fields are
        //    ever read — a regression that billed `totalSpend` (included +
        //    promotional bonus) as the numerator would pass section 1
        //    unnoticed. This payload has no message, so the branch under test
        //    is the real one; 4000 total against a 2000 limit is 200%, and the
        //    answer must be the included 500, not the capped total.
        let bonusJSON = """
        {"planUsage":{"totalSpend":4000,"includedSpend":500,"bonusSpend":3500,"limit":2000}}
        """
        guard let bonus = CursorUsageFetcher.parsePlan(Data(bonusJSON.utf8)) else {
            preconditionFailure("a bonus-spend payload must decode")
        }
        precondition(abs(bonus.usedFraction - 0.25) < 0.0001,
                     "included spend must be the numerator, was \(bonus.usedFraction)")

        // --- 3. A response shape with no percentage at all is refused --------
        //    (a zero would read as "0% used", which is a worse lie than nil)
        precondition(CursorUsageFetcher.parsePlan(Data("{\"planUsage\":{}}".utf8)) == nil,
                     "no percentage and no money must yield nil, not a zero")
        //    ...but money alone is enough to derive one.
        let moneyOnly = CursorUsageFetcher.parsePlan(
            Data("{\"planUsage\":{\"totalSpend\":1000,\"limit\":2000}}".utf8))
        precondition(moneyOnly != nil && abs(moneyOnly!.usedFraction - 0.5) < 0.0001,
                     "money-only payload must derive 50%")
        // A payload with only `totalPercentUsed` names no pool: the chip must
        // show that the pools are absent (no gauge) rather than draw a 0% bar
        // that reads "all of it is left". `hasNamedPools` is that decision.
        let noPools = CursorUsageFetcher.parsePlan(
            Data("{\"planUsage\":{\"totalPercentUsed\":25}}".utf8))
        precondition(noPools != nil, "a total-only payload must still decode")
        precondition(noPools?.cursorModelsFraction == nil && noPools?.otherModelsFraction == nil,
                     "a total-only payload must report no named pools")
        precondition(noPools?.hasNamedPools == false, "hasNamedPools must be false")
        // With no money fields the reported percentage *is* the answer; the
        // fallback must not return a zero that reads as "nothing used".
        precondition(abs((noPools?.usedFraction ?? -1) - 0.25) < 0.0001,
                     "a total-only payload must fall back to the percentage, was \(String(describing: noPools?.usedFraction))")
        // ...and a payload with just one pool still reports it (legacy/team
        // shapes omit `autoPercentUsed`), so a lone pool is not silently lost.
        let onePool = CursorUsageFetcher.parsePlan(
            Data("{\"planUsage\":{\"apiPercentUsed\":40,\"totalPercentUsed\":40}}".utf8))
        precondition(abs((onePool?.otherModelsFraction ?? -1) - 0.4) < 0.0001,
                     "the reported pool must survive alone")
        precondition(onePool?.cursorModelsFraction == nil && onePool?.hasNamedPools == true,
                     "one pool is still a named pool")

        // --- 4. The Grok window, with an ISO-8601 reset ----------------------
        let grokJSON = """
        {"currentPeriodStart":"2026-09-26T12:31:48.568Z",
         "nextResetTimestampUtc":"2026-10-03T12:31:48.568Z",
         "usagePercent":0.51745,"hasAvailableUsage":true,"cursorPlanName":"Pro"}
        """
        guard let grok = CursorUsageFetcher.parseGrok(Data(grokJSON.utf8)) else {
            preconditionFailure("the live Grok payload must decode")
        }
        precondition(abs(grok.usedPercent - 0.51745) < 0.0001, "Grok percent must be 0.51745")
        precondition(grok.planName == "Pro", "plan name must survive")
        precondition(grok.nextReset != nil, "the ISO-8601 reset must parse")

        // --- 5. The cookie spelling ------------------------------------------
        let subject = "google-oauth2|user_01JGDNMVAA8QJ9NGSZNTBQYDAK"
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
        let cookie = CursorUsageFetcher.cookieValue(subject: subject, token: token)
        precondition(cookie.hasPrefix("WorkosCursorSessionToken="), "cookie must be named")
        precondition(!cookie.contains("|"), "the sub's pipe must be percent-encoded: \(cookie)")
        // The separator must be encoded too — an unencoded '::' is the field-note
        // failure mode, so the raw '::' must not appear.
        let value = cookie.replacingOccurrences(of: "WorkosCursorSessionToken=", with: "")
        precondition(!value.contains("::"), "the :: separator must be percent-encoded")
        precondition(value.hasSuffix(token.percentEncodedLikeCookie) || value.contains("%2E"),
                     "the JWT must be carried through")

        // --- 6. Last-known round-trip ---------------------------------------
        // The persisted reading has to survive encode/decode intact: it is what
        // the popup opens on before the first probe can succeed (the launch
        // probe goes out before the system proxy is written), and a field lost
        // here would blank the Grok line or the reset on every relaunch.
        let planForDisk = CursorUsageFetcher.parsePlan(Data(planJSON.utf8))!
        let grokForDisk = CursorUsageFetcher.parseGrok(Data(grokJSON.utf8))!
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let known = CursorUsageFetcher.LastKnown(plan: planForDisk, grok: grokForDisk, at: stamp)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let roundTrip = try? dec.decode(CursorUsageFetcher.LastKnown.self,
                                              from: try enc.encode(known)) else {
            preconditionFailure("the last-known reading must round-trip")
        }
        // Field-by-field, not `==`: `.iso8601` drops sub-second precision, so a
        // whole-value compare fails on the timestamp alone. That is the encoder
        // being lossy about a *second* of staleness, not a field going missing.
        precondition(roundTrip.plan?.usedPercent == known.plan?.usedPercent,
                     "the plan percentage must survive")
        precondition(roundTrip.plan?.spendText == "$492.45 / $20", "the money line must survive")
        precondition(roundTrip.plan?.hitLimit == true, "hitLimit is what pins the gauge at 0% left")
        precondition(roundTrip.grok?.planName == "Pro" && roundTrip.grok?.nextReset != nil,
                     "the Grok plan name and its reset must survive")
        precondition(abs(roundTrip.at.timeIntervalSince(stamp)) < 1, "the timestamp must survive")
        precondition(roundTrip.plan?.billingCycleEnd == known.plan?.billingCycleEnd,
                     "the reset instant must survive (the date strategy must not shift it)")

        // --- 7. The disk round-trip drives the production file --------------
        // The block above proves the *shape* survives JSON; it never touches
        // `remember` / `lastKnown`, so a failure to write (or a read of the
        // wrong path) would still pass. Re-run them against a fixture home:
        // an empty snapshot must not erase a seeded reading, and a real one
        // must come back with its fields intact.
        try! FileManager.default.createDirectory(at: FilePaths.appSupportDir,
                                                 withIntermediateDirectories: true)
        CursorUsageFetcher.resetLastKnownForTesting()
        precondition(CursorUsageFetcher.lastKnown() == nil, "a fresh install has no last-known reading")
        CursorUsageFetcher.remember(CursorUsageFetcher.Snapshot())
        precondition(CursorUsageFetcher.lastKnown() == nil,
                     "an empty snapshot must not write a blank reading")
        CursorUsageFetcher.remember(CursorUsageFetcher.Snapshot(plan: planForDisk, grok: grokForDisk))
        guard let persisted = CursorUsageFetcher.lastKnown() else {
            preconditionFailure("a good reading must survive a relaunch: remember() wrote nothing, "
                + "or lastKnown() could not read what it wrote")
        }
        precondition(persisted.plan?.spendText == "$492.45 / $20",
                     "the persisted money line must survive the disk round-trip")
        precondition(persisted.plan?.hitLimit == true, "hitLimit must survive the disk round-trip")
        precondition(persisted.grok?.planName == "Pro", "the Grok half must survive too")
        // And an empty snapshot after a seeded one must leave the old reading
        // in place rather than truncating it.
        CursorUsageFetcher.remember(CursorUsageFetcher.Snapshot())
        precondition(CursorUsageFetcher.lastKnown()?.plan != nil,
                     "an empty snapshot must not erase the seeded file")

        print("PASS: Cursor allowance decodes the live plan + Grok payloads; totalSpend's "
              + "bonus spend never leaks into the used fraction; both reset formats parse; "
              + "the cookie spelling percent-encodes the sub and the :: separator; the two "
              + "named pools (Cursor Models = autoPercentUsed, Other Models = apiPercentUsed) "
              + "fraction cleanly and a missing pool stays absent rather than reading 0%; the "
              + "last-known reading round-trips through disk with its money, reset and "
              + "hit-limit intact")
    }
}
'''

# The Swift template spells the cookie's percent-encoding helper differently:
# `percentEncodedLikeCookie` is not a member production ever had (it was a
# Tests-side spelling), so the harness rewrites that one fragment to the real
# call before compiling. The substitution below is load-bearing — without it the
# template does not compile — and the template's call site is the only place the
# wrong spelling appears.
swift = swift.replace(
    'value.hasSuffix(token.percentEncodedLikeCookie) || value.contains("%2E"),\n                     "the JWT must be carried through")',
    'value.contains("eyJhbGciOiJIUzI1NiJ9"),\n                     "the JWT must be carried through")')

swift = (swift
         .replace('TYPES', types_and_helpers)
         .replace('SNAPSHOT', snapshot)
         .replace('COOKIE', cookie)
         .replace('PARSEPLAN', parse_plan)
         .replace('PARSEGROK', parse_grok)
         .replace('LASTKNOWN', known + '\n' + persisted_helpers)
         .replace('HELPERS', decode_helpers)
         .replace('MONEY', money))

# The last-known persistence path is driven against a fixture home, so the real
# `~/Library/Application Support` is never touched: FilePaths is spliced the same
# way `cursor-turn-regressions.py` does it, and the file URL and the two helpers
# that read/write it are pulled in with the rest of the type. The harness-only
# shims above expose production's `private remember` and add a reset; the
# production path composition (`FilePaths.appSupportDir`) is unchanged.
paths = (root / 'Sources/ClaudeBar/Utils/FilePaths.swift').read_text()
paths = paths.replace('FileManager.default.homeDirectoryForCurrentUser', 'fixtureHome')
paths = paths.replace('FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]',
                      'fixtureSupport')
build_channel = (root / 'Sources/Shared/BuildChannel.swift').read_text()

with tempfile.TemporaryDirectory(prefix='claudebar-cursor-usage-') as folder:
    folder = Path(folder)
    support = folder / 'support'
    support.mkdir()
    header = ('import Foundation\n'
              'let fixtureHome = URL(fileURLWithPath: CommandLine.arguments[1])\n'
              'let fixtureSupport = URL(fileURLWithPath: CommandLine.arguments[2])\n'
              + build_channel + '\n' + paths + '\n')
    swift = header + swift.replace('import Foundation\n', '', 1)
    path = folder / 'Regression.swift'
    path.write_text(swift)
    binary = folder / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder / 'home'), str(support)], check=True)
