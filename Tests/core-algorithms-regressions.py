#!/usr/bin/env python3
"""Production family routing, synthetic/temporary data only."""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline-dir', type=Path)
p.add_argument('--keep-fixture', type=Path)
p.add_argument('--output-json', type=Path)
a = p.parse_args()


def declaration(text, marker):
    start = text.index(marker); end = text.index('{', start) + 1; depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]


def read(name):
    return ((a.baseline_dir / name) if a.baseline_dir else root / 'Sources/ClaudeBar/Utils' / name).read_text()


index = read('UsageIndex.swift')
oracle = (root / 'Tests/fixtures/session-family-baseline.swift').read_text()
if 'static func sessionFamilyRollups(' in index:
    family = 'struct ProductionFamilyRollups {\n' + declaration(index, '    static func sessionFamilyRollups(') + '\n}\n'
else:
    start = index.index('        var result: [String: [ModelUsage]] = [:]', index.index('static func fetchSessionFamilies'))
    end = index.index('        return result\n    }', start) + len('        return result\n    }')
    signature = oracle[:oracle.index('        var result:')].replace('OriginalFamilyRollups', 'ProductionFamilyRollups')
    family = signature + index[start:end] + '\n}\n'
models = (root / 'Sources/ClaudeBar/Models/ModelUsage.swift').read_text()
swift = 'import Foundation\nimport Darwin\nenum UsageSource { case claude, codex, thirdParty }\n'
swift += '\n'.join(declaration(models, m) for m in ['struct ModelUsage', 'struct DayUsage'])
swift += oracle + family
swift += r'''
func canonical(_ rows: [ModelUsage]) -> [ModelUsage] { rows.sorted { $0.model < $1.model } }
func same(_ a: [String: [ModelUsage]], _ b: [String: [ModelUsage]]) -> Bool {
    a.mapValues(canonical) == b.mapValues(canonical)
}
func milliseconds(_ body: () -> Void) -> Double {
    let start = ContinuousClock.now; body()
    let d = start.duration(to: .now)
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
func sample(_ body: () -> Void) -> Double {
    var times: [Double] = []
    for _ in 0..<5 { times.append(milliseconds(body)) }
    return times.sorted()[2]
}
@main struct Regression {
    static func main() throws {
        var metrics: [String: Double] = [:]
        var seed: UInt64 = 0x29345
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(n)) }
        func usage(_ n: Int) -> ModelUsage {
            .init(model: "m\(n % 7)", calls: n + 1, inputTokens: n * 3, outputTokens: n,
                  cacheReadTokens: n * 2, cacheCreationTokens: n % 4)
        }
        // Path fallbacks are independent of metadata; one file can belong to
        // more than one requested family, but only once within each family.
        let paths: [String: [ModelUsage]] = [
            "claude:/p/root.jsonl": [usage(1)],
            "claude:/p/root/subagents/workflows/done/agent.jsonl": [usage(2)],
            "claude:/p/root/subagents/nested/subagents/child.jsonl": [usage(3)],
            "claude:/p/root-other.jsonl": [usage(4)],
            "claude:/p/根😀/subagents/leaf.jsonl": [usage(5)],
            "claude:/p/a.b.jsonl": [usage(6)],
            "claude:/p/xsubagents/rootish.jsonl": [usage(7)],
            "claude:/p/root/subagents": [usage(8)],
            "claude:/subagents/leaf.jsonl": [usage(9)]
        ]
        let claudeIDs: Set<String> = ["root", "root-other", "nested", "根😀", "a.b", "missing", "child", "claude:"]
        precondition(same(ProductionFamilyRollups.sessionFamilyRollups(source: .claude, ids: claudeIDs, byPath: paths, pathIDs: [:], parents: [:]),
                          OriginalFamilyRollups.sessionFamilyRollups(source: .claude, ids: claudeIDs, byPath: paths, pathIDs: [:], parents: [:])))
        var graph: [String: String] = ["child": "middle", "middle": "root", "a": "b", "b": "a", "tail": "a", "self": "self"]
        var pathIDs = ["codex:/archive/rollout-child.jsonl": "child", "codex:/p/rollout-a.jsonl": "a",
                       "codex:/p/rollout-b.jsonl": "b", "codex:/p/rollout-tail.jsonl": "tail",
                       "codex:/p/rollout-self.jsonl": "self", "codex:/p/rollout-other-root.jsonl": "child"]
        var codexPaths = pathIDs.keys.enumerated().reduce(into: [String: [ModelUsage]]()) { $0[$1.element] = [usage($1.offset + 1)] }
        codexPaths["codex:/p/rollout-no-header-with-hyphens.jsonl"] = [usage(9)]
        codexPaths["codex:/p/no-parent-no-header-with-hyphens.jsonl/extra"] = [usage(10)]
        let graphIDs: Set<String> = ["root", "middle", "child", "a", "b", "tail", "self", "other-root", "with-hyphens", "hyphens", "missing"]
        func compare() {
            precondition(same(ProductionFamilyRollups.sessionFamilyRollups(source: .codex, ids: graphIDs, byPath: codexPaths, pathIDs: pathIDs, parents: graph),
                              OriginalFamilyRollups.sessionFamilyRollups(source: .codex, ids: graphIDs, byPath: codexPaths, pathIDs: pathIDs, parents: graph)))
        }
        compare(); graph["middle"] = "other-root"; compare()
        pathIDs.removeValue(forKey: "codex:/p/rollout-b.jsonl"); compare()
        // Deterministic random functional graphs cover cycles, missing parents,
        // duplicate header IDs and unmatched filename fallback simultaneously.
        for _ in 0..<60 {
            var parents: [String: String] = [:], metadata: [String: String] = [:], rows: [String: [ModelUsage]] = [:]
            for i in 0..<80 {
                let path = "codex:/p/rollout-n\(i).jsonl"
                rows[path] = [usage(random(15)), usage(random(15))]
                if random(5) > 0 { metadata[path] = "n\(random(80))" }
                if random(4) > 0 { parents["n\(i)"] = "n\(random(90))" }
            }
            let ids = Set((0..<15).map { _ in "n\(random(90))" })
            precondition(same(ProductionFamilyRollups.sessionFamilyRollups(source: .codex, ids: ids, byPath: rows, pathIDs: metadata, parents: parents),
                              OriginalFamilyRollups.sessionFamilyRollups(source: .codex, ids: ids, byPath: rows, pathIDs: metadata, parents: parents)))
        }
        var checksum = 0
        for requests in [8, 64, 256] {
            var rows: [String: [ModelUsage]] = [:], metadata: [String: String] = [:], parents: [String: String] = [:]
            for i in 0..<4000 {
                let path = "codex:/p/rollout-node\(i).jsonl"
                rows[path] = [usage(i % 17)]
                metadata[path] = "node\(i)"
                if i % 16 > 0 { parents["node\(i)"] = "node\(i - 1)" }
            }
            let ids = Set((0..<requests).map { "node\($0 * 16)" })
            let expected = OriginalFamilyRollups.sessionFamilyRollups(source: .codex, ids: ids, byPath: rows, pathIDs: metadata, parents: parents)
            precondition(same(ProductionFamilyRollups.sessionFamilyRollups(source: .codex, ids: ids, byPath: rows, pathIDs: metadata, parents: parents), expected))
            metrics["codex_4000_paths_\(requests)_requested_ms"] = sample {
                let result = ProductionFamilyRollups.sessionFamilyRollups(source: .codex, ids: ids, byPath: rows, pathIDs: metadata, parents: parents)
                checksum += result.values.flatMap { $0 }.reduce(0) { $0 + $1.totalTokens }
            }
            let claudeRows = Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
                ("claude:/p/root\(index / 16)/subagents/a\(index).jsonl", row.value)
            })
            let claudeRequested = Set((0..<requests).map { "root\($0)" })
            precondition(same(ProductionFamilyRollups.sessionFamilyRollups(source: .claude, ids: claudeRequested, byPath: claudeRows, pathIDs: [:], parents: [:]),
                              OriginalFamilyRollups.sessionFamilyRollups(source: .claude, ids: claudeRequested, byPath: claudeRows, pathIDs: [:], parents: [:])))
            metrics["claude_4000_paths_\(requests)_requested_ms"] = sample {
                checksum += ProductionFamilyRollups.sessionFamilyRollups(source: .claude, ids: claudeRequested, byPath: claudeRows, pathIDs: [:], parents: [:]).values.flatMap { $0 }.reduce(0) { $0 + $1.totalTokens }
            }
        }
        // A long chain must not recurse on the Swift call stack.
        var longParents: [String: String] = [:]
        for i in 1..<12000 { longParents["n\(i)"] = "n\(i - 1)" }
        precondition(same(ProductionFamilyRollups.sessionFamilyRollups(source: .codex, ids: ["n0"], byPath: ["codex:/p/rollout-n11999.jsonl": [usage(1)]], pathIDs: ["codex:/p/rollout-n11999.jsonl": "n11999"], parents: longParents),
                          OriginalFamilyRollups.sessionFamilyRollups(source: .codex, ids: ["n0"], byPath: ["codex:/p/rollout-n11999.jsonl": [usage(1)]], pathIDs: ["codex:/p/rollout-n11999.jsonl": "n11999"], parents: longParents)))
        metrics["codex_dense_12000_chain_ms"] = milliseconds {
            let allIDs = Set((0..<12000).map { "n\($0)" })
            let dense = ProductionFamilyRollups.sessionFamilyRollups(source: .codex, ids: allIDs,
                byPath: ["codex:/p/rollout-n11999.jsonl": [usage(1)]], pathIDs: ["codex:/p/rollout-n11999.jsonl": "n11999"], parents: longParents)
            precondition(dense.count == 12000 && dense.values.allSatisfy { $0 == [usage(1)] })
        }
        var info = rusage(); getrusage(RUSAGE_SELF, &info)
        metrics["process_peak_rss_bytes"] = Double(info.ru_maxrss)
        print("METRICS " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
        print("PASS production family routing, random graphs/cycles/long chains")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-core-algorithms-') as tmp:
    folder = a.keep_fixture or Path(tmp); folder.mkdir(parents=True, exist_ok=True)
    path = folder / 'probe.swift'; path.write_text(swift); binary = folder / 'probe'
    subprocess.run(['swiftc', '-O', '-g', '-parse-as-library', '-target', 'arm64-apple-macos15.0', str(path), '-o', str(binary)], check=True)
    data = Path(tmp) / 'data'; data.mkdir()
    output = subprocess.check_output([str(binary), str(data)], text=True); print(output, end='', flush=True)
    if a.output_json:
        metrics = next(json.loads(line[8:]) for line in output.splitlines() if line.startswith('METRICS '))
        a.output_json.write_text(json.dumps(metrics, indent=2) + '\n')
