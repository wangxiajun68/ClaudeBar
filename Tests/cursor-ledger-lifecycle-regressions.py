#!/usr/bin/env python3
"""`CursorLedgerStore`'s switch handling, driven with a stubbed transport.

The finding this suite exists for: `refresh` already cleared everything when
the 读取 Cursor 会话 switch said no, but **nothing called it when the switch
flipped** — the page's `.task(id: window)` only runs on appear — so the last
reading (and the money drawn from it) survived the switch indefinitely, the
warm-start cache kept it across relaunches, and an in-flight read republished
after revocation.

The store is sliced verbatim; only its edges are stubbed — the network reader
(a continuation the test resolves), the permission gate (a settable flag),
and `CursorLedger`'s pure math. No Cursor installation, no credentials, no
network, no app launch.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
store_source = (root / 'Sources/ClaudeBar/Utils/CursorLedgerStore.swift').read_text()

# The store class and its on-disk cache, verbatim. The slice stops at the
# reader marker: the transport is stubbed below, so nothing here can reach
# `state.vscdb` or cursor.com.
start = store_source.index('@MainActor\nfinal class CursorLedgerStore: ObservableObject {')
end = store_source.index('// MARK: - Reader')
store_class = store_source[start:end].rstrip() + '\n'
cache_start = store_source.index('private final class LedgerCache {')
ledger_cache = store_source[cache_start:].replace('private final class LedgerCache', 'final class LedgerCache', 1)

harness = r'''
import Foundation
import Combine

enum AppPermission { case cursorData }
enum PermissionGate {
    /// The warm-start run is a separate process, so the gate's answer for it
    /// rides in the environment rather than through a shared mutable.
    static var enabled = ProcessInfo.processInfo.environment["CLAUDEBAR_FIXTURE_PERMISSION"] != "off"
    static func allows(_ permission: AppPermission) -> Bool { enabled }
}
extension Notification.Name {
    static let permissionDidChange = Self("fixture.permission")
    static let cursorLedgerDidChange = Self("fixture.cursorLedger")
}
enum FilePaths {
    static let appSupportDir = URL(fileURLWithPath: CommandLine.arguments[1])
}

/// `CursorLedger`'s pure-render surface: `folded` and the window planner. The
/// store's own behaviour is what this file drives, so the parse is out of
/// scope and the network shapes live in `cursor-ledger-regressions.py`.
enum CursorLedger {
    struct Row: Equatable, Codable { var model: String }
    static func folded(_ rows: [Row]) -> [String: Row] {
        var out: [String: Row] = [:]
        for row in rows { out[row.model] = row }
        return out
    }
    static func plan(for window: DateInterval, billingCycle: DateInterval?) -> (window: DateInterval, truncated: Bool) {
        (window, false)
    }
}

func cursorLedgerShortDate(_ date: Date) -> String { "d" }

/// The transport, as a continuation the test resolves — the same shape
/// `remaining-lifecycle-regressions.py` uses for the allowance probe, and the
/// only way to drive "a cancelled read completes late" deterministically.
@MainActor enum CursorLedgerReader {
    static var pending: [CheckedContinuation<(folded: [String: CursorLedger.Row], raw: [CursorLedger.Row])?, Never>] = []
    static var plans: [DateInterval] = []
    static func read(plan: (window: DateInterval, truncated: Bool))
        async -> (folded: [String: CursorLedger.Row], raw: [CursorLedger.Row])? {
        plans.append(plan.window)
        return await withCheckedContinuation { pending.append($0) }
    }
}

STORE_CLASS

LEDGER_CACHE

func require(_ ok: @autoclosure () -> Bool, _ message: String) {
    guard ok() else { fatalError(message) }
}

@main struct Regression {
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        fatalError("fixture did not settle")
    }

    @MainActor static func main() async {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "lifecycle"

        // The warm start is gated on the switch — the persisted reading is
        // Cursor's own bill, and with the switch off it must not be drawn even
        // for the frame before the first `refresh`. Driven in its own process
        // because the store is a singleton: a seeded cache file and the gate
        // answer are the whole input.
        if mode == "warm" {
            let lit = PermissionGate.enabled
            let store = CursorLedgerStore.shared
            require(store.rows.isEmpty == !lit,
                    "a seeded warm start must load only when the switch allows it")
            print(lit ? "PASS: warm start loads the seeded reading with the switch on"
                      : "PASS: warm start ignores the seeded reading with the switch off")
            return
        }

        let cacheFile = dir.appendingPathComponent("cursor-ledger.json")
        let store = CursorLedgerStore.shared
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let window = DateInterval(start: start, end: start + 86_400)
        let other = DateInterval(start: start + 86_400, end: start + 172_800)

        // --- A read lands and is persisted ---------------------------------
        PermissionGate.enabled = true
        store.refresh(window: window)
        await until { CursorLedgerReader.pending.count == 1 }
        require(CursorLedgerReader.plans == [window], "the store must ask for the page's window")
        var changed = 0
        let token = NotificationCenter.default.addObserver(forName: .cursorLedgerDidChange, object: nil, queue: .main) { _ in changed += 1 }
        CursorLedgerReader.pending[0].resume(returning: (folded: ["m": CursorLedger.Row(model: "m")],
                                                           raw: [CursorLedger.Row(model: "m")]))
        await until { store.rows["m"] != nil }
        require(store.window == window && store.fetchedAt != nil && !store.loading,
                "a landed read populates rows/window/fetchedAt")
        require(FileManager.default.fileExists(atPath: cacheFile.path), "a landed read is persisted for the warm start")
        require(changed == 1, "a landed read announces itself")

        // --- Revocation clears the live reading, the file, and any in-flight
        // completion --------------------------------------------------------
        store.refresh(window: other)                     // an in-flight read…
        await until { CursorLedgerReader.pending.count == 2 }
        PermissionGate.enabled = false
        NotificationCenter.default.post(name: .permissionDidChange, object: AppPermission.cursorData)
        await until { store.rows.isEmpty }
        require(store.window == nil && store.fetchedAt == nil && store.note == nil && !store.loading,
                "revocation clears the whole reading")
        require(!FileManager.default.fileExists(atPath: cacheFile.path),
                "revocation deletes the warm-start file — the switch promises Cursor's data is not kept")
        CursorLedgerReader.pending[1].resume(returning: (folded: ["late": CursorLedger.Row(model: "late")],
                                                           raw: [CursorLedger.Row(model: "late")]))
        try? await Task.sleep(for: .milliseconds(30))
        require(store.rows.isEmpty && store.window == nil,
                "a read that completes after revocation must not republish")

        // --- A request made while off is remembered, not read --------------
        let beforeOff = CursorLedgerReader.plans.count
        store.refresh(window: other)
        try? await Task.sleep(for: .milliseconds(20))
        require(CursorLedgerReader.plans.count == beforeOff, "a request while the switch is off must not read")

        // --- Regrant re-reads the last requested window --------------------
        PermissionGate.enabled = true
        NotificationCenter.default.post(name: .permissionDidChange, object: AppPermission.cursorData)
        await until { CursorLedgerReader.pending.count == 3 }
        require(CursorLedgerReader.plans.last == other,
                "regrant re-reads the window the page last asked for, not the one that had landed")
        CursorLedgerReader.pending[2].resume(returning: (folded: ["again": CursorLedger.Row(model: "again")],
                                                           raw: [CursorLedger.Row(model: "again")]))
        await until { store.rows["again"] != nil }
        require(store.window == other, "the regranted reading replaces the window")

        // --- The cooldown and freshness rules still hold after a revoke ----
        // (A revoke resets `lastProbe`; the next read is admitted rather than
        // blocked by the throttle that belonged to the previous session.)
        PermissionGate.enabled = false
        NotificationCenter.default.post(name: .permissionDidChange, object: AppPermission.cursorData)
        await until { store.rows.isEmpty }
        PermissionGate.enabled = true
        NotificationCenter.default.post(name: .permissionDidChange, object: AppPermission.cursorData)
        await until { CursorLedgerReader.pending.count == 4 }
        CursorLedgerReader.pending[3].resume(returning: (folded: ["fresh": CursorLedger.Row(model: "fresh")],
                                                           raw: [CursorLedger.Row(model: "fresh")]))
        await until { store.rows["fresh"] != nil }
        require(store.window == other, "a revoke→regrant cycle re-reads the last window again")
        NotificationCenter.default.removeObserver(token)

        print("PASS: Cursor ledger revocation clears the reading and its file, a late completion cannot republish, and a regrant re-reads the last requested window")
    }
}
'''

swift = (harness
         .replace('STORE_CLASS', store_class.rstrip())
         .replace('LEDGER_CACHE', ledger_cache.rstrip()))

seed = r'''{"rows":[{"model":"seeded"}],"windowStart":"2023-11-14T22:13:20Z",
"windowEnd":"2023-11-15T22:13:20Z","truncated":false,"at":"2023-11-14T22:13:20Z"}'''

with tempfile.TemporaryDirectory(prefix='claudebar-ledger-lifecycle-') as folder:
    source = Path(folder) / 'Regression.swift'
    source.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                    str(source), '-o', str(binary)], check=True)
    storage = Path(folder) / 'storage'
    storage.mkdir()
    subprocess.run([str(binary), str(storage)], check=True)

    # Warm start, both gate answers, each in its own process (the store is a
    # singleton and reads its cache exactly once).
    for allowed in (True, False):
        warm = Path(folder) / ('warm-' + ('on' if allowed else 'off'))
        warm.mkdir()
        (warm / 'cursor-ledger.json').write_text(seed)
        env = {**__import__('os').environ,
               'CLAUDEBAR_FIXTURE_PERMISSION': 'on' if allowed else 'off'}
        subprocess.run([str(binary), str(warm), 'warm'], check=True, env=env)
