#!/usr/bin/env python3
"""Real VPN lookup ownership and endpoint sweep; fake transport, no VPN or network."""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--probe', action='store_true')
p.add_argument('--baseline-ref')
p.add_argument('--output-json', type=Path)
a = p.parse_args()
path = 'Sources/ClaudeBar/Utils/VpnNetProbe.swift'
source = subprocess.check_output(['git', 'show', f'{a.baseline_ref}:{path}'], cwd=root, text=True) if a.baseline_ref else (root / path).read_text()


def braced(signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')


swift = r'''
import Foundation
struct VpnIPInfo: Equatable { var ip = "" }
@MainActor final class VpnManager {
    static let shared = VpnManager()
    let mixedPortIfRunning: Int? = 12345
}
@MainActor final class ProbeFixture {
    static let defaultSites = ["fixture"]
    var sites = defaultSites
    var ipInfo: VpnIPInfo?
    var ipError: String?
    var ipLoading = false
    private var ipLookup: Task<Void, Never>?
    private var ipGeneration = UUID()
    static var pending: [CheckedContinuation<VpnIPInfo?, Never>] = []
    static func fetchIP(proxyPort: Int?) async -> VpnIPInfo? {
        await withCheckedContinuation { pending.append($0) }
    }
RESET
REFRESH
PERFORM
}
@MainActor final class EndpointFixture {
ENDPOINTS
TYPE
    static var pending: CheckedContinuation<VpnIPInfo?, Never>?
    static var queries = 0
    private static func fetchOne(_ endpoint: IPEndpoint, proxyPort: Int?) async -> VpnIPInfo? {
        queries += 1
        if queries == 1 { return await withCheckedContinuation { pending = $0 } }
        return nil
    }
SWEEP
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        if PROBE { print("BASELINE VIOLATION:", message) } else { fatalError(message) }
    }
}
@main struct Regression {
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        fatalError("controlled transport did not arrive")
    }
    @MainActor static func main() async {
        let probe = ProbeFixture()
        let first = Task { await probe.refreshIP() }
        await until { ProbeFixture.pending.count == 1 }
        probe.reset()
        let latest = Task { await probe.refreshIP() }
        await until { ProbeFixture.pending.count == 2 }
        ProbeFixture.pending[0].resume(returning: .init(ip: "obsolete"))
        await first.value
        require(probe.ipInfo == nil && probe.ipLoading, "old result changed reset/replacement state")
        let duplicate = Task { await probe.refreshIP() }
        try? await Task.sleep(for: .milliseconds(20))
        let requests = ProbeFixture.pending.count
        require(requests == 2, "old defer cleared new handle and admitted overlap")
        ProbeFixture.pending[1].resume(returning: .init(ip: "latest"))
        if requests > 2 { ProbeFixture.pending[2].resume(returning: .init(ip: "latest")) }
        await latest.value; await duplicate.value
        require(probe.ipInfo?.ip == "latest" && !probe.ipLoading, "latest lookup did not settle")
        let beforeSleep = ProbeFixture.pending.count
        let delayed = Task { await probe.refreshIP(afterNodeSwitch: true) }
        await until { probe.ipLoading }
        probe.reset()
        try? await Task.sleep(for: .milliseconds(20))
        let afterSleep = ProbeFixture.pending.count
        require(afterSleep == beforeSleep, "cancelled node-switch sleep still started a query")
        if afterSleep > beforeSleep { ProbeFixture.pending[beforeSleep].resume(returning: nil) }
        await delayed.value
        require(probe.ipInfo == nil && probe.ipError == nil && !probe.ipLoading, "reset state was republished")
        let beforeCancel = ProbeFixture.pending.count
        let cancelled = Task { await probe.refreshIP() }
        await until { ProbeFixture.pending.count == beforeCancel + 1 }
        cancelled.cancel()
        ProbeFixture.pending[beforeCancel].resume(returning: .init(ip: "cancelled-answer"))
        await cancelled.value
        require(probe.ipInfo == nil && probe.ipError == nil && !probe.ipLoading, "cancelled caller published its answer")
        probe.reset()
        let sweep = Task { await EndpointFixture.fetchIP(proxyPort: nil) }
        await until { EndpointFixture.pending != nil }
        sweep.cancel(); EndpointFixture.pending?.resume(returning: nil)
        let result = await sweep.value
        require(result == nil && EndpointFixture.queries == 1, "cancelled sweep continued to later endpoints")
        let countAfterCancel = EndpointFixture.queries
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await EndpointFixture.fetchIP(proxyPort: nil)
        }
        _ = await preCancelled.value
        require(EndpointFixture.queries == countAfterCancel, "pre-cancelled sweep queried endpoints")
        let metrics = ["overlap_fixture_total_queries": requests, "cancelled_sleep_queries": afterSleep - beforeSleep, "cancelled_sweep_queries": countAfterCancel, "pre_cancelled_sweep_queries": EndpointFixture.queries - countAfterCancel]
        print("METRICS " + String(data: try! JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), encoding: .utf8)!)
        print(PROBE ? "Baseline lifecycle violations reported" : "PASS: reset/replacement ownership, no duplicate query, parent cancellation, node-switch wait and cancelled endpoint sweep")
    }
}
'''
endpoints = source[source.index('    private static let ipEndpoints:'):source.index('    private struct IPEndpoint')]
for key, value in {'RESET': braced('    func reset()'), 'REFRESH': braced('    func refreshIP('),
                   'PERFORM': braced('    private func performIPLookup('), 'TYPE': braced('    private struct IPEndpoint'),
                   'ENDPOINTS': endpoints, 'SWEEP': braced('    static func fetchIP('), 'PROBE': str(a.probe).lower()}.items():
    swift = swift.replace(key, value)
with tempfile.TemporaryDirectory(prefix='claudebar-vpn-ownership-') as folder:
    source_path = Path(folder) / 'Regression.swift'
    source_path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source_path), '-o', str(binary)], check=True)
    output = subprocess.check_output([str(binary)], text=True)
    print(output.strip())
    if a.output_json:
        metrics = json.loads(next(line.removeprefix('METRICS ') for line in output.splitlines() if line.startswith('METRICS ')))
        a.output_json.write_text(json.dumps(metrics, indent=2) + '\n')
