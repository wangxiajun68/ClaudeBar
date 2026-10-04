#!/usr/bin/env python3
"""Replay measured hot paths with synthetic logs and usage; no app is started.

--compare alternates HEAD and working-tree -O executables. Timing is diagnostic;
semantic checks, including an independent result oracle, run in both arms.
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
args = p.parse_args()


def read(path, baseline=False):
    if baseline:
        return subprocess.check_output(['git', 'show', args.baseline_ref + ':' + path], cwd=root, text=True)
    return (root / path).read_text()


def declaration(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def harness(baseline):
    monitor = read('Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift', baseline)
    recovery = declaration(monitor, '    private static func recoverBeforeTail(').replace('private static func', 'static func')
    models = read('Sources/ClaudeBar/Models/ModelUsage.swift')
    pricing = read('Sources/ClaudeBar/Utils/ModelPricing.swift')
    source = 'import Foundation\n'
    source += 'enum UsageSource: CaseIterable { case claude, codex, thirdParty }\n'
    source += declaration(models, 'struct ModelUsage') + '\n'
    source += declaration(models, 'enum UsageProviderAttribution') + '\n'
    source += 'enum ModelPricing {\n'
    source += declaration(pricing, '    private static let snapshotSuffixes:') + '()\n'
    source += declaration(pricing, '    static func canonical(') + '\n'
    source += declaration(pricing, '    private static func tierSuffix(') + '\n}\n'
    source += '''enum Recovery {
        static let codexLifecycleLookback: UInt64 = 24 * 1024 * 1024
        static let codexLifecycleLineCap = 65_536
    ''' + recovery + '\n}\n'
    page = read('Sources/ClaudeBar/Views/Pages/UsageView.swift', True) if baseline else ''
    if baseline and 'private var providerGroups:' in page:
        group = declaration(page, 'private struct UsageProviderGroup:').replace('private struct', 'struct')
        body = declaration(page, '    private var providerGroups:')
        body = body[body.index('{') + 1:-1]
        body = body.replace('providerStore.providers', 'claudeProviders').replace('codexStore.providers', 'codexProviders')
        body = body.replace('        let interval = UsageStats.interval(for: providerStore.usagePeriod, reference: providerStore.usageReferenceDate)\n', '')
        body = body.replace('(attributionInterval == interval ? officialCodexUsage : [])', 'officialCodex')
        body = body.replace('providerStore.usageBySource', 'sources')
        source += group + '''
struct Provider {
    struct Model { let name: String }
    let name: String
    let models: [Model]
    var asDisplayProvider: Provider { self }
}
enum UsageProviderInventory {
    struct Owner { let source: UsageSource; let name: String; let models: [String] }
    static func groups(sources: [UsageSource: [ModelUsage]], owners: [Owner], officialCodex: [ModelUsage]) -> [UsageProviderGroup] {
        let claudeProviders = owners.filter { $0.source == .claude }.map { Provider(name: $0.name, models: $0.models.map { Provider.Model(name: $0) }) }
        let codexProviders = owners.filter { $0.source == .codex }.map { Provider(name: $0.name, models: $0.models.map { Provider.Model(name: $0) }) }
        ''' + body + '\n    }\n}\n'
    else:
        source += read('Sources/ClaudeBar/Utils/UsageProviderInventory.swift', baseline)
    source += r'''
func require(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
    if !condition() { fputs("FAIL \(line): \(message)\n", stderr); exit(1) }
}
@main struct Regression {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let log = directory.appendingPathComponent("synthetic.jsonl")
        func event(_ type: String) -> String {
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"}}"
        }
        func tool(_ name: String, kind: String = "custom_tool_call") -> String {
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"\(kind)\",\"name\":\"\(name)\"}}"
        }
        func recover(_ data: Data, end: UInt64? = nil) throws -> (open: Bool?, activity: String) {
            try data.write(to: log)
            let handle = try FileHandle(forReadingFrom: log)
            defer { try? handle.close() }
            return Recovery.recoverBeforeTail(handle: handle, before: end ?? UInt64(data.count))
        }
        func check(_ text: String, open: Bool?, activity: String) throws {
            let got = try recover(Data(text.utf8))
            precondition(got.open == open && got.activity == activity, "lifecycle/order oracle: expected \(String(describing: open))/\(activity), got \(String(describing: got.open))/\(got.activity)")
        }
        try check("", open: nil, activity: "")
        try check(event("task_started") + "\n" + tool("执行😀") + "\n", open: true, activity: "执行😀")
        try check(event("task_started") + "\n" + tool("old") + "\n" + event("task_complete") + "\n" + tool("new", kind: "function_call"), open: false, activity: "new")
        try check(tool("old") + "\n" + event("task_started") + "\n" + tool("") + "\n" + event("turn_aborted") + "\n" + "invalid task_started custom_tool_call", open: false, activity: "old")
        try check("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"text\":\"task_started function_call\"}}\n", open: nil, activity: "")
        // JSON lines use LF; CRLF is accepted. A byte cap applies before UTF-8
        // decoding, including oversized Unicode output and false marker text.
        let huge = "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"name\":\"wrong\",\"output\":\"" + String(repeating: "😀", count: 20_000) + "\"}}"
        try check(event("task_started") + "\n" + tool("real") + "\n" + huge, open: true, activity: "real")
        let capped = Data((event("task_started") + "\n" + String(repeating: "x", count: 24 * 1024 * 1024) + "\n" + event("task_complete") + "\n" + tool("bounded") + "\n").utf8)
        let capResult = try recover(capped)
        precondition(capResult.open == false && capResult.activity == "bounded")
        let partial = Data((event("task_started") + "\n" + tool("partial")).utf8)
        let partialResult = try recover(partial, end: UInt64(partial.count - 4))
        precondition(partialResult.open == true && partialResult.activity.isEmpty)
        var malformed = Data((event("task_started") + "\n" + tool("replace")).utf8)
        malformed.insert(0xFF, at: malformed.count - 3)
        let malformedResult = try recover(malformed)
        precondition(malformedResult.open == true && malformedResult.activity == "replace�")

        typealias Owner = UsageProviderInventory.Owner
        let owners = [Owner(source: .claude, name: "Claude vendor", models: ["claude-sonnet-4-20250514", "shared"]),
                      Owner(source: .codex, name: "Codex vendor", models: ["gpt-5", "shared"]),
                      Owner(source: .codex, name: "second", models: ["shared"])]
        let stats: [UsageSource: [ModelUsage]] = [
            .claude: [.init(model: "claude-sonnet-4", calls: 2, inputTokens: 10, outputTokens: 2), .init(model: "shared", inputTokens: 7)],
            .codex: [.init(model: "gpt-5", calls: 4, inputTokens: 20, outputTokens: 10, cacheReadTokens: 5), .init(model: "shared", inputTokens: 13)],
            .thirdParty: [.init(model: "shared", inputTokens: 17), .init(model: "missing", inputTokens: 19), .init(model: "zero")]]
        let official = [ModelUsage(model: "gpt-5", calls: 1, inputTokens: 5, outputTokens: 99, cacheReadTokens: 2)]
        let groups = UsageProviderInventory.groups(sources: stats, owners: owners, officialCodex: official)
        let totals = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.total.totalTokens) })
        precondition(totals == ["Claude vendor": 19, "Codex vendor": 18, "OpenAI 官方": 17, "未归属": 49])
        precondition(groups.last?.id == "未归属" && Set(groups.map(\.id)).count == groups.count)
        precondition(groups.reduce(0) { $0 + $1.total.totalTokens } == stats.values.flatMap { $0 }.reduce(0) { $0 + $1.totalTokens })
        precondition(groups.first { $0.id == "OpenAI 官方" }!.total.outputTokens == 10)
        // Stores can use the same vendor name with different profile IDs.
        let same = [Owner(source: .claude, name: "one", models: ["shared"]), Owner(source: .codex, name: "one", models: ["shared"])]
        let union = UsageProviderInventory.groups(sources: [.thirdParty: [.init(model: "shared", inputTokens: 1)]], owners: same, officialCodex: [])
        precondition(union.count == 1 && union[0].id == "one")
        precondition(UsageProviderInventory.groups(sources: [:], owners: [], officialCodex: []).isEmpty)

        func ms(_ work: () throws -> Void) rethrows -> Double {
            let start = ContinuousClock.now
            try work()
            let elapsed = start.duration(to: .now).components
            return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        }
        // Simulates a lifecycle/tool pair buried behind 12 MiB of tool output.
        let replay = Data((event("task_started") + "\n" + tool("exec") + "\n" + String(repeating: "x", count: 12 * 1024 * 1024) + "\n").utf8)
        try replay.write(to: log)
        let handle = try FileHandle(forReadingFrom: log)
        defer { try? handle.close() }
        let recoveryMS = ms {
            for _ in 0..<8 {
                let got = Recovery.recoverBeforeTail(handle: handle, before: UInt64(replay.count))
                precondition(got.open == true && got.activity == "exec")
            }
        }
        let manyOwners = (0..<40).map { index in
            Owner(source: index % 2 == 0 ? .claude : .codex, name: "vendor\(index)",
                  models: (0..<100).map { "model-\($0)-20250514" })
        }
        let manyStats = Dictionary(uniqueKeysWithValues: UsageSource.allCases.map { source in
            (source, (0..<100).map { ModelUsage(model: "model-\($0)-20250514", inputTokens: 1 + $0) })
        })
        let groupsMS = ms {
            for _ in 0..<10 {
                let result = UsageProviderInventory.groups(sources: manyStats, owners: manyOwners, officialCodex: [])
                precondition(result.count == 1 && result[0].id == "未归属" && result[0].total.totalTokens == 15_150)
            }
        }
        let metrics = ["lookback_8x12MiB_ms": recoveryMS, "provider_groups_10x4000_configured_models_ms": groupsMS]
        print("METRICS " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
    }
}
'''
    if 'data.withUnsafeBytes' in recovery:
        source = source.replace('        let huge =', '        try check(event("task_started") + "\\r\\n" + tool("CRLF") + "\\r\\n", open: true, activity: "CRLF")\n        let huge =')
    if 'guard !Task.isCancelled' in source:
        source = source.replace('        let groupsMS =', '''        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return UsageProviderInventory.groups(sources: manyStats, owners: manyOwners, officialCodex: [])
        }
        let cancelledGroups = await cancelled.value
        require(cancelledGroups.isEmpty, "cancelled preparation must stop")
        let groupsMS =''')
    return source.replace('precondition(', 'require(')


with tempfile.TemporaryDirectory(prefix='claudebar-measured-') as folder:
    work = Path(folder)
    arms = ['baseline', 'current'] if args.compare else ['current']
    for arm in arms:
        source = work / (arm + '.swift')
        source.write_text(harness(arm == 'baseline'))
        subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(work / arm)], check=True)
    samples = {arm: [] for arm in arms}
    for repetition in range(3 if args.compare else 1):
        for arm in arms if repetition % 2 == 0 else list(reversed(arms)):
            output = subprocess.check_output([str(work / arm), str(work)], text=True)
            samples[arm].append(json.loads(next(line[8:] for line in output.splitlines() if line.startswith('METRICS '))))
    result = {'workload': 'Synthetic logs and providers; optimized production source slices; no app/system integration', 'samples': samples,
              'medians_ms': {arm: {key: statistics.median(run[key] for run in runs) for key in runs[0]} for arm, runs in samples.items()}}
    if args.output_json:
        args.output_json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print('PASS: bounded lifecycle recovery, newest valid fields, malformed UTF-8, Unicode, CRLF, truncated records, ownership ambiguity, official clamping and token conservation')
