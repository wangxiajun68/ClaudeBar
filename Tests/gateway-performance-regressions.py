#!/usr/bin/env python3
"""Optimized production actor benchmark; no sockets, user data or app launch."""
from pathlib import Path
import argparse
import json
import statistics
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
args = argparse.ArgumentParser()
args.add_argument('--baseline-ref')
options = args.parse_args()
paths = ['Sources/ClaudeBar/Models/FreeModelPool.swift',
         'Sources/ClaudeBar/Utils/GatewayTaskRouter.swift',
         'Sources/ClaudeBar/Utils/FreeModelGateway.swift']
harness = r'''
extension FreeModelGateway {
    func exercise() async throws -> [String:Double] {
        let id = UUID()
        var pool = FreeModelPool(); pool.enabled = true; pool.requestsPerMinute = 60
        let start = Date()
        pool.discoveredAt = start
        pool.catalog = (0..<1000).map { i in
            .init(id:"fixture/\(i)",name:"Fixture",contextLength:32000,supportsTools:true,supportsImages:true,supportsJSON:true,maxOutput:4096)
        }
        pool.members = pool.catalog.suffix(200).map { $0.member(providerID:id) }
        configure(pool,endpoints:[.init(id:id,name:"Fixture",baseURL:"https://openrouter.ai/api/v1",apiKey:"synthetic")])
        let needs = try GatewayRequirements(chat:["messages":[["role":"user","content":"hello"]],"max_tokens":1])
        var durations: [Double] = []
        for i in 0..<1000 {
            // Real sliding-window limits remain enabled. Advance test time
            // rather than relaxing production admission for the benchmark.
            let clock = ContinuousClock.now
            let plan = try await begin(needs,now:start.addingTimeInterval(Double(i)*61))
            finish(plan)
            let d = clock.duration(to:.now).components
            durations.append(Double(d.seconds)*1000 + Double(d.attoseconds)/1e15)
        }
        durations.sort()
        let sampleStart = ContinuousClock.now
        for _ in 0..<10000 { precondition(snapshot(now:start).active == 0) }
        let sample = sampleStart.duration(to:.now).components
        return ["dispatch_p50_ms":durations[500],"dispatch_p95_ms":durations[950],
                "snapshot_10000_ms":Double(sample.seconds)*1000 + Double(sample.attoseconds)/1e15]
    }
}
@main struct Benchmark {
    static func main() async throws {
        let result = try await FreeModelGateway().exercise()
        print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
    }
}
'''

results = {}
with tempfile.TemporaryDirectory(prefix='claudebar-gateway-performance-') as directory:
    folder = Path(directory)
    for label, ref in ([('baseline', options.baseline_ref)] if options.baseline_ref else []) + [('current', None)]:
        sources = []
        for path in paths:
            source = subprocess.check_output(['git', 'show', f'{ref}:{path}'], cwd=root, text=True) if ref else (root/path).read_text()
            if path.endswith('/FreeModelGateway.swift'):
                source = source.split('final class GatewayNetwork:', 1)[0]
            sources.append(source)
        swift = folder/f'{label}.swift'
        swift.write_text('\n'.join(sources) + harness)
        binary = folder/label
        subprocess.run(['swiftc', '-O', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
        samples = [json.loads(subprocess.check_output([str(binary)], text=True, timeout=30)) for _ in range(3)]
        results[label] = {key: statistics.median(sample[key] for sample in samples) for key in samples[0]}
    print(json.dumps({'workload': '200 models / 1000 catalog entries; 1000 admissions; 10000 snapshots; median of 3 optimized runs',
                      'baseline_ref': options.baseline_ref, 'measurements': results}, indent=2))
    # A generous pathological-regression ceiling, not an upstream latency SLA.
    assert results['current']['dispatch_p95_ms'] < 20, results
    assert results['current']['snapshot_10000_ms'] < 3000, results
print('PASS: production routing benchmark, bounded catalog, no network or system integration')
