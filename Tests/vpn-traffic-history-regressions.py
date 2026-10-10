#!/usr/bin/env python3
"""Exercise the production history sampler, periods and private archive in tmp dirs."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
history = (root / 'Sources/ClaudeBar/Utils/VpnTrafficHistory.swift').read_text()
history = history[:history.index('@MainActor\nfinal class VpnTrafficHistory')].replace('import Combine', '')
log = (root / 'Sources/ClaudeBar/Utils/VpnDomainLog.swift').read_text()
models = log[log.index('enum VpnDomainRoute:'):log.index('/// Ring of recent mihomo connections')]
manager = (root / 'Sources/ClaudeBar/Utils/VpnManager.swift').read_text()
format_source = manager[manager.index('enum VpnFormat {'):manager.index("/// The core's log ring.")]
writer = (root / 'Sources/ClaudeBar/Utils/PrivateFileWriter.swift').read_text()
assert 'VpnTrafficHistory.shared.beginCoreSession()' in manager
assert 'await VpnTrafficHistory.shared.record(prepared, root: hasRootTotals' in manager
section = (root / 'Sources/ClaudeBar/Views/Pages/VpnDomainLogSection.swift').read_text()
assert 'case detail, summary, connections, analytics' in section
assert 'VpnTrafficAnalyticsView(isVisible: isVisible)' in section
assert 'VpnRouteTrafficSummary(' not in section
assert 'trafficCell(' not in section
assert '流量历史和磁盘上的 core.log 不受影响' in section

swift = models + format_source + writer + history + r'''
func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
func connection(_ id: String, _ route: VpnDomainRoute, _ up: Int64, _ down: Int64, host: String = "example.com") -> VpnDomainConnection {
    .init(id: id, endpoint: host + ":443", process: "fixture", route: route, rule: "Domain", outbound: "fixture", upload: up, download: down)
}
@main struct Regression {
    static func main() async throws {
        NSTimeZone.default = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15))!
        var sampler = VpnTrafficHistorySampler()
        let first = [connection("p", .proxied, 10, 20), connection("d", .direct, 5, 15), connection("r", .reject, 99, 99)]
        let a = sampler.sample(first + [first[0]], root: .init(upload: 20, download: 50))
        check(a.traffic.core.total == 70 && a.traffic.proxied.total == 30 && a.traffic.direct.total == 20, "root total and route samples remain separate")
        check(a.traffic.unclassified.total == 20 && a.hosts["example.com"]?.direct.total == 20, "unclassified gap and per-host routes")
        check(sampler.sample(first, root: .init(upload: 20, download: 50)).traffic == .init(), "identical polls never duplicate bytes")
        let regressed = [connection("p", .proxied, 2, 3), connection("d", .direct, 1, 2)]
        check(sampler.sample(regressed, root: .init(upload: 1, download: 2)).traffic == .init(), "regression retains monotonic baselines")
        let increased = [connection("p", .proxied, 15, 30), connection("d", .direct, 8, 17)]
        let b = sampler.sample(increased, root: .init(upload: 30, download: 70))
        check(b.traffic.proxied.total == 15 && b.traffic.direct.total == 5 && b.traffic.core.total == 30, "high-water delta survives regressed counters")
        let closed = sampler.sample([], root: .init(upload: 40, download: 100))
        check(closed.traffic.core.total == 40 && closed.traffic.proxied.total == 0, "closed short connections still contribute root totals")
        sampler.beginCoreSession()
        check(sampler.sample([first[0]], root: .init(upload: 10, download: 20)).traffic.core.total == 30, "new core session resets baseline without clearing history")
        var fallback = VpnTrafficHistorySampler()
        check(fallback.sample(first, root: nil).traffic.core.total == 50, "old-core fallback samples both routes")
        check(fallback.sample(first, root: .init(upload: 20, download: 50)).traffic.core.total == 20, "root becoming available does not duplicate sampled bytes")
        check(fallback.sample(increased, root: nil).traffic.core.total == 0, "missing root after root availability avoids double counting")
        check(fallback.sample(increased, root: .init(upload: 30, download: 70)).traffic.core.total == 30, "next root catches up once")

        var ledger = VpnTrafficLedger()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        ledger.record(a.traffic, hosts: a.hosts, at: yesterday)
        ledger.record(b.traffic, hosts: b.hosts, at: today)
        let recent = ledger.report(period: .today, now: today, calendar: calendar)
        check(recent.totals.core.total == 30 && recent.lifetime.core.total == 100, "today and lifetime boundaries")
        check(recent.domains.first?.total == 20, "today domain ranking follows the same period")
        check(recent.proxyRanking.first?.traffic.proxied.total == 15 && recent.directRanking.first?.traffic.direct.total == 5, "route rankings preserve separate byte measures")
        check(recent.activity.count == 24 && recent.activity.reduce(Int64(0)) { $0 + $1.bytes } == 30, "hourly activity conserves today's total")
        let week = ledger.report(period: .week, now: today, calendar: calendar)
        check(week.points.count == 7 && week.totals.core.total == 100, "week includes zero days without changing totals")
        check(week.domains.first?.total == 70, "same host accumulates both routes across days")
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11))!
        var boundary = VpnTrafficLedger()
        boundary.record(a.traffic, hosts: a.hosts, at: midnight.addingTimeInterval(-1))
        boundary.record(b.traffic, hosts: b.hosts, at: midnight)
        check(boundary.report(period: .today, now: today, calendar: calendar).totals.core.total == 30, "local midnight keeps prior-day bytes out")
        var long = VpnTrafficLedger()
        let old = calendar.date(byAdding: .day, value: -120, to: today)!
        // More historical domains than the entire diagnostic ring capacity.
        let hosts = Dictionary(uniqueKeysWithValues: (0..<3001).map { ("host\($0).example", a.traffic) })
        long.record(a.traffic, hosts: hosts, at: old)
        long.record(b.traffic, hosts: b.hosts, at: today)
        let all = long.report(period: .all, now: today, calendar: calendar)
        check(all.totals.core.total == 100 && all.domains.count == 3002 && all.points.count <= 6, "all history survives ring size and monthly chart aggregation")
        check(long.hours.count == 1 && long.days.count == 2, "hour retention never evicts daily totals")
        check(long.report(period: .month, now: today, calendar: calendar).totals.core.total == 30, "30-day total excludes old bytes")

        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let url = base.appendingPathComponent("traffic-history")
        let archive = VpnTrafficHistoryArchive(url: url)
        _ = try await archive.record(first, root: .init(upload: 20, download: 50), at: today)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(VpnTrafficLedger.dayKey(today) + ".json").path)[.posixPermissions] as! NSNumber
        check(permissions.intValue & 0o777 == 0o600, "archive is private")
        let dayFile = url.appendingPathComponent(VpnTrafficLedger.dayKey(today) + ".json")
        let fixedModification = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedModification], ofItemAtPath: dayFile.path)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: today)!
        _ = try await archive.record(first, root: .init(upload: 21, download: 51), at: nextDay)
        check(try FileManager.default.attributesOfItem(atPath: dayFile.path)[.modificationDate] as? Date == fixedModification, "new-day writes never rewrite old archive files")
        let restored = VpnTrafficHistoryArchive(url: url)
        check(try await restored.report(period: .all, now: nextDay).totals.core.total == 72, "archive restores lifetime and domain aggregates")
        await archive.beginCoreSession()
        _ = try await archive.record(first, root: .init(upload: 20, download: 50), at: today)
        check(try await archive.report(period: .all, now: nextDay).totals.core.total == 142, "restart adds a fresh session without resetting lifetime")
        try await archive.clear()
        _ = try await archive.record(first, root: .init(upload: 20, download: 50), at: today)
        check(try await archive.report(period: .all, now: today).totals.core.total == 0, "explicit clear retains live baselines")
        _ = try await archive.record(increased, root: .init(upload: 30, download: 70), at: today)
        check(try await archive.report(period: .all, now: today).totals.core.total == 30, "only new bytes follow a clear")

        let corruptURL = base.appendingPathComponent("corrupt.json")
        let bad = Data("{not json}".utf8)
        try bad.write(to: corruptURL)
        let corrupt = VpnTrafficHistoryArchive(url: corruptURL)
        do { _ = try await corrupt.record(first, root: nil, at: today); fatalError("corruption must fail") } catch { }
        check(try Data(contentsOf: corruptURL) == bad, "damaged file is not overwritten")
        do { _ = try await corrupt.report(period: .all, now: today); fatalError("read must report corruption") } catch { }
        try await corrupt.clear()
        check(try await corrupt.report(period: .all, now: today).startedAt == nil, "explicit recovery after corruption")

        let blockedParent = base.appendingPathComponent("blocked")
        try Data("blocked".utf8).write(to: blockedParent)
        let retry = VpnTrafficHistoryArchive(url: blockedParent.appendingPathComponent("history.json"))
        do { _ = try await retry.record(first, root: .init(upload: 20, download: 50), at: today); fatalError("write must fail") } catch { }
        try FileManager.default.removeItem(at: blockedParent)
        _ = try await retry.record(first, root: .init(upload: 20, download: 50), at: today)
        check(try await retry.report(period: .all, now: today).totals.core.total == 70, "failed atomic write retries retained bytes even on an idle poll")
        print("PASS: total/root sampling, route/domain deltas, reset, local periods, >2,000 domains, retention, restore, private archive, corruption and failed-write recovery")
    }
}
'''
with tempfile.TemporaryDirectory() as tmp:
    directory = Path(tmp)
    source = directory / 'history.swift'
    source.write_text(swift)
    binary = directory / 'history'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary), tmp], check=True)
