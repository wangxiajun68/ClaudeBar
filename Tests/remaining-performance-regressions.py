#!/usr/bin/env python3
"""Optimized production slices: palette ranking, manual markup and widget publication.

Synthetic inputs only. Widget persistence and reloads are intercepted; no app,
user defaults, permission requests or real containers are touched. Timing is
reported separately from assertions, without flaky CI speed thresholds.
"""
from pathlib import Path
import argparse
import json
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--compare', action='store_true')
p.add_argument('--baseline-ref', default='HEAD')
p.add_argument('--output-json', type=Path)
a = p.parse_args()

def read(path, baseline):
    return subprocess.check_output(['git', 'show', a.baseline_ref + ':' + path], cwd=ROOT, text=True) if baseline else (ROOT / path).read_text()

def declaration(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

def harness(baseline):
    palette = read('Sources/ClaudeBar/Views/Shared/CommandPalette.swift', baseline)
    catalog = read('Sources/ClaudeBar/Views/Shared/HelpCatalog.swift', baseline)
    writer = read('Sources/ClaudeBar/Models/WidgetSnapshotWriter.swift', baseline)
    snapshot = read('Sources/ClaudeBar/Models/WidgetSnapshot.swift', baseline)
    item = declaration(palette, 'struct CommandItem:')
    modern = 'static func matching(' in item
    matching = 'CommandItem.matching(items, query: query)' if modern else 'Filter(items: items, query: query).filtered'
    selection_fixture = ''
    if modern:
        selection_fixture = 'struct ResultsFixture { var items: [CommandItem]; var query: String; var filtered: [CommandItem] = []; var selection: String?\n' + declaration(palette, '    private func refreshResults(').replace('private func', 'mutating func') + '\n}'
    old_filter = '''struct Filter {
    let items: [CommandItem]; let query: String
    var filtered: [CommandItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.searchTitle.contains(q) || $0.searchSubtitle.contains(q) }
            .sorted { $0.searchTitle.hasPrefix(q) && !$1.searchTitle.hasPrefix(q) }
    }}'''
    if not modern:
        old_filter = 'struct Filter { let items: [CommandItem]; let query: String\n' + declaration(palette, '    private var filtered:').replace('private var', 'var') + '\n}'
    help_fn = 'HelpInlineMarkdown.attributed(raw)' if 'enum HelpInlineMarkdown' in catalog else 'originalMarkup(raw)'
    # The entire real serial submit path and encoder; only OS effects replaced.
    writer = writer[writer.index('enum WidgetSnapshotWriter {'):writer.index('    private static func persist(')] + '''
    static var writes = 0
    static var lastPayload: Data?
    private static func persist(_ data: Data) { writes += 1; lastPayload = data }
    static func drain() { queue.sync {} }
    }
'''
    return '''import Foundation
enum LocalProxyAddress { static let port = 23186; static let openaiRoot = "http://127.0.0.1:23186/v1" }
struct Color: Equatable { static let fixture = Color() }
enum CommandResult: Equatable { case fixture }
enum BuildChannel { static var promptsForSystemPermissions = true }
enum PermissionGate { enum Kind { case widgetData }; static var enabled = true; static func allows(_ kind: Kind) -> Bool { enabled } }
final class WidgetCenter { static let shared = WidgetCenter(); var reloads = 0; func reloadAllTimelines() { reloads += 1 } }
func require(_ ok: @autoclosure () -> Bool, _ message: String = "", line: Int = #line) {
    if !ok() { fatalError("CHECK \\(line): \\(message)") }
}
func ms(_ work: () -> Void) -> Double {
    let start = ContinuousClock.now; work()
    let d = start.duration(to: .now).components
    return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
}
func originalMarkup(_ raw: String) -> AttributedString {
    (try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(raw)
}
''' + '\n'.join([item, old_filter, selection_fixture, catalog, snapshot, writer]) + '''
func matches(_ items: [CommandItem], _ query: String) -> [CommandItem] { __MATCH__ }
func markup(_ raw: String) -> AttributedString { __HELP__ }
func fixtureItems() -> [CommandItem] {
    var items: [CommandItem] = []
    items.reserveCapacity(10000)
    for i in 0..<10000 {
        let title: String = i % 3 == 0 ? "Claude 项目 \\(i)" : "项目 \\(i) Claude"
        let subtitle: String = i % 5 == 0 ? "Cursor · 会话" : "供应商 模型"
        items.append(CommandItem(id: String(i), title: title, subtitle: subtitle,
                                 icon: "fixture", tint: .fixture, result: .fixture))
    }
    return items
}
@main struct Probe {
    static func main() throws {
        var metrics: [String: Double] = [:]
        var checksum = 0
        // Built by a dedicated function: inlined into `main` as a two-branch
        // `map` closure, the whole body became one expression the type
        // checker gave up on ("unable to type-check in reasonable time").
        let items = fixtureItems()
        for query in ["", "   ", " cLaUdE ", "Cursor", "项目", "会话", "不存在", "\\n", "😀", "供应商"] {
            require(matches(items, query).map(\\.id) == Filter(items: items, query: query).filtered.map(\\.id), "palette ranking changed")
        }
        __SELECTION_CHECK__
        metrics["palette_3_preparations_and_180_selection_updates_ms"] = ms {
            for _ in 0..<3 {
                __PREPARE__
                for selected in 0..<60 {
                    let rows = __ROWS__
                    checksum += rows.firstIndex { $0.id == String(selected) } ?? -1
                    checksum += __COUNT__
                }
            }
        }
        var paragraphs = HelpCatalog.entries.flatMap { entry in entry.body.flatMap { block -> [String] in
            switch block { case .para(let s): return [s]; case .bullets(let items): return items; default: return [] }
        }}
        paragraphs += ["**bold** `code` [link](https://example.invalid) 中文😀", "a  b\\n c\\t", "*unfinished", "\\\\*literal\\\\*", "", "<broken>"]
        for raw in paragraphs { require(markup(raw) == originalMarkup(raw), "inline formatting or whitespace changed") }
        // Deliberately include repeated redraws of all real manual paragraphs.
        metrics["help_20_warm_redraws_ms"] = ms {
            for _ in 0..<20 { for raw in paragraphs { checksum += markup(raw).characters.count } }
        }
        if __MODERN_HELP__ {
            DispatchQueue.concurrentPerform(iterations: 20) { index in
                let raw = paragraphs[index % paragraphs.count]
                require(markup(raw) == originalMarkup(raw), "concurrent cache read")
            }
        }
        // Cache eviction or an unrelated article must not change markup.
        for i in 0..<1000 { _ = markup("**eviction fixture \(i)**") }
        for raw in paragraphs { require(markup(raw) == originalMarkup(raw), "cache refill changed attributes") }
        var value = WidgetSnapshot(todayTotalTokens: 100, usagePeriodLabel: "月", unitStyle: "metric", isDark: true,
            modelBreakdown: [.init(model: "sample", totalTokens: 100)], activeProviderName: "fixture", activeModelName: "sample", balanceText: nil,
            totalSessionCount: 1, busySessionCount: 0,
            sessions: [.init(pid: 1, status: "idle", model: "sample", contextTokens: 100, contextLimit: 200, contextRatio: 0.5, projectFolder: "fixture", currentActivity: "", waiting: false)],
            cursorSessions: [], externalSessions: [], updatedAt: Date(timeIntervalSince1970: 1))
        metrics["widget_1000_unchanged_submissions_ms"] = ms {
            for i in 0..<1000 { value.updatedAt = Date(timeIntervalSince1970: Double(i)); WidgetSnapshotWriter.submit(value) }
            WidgetSnapshotWriter.drain()
        }
        metrics["widget_unchanged_writes"] = Double(WidgetSnapshotWriter.writes)
        if __STABLE_WRITER__ { require(WidgetSnapshotWriter.writes == 1, "timestamp-only changes must not write or reload") }
        var count = WidgetSnapshotWriter.writes
        value.sessions[0].currentActivity = "changed nested field"
        WidgetSnapshotWriter.submit(value); WidgetSnapshotWriter.drain()
        require(WidgetSnapshotWriter.writes == count + 1, "nested change must publish")
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: WidgetSnapshotWriter.lastPayload!)
        require(decoded.sessions[0].currentActivity == value.sessions[0].currentActivity && decoded.updatedAt == value.updatedAt, "snapshot round trip")
        count = WidgetSnapshotWriter.writes
        WidgetSnapshotWriter.submit(value, force: true); WidgetSnapshotWriter.drain()
        require(WidgetSnapshotWriter.writes == count + 1, "forced refresh must publish")
        count = WidgetSnapshotWriter.writes
        BuildChannel.promptsForSystemPermissions = false
        value.todayTotalTokens += 1
        WidgetSnapshotWriter.submit(value, force: true); WidgetSnapshotWriter.drain()
        require(WidgetSnapshotWriter.writes == count, "dev gate bypass")
        BuildChannel.promptsForSystemPermissions = true; PermissionGate.enabled = false
        WidgetSnapshotWriter.submit(value); WidgetSnapshotWriter.drain()
        require(WidgetSnapshotWriter.writes == count, "permission gate bypass")
        PermissionGate.enabled = true
        WidgetSnapshotWriter.submit(value); WidgetSnapshotWriter.drain()
        require(WidgetSnapshotWriter.writes == count + 1, "permission grant must publish")
        require(WidgetCenter.shared.reloads == WidgetSnapshotWriter.writes, "reload/write parity")
        print("CHECKSUM", checksum)
        print("METRICS", String(data: try JSONSerialization.data(withJSONObject: metrics, options: .sortedKeys), encoding: .utf8)!)
    }
}
'''.replace('__SELECTION_CHECK__', '''var results = ResultsFixture(items: items, query: "Claude")
        results.refreshResults(reselect: true)
        require(results.selection == results.filtered.first?.id, "query selection")
        results.selection = results.filtered.last?.id
        let kept = results.selection
        results.refreshResults()
        require(results.selection == kept, "source refresh must keep a surviving selection")
        results.items.removeAll { $0.id == kept }
        results.refreshResults()
        require(results.selection == results.filtered.first?.id, "removed selection must reconcile")
        results.query = "不存在"; results.refreshResults(reselect: true)
        require(results.filtered.isEmpty && results.selection == nil, "empty result selection")''' if modern else '').replace('__MATCH__', matching).replace('__HELP__', help_fn).replace('__PREPARE__', 'let prepared = matches(items, "claude")' if modern else '').replace('__ROWS__', 'prepared' if modern else 'matches(items, "claude")').replace('__COUNT__', 'prepared.count' if modern else 'matches(items, "claude").count').replace('__MODERN_HELP__', str('enum HelpInlineMarkdown' in catalog).lower()).replace('__STABLE_WRITER__', str('.sortedKeys' in writer).lower())

with tempfile.TemporaryDirectory(prefix='claudebar-remaining-') as folder:
    work = Path(folder)
    arms = ['baseline', 'current'] if a.compare else ['current']
    for arm in arms:
        source = work / (arm + '.swift')
        source.write_text(harness(arm == 'baseline'))
        subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(work / arm)], check=True)
    samples = {arm: [] for arm in arms}
    digests = []
    for repetition in range(3 if a.compare else 1):
        for arm in arms if repetition % 2 == 0 else list(reversed(arms)):
            lines = subprocess.check_output([str(work / arm)], text=True).splitlines()
            digests.append(next(line for line in lines if line.startswith('CHECKSUM')))
            samples[arm].append(json.loads(next(line[8:] for line in lines if line.startswith('METRICS '))))
    if len(set(digests)) != 1:
        raise SystemExit('Palette/markup checksum differs between comparison arms')
    result = {'baseline_ref': a.baseline_ref if a.compare else None, 'workload': 'Synthetic 10000 palette items, real static manual paragraphs, synthetic Widget snapshot; optimized production slices; OS effects intercepted',
              'samples': samples, 'medians': {arm: {key: statistics.median(run[key] for run in runs) for key in runs[0]} for arm, runs in samples.items()}}
    if a.output_json:
        a.output_json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print('PASS: stable ranking, full attributed text equality, concurrent cache reads, timestamp deduplication, nested change, forced publication, channel and permission gates, round trip')
