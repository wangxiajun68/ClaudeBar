#!/usr/bin/env python3
"""Real store/callback lifecycle with controlled transports and deferred scrolls.
No account, network, application or real settings are touched.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--probe', action='store_true', help='Report baseline violations without asserting')
a = p.parse_args()
store = (root / 'Sources/ClaudeBar/Models/CursorUsageStore.swift').read_text()
traffic = (root / 'Sources/ClaudeBar/Views/Pages/TrafficView.swift').read_text()
start = traffic.index('        .onReceive(streams.$live) { values in')
opening = traffic.index('{', start)
depth, end = 1, opening + 1
while depth:
    depth += (traffic[end] == '{') - (traffic[end] == '}')
    end += 1
receive = traffic[opening + 1:end - 1].replace('values in\n', '', 1)
provider = (root / 'Sources/Widget/WidgetProvider.swift').read_text()
start = provider.index('    func getTimeline(')
opening = provider.index('{', start)
depth, end = 1, opening + 1
while depth:
    depth += (provider[end] == '{') - (provider[end] == '}')
    end += 1
timeline = provider[start:end]
swift = r'''
import Foundation
import Combine
enum AppPermission { case cursorData }
enum PermissionGate {
    static var enabled = true
    static func allows(_ permission: AppPermission) -> Bool { enabled }
}
enum AppConfig { static let cursorQuotaPollInterval: TimeInterval = 600 }
extension Notification.Name { static let permissionDidChange = Self("fixture.permission") }
@MainActor enum CursorUsageFetcher {
    typealias PlanUsage = String
    typealias GrokUsage = String
    struct Snapshot {
        var plan: String?; var grok: String?; var note: String?
        var isEmpty: Bool { plan == nil && grok == nil }
    }
    static var pending: [CheckedContinuation<Snapshot, Never>] = []
    static func lastKnown() -> Snapshot? { nil }
    static func invalidateCache() {}
    static func fetch() async -> Snapshot {
        // Cancellation cannot retroactively prevent a transport completion.
        await withCheckedContinuation { pending.append($0) }
    }
}
STORE
struct Context {}
struct WidgetEntry { static let placeholder = WidgetEntry() }
struct Timeline<Entry> {
    enum Policy { case after(Date) }
    let entries: [Entry]; let policy: Policy
}
struct TimelineFixture {
    func loadEntry() -> WidgetEntry? { nil }
    TIMELINE
}
struct CaptureLive: Equatable { let text: String }
struct Summary { let id: Int }
final class PageState { var mounted = true; var loadGen = 0 }
enum ScrollHoverGate {
    static var delayed: (() -> Void)?
    static func afterScroll(_ key: String, _ apply: @escaping () -> Void) { delayed = apply }
    static func flush() { let apply = delayed; delayed = nil; apply?() }
}
final class TrafficFixture {
    let state = PageState()
    var currentSummary: Summary? = Summary(id: 1)
    var selectedLive: CaptureLive?
    var rebuilds = 0
    func rebuildConversation() { rebuilds += 1 }
    func receive(_ values: [Int: CaptureLive]) {
        RECEIVE
    }
}
func require(_ ok: @autoclosure () -> Bool, _ message: String) {
    if !ok() {
        if PROBE { print("BASELINE VIOLATION:", message) }
        else { fatalError(message) }
    }
}
@main struct Regression {
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        fatalError("fixture did not settle")
    }
    @MainActor static func main() async {
        let started = Date()
        TimelineFixture().getTimeline(in: Context()) { timeline in
            require(timeline.entries.count == 1, "placeholder fallback lost")
            if case .after(let next) = timeline.policy {
                require((299...301).contains(next.timeIntervalSince(started)), "Widget fallback must request five-minute spacing")
            }
        }
        let store = CursorUsageStore.shared
        store.start(); store.refresh()
        await until { CursorUsageFetcher.pending.count == 1 }
        store.stop(); store.start(); store.refresh()
        await until { CursorUsageFetcher.pending.count == 2 }
        CursorUsageFetcher.pending[0].resume(returning: .init(plan: "obsolete", note: "old"))
        try? await Task.sleep(for: .milliseconds(25))
        require(store.plan == nil && store.loading, "cancelled old request republished / cleared loading")
        store.refresh()
        try? await Task.sleep(for: .milliseconds(25))
        require(CursorUsageFetcher.pending.count == 2, "obsolete defer cleared replacement handle and admitted overlapping fetch")
        CursorUsageFetcher.pending[1].resume(returning: .init(plan: "latest"))
        if CursorUsageFetcher.pending.count > 2 { CursorUsageFetcher.pending[2].resume(returning: .init(plan: "latest")) }
        await until { !store.loading }
        require(store.plan == "latest", "latest request did not publish")
        let before = CursorUsageFetcher.pending.count
        store.refresh(); await until { CursorUsageFetcher.pending.count == before + 1 }
        PermissionGate.enabled = false
        NotificationCenter.default.post(name: .permissionDidChange, object: AppPermission.cursorData)
        try? await Task.sleep(for: .milliseconds(20))
        require(store.plan == nil && !store.loading, "revocation missed when permission was initially allowed")
        CursorUsageFetcher.pending[before].resume(returning: .init(plan: "after-revocation"))
        try? await Task.sleep(for: .milliseconds(20))
        require(store.plan == nil && !store.loading, "revoked transport completion republished")
        PermissionGate.enabled = true
        NotificationCenter.default.post(name: .permissionDidChange, object: AppPermission.cursorData)
        if !PROBE {
            await until { CursorUsageFetcher.pending.count == before + 2 }
            CursorUsageFetcher.pending[before + 1].resume(returning: .init(plan: "regranted"))
            await until { store.plan == "regranted" }
        }
        store.stop()
        let fixture = TrafficFixture()
        fixture.receive([1: CaptureLive(text: "first")])
        fixture.state.mounted = false; fixture.state.loadGen += 1
        ScrollHoverGate.flush()
        require(fixture.rebuilds == 0 && fixture.selectedLive == nil, "deferred stream callback rebuilt a departed page")
        fixture.state.mounted = true
        fixture.receive([1: CaptureLive(text: "stale")])
        fixture.state.mounted = false; fixture.state.loadGen += 1; fixture.state.mounted = true
        ScrollHoverGate.flush()
        require(fixture.rebuilds == 0 && fixture.selectedLive == nil, "old deferred batch entered a remounted page")
        fixture.receive([1: CaptureLive(text: "fresh")]); ScrollHoverGate.flush()
        let expected = PROBE ? fixture.rebuilds : 1
        require(fixture.rebuilds == expected && fixture.selectedLive?.text == "fresh", "current live batch missing")
        fixture.receive([1: CaptureLive(text: "fresh")]); ScrollHoverGate.flush()
        require(fixture.rebuilds == expected, "identical live batch rebuilt")
        print(PROBE ? "PROBE: baseline lifecycle checks completed" : "PASS: cancelled request ownership, replacement overlap prevention, revocation/regrant, deferred traffic unmount/remount and unchanged batch")
    }
}
'''.replace('TIMELINE', timeline).replace('STORE', store).replace('RECEIVE', receive).replace('PROBE', str(a.probe).lower())
# Member lookup in an escaping callback needs explicit capture in this class
# fixture, unlike SwiftUI's value view; the production closure body is intact.
swift = swift.replace('ScrollHoverGate.afterScroll("TrafficView.live") {', 'ScrollHoverGate.afterScroll("TrafficView.live") { [self] in')
with tempfile.TemporaryDirectory(prefix='claudebar-lifecycle-') as folder:
    source = Path(folder) / 'Regression.swift'
    source.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
