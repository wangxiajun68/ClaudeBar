#!/usr/bin/env python3
"""Read production access-log tails using temporary synthetic files only.

--baseline-file compares the previous reader. CPU/read volume/RSS diagnostics
are isolated from fixture generation; CI verifies content and lifecycle only.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import statistics
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline-file', type=Path)
p.add_argument('--output-json', type=Path)
args = p.parse_args()
path = root / 'Sources/ClaudeBar/Utils/ProxyAccessLog.swift'


def harness(baseline):
    log = (args.baseline_file if baseline else path).read_text()
    asynchronous = 'func loadListIfNeeded()' in log
    marker = 'private func readRecentEntries()' if asynchronous else 'private func loadLocked()'
    log = log.replace('private init()', 'init()')
    log = log.replace(marker + ' -> [ProxyLogEntry] {', marker + ''' -> [ProxyLogEntry] {
        let started = ContinuousClock.now
        Probe.lock.lock(); Probe.reads += 1; Probe.offMain = !Thread.isMainThread; Probe.started = true; Probe.lock.unlock()
        if let gate = Probe.gate { gate.wait() }
        defer {
            let duration = started.duration(to: .now).components
            Probe.lock.lock(); Probe.workMS = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15; Probe.lock.unlock()
        }
''')
    log = log.replace('chunk.append(part)', 'Probe.lock.lock(); Probe.bytes += part.count; Probe.lock.unlock()\n                    chunk.append(part)')
    if not asynchronous:
        log = log.replace('guard let data = try? Data(contentsOf: FilePaths.proxyLogFile)', 'guard let data = try? Probe.readFile()')
    else:
        log += '\nextension ProxyAccessLog { func loadedForTest() -> Bool { lock.lock(); defer { lock.unlock() }; return loaded } }\n'
    return r'''
import Foundation
import Combine
import Darwin
enum FilePaths { static var proxyLogFile = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("large.jsonl") }
struct TokenTotals {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    var isEmpty: Bool { input + output + cacheRead + cacheWrite == 0 }
}
enum UsageStats { static func formatTokens(_ value: Int) -> String { String(value) } }
/// `ProxyAccessLog.clip` delegates to the production `CaptureTranscript.clip`
/// (finding 608); this harness compiles the log file alone, so the shape is
/// stubbed here. The real implementation is driven by
/// `Tests/capture-detail-regressions.py`, which checks the windowed fold
/// against the pre-window reference.
enum CaptureTranscript {
    static func clip(_ text: String, cap: Int = 160) -> String {
        let folded = text.split(whereSeparator: { $0.isNewline || $0 == "\r" })
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return folded.count > cap ? String(folded.prefix(cap)) + "…" : folded
    }
}
enum Probe {
    static let lock = NSLock()
    static var bytes = 0, reads = 0
    static var workMS = 0.0, started = false, offMain = false
    static var gate: DispatchSemaphore?
    static func readFile() throws -> Data {
        let data = try Data(contentsOf: FilePaths.proxyLogFile)
        lock.lock(); bytes += data.count; lock.unlock()
        return data
    }
    static func snapshot() -> (Int, Int, Double, Bool, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (bytes, reads, workMS, started, offMain)
    }
    static func pause(_ gate: DispatchSemaphore) {
        lock.lock(); defer { lock.unlock() }
        self.gate = gate; started = false; workMS = 0
    }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { print("FAIL: " + message); exit(1) }
}
''' + log + r'''
@main struct Regression {
    @MainActor static func waitUntil(_ condition: () -> Bool, _ stage: String = "?", line: Int = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            require(ContinuousClock.now < deadline, "timed out waiting for publication at line \(line)")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor static func main() async throws {
        let start = ContinuousClock.now
        let large = ProxyAccessLog()
        let construct = start.duration(to: .now).components
        let constructMS = Double(construct.seconds) * 1000 + Double(construct.attoseconds) / 1e15
        __LOAD_LARGE__
        require(large.entries.map(\.id) == Array(49_501...50_000).map(UInt64.init), "large file tail order")
        require(large.entries.allSatisfy { $0.path == "/中文😀/health" && $0.totalTokens == 10 }, "UTF8/token fields")
        let snapshot = Probe.snapshot()
        var metrics: [String: Double] = ["log_construct_ms": constructMS, "log_read_work_ms": snapshot.2,
            "log_read_bytes": Double(snapshot.0), "log_file_bytes": Double((try FilePaths.proxyLogFile.resourceValues(forKeys: [.fileSizeKey])).fileSize!)]
        if __ASYNC__ { require(snapshot.4, "history read ran on main thread"); require(snapshot.0 < 1024 * 1024, "reader scanned the whole valid corpus") }
        let next = large.begin(method: "GET", path: "/new", source: .other, kind: .other, provider: "", model: "", stream: false, bytesIn: 0)
        require(next.id == 50_001, "history id continuation")
        __FIRST_REQUESTS__
        let base = FilePaths.proxyLogFile.deletingLastPathComponent()
        for name in ["boundary", "single", "empty", "missing"] {
            FilePaths.proxyLogFile = base.appendingPathComponent(name + ".jsonl")
            let store = ProxyAccessLog()
            let expected = name == "boundary" ? Array(301...800).map(UInt64.init)
                : name == "single" ? [UInt64(7)] : []
            __LOAD_SMALL__
            require(store.entries.map(\.id) == expected, "\(name) tail differs")
            if name == "boundary" { require(store.entries.allSatisfy { $0.path == "/中文😀/health" }, "chunk boundary broke UTF8") }
        }
        FilePaths.proxyLogFile = base.appendingPathComponent("unicode-separators.jsonl")
        var store = ProxyAccessLog()
        var expected = Array(101...600).map(UInt64.init)
        __LOAD_SMALL__
        require(store.entries.allSatisfy { $0.path.contains("\u{2028}") || $0.path.contains("\u{2029}") },
                "a raw U+2028/U+2029 split the record it belonged to")
        // Out-of-range token buckets must read as unreported, not as Int.max:
        // summing four clamped buckets traps under -O while the page renders.
        FilePaths.proxyLogFile = base.appendingPathComponent("oversized-tokens.jsonl")
        store = ProxyAccessLog()
        expected = [UInt64(21), 22]
        __LOAD_SMALL__
        require(store.entries.map(\.id) == expected, "token fixture tail differs")
        require(store.entries.allSatisfy { $0.totalTokens == nil }, "oversized token bucket produced a total")
        require(store.entries.allSatisfy { $0.promptTokens == nil && $0.completionTokens == nil
            && $0.cacheReadTokens == nil && $0.cacheWriteTokens == nil }, "oversized token bucket survived decode")
        if __ASYNC__ {
            // Pause the real reader before disk I/O. Clear must finish while
            // it is paused, and an old history result must not overwrite fresh traffic.
            FilePaths.proxyLogFile = base.appendingPathComponent("race.jsonl")
            let gate = DispatchSemaphore(value: 0)
            Probe.pause(gate)
            let store = ProxyAccessLog()
            __RACE_LOAD__
            try await waitUntil { Probe.snapshot().3 }
            store.clear()
            let fresh = store.begin(method: "GET", path: "/fresh", source: .other, kind: .other, provider: "", model: "", stream: false, bytesIn: 0)
            require(fresh.id == 1, "clear before first allocation")
            gate.signal()
            try await waitUntil { Probe.snapshot().2 > 0 && store.entries.count == 1 }
            require(store.entries.first?.path == "/fresh", "history resurrected after clear")
            // Repeated loads after consumption must not read or republish history.
            let count = Probe.snapshot().1
            __RACE_LOAD__
            try await Task.sleep(for: .milliseconds(150))
            require(Probe.snapshot().1 == count && store.entries.first?.path == "/fresh", "history reloaded")
            Probe.gate = nil
        }
        metrics["large_read_off_main"] = snapshot.4 ? 1 : 0
        print("METRICS " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
    }
}
'''.replace('__FIRST_REQUESTS__', r'''
        let requestStore = ProxyAccessLog()
        let ids = await withTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await requestStore.prepareForRequests()
                    return requestStore.begin(method: "GET", path: "/request", source: .other, kind: .other,
                        provider: "", model: "", stream: false, bytesIn: 0).id
                }
            }
            var result: [UInt64] = []
            for await id in group { result.append(id) }
            return result.sorted()
        }
        require(ids == Array(50_001...50_100).map(UInt64.init), "concurrent first requests lost history or reused ids")
        try await waitUntil { requestStore.entries.last?.id == 50_100 }
        require(requestStore.entries.map(\.id) == Array(49_601...50_100).map(UInt64.init), "history/request ordering")
        ''' if asynchronous else '').replace('__ASYNC__', 'true' if asynchronous else 'false').replace('__LOAD_LARGE__', 'large.loadListIfNeeded(); try await waitUntil { large.entries.count == 500 }' if asynchronous else '').replace('__LOAD_SMALL__', '__STORE__.loadListIfNeeded(); try await waitUntil { __STORE__.loadedForTest() && __STORE__.entries.map(\.id) == expected }' if asynchronous else '').replace('__STORE__', 'store').replace('__RACE_LOAD__', 'store.loadListIfNeeded()' if asynchronous else '')


def line(ident, padding=256, path='/中文😀/health', tokens=(1, 2, 3, 4)):
    return json.dumps(dict(id=ident, at='2026-10-03T00:00:00Z', end='2026-10-03T00:00:01Z',
                           method='GET', path=path, source='other', kind='health',
                           promptTokens=tokens[0], completionTokens=tokens[1],
                           cacheReadTokens=tokens[2], cacheWriteTokens=tokens[3],
                           ignored='x' * padding), ensure_ascii=False).encode()


with tempfile.TemporaryDirectory(prefix='claudebar-access-tail-') as folder:
    work = Path(folder)
    # Write on Python's test driver, outside the measured Swift processes.
    for name, count, padding, separator in [('large', 50_000, 256, b'\n'), ('boundary', 800, 121, b'\r\n')]:
        with (work / (name + '.jsonl')).open('wb') as f:
            for ident in range(1, count + 1):
                f.write(line(ident, padding) + separator)
            if name == 'boundary':
                f.write(b'broken' * 30_000 + b'\n' + b'{"id":')
            elif name == 'large':
                f.write(b'\xffbad\n{"id":')
    # U+2028 / U+2029 are `CharacterSet.newlines` members and `JSONSerialization`
    # writes them raw inside a string, so a real path can carry one. Records are
    # still separated by LF: a reader that also splits on those scalars tears the
    # record in half and silently drops the row.
    with (work / 'unicode-separators.jsonl').open('wb') as f:
        for ident in range(1, 601):
            scalar = '\u2028' if ident % 2 else '\u2029'
            f.write(line(ident, 0, path='/中文' + scalar + '/health').replace(
                scalar.encode('unicode_escape'), scalar.encode()) + b'\n')
    (work / 'single.jsonl').write_bytes(line(7))
    # Out-of-range token buckets: `NSNumber.intValue` clamps these to Int.max,
    # and four clamped buckets used to trap the total under `-O`.
    (work / 'oversized-tokens.jsonl').write_bytes(
        line(21, tokens=(9_223_372_036_854_775_807, 9_223_372_036_854_775_807,
                         9_223_372_036_854_775_807, 9_223_372_036_854_775_807)) + b'\n'
        + line(22, tokens=(1.5e300, -1, 1e16, 9e18)) + b'\n')
    (work / 'empty.jsonl').write_bytes(b'')
    (work / 'race.jsonl').write_bytes(line(99) + b'\n')
    binaries = {}
    for baseline in ([True, False] if args.baseline_file else [False]):
        name = 'before' if baseline else 'after'
        source, binary = work / (name + '.swift'), work / name
        source.write_text(harness(baseline))
        subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
        binaries[name] = binary
    samples = {name: [] for name in binaries}
    for repetition in range(3 if args.baseline_file else 1):
        for name in list(binaries)[::(-1 if repetition % 2 else 1)]:
            (work / 'race.jsonl').write_bytes(line(99) + b'\n')
            run = subprocess.run(['/usr/bin/time', '-l', str(binaries[name]), str(work)], capture_output=True, text=True, timeout=30)
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
            'baseline_source_sha256': hashlib.sha256(args.baseline_file.read_bytes()).hexdigest() if args.baseline_file else None,
            'working_source_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'compiler_flags': ['-O', '-parse-as-library'],
            'hardware': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
            'swift': subprocess.check_output(['swiftc', '--version'], text=True, stderr=subprocess.STDOUT).strip(),
            'fixtures': {'large_valid_lines': 50000, 'display_limit': 500, 'chunk_bytes': 65536, 'long_damaged_tail_bytes': 180000},
            'samples': samples, 'medians': medians,
            'limitations': ['synthetic sidecar, no app launch', 'read byte count measures requested payload, not physical disk/cache I/O', 'RSS includes Foundation and boundary/lifecycle checks', 'legacy files with only Unicode/CR separators and oversized corrupt records may require larger reads'],
        }, indent=2, ensure_ascii=False) + '\n')
print('PASS: production tail reader, UTF8/CRLF/damage/id sequence and load/clear/request races')
