#!/usr/bin/env python3
"""Offscreen production SwiftUI hover work; synthetic data, no VPN or real files.

Counts body evaluations, not display FPS. --baseline-ref compares a saved chart
implementation with the current one using identical native hosting conditions.
"""
from pathlib import Path
import argparse
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline-ref')
parser.add_argument('--compile-only', action='store_true')
args = parser.parse_args()
out = root / '.build/vpn-performance'
out.mkdir(parents=True, exist_ok=True)
assembly = (root / 'Tools/render-vpn-preview.py').read_text()
namespace = {'__file__': str(root / 'Tools/render-vpn-preview.py')}
exec(assembly[:assembly.index("source += r'''\nextension VpnDomainRulesView")], namespace)
source = namespace['source']
chart_path = 'Sources/ClaudeBar/Views/Pages/VpnTrafficAnalyticsView.swift'
current = (root / chart_path).read_text()
chart = subprocess.check_output(['git', 'show', args.baseline_ref + ':' + chart_path], cwd=root, text=True) if args.baseline_ref else current
source = source.replace(current, chart)
# Instrument the generated harness only; production contains no counters or driver.
for name in ['totals', 'trend', 'routeComparison', 'hourlyActivity', 'domainRanking']:
    marker = f'private func {name}(_ report: VpnTrafficReport) -> some View {{'
    if marker not in source:
        continue
    if name in ['totals', 'trend', 'routeComparison']:
        source = source.replace(marker + '\n        VStack', marker + f'\n        let _ = PerfDriver.hit("{name}")\n        return VStack')
    else:
        source = source.replace(marker, marker + f'\n        let _ = PerfDriver.hit("{name}")')
# The interaction seam follows whichever view actually owns selection state.
source = source.replace('.chartXSelection(value: $selectedDate)', '.chartXSelection(value: $selectedDate)\n            .onReceive(PerfDriver.shared.$date) { selectedDate = $0 }')
trend_start = source.find('private struct VpnTrafficTrendView:')
if trend_start >= 0:
    tail = source[trend_start:]
    tail = tail.replace('var body: some View {\n        VStack', 'var body: some View {\n        let _ = PerfDriver.hit("trend")\n        return VStack', 1)
    source = source[:trend_start] + tail
source = source.replace('.chartXSelection(value: selection)', '.chartXSelection(value: selection)\n            .onReceive(PerfDriver.shared.$date) { selection.wrappedValue = $0 }')
source += r'''
@MainActor final class PerfDriver: ObservableObject {
    static let shared = PerfDriver()
    static var counts: [String: Int] = [:]
    @Published var date: Date?
    static func hit(_ name: String) { counts[name, default: 0] += 1 }
}
extension VpnTrafficAnalyticsView {
    init(fixture: VpnTrafficReport) {
        isVisible = false
        _report = State(initialValue: fixture)
    }
}
@main struct Measure {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let now = Date()
        var report = VpnTrafficReport(startedAt: now.addingTimeInterval(-86400 * 30))
        for i in 0..<30 {
            let traffic = VpnTrafficSplit(core: .init(upload: 900_000, download: Int64(20_000_000 + i * 900_000)),
                proxied: .init(upload: 600_000, download: 13_000_000), direct: .init(upload: 300_000, download: 7_000_000))
            report.points.append(.init(date: now.addingTimeInterval(Double(i - 30) * 86400), traffic: traffic))
            report.totals.add(traffic)
        }
        for day in 0..<7 { for hour in 0..<24 {
            report.activity.append(.init(day: now.addingTimeInterval(Double(-day) * 86400), hour: hour, bytes: Int64((hour + 1) * 1_000_000)))
        }}
        for i in 0..<3000 {
            report.domains.append(.init(host: "host\(i).example", traffic: report.points[i % 30].traffic))
        }
        let host = NSHostingView(rootView: VpnTrafficAnalyticsView(fixture: report).frame(width: 860, height: 1500))
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 1500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        PerfDriver.counts = [:]
        var elapsed: [Double] = []
        for i in 0..<120 {
            let start = ProcessInfo.processInfo.systemUptime
            PerfDriver.shared.date = report.points[i % 30].date
            // Give SwiftUI the same commit opportunity for each selection.
            try await Task.sleep(nanoseconds: 1_000_000)
            host.layoutSubtreeIfNeeded()
            elapsed.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        elapsed.sort()
        print("HOVER 120 selections; section evaluations=\(PerfDriver.counts); commit wall median=\(elapsed[60])ms p95=\(elapsed[114])ms (includes 1ms scheduling; not FPS)")
        PerfDriver.shared.date = report.points[0].date
        try await Task.sleep(nanoseconds: 20_000_000)
        PerfDriver.counts = [:]
        for i in 0..<120 {
            PerfDriver.shared.date = report.points[0].date.addingTimeInterval(Double(i))
            try await Task.sleep(nanoseconds: 1_000_000)
            host.layoutSubtreeIfNeeded()
        }
        print("WITHIN-BUCKET 120 pointer positions; section evaluations=\(PerfDriver.counts)")
        window.close()
    }
}
'''
variant = 'baseline' if args.baseline_ref else 'current'
(out / (variant + '.swift')).write_text(source)
subprocess.run(['swiftc', '-parse-as-library', '-O', str(out / (variant + '.swift')), '-o', str(out / variant)], check=True)
if not args.compile_only:
    subprocess.run([str(out / variant), str(out)], check=True)
