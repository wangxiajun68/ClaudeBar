#!/usr/bin/env python3
"""Render production VPN rules and flow views with synthetic, isolated data."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / '.build/vpn-preview'
out.mkdir(parents=True, exist_ok=True)
# Share the existing control preview's production theme/control assembly.
assembly = (root / 'Tools/render-control-preview.py').read_text()
namespace = {'__file__': str(root / 'Tools/render-control-preview.py')}
exec(assembly[:assembly.index("source += '''\n@main struct Probe")], namespace)
source = namespace['source']
declaration = namespace['declaration']
source += '\nimport Combine\n'
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'struct HairlineDivider: View {')
source += (root / 'Sources/ClaudeBar/Views/Shared/InstrumentSearchField.swift').read_text()
source += declaration('Sources/ClaudeBar/Utils/VpnManager.swift', 'enum VpnFormat {')
log = (root / 'Sources/ClaudeBar/Utils/VpnDomainLog.swift').read_text()
source += log[log.index('enum VpnDomainRoute:'):log.index('/// Ring of recent mihomo connections')]
source += log[log.index('enum VpnWatchlist {'):]
stat_start = log.index('nonisolated static func stat(')
stat = log[stat_start:log.index('// MARK: - Flush', stat_start)]
source += r'''
@MainActor final class VpnManager: ObservableObject {
    static let shared = VpnManager()
    enum State: Equatable { case idle, running }
    @Published var state = State.running
    var isRunning: Bool { state == .running }
    func reloadConfig() { fatalError("Preview must never reload a VPN") }
}
@MainActor final class VpnDomainLog: ObservableObject {
    static let shared = VpnDomainLog()
    static let limit = 2000
    @Published var connections: [VpnDomainConnection] = []
    @Published var connectionRevision = 0
    @Published var revision = 0
    @Published var proxiedTraffic = VpnDomainTraffic(upload: 350_000, download: 12_600_000)
    @Published var directTraffic = VpnDomainTraffic(upload: 190_000, download: 7_100_000)
    var trafficByHost: [String: VpnDomainTraffic] = [:]
    var directTrafficByHost: [String: VpnDomainTraffic] = [:]
    var entries: [VpnDomainEntry] = []
    var received = 0
    func clear() { fatalError("Preview must never clear live logs") }
''' + stat + '}'
source += r'''
enum FilePaths { static var vpnDir: URL { URL(fileURLWithPath: CommandLine.arguments[1]) } }
'''
for path in ['Sources/ClaudeBar/Utils/VpnDomainRules.swift', 'Sources/ClaudeBar/Utils/PrivateFileWriter.swift',
             'Sources/ClaudeBar/Utils/VpnDomainQuery.swift', 'Sources/ClaudeBar/Views/Shared/VPNSurface.swift',
             'Sources/ClaudeBar/Views/Shared/StandbyEmptyState.swift',
             'Sources/ClaudeBar/Views/Pages/VpnDomainRulesView.swift',
             'Sources/ClaudeBar/Utils/VpnTrafficHistory.swift',
             'Sources/ClaudeBar/Views/Pages/VpnTrafficAnalyticsView.swift',
             'Sources/ClaudeBar/Views/Shared/VpnRouteTrafficSummary.swift',
             'Sources/ClaudeBar/Views/Pages/VpnDomainLogSection.swift']:
    source += (root / path).read_text() + '\n'
source += r'''
extension VpnDomainRulesView {
    init(fixture: [VpnDomainRule]) { _rules = State(initialValue: fixture) }
}
extension VpnDomainLogSection {
    init(fixtureMode: Mode, entries: [VpnDomainEntry]) {
        _mode = State(initialValue: fixtureMode)
        _visibleRows = State(initialValue: entries)
        _proxiedTraffic = State(initialValue: VpnDomainLog.shared.proxiedTraffic)
        _directTraffic = State(initialValue: VpnDomainLog.shared.directTraffic)
        var stats = VpnDomainLog.stat(entries: entries)
        for index in stats.indices {
            stats[index].traffic = VpnDomainLog.shared.trafficByHost[stats[index].host]
            stats[index].directTraffic = VpnDomainLog.shared.directTrafficByHost[stats[index].host]
        }
        _visibleStats = State(initialValue: stats)
        _routeCounts = State(initialValue: [.proxied: 31, .direct: 18, .reject: 1])
        _matchedCount = State(initialValue: entries.count)
        _tallyProxied = State(initialValue: entries.filter { $0.route == .proxied }.count)
        _tallyDirect = State(initialValue: entries.filter { $0.route == .direct }.count)
    }
}
@main struct VPNPreview {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = FilePaths.vpnDir
        let rules = [
            VpnDomainRule(domain: "api.example.com", includesSubdomains: false, route: .proxy),
            VpnDomainRule(domain: "example.com", includesSubdomains: true, route: .direct),
            VpnDomainRule(domain: "github.com", includesSubdomains: true, route: .proxy),
            VpnDomainRule(domain: "assets.example.net", includesSubdomains: false, route: .direct),
            VpnDomainRule(domain: "very-long-service-name.staging.example.org", includesSubdomains: true, route: .proxy)
        ]
        try VpnDomainRules.save(rules)
        let entries = [
            VpnDomainEntry(id: 1, timeText: "14:32:18", host: "github.com", port: 443, route: .proxied,
                outbound: "主代理[Tokyo 01]", rule: "DomainSuffix(github.com)", failed: false),
            VpnDomainEntry(id: 2, timeText: "14:32:20", host: "example.com", port: 443, route: .direct,
                outbound: "DIRECT", rule: "DomainSuffix(example.com)", failed: false),
            VpnDomainEntry(id: 3, timeText: "14:32:22", host: "api.example.com", port: 443, route: .proxied,
                outbound: "主代理[Tokyo 01]", rule: "Domain(api.example.com)", failed: false),
            VpnDomainEntry(id: 4, timeText: "14:32:24", host: "github.com", port: 443, route: .direct,
                outbound: "DIRECT", rule: "Domain(github.com)", failed: false)
        ]
        let log = VpnDomainLog.shared
        log.entries = entries
        log.trafficByHost = ["github.com": .init(upload: 210_000, download: 8_700_000),
                             "api.example.com": .init(upload: 140_000, download: 3_900_000)]
        log.directTrafficByHost = ["example.com": .init(upload: 90_000, download: 3_100_000),
                                   "github.com": .init(upload: 100_000, download: 4_000_000)]
        var ledger = VpnTrafficLedger()
        let calendar = Calendar.current
        let now = Date()
        for offset in (0..<30).reversed() {
            let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!
            let up = Int64(24_000_000 + (offset * 37 % 113) * 1_000_000)
            let down = Int64(190_000_000 + (offset * 71 % 397) * 2_000_000)
            let proxy = VpnTrafficAmounts(upload: up, download: down)
            let direct = VpnTrafficAmounts(upload: up / 3, download: down / 2)
            let traffic = VpnTrafficSplit(core: .init(upload: up + direct.upload + 8_000_000,
                                                    download: down + direct.download + 21_000_000),
                                          proxied: proxy, direct: direct)
            for hour in 0..<24 {
                let timestamp = day.addingTimeInterval(Double(hour) * 3600)
                guard timestamp <= now else { continue }
                let factor = (0.22 + exp(-pow((Double(hour) - 10) / 3, 2)) + 0.7 * exp(-pow((Double(hour) - 20) / 2.5, 2))) / 12
                let sample = VpnTrafficSplit(
                    core: .init(upload: Int64(Double(traffic.core.upload) * factor), download: Int64(Double(traffic.core.download) * factor)),
                    proxied: .init(upload: Int64(Double(proxy.upload) * factor), download: Int64(Double(proxy.download) * factor)),
                    direct: .init(upload: Int64(Double(direct.upload) * factor), download: Int64(Double(direct.download) * factor)))
                ledger.record(sample, hosts: [
                    "github.com": .init(proxied: .init(upload: sample.proxied.upload / 2, download: sample.proxied.download / 2)),
                    "example.com": .init(direct: sample.direct),
                    "api.example.com": .init(proxied: .init(upload: sample.proxied.upload / 3, download: sample.proxied.download / 3)),
                    "very-long-service-name.staging.example.org": .init(proxied: .init(upload: sample.proxied.upload / 6, download: sample.proxied.download / 6))
                ], at: timestamp)
            }
        }
        let archive = out.appendingPathComponent("traffic-history", isDirectory: true)
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        for (day, totals) in ledger.days {
            let date = VpnTrafficLedger.dayDate(day)!
            let record = VpnTrafficArchiveDay(day: day, totals: totals,
                hours: ledger.hours.filter { key, _ in VpnTrafficLedger.dayKey(Date(timeIntervalSince1970: Double(key)!)) == day },
                domains: ledger.domains[day] ?? [:], firstRecord: date, lastRecord: date)
            try PrivateFileWriter.write(JSONEncoder().encode(record), to: archive.appendingPathComponent(day + ".json"))
        }
        _ = await VpnTrafficHistory.shared.report(period: .week)
        for dark in [false, true] {
            AppPreferences.shared.isDark = dark
            let views: [(String, AnyView, CGFloat, CGFloat)] = [
                ("rules", AnyView(VpnDomainRulesView(fixture: rules)), 760, 650),
                ("rules-empty", AnyView(VpnDomainRulesView(fixture: [])), 760, 650),
                ("detail", AnyView(VpnDomainLogSection(fixtureMode: .detail, entries: entries)), 900, 600),
                ("detail-compact", AnyView(VpnDomainLogSection(fixtureMode: .detail, entries: entries)), 560, 600),
                ("summary", AnyView(VpnDomainLogSection(fixtureMode: .summary, entries: entries)), 1100, 600),
                ("analytics", AnyView(VpnDomainLogSection(fixtureMode: .analytics, entries: entries)), 900, 1500),
                ("analytics-compact", AnyView(VpnDomainLogSection(fixtureMode: .analytics, entries: entries)), 560, 1500)
            ]
            for (name, view, width, height) in views {
                let content = view.frame(width: width, height: height)
                    .environment(\.colorScheme, dark ? .dark : .light)
                if name == "rules-empty" { try VpnDomainRules.save([]) }
                else if name == "rules" { try VpnDomainRules.save(rules) }
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                window.orderBack(nil)
                try await Task.sleep(nanoseconds: 450_000_000)
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("VPN bitmap failed") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("VPN render failed") }
                try png.write(to: out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                window.close()
            }
        }
    }
}
'''
(out / 'main.swift').write_text(source)
subprocess.run(['swiftc', '-parse-as-library', '-O', str(out / 'main.swift'), '-o', str(out / 'preview')], check=True)
subprocess.run([str(out / 'preview'), str(out)], check=True)
print(out)
