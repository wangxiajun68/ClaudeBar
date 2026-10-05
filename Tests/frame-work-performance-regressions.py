#!/usr/bin/env python3
"""Production Canvas work, traffic filtering lifecycle and usage density. Synthetic data only."""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--baseline-ref')
p.add_argument('--probe', action='store_true')
p.add_argument('--keep-fixture', type=Path)
p.add_argument('--output-json', type=Path)
a = p.parse_args()


def read(path):
    if a.baseline_ref:
        return subprocess.check_output(['git', 'show', f'{a.baseline_ref}:{path}'], cwd=root, text=True)
    return (root / path).read_text()


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


heat = read('Sources/ClaudeBar/Views/Shared/UsageHeatmap.swift').split('/// Sliding-pill')[0]
draw = declaration(heat, '            Canvas { ctx, _ in')
draw = draw[draw.index('{') + 1:draw.rindex('}')].replace('ctx, _ in', '', 1).replace('Self.dayKey(', 'UsageHeatmap.dayKey(')
prepared = 'func cells(' in heat
pricing = (root / 'Sources/ClaudeBar/Utils/ModelPricing.swift').read_text()
day_key = declaration(pricing, '    static func dayKey(').replace('        let parts', '        Metrics.dayKeys += 1\n        let parts', 1)
models = (root / 'Sources/ClaudeBar/Models/ModelUsage.swift').read_text()
model_declarations = '\n'.join(declaration(models, marker) for marker in ['enum UsagePeriod', 'struct DayUsage', 'struct ModelUsage', 'enum UsageProviderAttribution'])
heat_fixture = r'''
import AppKit
import SwiftUI
import CryptoKit
MODELS
enum Metrics { static var dayKeys = 0 }
enum ModelPricing { DAY_KEY }
enum UsageStats {
    static func formatTokens(_ value: Int) -> String { String(value) }
    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.dateFormat = format; return f
    }
}
enum Theme {
    static let chartPurple = Color.purple, textPrimary = Color.primary
    static func textTertiary() -> Color { .gray }
    static func cardFill(_ opacity: Double) -> Color { Color.gray.opacity(opacity) }
    enum Animation { static let smooth = SwiftUI.Animation.smooth(duration: 0.3) }
}
HEAT
struct Paint {
    struct Shading { let color: Color; static func color(_ color: Color) -> Shading { Shading(color: color) } }
    var raster: CGContext?
    var count = 0
    mutating func fill(_ path: Path, with shading: Shading) {
        count += 1
        if let raster {
            raster.setFillColor(NSColor(shading.color).cgColor)
            raster.addPath(path.cgPath); raster.fillPath()
        }
    }
}
private struct DrawFixture {
    let layout: HeatLayout
    let cal: Calendar
    let by: [String: Int]
    let peak: Double
    CELLS_DECL
    func fill(_ intensity: Double?) -> Color {
        guard let v = intensity, v > 0 else { return Theme.cardFill(0.06) }
        return Theme.chartPurple.opacity(0.16 + 0.84 * v)
    }
    func paint(_ ctx: inout Paint) { DRAW }
}
func digest(_ image: CGImage) -> String {
    SHA256.hash(data: image.dataProvider!.data! as Data).map { String(format: "%02x", $0) }.joined()
}
@main struct HeatRegression {
    @MainActor static func main() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = cal.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        var measurements: [[String: Any]] = []
        for count in [366, 2557] {
            let end = cal.date(byAdding: .day, value: count, to: start)!
            let layout = HeatLayout.make(interval: DateInterval(start: start, end: end), size: CGSize(width: 900, height: 108), cal: cal, compact: false)
            var by: [String: Int] = [:]
            for day in 0..<count where day % 3 != 0 {
                by[UsageHeatmap.dayKey(cal.date(byAdding: .day, value: day, to: start)!)] = day % 100 + 1
            }
            let prepareStart = CACurrentMediaTime()
            let CELLS_NAME = PREPARE
            let prepareMS = (CACurrentMediaTime() - prepareStart) * 1000
            let fixture = DrawFixture(layout: layout, cal: cal, by: by, peak: 100 CELLS_INIT)
            Metrics.dayKeys = 0
            var durations: [Double] = [], sink = 0
            for _ in 0..<120 {
                let start = CACurrentMediaTime()
                var ctx = Paint()
                fixture.paint(&ctx); sink += ctx.count
                durations.append((CACurrentMediaTime() - start) * 1000)
            }
            precondition(sink == layout.cols * 7 * 120)
            if PREPARED { precondition(Metrics.dayKeys == 0, "Canvas redraw must not format date keys") }
            let keys = Metrics.dayKeys
            let context = CGContext(data: nil, width: 900, height: 108, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            var raster = Paint(raster: context); fixture.paint(&raster)
            measurements.append(["days": count, "frames": 120, "prepare_ms": prepareMS, "median_ms": durations.sorted()[60], "day_keys": keys,
                                 "image_sha256": digest(context.makeImage()!)])
            // Date hit-testing retains leading/trailing padding and actual calendar days.
            for i in [0, count / 2, count - 1] {
                let slot = i + layout.leading
                let rect = layout.rect(col: slot / 7, row: slot % 7)
                precondition(layout.date(at: CGPoint(x: rect.midX, y: rect.midY), cal: cal) == cal.date(byAdding: .day, value: i, to: start))
            }
            precondition(layout.date(at: CGPoint(x: -10, y: 0), cal: cal) == nil)
        }
        print("METRICS " + String(data: try JSONSerialization.data(withJSONObject: ["heatmap": measurements], options: [.sortedKeys]), encoding: .utf8)!)
        for zone in ["UTC", "America/New_York", "Pacific/Apia"] {
            cal.timeZone = TimeZone(identifier: zone)!
            for firstWeekday in [1, 2] {
                cal.firstWeekday = firstWeekday
                let start = cal.date(from: DateComponents(year: 2024, month: 3, day: 1))!
                let end = cal.date(byAdding: .day, value: 31, to: start)!
                for compact in [false, true] {
                    let layout = HeatLayout.make(interval: DateInterval(start: start, end: end), size: CGSize(width: 260, height: 56), cal: cal, compact: compact)
                    for slot in 0..<(layout.cols * 7) {
                        let rect = layout.rect(col: slot / 7, row: slot % 7)
                        let actual = layout.date(at: CGPoint(x: rect.midX, y: rect.midY), cal: cal)
                        let i = slot - layout.leading
                        let expected = i >= 0 && i < 31 ? cal.date(byAdding: .day, value: i, to: start) : nil
                        precondition(actual == expected, "DST/calendar/compact hit testing changed")
                    }
                }
            }
        }
        print("PASS production heatmap painting and hit testing")
    }
}
'''
heat_fixture = heat_fixture.replace('MODELS', model_declarations).replace('DAY_KEY', day_key).replace('HEAT', heat)
heat_fixture = heat_fixture.replace('DRAW', draw).replace('PREPARED', 'true' if prepared else 'false')
heat_fixture = heat_fixture.replace('CELLS_DECL', 'let cells: [HeatLayout.Cell]' if prepared else '')
heat_fixture = heat_fixture.replace('PREPARE', 'layout.cells(by: by, peak: 100, cal: cal)' if prepared else '()')
heat_fixture = heat_fixture.replace('CELLS_INIT', ', cells: cells' if prepared else '').replace('CELLS_NAME', 'cells' if prepared else '_')

