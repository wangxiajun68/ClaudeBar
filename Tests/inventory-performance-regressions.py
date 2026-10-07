#!/usr/bin/env python3
"""Production inventory and custom-directory transforms; synthetic data only.

Comparison timings are diagnostic, never CI speed thresholds. No app/network,
real user configuration, database or system integration is opened.
"""
from pathlib import Path
import argparse
import json
import statistics
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--compare', action='store_true')
p.add_argument('--baseline-ref', default='HEAD')
p.add_argument('--output-json', type=Path)
a = p.parse_args()

def read(path, old):
    return subprocess.check_output(['git', 'show', a.baseline_ref + ':' + path], cwd=root, text=True) if old else (root/path).read_text()

def decl(text, marker):
    start = text.index(marker); opening = text.index('{', start); depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]

def harness(old):
    models = read('Sources/ClaudeBar/Models/ModelUsage.swift', old)
    inventory = read('Sources/ClaudeBar/Utils/UsageModelInventory.swift', old)
    page = read('Sources/ClaudeBar/Views/Pages/UsageView.swift', old)
    browser = read('Sources/ClaudeBar/Views/Shared/ProviderDirectory.swift', old)
    modern = '@State private var modelRows:' in page
    methods = '\n'.join(decl(browser, marker).replace('private ', '') for marker in ['private var searchTerm:', 'private func searchHaystack(', 'private func matches(', 'private func custom(', 'private func connectionSearchText('])
    source = '''import Foundation
struct Color {}
enum Theme { static let claude = Color(); static let codex = Color(); static let cursor = Color(); enum Ink { static let claude = Color(); static let codex = Color(); static let cursor = Color() } }
struct Provider { struct Model { let name: String }; let id: Int; let name: String; let baseURL: String; let models: [Model] }
struct DirectoryFixture { struct Partition { let custom: [Provider] }; let query: String
''' + methods + '\n}\n'
    source += '\n'.join(decl(models, marker) for marker in ['enum UsageSource', 'struct ModelUsage'])
    source += '\n' + read('Sources/ClaudeBar/Utils/ModelPricing.swift', old) + '\n' + read('Sources/ClaudeBar/Utils/ModelPriceTable.swift', old) + '\n' + inventory
    presentation_check = ''
    if modern:
        source += '\nenum CursorLedger {\n' + decl(read('Sources/ClaudeBar/Utils/CursorLedger.swift', old), '    struct Row:') + '\n}\n'
        source += '@MainActor final class PresentationFixture {\n' + decl(page, '    private struct ModelRequest:').replace('private struct', 'struct') + '\n'
        source += 'var modelRequest: ModelRequest; var rowPublications = 0; var modelRows: [UsageModelInventory.Row] = [] { didSet { rowPublications += 1 } }; var renderedModelRequest: ModelRequest?\ninit(_ request: ModelRequest) { modelRequest = request }\n'
        source += decl(page, '    private func refreshModelRows(').replace('private func', 'func') + '\n}\n'
        presentation_check = r'''let interval = DateInterval(start: Date(timeIntervalSince1970: 1), duration: 86400)
        let request = PresentationFixture.ModelRequest(interval: interval, local: stats, sources: sources,
            cursor: ["cursor-only": .init(model: "cursor-only", inputTokens: 99, costCents: 5)], costs: costs, cursorWindowLabel: "fixture A", ready: true)
        let presentation = PresentationFixture(request)
        await presentation.refreshModelRows(request)
        require(presentation.modelRows.count == 4001 && presentation.renderedModelRequest == request, "initial presentation")
        let oldRows = presentation.modelRows
        let unready = PresentationFixture.ModelRequest(interval: DateInterval(start: interval.end, duration: 86400), local: [], sources: [:], cursor: [:], costs: [:], cursorWindowLabel: "fixture B", ready: false)
        presentation.modelRequest = unready
        await presentation.refreshModelRows(unready)
        require(presentation.modelRows == oldRows && presentation.renderedModelRequest == request, "unready period must retain coherent snapshot")
        await presentation.refreshModelRows(request)
        require(presentation.modelRows == oldRows && presentation.renderedModelRequest == request, "superseded request published")
        let next = PresentationFixture.ModelRequest(interval: unready.interval, local: aliases, sources: [.codex: aliases],
            cursor: ["gpt-5.4": .init(model: "gpt-5.4", inputTokens: 42, costCents: 19)], costs: [:], cursorWindowLabel: "fixture B", ready: true)
        presentation.modelRequest = next
        let cancelledPresentation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await presentation.refreshModelRows(next)
        }
        await cancelledPresentation.value
        require(presentation.modelRows == oldRows && presentation.renderedModelRequest == request, "cancelled request published")
        await presentation.refreshModelRows(next)
        require(presentation.modelRows.count == 1 && presentation.modelRows[0].cursor?.totalTokens == 42 && presentation.renderedModelRequest?.cursor["gpt-5.4"]?.costCents == 19, "new ledger, tokens and money lost")
        let priced = PresentationFixture.ModelRequest(interval: next.interval, local: aliases, sources: next.sources,
            cursor: next.cursor, costs: ["gpt-5.4": .init(model: "gpt-5.4", cost: .init(usd: 6), unpriced: nil)], cursorWindowLabel: "fixture B", ready: true)
        presentation.modelRequest = priced
        await presentation.refreshModelRows(priced)
        require(presentation.modelRows[0].costLine?.cost.usd == 6, "price-only change failed to invalidate")
        let publications = presentation.rowPublications
        await presentation.refreshModelRows(priced)
        require(presentation.rowPublications == publications, "equal result republished")
        let moneyOnly = PresentationFixture.ModelRequest(interval: priced.interval, local: priced.local, sources: priced.sources,
            cursor: ["gpt-5.4": .init(model: "gpt-5.4", inputTokens: 42, costCents: 29)], costs: priced.costs, cursorWindowLabel: "fixture C", ready: true)
        presentation.modelRequest = moneyOnly
        await presentation.refreshModelRows(moneyOnly)
        require(presentation.rowPublications == publications && presentation.renderedModelRequest?.cursorWindowLabel == "fixture C" && presentation.renderedModelRequest?.cursor["gpt-5.4"]?.costCents == 29, "settlement caption and money must advance together")
'''
    # Original independent value oracle for result identity and cost preservation.
    oracle = read('Sources/ClaudeBar/Utils/UsageModelInventory.swift', True).replace('enum UsageModelInventory', 'enum OriginalInventory')
    source += '\n' + oracle
    source += r'''
func require(_ ok: @autoclosure () -> Bool, _ message: String) { if !ok() { fatalError(message) } }
func ms(_ work: () -> Void) -> Double {
    let start = ContinuousClock.now; work()
    let d = start.duration(to: .now).components
    return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
}
func digest(_ rows: [UsageModelInventory.Row]) -> [String] {
    rows.map { "\($0.id)|\($0.local)|\(String(describing: $0.cursor))|\($0.sourceTokens.sorted { $0.key.rawValue < $1.key.rawValue })|\($0.recordedNames.sorted())|\(String(describing: $0.costLine))" }
}
@main struct Probe {
    @MainActor static func main() async {
        let stats = (0..<4000).map { ModelUsage(model: "fixture-model-\($0)", inputTokens: 100 + $0, outputTokens: 20, cacheReadTokens: 10, cacheCreationTokens: 5) }
        let sources: [UsageSource: [ModelUsage]] = [.claude: Array(stats.prefix(2500)), .codex: Array(stats.suffix(1500))]
        let cursor = Array(stats.prefix(1000)) + [ModelUsage(model: "cursor-only", inputTokens: 99)]
        let costs = Dictionary(uniqueKeysWithValues: stats.map { ($0.model, ModelPricing.Estimate.Line(model: $0.model, cost: .init(usd: 1), unpriced: nil)) })
        let rows = UsageModelInventory.rows(local: stats, sources: sources, cursor: cursor, costs: costs)
        let oracle = OriginalInventory.rows(local: stats, sources: sources, cursor: cursor, costs: costs)
        require(rows.count == oracle.count, "inventory count")
        for (row, expected) in zip(rows, oracle) {
            require(row.id == expected.id && row.local == expected.local && row.cursor == expected.cursor && row.sourceTokens == expected.sourceTokens && row.recordedNames == expected.recordedNames && row.costLine == expected.costLine, "inventory value changed")
        }
        let aliases = [ModelUsage(model: "gpt-5.4-20250101", inputTokens: 100), ModelUsage(model: "gpt-5.4", outputTokens: 20), ModelUsage(model: "zero")]
        let missing = UsageModelInventory.rows(local: aliases, sources: [.codex: aliases], cursor: [], costs: [:])
        require(missing.count == 1 && missing[0].local.totalTokens == 120 && missing[0].costLine?.unpricedTokens == 120, "aliases, zero rows or missing costs changed")
        // Partial coverage: `costs` comes from the period-wide estimate, whose
        // keys are computed model names. An alias whose *own* slug has no
        // entry must contribute its tokens to the unpriced total rather than
        // vanish from the money picture — the same 102 all-missing case above
        // cannot see this, because with no line at all every name is missing.
        let partial = UsageModelInventory.rows(local: aliases, sources: [.codex: aliases], cursor: [],
            costs: [ModelPricing.canonical("gpt-5.4"): .init(model: ModelPricing.canonical("gpt-5.4"), cost: .init(usd: 1), unpriced: nil)])
        require(partial.count == 1, "aliases must still merge to one row")
        require(partial[0].costLine?.cost.usd == 1 && partial[0].costLine?.unpricedTokens == 100,
                "only the priced alias is costed; the unpriced one stays counted as tokens: \(String(describing: partial[0].costLine))")
        require(partial[0].costLine?.unpriced == .unknownSlug,
                "a partially priced row must say part of it has no table entry")
        var metrics: [String: Double] = [:]; var checksum = 0
        metrics["inventory_single_prepare_ms"] = ms { checksum += UsageModelInventory.rows(local: stats, sources: sources, cursor: cursor, costs: costs).count }
        metrics["inventory_prepare_and_20_reads_ms"] = ms {
            PREPARE
            for _ in 0..<20 { checksum += READ.count }
        }
        let providers = (0..<4000).map { i in Provider(id: i, name: "供应商 \(i) Claude", baseURL: "https://fixture.invalid/\(i)", models: (0..<20).map { Provider.Model(name: "模型 \($0) Cursor") }) }
        let partition = DirectoryFixture.Partition(custom: providers)
        for q in ["", "  \n", " Claude ", "Cursor", "模型", "不存在", "https://fixture.invalid/3999"] {
            let actual = DirectoryFixture(query: q).custom(in: partition).map(\.id)
            let term = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let expected = providers.filter { term.isEmpty || ([$0.name, $0.baseURL] + $0.models.map(\.name)).joined(separator: " ").lowercased().contains(term) }.map(\.id)
            require(actual == expected, "custom directory ordering/search changed")
        }
        for (label, query) in [("empty", ""), ("active", " Claude ")] {
            metrics["directory_20_\(label)_queries_ms"] = ms {
                for _ in 0..<20 { checksum += DirectoryFixture(query: query).custom(in: partition).count }
            }
        }
        if CANCELLABLE {
            let cancelled = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return UsageModelInventory.rows(local: stats, sources: sources, cursor: cursor, costs: costs)
            }
            let cancelledRows = await cancelled.value
            require(cancelledRows.isEmpty, "cancelled preparation did full work")
        }
        PRESENTATION_CHECK
        print("CHECKSUM", checksum)
        print("METRICS", String(data: try! JSONSerialization.data(withJSONObject: metrics, options: .sortedKeys), encoding: .utf8)!)
    }
}
'''
    source = source.replace('PREPARE', 'let prepared = UsageModelInventory.rows(local: stats, sources: sources, cursor: cursor, costs: costs)' if modern else '')
    source = source.replace('READ.count', 'prepared.count' if modern else 'UsageModelInventory.rows(local: stats, sources: sources, cursor: cursor, costs: costs).count')
    source = source.replace('PRESENTATION_CHECK', presentation_check)
    return source.replace('CANCELLABLE', str('Task.isCancelled' in inventory).lower())

