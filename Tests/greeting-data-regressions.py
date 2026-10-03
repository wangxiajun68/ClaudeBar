#!/usr/bin/env python3
"""Exercise account credit parsing through real rate-limit payloads.
No network and no local account credentials: compile the production fetcher
with its response parser made internal in the temporary test module only.

`CodexRuntime` is compiled in whole because `CodexQuotaFetcher` resolves the
installed `codex` binary through it — the same resolver `CodexAppServerClient`
uses to reach the app server, so the slice has to carry it to keep the
production call site compiling rather than stubbing it out.
"""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
fetcher = (root / 'Sources/ClaudeBar/Utils/CodexQuotaFetcher.swift').read_text()
fetcher = fetcher.replace('private static func parseResponse', 'static func parseResponse')
coerce = (root / 'Sources/ClaudeBar/Utils/JSONCoerce.swift').read_text()
runtime = (root / 'Sources/ClaudeBar/Utils/CodexAppServerClient.swift').read_text()
runtime = runtime[:runtime.index('/// Lists and cleans up Codex threads')]
probe = r'''
@main struct Probe {
    static func main() {
        func parse(_ rate: [String: Any], modern: Bool = true) -> CodexQuotaFetcher.Snapshot {
            let result: [String: Any] = modern ? ["rateLimitsByLimitId": ["codex": rate]] : ["rateLimits": rate]
            return CodexQuotaFetcher.parseResponse(["result": result], authMode: "chatgpt")
        }
        let window: [String: Any] = ["usedPercent": 84.0, "windowDurationMins": 300, "resetsAt": 1_900_000_000]
        let populated = parse(["primary": window, "credits": ["balance": "12.5", "hasCredits": true]])
        precondition(populated.windows.count == 1)
        precondition(populated.windows[0].usedPercent == 84)
        precondition(populated.windows[0].resetsAt == Date(timeIntervalSince1970: 1_900_000_000))
        precondition(populated.creditBalance?.hasSuffix(" Credits") == true)
        precondition(parse(["credits": ["balance": "0", "hasCredits": false]]).creditBalance == "0 Credits")
        precondition(parse(["credits": ["unlimited": true]]).creditBalance == "不限量")
        precondition(parse(["primary": window]).creditBalance == nil)
        precondition(parse(["credits": ["hasCredits": false]]).creditBalance == nil)
        for invalid in ["nan", "inf", "-1", "", "USD 3"] {
            precondition(parse(["credits": ["balance": invalid]]).creditBalance == nil)
        }
        let creditOnly = parse(["credits": ["balance": 42.25]], modern: false)
        precondition(creditOnly.windows.isEmpty && creditOnly.creditBalance != nil)
        precondition(creditOnly.note != nil)
        let failure = CodexQuotaFetcher.parseResponse(["error": ["message": "auth expired"]], authMode: nil)
        precondition(failure.creditBalance == nil && failure.windows.isEmpty)

        // A failed read is flagged, an authoritative "no windows" answer is
        // not. The reader keys off the flag to decide between keeping the last
        // good reading on screen and clearing the row.
        precondition(failure.failed, "a JSON-RPC error must be marked as a failure")
        precondition(!creditOnly.failed, "an account with no windows answered; it did not fail")

        // Slot, not label, is the window identity: a payload that omits
        // `windowDurationMins` labels both windows 「额度」and they must still be
        // distinguishable — the whole reason the slot exists.
        let both: [String: Any] = [
            "primary": ["usedPercent": 95.0, "resetsAt": 1_900_000_000],
            "secondary": ["usedPercent": 10.0, "windowDurationMins": 10_080, "resetsAt": 1_900_000_000],
        ]
        let labelled = parse(both)
        precondition(labelled.windows.count == 2, "both windows must parse")
        precondition(labelled.windows[0].label == "额度" && labelled.windows[1].label == "7 天")
        precondition(labelled.windows[0].id == "primary" && labelled.windows[1].id == "secondary",
                     "identity must come from the slot, not the label")
        precondition(Set(labelled.windows.map(\.id)).count == 2, "the two windows must not collide")
        precondition(labelled.windows[0].durationMinutes == 0, "a missing duration stays 0 (unknown)")

        // Windows that arrived but could not be read (a malformed payload —
        // `usedPercent` missing entirely) must read as a failure, not as an
        // account without an allowance: the row would otherwise go blank and
        // the detector's per-window state would be wiped.
        let malformed = parse(["primary": ["resetsAt": 1_900_000_000],
                               "secondary": ["windowDurationMins": 10_080]])
        precondition(malformed.windows.isEmpty)
        precondition(malformed.failed, "windows that will not parse are a failed read")
        let noWindows = parse(["credits": ["balance": "3"]])
        precondition(noWindows.windows.isEmpty && !noWindows.failed,
                     "a payload with no window keys is an empty answer, not a failure")

        print("PASS: credits, zero, unknown, unlimited, invalid values, credit-only accounts, legacy payloads, "
              + "auth failures, failure flagging, slot identity, malformed windows")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='greeting-data-') as tmp:
    path = Path(tmp) / 'Probe.swift'
    path.write_text((root / 'Sources/Shared/BuildChannel.swift').read_text() + '\n' + fetcher + '\n' + runtime + '\n' + coerce + '\n' + probe)
    binary = Path(tmp) / 'probe'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