traffic = read('Sources/ClaudeBar/Views/Pages/TrafficView.swift')
records_source = (root / 'Sources/ClaudeBar/Utils/ProxyCaptureStore.swift').read_text()
traffic_models = '\n'.join(declaration(records_source, marker) for marker in ['struct CaptureSummary:', 'enum CaptureKind:', 'enum CaptureState:'])
receive = declaration(traffic, '        .onReceive(catalog.$records)')
receive = receive[receive.index('{') + 1:receive.rindex('}')].replace('_ in', '', 1).replace('DispatchQueue.main.async {', 'DispatchQueue.main.async { [self] in')
traffic_methods = '\n'.join(declaration(traffic, marker).replace('private ', '').replace('nonmutating ', '') for marker in
                           ['    private static func stamp(', '    private func recomputeFiltered()'])
if 'private func reconcileFilteredRecords()' in traffic:
    traffic_methods += '\n' + declaration(traffic, '    private func reconcileFilteredRecords()').replace('private ', '')
traffic_fixture = r'''
import Foundation
import Combine
enum CaptureSource { case claude, codex, other }
TRAFFIC_MODELS
final class Catalog { var records: [CaptureSummary] = [] }
final class PageState { var mounted = true; var loadGen = 0 }
final class Fixture {
    let catalog = Catalog(), state = PageState()
    var recordsStamp = ""
    var filteredCache: [CaptureSummary] = []
    var filtered: [CaptureSummary] { filteredCache }
    var selectedID: Int64?
    var query = ""
    var filter = TrafficFilter.all
    FILTER
    METHODS
    func receive() { RECEIVE }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { if PROBE { print("BASELINE VIOLATION:", message) } else { fatalError(message) } }
}
@main struct TrafficRegression {
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(20)) }
    @MainActor static func main() async throws {
        let f = Fixture()
        f.catalog.records = (1...120).map { i in
            CaptureSummary(id: Int64(i), startedAt: .distantPast, kind: .openaiChat, source: .codex,
                           providerName: "fixture", model: "fixture-model", path: "/fixture", isStream: true,
                           state: .streaming, httpStatus: 200, preview: String(repeating: "中文 preview ", count: 1000))
        }
        f.query = "fixture-model"; f.recomputeFiltered(); f.selectedID = 3
        for i in f.catalog.records.indices {
            f.catalog.records[i].state = .done; f.catalog.records[i].completionTokens = 42
            f.catalog.records[i].endedAt = Date(timeIntervalSince1970: 100)
        }
        f.receive(); await settle()
        let obsolete = f.filtered.filter { $0.state == .streaming || $0.state == .pending }.count
        require(obsolete == 0 && f.filtered.allSatisfy { $0.completionTokens == 42 }, "Completed rows must stop using the live-preview observer branch")
        require(f.selectedID == 3, "Status patches must preserve selection")
        f.catalog.records[0].model = "different"; f.receive(); await settle()
        require(!f.filtered.contains { $0.id == 1 }, "Search fields must still refresh membership")
        f.catalog.records.removeAll { $0.id == 3 }; f.receive(); await settle()
        require(f.selectedID == f.filtered.first?.id, "Pruned selection must reconcile")
        let order = f.filtered.map(\.id).reversed()
        f.catalog.records.reverse(); f.receive(); await settle()
        require(f.filtered.map(\.id) == Array(order), "Catalog ordering must stay current")
        f.catalog.records[0].state = .error; f.catalog.records[0].httpStatus = 500
        f.receive(); await settle()
        require(f.filtered.first?.state == .error && f.filtered.first?.httpStatus == 500, "Terminal error patches must stay current")
        let saved = f.filtered
        f.catalog.records = []; f.receive(); f.state.mounted = false; f.state.loadGen += 1
        await settle()
        require(f.filtered == saved, "Unmounted catalog callback must not republish")
        f.state.mounted = true; f.catalog.records = saved; f.recomputeFiltered()
        f.catalog.records = []; f.receive()
        f.state.mounted = false; f.state.loadGen += 1; f.state.mounted = true
        await settle()
        require(f.filtered == saved, "Old catalog callback must not republish into a remounted page")
        print("METRICS " + String(data: try JSONSerialization.data(withJSONObject: ["traffic_stale_live_rows": obsolete]), encoding: .utf8)!)
        if !PROBE { print("PASS production traffic cache status, membership, selection and unmount") }
    }
}
'''.replace('TRAFFIC_MODELS', traffic_models)
traffic_fixture = traffic_fixture.replace('FILTER', declaration(traffic, '    enum TrafficFilter:'))
traffic_fixture = traffic_fixture.replace('METHODS', traffic_methods).replace('RECEIVE', receive).replace('PROBE', 'true' if a.probe else 'false')