with tempfile.TemporaryDirectory(prefix='claudebar-inventory-') as folder:
    work = Path(folder); arms = ['baseline','current'] if a.compare else ['current']
    for arm in arms:
        path = work/(arm+'.swift'); path.write_text(harness(arm=='baseline'))
        subprocess.run(['swiftc','-O','-parse-as-library',str(path),'-o',str(work/arm)],check=True)
    samples={arm:[] for arm in arms}; checks=[]
    for repetition in range(3 if a.compare else 1):
        for arm in arms if repetition%2==0 else list(reversed(arms)):
            lines=subprocess.check_output([str(work/arm)],text=True).splitlines()
            checks.append(next(s for s in lines if s.startswith('CHECKSUM')))
            samples[arm].append(json.loads(next(s[8:] for s in lines if s.startswith('METRICS '))))
    assert len(set(checks))==1,'cross-arm checksum changed'
    result={'workload':'4000 synthetic inventory models, 1001 Cursor models; 20 result reads; 4000 providers × 20 models, 20 queries; no app or system integration','baseline_ref':a.baseline_ref if a.compare else None,'samples':samples,'medians_ms':{arm:{key:statistics.median(run[key] for run in runs) for key in runs[0]} for arm,runs in samples.items()}}
    if a.output_json:a.output_json.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(result,ensure_ascii=False,indent=2))
    print('PASS: exact inventory values, source/alias/cost preservation, stable custom search and cooperative cancellation')
