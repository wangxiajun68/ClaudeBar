#!/usr/bin/env python3
"""Production JSON rollups and MCP discovery with temporary files/mock children.

--baseline-dir compares a saved pre-change source snapshot with the working tree.
Timings are diagnostics, not CI speed thresholds. No app/client/VPN is started.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline-dir', type=Path)
p.add_argument('--output-json', type=Path)
args = p.parse_args()
paths = ['Sources/ClaudeBar/Utils/UsageJSONStore.swift',
         'Sources/ClaudeBar/Models/MCPToolDiscovery.swift']


def declaration(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def harness(baseline):
    sources = [(args.baseline_dir / Path(path).name if baseline else root / path).read_text() for path in paths]
    models = (root / 'Sources/ClaudeBar/Models/ModelUsage.swift').read_text()
    connection = (root / 'Sources/ClaudeBar/Models/ConnectorManager.swift').read_text()
    source = 'import Foundation\nimport Darwin\n'
    source += '\n'.join(declaration(models, marker) for marker in ['struct ModelUsage', 'struct DayUsage'])
    source += '\n' + declaration(connection, 'struct MCPConnection') + '\n'
    source += (root / 'Sources/ClaudeBar/Utils/JSONLineCollector.swift').read_text() + '\n'
    source += '''
enum FilePaths {
    static var root = URL(fileURLWithPath: CommandLine.arguments[1])
    static var usageFilesJSON: URL { root.appendingPathComponent("files.json") }
    static var usageRollupJSONL: URL { root.appendingPathComponent("rollup.jsonl") }
}
'''
    source += '\n'.join(sources)
    source += r'''
func require(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    guard condition() else { print("FAIL \(line): \(message)"); exit(1) }
}
@main struct Regression {
    static func ms(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now; try body()
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
    static func main() async throws {
        let store = UsageJSONStore.shared
        var metrics: [String: Double] = [:]
        func row(_ path: String, _ day: Int, _ input: Int = 10) -> UsageJSONStore.RollupRec {
            .init(path: path, day: String(format: "2026-09-%02d", day / 2 + 1), model: "m\(day % 2)",
                  calls: 1, input: input, output: 3, cacheRead: 4, cacheCreate: 5)
        }
        store.load()
        metrics["json_seed_ms"] = ms {
            for path in 0..<2000 { store.addRollup(path: "claude:\(path).jsonl", rows: (0..<32).map { row("claude:\(path).jsonl", $0) }) }
        }
        require(store.fetch(startDay: "", endDay: "9999").reduce(0) { $0 + $1.totalTokens } == 1_408_000, "seed conservation")
        metrics["json_replace_800_ms"] = ms {
            for _ in 0..<2 {
                for path in 0..<400 { store.replaceRollup(path: "claude:\(path).jsonl", rows: (0..<32).map { row("claude:\(path).jsonl", $0, 20) }) }
            }
        }
        var checksum = 0
        metrics["json_session_400_ms"] = ms {
            for path in 0..<400 {
                checksum += store.fetchSession(pathPrefix: "claude:", pathSuffix: ":\(path).jsonl").reduce(0) { $0 + $1.totalTokens }
            }
        }
        require(checksum == 409_600, "session conservation")
        metrics["json_delete_400_ms"] = ms { for path in 0..<400 { store.deletePath("claude:\(path).jsonl") } }
        require(store.fetch(startDay: "", endDay: "9999").reduce(0) { $0 + $1.totalTokens } == 1_126_400, "delete conservation")
        store.replaceRollup(path: "claude:1600.jsonl", rows: [])
        require(store.fetchSession(pathPrefix: "claude:", pathSuffix: ":1600.jsonl").isEmpty, "empty replacement")
        // Row.path owns the row; preserve behavior even if it differs from the argument.
        store.replaceRollup(path: "missing", rows: [row("codex:foreign", 0)])
        store.addRollup(path: "missing", rows: [row("codex:foreign", 0)])
        require(store.fetchSession(pathPrefix: "codex:", pathSuffix: "foreign").first?.calls == 2, "foreign-row add")
        store.deletePath("codex:foreign")
        require(store.fetchSession(pathPrefix: "codex:", pathSuffix: "foreign").isEmpty, "foreign-row removal")
        let a = UsageJSONStore.RollupRec(path: "p", day: "d\u{1F}x", model: "m", calls: 1, input: 7, output: 0, cacheRead: 0, cacheCreate: 0)
        let b = UsageJSONStore.RollupRec(path: "p\u{1F}d", day: "x", model: "m", calls: 2, input: 9, output: 0, cacheRead: 0, cacheCreate: 0)
        store.replaceRollup(path: "p", rows: [a])
        store.replaceRollup(path: b.path, rows: [b])
        store.deletePath("p")
        require(store.fetchSession(pathPrefix: b.path, pathSuffix: "d").first?.inputTokens == 9, "composite collision transfer")
        store.deletePath(b.path)
        store.save(); store.reset(); store.load()
        require(store.fetchSession(pathPrefix: "claude:", pathSuffix: ":1600.jsonl").isEmpty, "reloaded index empty path")
        require(store.fetchSession(pathPrefix: "claude:", pathSuffix: ":1601.jsonl").reduce(0) { $0 + $1.totalTokens } == 704, "reloaded index")
        store.deletePath("claude:1601.jsonl"); store.save(); store.reset(); store.load()
        require(store.fetchSession(pathPrefix: "claude:", pathSuffix: ":1601.jsonl").isEmpty, "persisted delete")
        let fm = FileManager.default
        let config = FilePaths.root.appendingPathComponent("mock-config.json")
        let script = CommandLine.arguments[2], python = CommandLine.arguments[3]
        func connection(_ mode: String, _ marker: String) -> MCPConnection {
            MCPConnection(command: python, arguments: [script, mode, FilePaths.root.appendingPathComponent(marker).path], environment: [:])
        }
        let tools = try await MCPToolDiscovery.list(connection: connection("normal", "normal"), from: config)
        require(tools.map(\.name) == ["one", "two"], "pagination")
        require(tools[0].argumentNames == ["a", "z"] && tools[1].description == "暂无描述", "summary schema/default")
        for mode in ["eof", "error", "invalid"] {
            do { _ = try await MCPToolDiscovery.list(connection: connection(mode, mode), from: config); require(false, "accepted \(mode)") }
            catch is MCPToolDiscovery.DiscoveryError {}
        }
        do { _ = try await MCPToolDiscovery.list(connection: .init(command: "npx", arguments: [], environment: [:]), from: config); require(false, "runner accepted") }
        catch MCPToolDiscovery.DiscoveryError.unsupportedRunner {}
        func waitFor(_ url: URL) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !fm.fileExists(atPath: url.path) {
                require(ContinuousClock.now < deadline, "missing mock readiness \(url.lastPathComponent)")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        // Cancel both initialize and a later tools/list wait. Child readiness
        // files establish the race point without guessing process start time.
        for mode in ["slow-init", "slow-page"] {
            let marker = FilePaths.root.appendingPathComponent(mode)
            let worker = Task { try await MCPToolDiscovery.list(connection: connection(mode, mode), from: config) }
            try await waitFor(marker.appendingPathExtension("ready"))
            let start = ContinuousClock.now
            worker.cancel()
            do { _ = try await worker.value; require(__BASELINE__, "cancelled read returned success") }
            catch is CancellationError {}
            let duration = start.duration(to: .now)
            metrics["mcp_cancel_\(mode)_ms"] = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            let pid = Int32(try String(contentsOf: marker.appendingPathExtension("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while kill(pid, 0) == 0 {
                require(ContinuousClock.now < deadline, "owned child still alive after cancellation")
                try await Task.sleep(for: .milliseconds(5))
            }
            if !__BASELINE__ { require(!fm.fileExists(atPath: marker.appendingPathExtension("answered").path), "cancel waited for delayed response") }
        }
        if !__BASELINE__ {
            let marker = FilePaths.root.appendingPathComponent("precancel")
            let cancelled = Task { () throws -> [MCPToolSummary] in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await MCPToolDiscovery.list(connection: connection("slow-init", "precancel"), from: config)
            }
            do { _ = try await cancelled.value; require(false, "pre-cancel returned success") }
            catch is CancellationError {}
            require(!fm.fileExists(atPath: marker.appendingPathExtension("pid").path), "pre-cancel launched child")
            // Repeated cancellation around launch must still resume once and
            // release the process; normal discovery remains usable afterwards.
            for index in 0..<20 {
                let task = Task { try await MCPToolDiscovery.list(connection: connection("normal", "race\(index)"), from: config) }
                task.cancel()
                do { _ = try await task.value } catch is CancellationError {}
            }
            let afterCancellation = try await MCPToolDiscovery.list(connection: connection("normal", "after-cancel"), from: config)
            require(afterCancellation.count == 2, "discovery after cancellation")
        }
        print("METRICS " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
    }
}
'''.replace('__BASELINE__', 'true' if baseline else 'false')
    return source


mock = r'''
import json, os, sys, time
from pathlib import Path
mode, marker = sys.argv[1], Path(sys.argv[2])
marker.with_suffix(marker.suffix + '.pid').write_text(str(os.getpid()))
for line in sys.stdin:
    request = json.loads(line)
    method, ident = request.get('method'), request.get('id')
    if ident is None:
        continue
    if mode == 'eof':
        break
    if (mode == 'slow-init' and method == 'initialize') or (mode == 'slow-page' and method == 'tools/list'):
        marker.with_suffix(marker.suffix + '.ready').write_text('ready')
        time.sleep(1.2)
        marker.with_suffix(marker.suffix + '.answered').write_text('answered')
    if mode == 'error':
        response = {'error': {'code': -32000}}
    elif mode == 'invalid':
        response = {'result': 'invalid'}
    elif method == 'initialize':
        response = {'result': {'protocolVersion': '2025-06-18'}}
    elif request.get('params', {}).get('cursor') == 'next':
        response = {'result': {'tools': [{'name': 'two'}]}}
    else:
        response = {'result': {'tools': [{'name': 'one', 'description': 'fixture', 'inputSchema': {'properties': {'z': {}, 'a': {}}}}], 'nextCursor': 'next'}}
    print(json.dumps(dict(jsonrpc='2.0', id=ident, **response)), flush=True)
'''

with tempfile.TemporaryDirectory(prefix='claudebar-backend-perf-') as folder:
    work = Path(folder)
    server = work / 'mock.py'
    server.write_text(mock)
    binaries = {}
    for baseline in ([True, False] if args.baseline_dir else [False]):
        name = 'before' if baseline else 'after'
        source, binary = work / (name + '.swift'), work / name
        source.write_text(harness(baseline))
        subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
        binaries[name] = binary
    samples = {name: [] for name in binaries}
    for repetition in range(3 if args.baseline_dir else 1):
        for name in list(binaries)[::(-1 if repetition % 2 else 1)]:
            storage = work / (name + str(repetition)); storage.mkdir()
            run = subprocess.run(['/usr/bin/time', '-l', str(binaries[name]), str(storage), str(server), sys.executable], capture_output=True, text=True, timeout=90)
            if run.returncode:
                raise SystemExit(name + '\n' + run.stdout + run.stderr)
            metrics = json.loads(next(line[8:] for line in run.stdout.splitlines() if line.startswith('METRICS ')))
            metrics['peak_rss_mib'] = int(re.search(r'(\d+)\s+maximum resident set size', run.stderr).group(1)) / 1024 / 1024
            samples[name].append(metrics)
    medians = {name: {key: statistics.median(run[key] for run in runs) for key in runs[0]} for name, runs in samples.items()}
    for name in samples:
        print(name + ': ' + json.dumps(samples[name], sort_keys=True))
        print(name + ' medians: ' + json.dumps(medians[name], sort_keys=True))
    if args.output_json:
        args.output_json.write_text(json.dumps({
            'baseline_source_sha256': {Path(path).name: hashlib.sha256((args.baseline_dir / Path(path).name).read_bytes()).hexdigest() for path in paths} if args.baseline_dir else None,
            'working_source_sha256': {Path(path).name: hashlib.sha256((root / path).read_bytes()).hexdigest() for path in paths},
            'hardware': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
            'swift': subprocess.check_output(['swiftc', '--version'], text=True, stderr=subprocess.STDOUT).strip(),
            'compiler_flags': ['-O', '-parse-as-library'],
            'fixtures': {'json_paths': 2000, 'rows_per_path': 32, 'replacements': 800, 'session_queries': 400, 'deletions': 400, 'mock_reply_delay_ms': 1200},
            'samples': samples, 'medians': medians,
            'limitations': ['synthetic functions/mock children; not full-app FPS/CPU/power', 'RSS includes fixtures, serialization, reload and Foundation runtime', 'after arm additionally checks pre-cancel and launch races'],
        }, indent=2, ensure_ascii=False) + '\n')
print('PASS: JSON path replacement/add/delete/reload and mock MCP pagination/cancellation/owned-child cleanup')