analysis = read('Sources/ClaudeBar/Utils/UsageAnalysis.swift')
oracle = subprocess.check_output(['git', 'show', 'a5e9688:Sources/ClaudeBar/Utils/UsageAnalysis.swift'], cwd=root, text=True).replace('struct UsageAnalysis {', 'struct OriginalAnalysis {', 1) if a.baseline_ref else (root / 'Tests/fixtures/usage-density-baseline.swift').read_text()
analysis = analysis.replace('            density = (0..<96).map', '            let densityStart = CFAbsoluteTimeGetCurrent()\n            density = (0..<96).map', 1)
analysis = analysis.replace('        } else {\n            density = []', '            DensityMetrics.ms = (CFAbsoluteTimeGetCurrent() - densityStart) * 1000\n        } else {\n            density = []', 1)
analysis_fixture = 'import Foundation\nenum DensityMetrics { static var ms = 0.0 }\n' + model_declarations + '\n' + analysis + '\n' + oracle + r'''
@main struct DensityRegression {
    static func main() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = cal.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        let end = cal.date(byAdding: .day, value: 2000, to: start)!
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        let interval = DateInterval(start: start, end: end)
        var result: [[String: Any]] = []
        for distinct in [3, 30, 2000] {
            let days = (0..<2000).map { i in DayUsage(day: f.string(from: cal.date(byAdding: .day, value: i, to: start)!), inputTokens: i % distinct * 100) }
            let old = OriginalAnalysis(days: days, stats: [], period: .custom, interval: interval, now: end, calendar: cal)
            let current = UsageAnalysis(days: days, stats: [], period: .custom, interval: interval, now: end, calendar: cal)
            precondition(current.daily.map(\.total) == old.daily.map(\.total) && current.density.count == old.density.count)
            precondition(current.median == old.median && current.p95 == old.p95 && current.densityBandwidth == old.densityBandwidth)
            var error = 0.0
            for (x, y) in zip(current.density, old.density) {
                precondition(x.x == y.x); error = max(error, abs(x.y - y.y))
                precondition(abs(x.y - y.y) <= max(1e-15, abs(y.y) * 1e-12), "Weighted density must preserve each observation")
            }
            var times: [Double] = [], kdeTimes: [Double] = []; var sink = 0
            for _ in 0..<10 {
                let t = CFAbsoluteTimeGetCurrent()
                let a = UsageAnalysis(days: days, stats: [], period: .custom, interval: interval, now: end, calendar: cal)
                sink += a.density.count; kdeTimes.append(DensityMetrics.ms)
                times.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            }
            precondition(sink == 960)
            result.append(["days": 2000, "distinct_totals": distinct, "median_ms": times.sorted()[5], "kde_median_ms": kdeTimes.sorted()[5], "density_max_absolute_error": error])
        }
        print("METRICS " + String(data: try JSONSerialization.data(withJSONObject: ["density": result]), encoding: .utf8)!)
        print("PASS production usage density against frozen observation-by-observation oracle")
    }
}
'''

measurements = {}
with tempfile.TemporaryDirectory(prefix='claudebar-frame-work-') as temporary:
    out = a.keep_fixture or Path(temporary)
    out.mkdir(parents=True, exist_ok=True)
    for name, fixture in [('heatmap', heat_fixture), ('traffic', traffic_fixture), ('density', analysis_fixture)]:
        path = out / (name + '.swift'); path.write_text(fixture)
        binary = out / name
        subprocess.run(['swiftc', '-O', '-g', '-parse-as-library', '-target', 'arm64-apple-macos15.0', str(path), '-o', str(binary)], check=True)
        output = subprocess.check_output([str(binary)], text=True)
        print(output, end='', flush=True)
        for line in output.splitlines():
            if line.startswith('METRICS '): measurements.update(json.loads(line[8:]))
if a.output_json: a.output_json.write_text(json.dumps(measurements, ensure_ascii=False, indent=2) + '\n')
