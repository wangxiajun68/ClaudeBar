#!/usr/bin/env python3
"""Production CPU/update probes, using synthetic data and temporary persistence only.

--compare compiles HEAD and the working tree with -O, runs alternating arms,
and prints raw samples. Timing is diagnostic, never a flaky CI threshold.
"""
from pathlib import Path
import argparse
import json
import re
import statistics
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compare', action='store_true')
parser.add_argument('--baseline-ref', default='HEAD', help='Git ref for the comparison arm')
parser.add_argument('--output-json', type=Path, help='Save samples and medians for a review report')
args = parser.parse_args()


def read(path, baseline=False):
    if baseline:
        return subprocess.check_output(['git', 'show', args.baseline_ref + ':' + path], cwd=root, text=True)
    return (root / path).read_text()


def declaration(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def harness(baseline):
    table = read('Sources/ClaudeBar/Models/DocumentTable.swift', baseline)
    pricing = read('Sources/ClaudeBar/Utils/ModelPricing.swift', baseline)
    log = read('Sources/ClaudeBar/Utils/ProxyAccessLog.swift', baseline)
    collector = read('Sources/ClaudeBar/Utils/JSONLineCollector.swift', baseline)
    # Count production wait calls; instrumentation never enters the app build.
    collector = collector.replace('private let signal =', 'var waitCount = 0\n    private let signal =')
    collector = collector.replace('_ = signal.wait(', 'waitCount += 1\n            _ = signal.wait(')
    canonical = declaration(pricing, '    static func canonical(')
    tier = declaration(pricing, '    private static func tierSuffix(')
    regex = declaration(pricing, '    private static let snapshotSuffixes:') + '()' if 'private static let snapshotSuffixes:' in pricing else ''
    # Keep the prior geometry as an independent oracle for merged/edited rows.
    heights = r'''
    private var heights: [Double] {
        var values = model.rowHeights
        for cell in model.cells {
            let width = model.columnWidths[cell.column..<(cell.column + cell.columnSpan)].reduce(0, +) - 24
            let estimate = cell.value.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int(ceil(Double($1.count) * 8 / max(40, width)))) }
            let content = Double(measured[cell.id] ?? CGFloat(estimate * 21 + 4)) + 24
            let existing = values[cell.row..<(cell.row + cell.rowSpan)].reduce(0, +)
            if content > existing { values[cell.row + cell.rowSpan - 1] += content - existing }
        }
        return values
    }
    '''
    clusters = r'''
    private var clusters: [Range<Int>] {
        let byRow = Dictionary(grouping: model.cells, by: \.row)
        var result: [Range<Int>] = [], row = 0
        while row < model.rowCount {
            var end = row + 1, scanning = row
            while scanning < end {
                for cell in byRow[scanning] ?? [] { end = max(end, cell.row + cell.rowSpan) }
                scanning += 1
            }
            result.append(row..<end); row = end
        }
        return result
    }
    '''
    if baseline and 'func layout(' not in table:
        original_view = read('Sources/ClaudeBar/Views/Shared/DocumentTableView.swift', True)
        heights = declaration(original_view, '    private var heights:')
        clusters = declaration(original_view, '    private var clusters:')
    layout_fixture = 'struct LayoutFixture { let model: DocumentTable; let measured: [UUID: CGFloat]\n' + heights + '\n' + clusters + '''
        init(model: DocumentTable, measured: [UUID: CGFloat] = [:]) { self.model = model; self.measured = measured }
        func heightsForTest() -> [Double] { heights }
        func clustersForTest() -> [Range<Int>] { clusters }
        func visit() -> Int {
            let actual = heights
            return clusters.reduce(0) { count, rows in
                count + model.cells.filter { rows.contains($0.row) }.reduce(0) { total, cell in
                    total + Int(actual[cell.row..<(cell.row + cell.rowSpan)].reduce(0, +))
                }
            }
        }
        }
        '''
    layout_check = ''
    if 'func layout(' in table:
        layout = '''let layout = table.layout(measured: [:])
            checksum += layout.clusters.reduce(0) { count, cluster in
                count + cluster.cellIndices.reduce(0) { total, index in
                    let cell = table.cells[index]
                    return total + Int(layout.rowOffsets[cell.row + cell.rowSpan] - layout.rowOffsets[cell.row])
                }
            }'''
        layout_check = r'''
        var edited = DocumentTable(rows: (0..<8).map { row in
            ["", "中文😀\r\n第二行\n", "```swift\nlet x = 1\n```", String(repeating: "文字", count: row * 20), "end"]
        })
        func checkLayout(_ table: DocumentTable) {
            let measured = Dictionary(uniqueKeysWithValues: table.cells.enumerated().filter { $0.offset % 3 == 0 }
                .map { ($0.element.id, Double(30 + $0.offset * 9)) })
            let oracle = LayoutFixture(model: table, measured: measured.mapValues { CGFloat($0) })
            let next = table.layout(measured: measured)
            let expected = oracle.heightsForTest()
            precondition(next.rowOffsets.count == expected.count + 1)
            for row in expected.indices {
                precondition(abs(next.rowOffsets[row + 1] - next.rowOffsets[row] - expected[row]) < 1e-8)
            }
            precondition(next.clusters.map(\.rows) == oracle.clustersForTest())
            precondition(next.clusters.flatMap(\.cellIndices).sorted() == Array(table.cells.indices))
            for cluster in next.clusters {
                precondition(Set(cluster.cellIndices) == Set(table.cells.indices.filter { cluster.rows.contains(table.cells[$0].row) }))
            }
            for column in table.columnWidths.indices {
                precondition(abs(next.columnOffsets[column + 1] - next.columnOffsets[column] - table.columnWidths[column]) < 1e-8)
            }
            let widths = (0..<table.columnCount).map { column -> Double in
                let values = table.cells.filter { $0.column == column }.map(\.value)
                if values.contains(where: { $0.contains("```") }) { return 300 }
                let longest = values.flatMap { $0.components(separatedBy: "\n") }.map(\.count).max() ?? 0
                return min(300, max(150, Double(longest) * 7 + 24))
            }
            precondition(DocumentTable(cells: table.cells, rowCount: table.rowCount, columnCount: table.columnCount).columnWidths == widths)
        }
        checkLayout(edited)
        let first = edited.cells[0].id
        edited.merge(first, below: true); checkLayout(edited)
        edited.merge(edited.cells[2].id, below: false); checkLayout(edited)
        edited.insertRow(at: 1); edited.insertColumn(at: 2); checkLayout(edited)
        edited.deleteRow(at: 2); edited.deleteColumn(at: 1); checkLayout(edited)
        edited.split(first); checkLayout(edited)
        edited.columnWidths[0] = 153.375; edited.rowHeights[0] = 54.125; checkLayout(edited)
        edited.cells.reverse(); checkLayout(edited)
        '''
    else:
        layout = 'checksum += LayoutFixture(model: table).visit()'
    return '\n'.join([table, log, collector, layout_fixture,
                      'enum Canonical {\n' + regex + '\n' + canonical + '\n' + tier + '\n}']) + r'''
import Combine
// `ProxyAccessLog.clip` delegates to the production `CaptureTranscript.clip`
// (finding 608); this harness compiles the log file alone, so only that
// static is stubbed, mirroring the shape access-log-tail-regressions.py uses.
enum CaptureTranscript {
    static func clip(_ text: String, cap: Int = 160) -> String {
        let folded = text.split(whereSeparator: { $0.isNewline || $0 == "\r" })
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return folded.count > cap ? String(folded.prefix(cap)) + "…" : folded
    }
}
enum UsageStats { static func formatTokens(_ n: Int) -> String { String(n) } }
struct TokenTotals {
    var input: Int?; var output: Int?; var cacheRead: Int?; var cacheWrite: Int?
    var isEmpty: Bool { input == nil && output == nil && cacheRead == nil && cacheWrite == nil }
}
enum FilePaths {
    static let proxyLogFile = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("access.jsonl")
}
final class LogBox: @unchecked Sendable {
    let store: ProxyAccessLog
    init(_ store: ProxyAccessLog) { self.store = store }
}
func milliseconds(_ work: () -> Void) -> Double {
    let start = ContinuousClock.now
    work()
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
}
func check(_ condition: @autoclosure () -> Bool, _ message: String = "", line: Int = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("CHECK \(line): \(message)\n".utf8))
        exit(1)
    }
}
@main struct Probe {
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "asynchronous publication did not settle")
    }
    @MainActor static func main() async throws {
        var metrics: [String: Double] = [:]
        var checksum = 0
        let cells = (0..<2000).flatMap { row in
            (0..<12).map { DocumentTable.Cell(row: row, column: $0, value: "项目 \(row):\($0)") }
        }
        var table = DocumentTable(cells: [], rowCount: 0, columnCount: 0)
        metrics["table_init_ms"] = milliseconds { table = DocumentTable(cells: cells, rowCount: 2000, columnCount: 12) }
        var html = ""
        metrics["table_html_ms"] = milliseconds { html = table.html { $0 } }
        precondition(html.components(separatedBy: "<td").count - 1 == cells.count)
        metrics["table_layout_ms"] = milliseconds { __LAYOUT__ }
        __LAYOUT_CHECK__
        // A deterministic digest compares full exports, not merely their sizes.
        var digest: UInt64 = 14695981039346656037
        for byte in html.utf8 { digest = (digest ^ UInt64(byte)) &* 1099511628211 }
        try Data(html.utf8).write(to: FilePaths.proxyLogFile.deletingLastPathComponent().appendingPathComponent("table.html"))
        let slugs = ["anthropic/claude-sonnet-4-6-20250929:free", "GPT-5.4@latest", "z-ai/glm-5",
                     "vendor/model-20250101@20250202", "model-２０２５０１０１", "claude-opus-5-5-medium-thinking"]
        metrics["canonical_ms"] = milliseconds {
            for _ in 0..<3000 { for slug in slugs { checksum += Canonical.canonical(slug).utf8.count } }
        }
        precondition(Canonical.canonical(slugs[0]) == "claude-sonnet-4-6")
        precondition(Canonical.canonical(slugs[4]) == "model")
        let collector = JSONLineCollector()
        let batch = Data((0..<2000).map { "{\"id\":\($0),\"result\":\"项目😀\"}\n" }.joined().utf8)
        metrics["rpc_batch_ms"] = milliseconds { collector.append(batch) }
        for id in 0..<2000 {
            let message = try collector.response(id: id, until: Date().addingTimeInterval(1))
            precondition(message["result"] as? String == "项目😀")
        }
        collector.append(Data("{\"id\":2000,\"result\":\"中文😀\"}".utf8))
        collector.append(Data([10])); collector.finish()
        let lastMessage = try collector.response(id: 2000, until: Date().addingTimeInterval(1))
        precondition(lastMessage["result"] as? String == "中文😀")
        do { _ = try collector.response(id: 2001, until: Date().addingTimeInterval(1)); preconditionFailure() }
        catch JSONLineCollector.Failure.closed {}

        let quiet = JSONLineCollector()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.65) { quiet.append(Data("{\"id\":1}\n".utf8)) }
        let _: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { continuation.resume(returning: try quiet.response(id: 1, until: Date().addingTimeInterval(2))) }
                catch { continuation.resume(throwing: error) }
            }
        }
        metrics["rpc_quiet_waits"] = Double(quiet.waitCount)
        let timeout = JSONLineCollector()
        let timeoutStart = ContinuousClock.now
        do { _ = try timeout.response(id: 1, until: Date().addingTimeInterval(0.035)); preconditionFailure() }
        catch JSONLineCollector.Failure.timedOut {}
        metrics["rpc_timeout_ms"] = Double(timeoutStart.duration(to: .now).components.attoseconds) / 1e15

        // A large sidecar with corrupt tail lines: load the last valid rows,
        // skip corruption, preserve order and continue the id sequence.
        let seed = (1...5000).map { id in
            "{\"id\":\(id),\"at\":\"2026-10-03T00:00:00Z\",\"end\":\"2026-10-03T00:00:01Z\",\"method\":\"GET\",\"path\":\"/health\",\"source\":\"other\",\"kind\":\"health\"}\n"
        }.joined() + "broken\n{\"id\":\n"
        try Data(seed.utf8).write(to: FilePaths.proxyLogFile)
        var store: ProxyAccessLog!
        let loadStart = ContinuousClock.now
        metrics["log_construct_ms"] = milliseconds { store = ProxyAccessLog.shared }
        __ASYNC_LOG_LOAD__
        let loadDuration = loadStart.duration(to: .now).components
        metrics["log_load_ms"] = Double(loadDuration.seconds) * 1000 + Double(loadDuration.attoseconds) / 1e15
        precondition(store.entries.map(\.id) == Array(4501...5000).map(UInt64.init))
        var publishes = 0
        let observer = store.objectWillChange.sink { publishes += 1 }
        let tokens = TokenTotals(input: 2, output: 3, cacheRead: 4, cacheWrite: 5)
        metrics["log_burst_enqueue_ms"] = milliseconds {
            for _ in 0..<600 {
                let tap = store.begin(method: "POST", path: "/v1/messages?secret=omitted", source: .claude,
                                      kind: .anthropic, provider: "synthetic", model: "synthetic", stream: true, bytesIn: 128)
                tap.note(tokens: tokens); tap.finish(status: 200); tap.finish(status: 500)
            }
        }
        await waitUntil { store.entries.count == 500 && store.entries.last?.id == 5600 && store.entries.allSatisfy { !$0.isPending } }
        precondition(store.entries.map(\.id) == Array(5101...5600).map(UInt64.init))
        precondition(store.entries.allSatisfy { $0.totalTokens == 14 && $0.status == 200 && !$0.path.contains("secret") })
        metrics["log_burst_publishes"] = Double(publishes)
        let before = publishes
        store.clear()
        await waitUntil { store.entries.isEmpty && publishes > before }
        // Immediate clear followed by new traffic must not resurrect a queued
        // old snapshot. Publication remains bounded while traffic is continuous.
        if __OPTIMIZED__ {
            let old = store.begin(method: "GET", path: "/old", source: .other, kind: .other,
                                  provider: "", model: "", stream: false, bytesIn: 0)
            store.clear(); old.finish(status: 500)
        }
        let fresh = store.begin(method: "GET", path: "/fresh", source: .other, kind: .other,
                                provider: "", model: "", stream: false, bytesIn: 0)
        fresh.finish(status: 204)
        await waitUntil { store.entries.count == 1 && store.entries.first?.status == 204 }
        precondition(store.entries.first?.path == "/fresh")
        let started = ContinuousClock.now
        let initialPublishes = publishes
        for id in 0..<60 {
            let tap = store.begin(method: "GET", path: "/continuous/\(id)", source: .other, kind: .other,
                                  provider: "", model: "", stream: false, bytesIn: 0)
            tap.finish(status: 200)
            try? await Task.sleep(for: .milliseconds(5))
        }
        precondition(publishes > initialPublishes, "debounce starves a continuous stream")
        await waitUntil { store.entries.count == 61 && store.entries.allSatisfy { !$0.isPending } }
        let elapsed = started.duration(to: .now).components
        metrics["log_continuous_publishes"] = Double(publishes - initialPublishes)
        metrics["log_continuous_ms"] = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        if __OPTIMIZED__ {
            precondition(publishes - initialPublishes <= Int(metrics["log_continuous_ms"]! / 100) + 2)
            // Concurrent producers must retain monotonic order and completed
            // token buckets. No real proxy or child process is involved.
            let box = LogBox(store)
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    DispatchQueue.concurrentPerform(iterations: 200) { _ in
                        let tap = box.store.begin(method: "GET", path: "/concurrent", source: .other, kind: .other,
                                                 provider: "", model: "", stream: true, bytesIn: 0)
                        tap.note(tokens: tokens); tap.finish(status: 200)
                    }
                    continuation.resume()
                }
            }
            await waitUntil { store.entries.count == 261 && store.entries.allSatisfy { !$0.isPending } }
            precondition(store.entries.map(\.id) == store.entries.map(\.id).sorted())
            precondition(store.entries.suffix(200).allSatisfy { $0.totalTokens == 14 })
        }
        withExtendedLifetime(observer) {}
        metrics["checksum"] = Double(checksum)
        print("EXPORT " + String(digest))
        print("IDENTITIES " + String(decoding: try JSONSerialization.data(withJSONObject: slugs.map(Canonical.canonical)), as: UTF8.self))
        print("METRICS " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
    }
}
'''.replace('__ASYNC_LOG_LOAD__', 'store.loadListIfNeeded(); await waitUntil { store.entries.count == 500 }' if 'func loadListIfNeeded()' in log else '').replace('__LAYOUT__', layout).replace('__LAYOUT_CHECK__', layout_check).replace('__OPTIMIZED__', 'true' if 'schedulePublishLocked' in log else 'false').replace('precondition(', 'check(')


with tempfile.TemporaryDirectory(prefix='claudebar-module-perf-') as folder:
    work = Path(folder)
    arms = [True, False] if args.compare else [False]
    binaries = {}
    for baseline in arms:
        name = 'before' if baseline else 'after'
        source = work / (name + '.swift')
        source.write_text(harness(baseline))
        binary = work / name
        subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
        binaries[name] = binary
    samples = {name: [] for name in binaries}
    digests = set()
    identities = set()
    expected_export = None
    for repetition in range(3 if args.compare else 1):
        names = list(binaries) if repetition % 2 == 0 else list(reversed(binaries))
        for name in names:
            store = work / (name + str(repetition))
            store.mkdir()
            command = [str(binaries[name]), str(store)]
            if args.compare:
                command = ['/usr/bin/time', '-l'] + command
            run = subprocess.run(command, capture_output=True, text=True)
            if run.returncode:
                location = re.search(r'CHECK (\d+)', run.stderr)
                context = ''
                if location:
                    lines = (work / (name + '.swift')).read_text().splitlines()
                    line = int(location.group(1))
                    context = '\n'.join(f'{i + 1}: {lines[i]}' for i in range(max(0, line - 3), min(len(lines), line + 2)))
                raise SystemExit(name + ' failed:\n' + run.stderr + context)
            output = run.stdout
            exported = (store / 'table.html').read_bytes()
            if expected_export is None:
                expected_export = exported
            assert exported == expected_export, 'table export bytes changed across arms'
            for line in output.splitlines():
                if line.startswith('EXPORT '):
                    digests.add(line.removeprefix('EXPORT '))
                if line.startswith('IDENTITIES '):
                    identities.add(line.removeprefix('IDENTITIES '))
                if line.startswith('METRICS '):
                    metrics = json.loads(line.removeprefix('METRICS '))
                    rss = re.search(r'(\d+)\s+maximum resident set size', run.stderr)
                    if rss:
                        metrics['peak_rss_mib'] = int(rss.group(1)) / 1024 / 1024
                    samples[name].append(metrics)
    assert len(digests) == 1, 'table export changed across arms'
    assert len(identities) == 1, 'model canonicalization changed across arms'
    medians = {}
    for name, runs in samples.items():
        print(name + ': ' + json.dumps(runs, ensure_ascii=False, sort_keys=True))
        medians[name] = {key: statistics.median(run[key] for run in runs) for key in runs[0] if key != 'checksum'}
        if args.compare:
            print(name + ' medians: ' + json.dumps(medians[name], sort_keys=True))
    if args.output_json:
        args.output_json.write_text(json.dumps({
            'baseline_ref': args.baseline_ref if args.compare else None,
            'compiler_flags': ['-O', '-parse-as-library'],
            'hardware': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
            'swift': subprocess.check_output(['swiftc', '--version'], text=True, stderr=subprocess.STDOUT).strip(),
            'fixtures': {'table_rows': 2000, 'table_columns': 12, 'canonical_calls': 18000,
                         'rpc_messages': 2000, 'log_load_lines': 5000, 'log_burst_requests': 600,
                         'log_continuous_requests': 60},
            'export_digest': next(iter(digests)), 'samples': samples, 'medians': medians,
            'limitations': ['synthetic production-function probes, no app launch',
                            'layout traverses every cluster; not a visible-frame measurement',
                            'RSS includes input construction, checks and Swift/Foundation runtime',
                            'after arm additionally checks merged geometry and concurrent producers'],
        }, indent=2, ensure_ascii=False) + '\n')
    print('PASS: synthetic table, model identity, JSON-RPC framing and access-log lifecycle')
