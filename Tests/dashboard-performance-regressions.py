#!/usr/bin/env python3
"""Execute dashboard row derivation on synthetic mixed-source session lists."""
from pathlib import Path
import argparse
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--baseline-ref')
a = p.parse_args()
path = 'Sources/ClaudeBar/Views/Pages/DashboardView.swift'
source = ((root / path).read_text() if not a.baseline_ref else
          subprocess.check_output(['git', 'show', f'{a.baseline_ref}:{path}'], cwd=root, text=True))


def declaration(marker):
    start = source.index(marker)
    opening = source.index('{', start)
    level, end = 1, opening + 1
    while level:
        level += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private var', 'var')


fixture = r'''
import SwiftUI
import Foundation
enum Counter { static var formatted = 0 }
enum PillMark { case claude, cursor, codex }
enum Theme {
    static let claude = Color.orange, cursor = Color.blue, external = Color.green
    enum Ink { static let claude = Color.orange, cursor = Color.blue, success = Color.green }
}
enum ProcessSampler {
    enum Key: Equatable { case pid(Int), cursor, standardizedCwd(String) }
}
enum Kind: String { case codex, other; var displayName: String { rawValue } }
struct Session {
    let pid: Int
    var isAlive = true
    var isBusy = true
    var isWaiting = false
    var waitingReason = ""
    var contextRatio = 0.4
    var contextLabel = "40%"
    var relativeUpdated = "刚刚"
    var composerId: String { String(pid) }
    var sessionId: String { String(pid) }
    var kind = Kind.codex
    var isActive: Bool { isBusy }
    var displayTitle: String {
        Counter.formatted += 1
        return SessionTitle.condense("深度审查天气卡片并优化每一个布局节点 \(pid) /tmp/project")
    }
    var displayName: String { displayTitle }
    var displayActivity = "处理中"
    var currentActivity = "生成中"
    var model = "fixture-model"
    var cwd = "/fixture"
}
struct ProviderStore {
    var sessions: [Session] = []
    var cursorSessions: [Session] = []
    var externalSessions: [Session] = []
    var aliveSessions: [Session] { sessions.filter(\.isAlive) }
    var aliveExternalSessions: [Session] { externalSessions.filter(\.isAlive) }
}
struct DashboardFixture {
    var providerStore = ProviderStore()
    static let overviewCap = 6
    var aliveCount: Int { providerStore.aliveSessions.count }
    ROW
    ROWS
    TOTAL
}
@main struct Regression {
    static func main() {
        var cases = 0
        for cc in [0, 2, 6, 20] { for cursor in [0, 3, 20] { for external in [0, 4, 20] {
            var f = DashboardFixture()
            f.providerStore.sessions = (0..<cc).map { Session(pid: $0) }
            f.providerStore.sessions.insert(Session(pid: -1, isAlive: false), at: 0)
            f.providerStore.cursorSessions = (0..<cursor).map { Session(pid: $0 + 100) }
            f.providerStore.externalSessions = (0..<external).map { Session(pid: $0 + 200) }
            f.providerStore.externalSessions.append(Session(pid: -2, isAlive: false))
            let expected = (f.providerStore.sessions.filter(\.isAlive).map { "c-\($0.pid)" }
                            + f.providerStore.cursorSessions.map { "u-\($0.composerId)" }
                            + f.providerStore.aliveExternalSessions.map { "e-\($0.kind.rawValue)-\($0.sessionId)" }).prefix(6)
            Counter.formatted = 0
            let rows = f.overviewRows
            precondition(Array(rows.prefix(6)).map(\.id) == Array(expected), "Source priority and visible rows must stay identical")
            precondition(f.totalSessionCount == cc + cursor + external, "Overflow count must include every live session")
            if !BASELINE { precondition(rows.count <= 6 && Counter.formatted == rows.count, "Never format a hidden overview row") }
            for row in rows.prefix(6) {
                precondition(row.contextRatio == 0.4 && row.contextLabel == "40%" && row.updated == "刚刚")
                precondition(row.busy && !row.waiting)
            }
            cases += 1
        } } }
        var f = DashboardFixture()
        f.providerStore.sessions = [Session(pid: 1, isBusy: false, isWaiting: true, waitingReason: "确认权限")]
        f.providerStore.cursorSessions = [Session(pid: 2, isBusy: false, isWaiting: true)]
        f.providerStore.externalSessions = [Session(pid: 3, isBusy: false, kind: .other)]
        let rows = f.overviewRows
        precondition(rows.map(\.activity) == ["确认权限", "等待你确认计划", "fixture-model"])
        precondition(rows.map(\.load) == [.pid(1), .cursor, .standardizedCwd("/fixture")])
        precondition(rows.map(\.loadShared) == [false, true, false])
        f.providerStore.sessions = (0..<10_000).map { Session(pid: $0) }
        f.providerStore.cursorSessions = []; f.providerStore.externalSessions = []
        Counter.formatted = 0
        var elapsed: [Double] = []
        var sink = 0
        for _ in 0..<20 {
            let start = CFAbsoluteTimeGetCurrent()
            let rows = f.overviewRows
            sink += rows.reduce(0) { $0 + $1.project.utf8.count }
            elapsed.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        precondition(sink > 0)
        print("DASHBOARD_10000_MEDIAN_MS", elapsed.sorted()[10], "FORMATTED_PER_PASS", Counter.formatted / 20)
        print("PASS dashboard source ordering, full counts and bounded row formatting:", cases, "mixed cases")
    }
}
'''
fixture = fixture.replace('ROW', declaration('    struct OverviewRow: Identifiable {'), 1)
fixture = fixture.replace('ROWS', declaration('    private var overviewRows:'))
fixture = fixture.replace('TOTAL', declaration('    private var totalSessionCount:'))
fixture = fixture.replace('BASELINE', 'true' if a.baseline_ref else 'false')
with tempfile.TemporaryDirectory(prefix='claudebar-dashboard-') as temporary:
    out = Path(temporary)
    swift = out / 'Dashboard.swift'
    swift.write_text((root / 'Sources/ClaudeBar/Utils/SessionTitle.swift').read_text() + fixture)
    binary = out / 'dashboard'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
