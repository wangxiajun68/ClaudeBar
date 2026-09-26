#!/usr/bin/env python3
"""End-to-end wiring for the Codex swarm tree, against the *live* `~/.codex`.

`Tests/codex-session-regressions.py` proves the monitor's classification with a
synthetic index. This one proves the wiring on the other side of it — that what
the monitor returns is what the tree and the counters expect — and it is the
check that would have caught backlog §2 the day it was introduced, because it
compares the number of helpers returned against the number the tree actually
attaches.

Two modes:

  * default — structural assertions only, using a synthetic store. Safe to run
    anywhere, including CI with no `~/.codex` at all.
  * `CLAUDEBAR_E2E_REAL_INDEX=1` — additionally runs the monitor against the
    real index and asserts the live numbers (main threads exist, no helper is
    classified as main, every returned helper's parent is in the same scan).

Compiles the whole app target except `ClaudeBarApp.swift` (only that file has
its own `@main`), so this is a slow script by the standards of the others —
~2 minutes of `swiftc -O` — and is therefore *not* in `make test`.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source_dir = root / 'Sources/ClaudeBar'

harness = r'''
import AppKit

@main struct E2E {
    @MainActor static func main() {
        // Synthetic half: the tree's own contract, independent of any machine.
        let store = ProviderStore()
        func row(_ id: String, parent: String?, active: Bool, updated: Double, sub: Bool) -> ExternalSessionInfo {
            ExternalSessionInfo(kind: .codex, sessionId: id, cwd: "/tmp/p", startedAt: updated,
                                updatedAt: updated, model: "gpt-6", isAlive: true, isActive: active,
                                completionID: nil, contextTokens: 10, contextLimit: 100,
                                parentThreadId: parent, threadSource: sub ? "subagent" : "user",
                                agentNickname: sub ? "explore" : "", spawnDepth: sub ? 1 : 0,
                                holderPID: nil, inDesktop: false)
        }
        let now = Date().timeIntervalSince1970 * 1000
        store.externalSessions = [
            row("parent", parent: nil, active: true, updated: now, sub: false),
            row("kid-a", parent: "parent", active: true, updated: now, sub: true),
            row("kid-b", parent: "parent", active: true, updated: now - 2_000, sub: true),
            row("idle-main", parent: nil, active: false, updated: now - 9_000, sub: false),
        ]
        let tree = store.externalSessionTree(kind: .codex)
        precondition(tree.map(\.session.sessionId).sorted() == ["idle-main", "parent"],
                     "a helper must never be a root: \(tree.map(\.session.sessionId))")
        let parent = tree.first { $0.session.sessionId == "parent" }!
        precondition(parent.children.map(\.session.sessionId) == ["kid-a", "kid-b"],
                     "helpers attach to their parent, newest first")
        precondition(parent.descendantCount == 2 && parent.activeDescendantCount == 2)
        precondition(store.aliveExternalSessions.map(\.sessionId).sorted() == ["idle-main", "parent"],
                     "the session list is threads, not helpers")
        precondition(store.activeExternalCount == 1,
                     "the busy pill must be a subset of the thread population")

        guard ProcessInfo.processInfo.environment["CLAUDEBAR_E2E_REAL_INDEX"] == "1" else {
            print("PASS: synthetic tree wiring; live index skipped (set CLAUDEBAR_E2E_REAL_INDEX=1)")
            return
        }

        // Live half: the monitor against this machine's own index.
        let scan = ExternalSessionMonitor.scan()
        let mainIDs = Set(scan.main.map(\.sessionId))
        let orphaned = scan.subagents.filter { s in
            guard let p = s.parentThreadId else { return true }
            return !mainIDs.contains(p)
        }
        print("live index: main=\(scan.main.count) subagents=\(scan.subagents.count) orphaned=\(orphaned.count)")
        precondition(!scan.main.contains { $0.isSubagent }, "no helper may be classified as main")
        precondition(orphaned.isEmpty,
                     "every returned helper's parent must be in the same scan, or the tree drops it silently")
        let live = ProviderStore()
        live.externalSessions = scan.main + scan.subagents
        let liveTree = live.externalSessionTree(kind: .codex)
        precondition(liveTree.count == scan.main.count, "every main thread is a root")
        precondition(liveTree.reduce(0) { $0 + $1.descendantCount } == scan.subagents.count,
                     "every returned helper is attached under some root")
        print("PASS: synthetic tree wiring + live index → scan → store → tree")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-e2e-') as folder:
    main = Path(folder) / 'Main.swift'
    main.write_text(harness)
    binary = Path(folder) / 'e2e'
    sources = sorted(p for p in source_dir.rglob('*.swift') if p.name != 'ClaudeBarApp.swift')
    sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                         capture_output=True, text=True, check=True).stdout.strip()
    subprocess.run([
        'swiftc', '-O', '-whole-module-optimization', '-parse-as-library',
        '-o', str(binary), '-sdk', sdk, '-target', 'arm64-apple-macos15.0',
        '-framework', 'Metal', '-framework', 'SwiftUI', '-framework', 'AppKit',
        '-framework', 'WidgetKit', '-framework', 'CryptoKit', '-framework', 'CoreServices',
        '-framework', 'IOKit', '-framework', 'Carbon', '-framework', 'ScreenCaptureKit',
        '-framework', 'CoreLocation', '-framework', 'CoreWLAN', '-framework', 'IOBluetooth',
        '-framework', 'ServiceManagement', '-lsqlite3',
        '-Xlinker', '-rpath', '-Xlinker', '/usr/lib/swift',
        *[str(p) for p in sources], str(main),
    ], check=True)
    subprocess.run([str(binary)], check=True, env=os.environ)
