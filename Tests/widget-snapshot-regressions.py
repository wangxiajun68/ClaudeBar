#!/usr/bin/env python3
"""The widget snapshot must keep decoding payloads written by older builds.

`WidgetSnapshot` is the one contract between the app and its widget extension,
and the two sides are updated at different moments: after an app update the
WidgetKit process reads whatever snapshot the *previous* build left in the App
Group container and the `UserDefaults` suite. A field that was added
non-optional therefore does not fail loudly — `JSONDecoder` throws
`keyNotFound`, `WidgetProvider.loadEntry()` returns nil, and the widget shows
its empty state until the host app happens to write a fresh payload.

That is exactly what `externalSessions` did (added in 7fb70c8, non-optional,
next to three siblings that were made optional for this very reason). This
suite compiles the production model — the file the widget target symlinks,
read through `Sources/ClaudeBar/Models/` — and decodes the literal payload an
older build wrote: the JSON below was produced by `JSONEncoder` from the
pre-7fb70c8 `WidgetSnapshot`, so it carries every key that build emitted and
nothing else. The default that comes back (`[]`) is the older snapshot's
honest reading: it had no Codex sessions to carry.

It also pins the encoder side and the round trip, so a future edit that stops
emitting the key, or that reads a present-but-null key differently, fails here
rather than in a screenshot after the next update.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
# Deliberately the real file, not the widget symlink: the symlink target is
# what `Tools/doctor.sh` verifies, and this suite reads the same source.
snapshot_source = (root / 'Sources/ClaudeBar/Models/WidgetSnapshot.swift').read_text()

harness = '''
import Foundation

func check(_ value: Bool, _ message: String) {
    if !value { print("FAIL: \\(message)"); exit(1) }
}

@main struct Probe {
static func main() {
do {
    // What a build without `externalSessions` wrote (commit 7fb70c8's parent,
    // `JSONEncoder` output): no externalSessions, no usagePeriodLabel, no
    // unitStyle, no isDark, no waiting, no currentActivity-on-external.
    let older = Data(#"""
    {"sessions":[{"contextTokens":84000,"status":"busy","currentActivity":"Bash",
      "contextRatio":0.42,"contextLimit":200000,"projectFolder":"demo-project",
      "model":"claude-opus-5-5","pid":4711}],
     "modelBreakdown":[{"model":"claude-opus-5-5","totalTokens":940000}],
     "totalSessionCount":2,"activeModelName":"claude-opus-5-5","balanceText":"¥12.50",
     "busySessionCount":1,
     "cursorSessions":[{"status":"active","contextRatio":0.31,"projectFolder":"demo-project",
       "relativeUpdated":"2m","contextPercent":31,"composerId":"3f9c0d1e","currentActivity":"Edit"}],
     "todayTotalTokens":1240000,"updatedAt":-193307200,"activeProviderName":"Anthropic"}
    """#.utf8)
    let old = try JSONDecoder().decode(WidgetSnapshot.self, from: older)
    check(old.externalSessions.isEmpty,
          "an older payload carries no external sessions; got \\(old.externalSessions.count)")
    check(old.todayTotalTokens == 1_240_000 && old.sessions.count == 1 && old.cursorSessions.count == 1,
          "the rest of the older payload must still decode")
    check(old.usagePeriodLabel == nil && old.unitStyle == nil && old.isDark == nil,
          "fields the older payload never wrote stay nil")
    check(old.sessions[0].waiting == nil && old.cursorSessions[0].waiting == nil,
          "the waiting flags of the older payload stay nil")

    // The same payload with only the newest key present (what a build between
    // 7fb70c8 and now could have written) decodes with the optionals nil.
    let withExternal = Data(#"""
    {"sessions":[],"modelBreakdown":[],"totalSessionCount":0,"activeModelName":"",
     "activeProviderName":"","busySessionCount":0,"cursorSessions":[],
     "todayTotalTokens":0,"updatedAt":-193307200,
     "externalSessions":[{"id":"codex-1","status":"idle","model":"gpt-5.6-codex",
       "contextTokens":100,"contextLimit":200,"contextRatio":0.5,"projectFolder":"p",
       "relativeUpdated":"5m"}]}
    """#.utf8)
    let middle = try JSONDecoder().decode(WidgetSnapshot.self, from: withExternal)
    check(middle.externalSessions.count == 1 && middle.externalSessions[0].currentActivity == nil
          && middle.externalSessions[0].waiting == nil,
          "an external row without the optional fields decodes with them nil")

    // A current payload round-trips through the synthesized encoder, key by
    // key: if the hand-written decoder and the synthesized encoder ever
    // disagree about a key, this is where it shows.
    let current = WidgetSnapshot(
        todayTotalTokens: 7, usagePeriodLabel: "今天", unitStyle: "chinese", isDark: true,
        modelBreakdown: [WidgetSnapshot.ModelTokenUsage(model: "claude-opus-5-5", totalTokens: 7)],
        activeProviderName: "Anthropic", activeModelName: "claude-opus-5-5", balanceText: nil,
        totalSessionCount: 1, busySessionCount: 0,
        sessions: [WidgetSnapshot.SessionSummary(pid: 1, status: "waiting", model: "m",
            contextTokens: 1, contextLimit: 2, contextRatio: 0.5, projectFolder: "p",
            currentActivity: "Bash", waiting: true)],
        cursorSessions: [WidgetSnapshot.CursorSessionSummary(composerId: "c", status: "active",
            contextRatio: 0.5, contextPercent: 50, projectFolder: "p", currentActivity: "Edit",
            relativeUpdated: "1m", waiting: false)],
        externalSessions: [WidgetSnapshot.ExternalSessionSummary(id: "codex-1", status: "busy",
            model: "gpt-5.6-codex", contextTokens: 1, contextLimit: 2, contextRatio: 0.5,
            projectFolder: "p", relativeUpdated: "1m", currentActivity: "exec", waiting: false)],
        updatedAt: Date(timeIntervalSince1970: 785_000_000))
    let encoded = try JSONEncoder().encode(current)
    let encodedText = String(data: encoded, encoding: .utf8) ?? ""
    check(encodedText.contains("externalSessions"),
          "the encoder must still emit externalSessions")
    let round = try JSONDecoder().decode(WidgetSnapshot.self, from: encoded)
    check(round.externalSessions.count == 1 && round.externalSessions[0].waiting == false
          && round.usagePeriodLabel == "今天" && round.unitStyle == "chinese" && round.isDark == true
          && round.sessions[0].waiting == true && round.cursorSessions[0].waiting == false,
          "a current snapshot must survive the encode/decode round trip unchanged")
    check(round.updatedAt == current.updatedAt && round.balanceText == nil,
          "the timestamp and a nil balance must round-trip")

    print("PASS: the older payload decodes with empty external sessions, the optionals stay nil, "
          + "and the current shape round-trips through the shipped encoder")
} catch {
    print("FAIL: decoding a snapshot written by an older build threw: \\(error)")
    exit(1)
}
}
}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-widget-snapshot-') as folder:
    folder = Path(folder)
    source = folder / 'Main.swift'
    source.write_text(snapshot_source + '\n' + harness)
    binary = folder / 'widget-snapshot'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
