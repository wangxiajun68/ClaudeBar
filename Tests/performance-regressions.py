#!/usr/bin/env python3
"""Exercise production refresh scheduling with synthetic data; no user stores touched."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

def method(file, signature):
    source = (root / file).read_text()
    start = source.index(signature)
    body = source.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')

capture = 'Sources/ClaudeBar/Utils/ProxyCaptureStore.swift'
island = 'Sources/ClaudeBar/Models/IslandLiveModel.swift'
swift = r'''
import Foundation
import Combine

struct CaptureLive { var content: String; var reasoning = "" }
enum CaptureState { case pending, streaming, completed }
struct Row { var id: Int64; var state: CaptureState }
final class Catalog: ObservableObject {
    var records: [Row] = []
    @Published var livePreview: [Int64: String] = [:]
}
final class Streams: ObservableObject {
    @Published var live: [Int64: CaptureLive] = [:]
}
final class CaptureFixture {
    let lock = NSRecursiveLock()
    var pendingLive: [Int64: CaptureLive] = [:]
    var flushWork: DispatchWorkItem?
    let liveFlushQueue = DispatchQueue(label: "regression.capture")
    let catalog = Catalog()
    let streams = Streams()
    static func clip(_ text: String) -> String { String(text.prefix(80)) }
    SCHEDULE
    FLUSH
    func push(_ value: String) {
        lock.lock()
        for id in 0..<100 { pendingLive[Int64(id)] = CaptureLive(content: value) }
        lock.unlock()
        scheduleFlush()
    }
}
@MainActor final class IslandLiveModel {
    var usageRefreshPending = false
    var usageRefreshQueued = false
    var usage = 0
    nonisolated static let counter = Counter()
    nonisolated static func computeUsage(now: Date) -> Int {
        counter.begin()
        Thread.sleep(forTimeInterval: 0.06)
        return counter.end()
    }
    RELOAD
}
final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var active = 0
    var maximum = 0
    func begin() { lock.lock(); defer { lock.unlock() }; calls += 1; active += 1; maximum = max(maximum, active) }
    func end() -> Int { lock.lock(); defer { lock.unlock() }; active -= 1; return calls }
}
@main struct Regression {
    @MainActor static func main() async {
        let fixture = CaptureFixture()
        fixture.catalog.records = (0..<100).map { Row(id: Int64($0), state: .streaming) }
        var streamPublishes = 0
        var previewPublishes = 0
        let s = fixture.streams.objectWillChange.sink { streamPublishes += 1 }
        let p = fixture.catalog.objectWillChange.sink { previewPublishes += 1 }
        // An uninterrupted stream must publish before it goes quiet.
        for i in 0..<60 {
            fixture.push("token \(i)")
            try? await Task.sleep(for: .milliseconds(5))
        }
        precondition(streamPublishes >= 2, "Debouncing starves continuous streams")
        try? await Task.sleep(for: .milliseconds(200))
        precondition(fixture.streams.live[99]?.content == "token 59")
        precondition(streamPublishes < 12, "Publish once per batch, not once per record")
        precondition(previewPublishes == streamPublishes)
        // A pending flush must not overwrite finished content or revive a deleted row.
        fixture.push("stale")
        fixture.catalog.records = []
        let count = streamPublishes
        try? await Task.sleep(for: .milliseconds(200))
        precondition(streamPublishes == count)
        withExtendedLifetime((s, p)) {}

        // Hold the shared database lock across the scheduled flush. A main
        // queue probe must execute before that worker releases the lock.
        let locked = DispatchSemaphore(value: 0)
        let probe = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let databaseLock = fixture.lock
        fixture.push("lock contention")
        DispatchQueue.global().async {
            databaseLock.lock()
            locked.signal()
            let responsive = probe.wait(timeout: .now() + 2) == .success
            databaseLock.unlock()
            precondition(responsive, "Live flush blocked the interaction thread on the database lock")
            finished.signal()
        }
        precondition(locked.wait(timeout: .now() + 2) == .success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { probe.signal() }
        try? await Task.sleep(for: .milliseconds(300))
        precondition(finished.wait(timeout: .now() + 2) == .success)

        let model = IslandLiveModel()
        model.reloadUsage()
        for _ in 0..<100 { model.reloadUsage() }
        try? await Task.sleep(for: .milliseconds(300))
        precondition(IslandLiveModel.counter.maximum == 1, "Usage queries must not overlap")
        precondition(IslandLiveModel.counter.calls == 2, "Burst must coalesce to one trailing pass")
        precondition(model.usage == 2 && !model.usageRefreshPending)
        model.reloadUsage()
        try? await Task.sleep(for: .milliseconds(150))
        precondition(model.usage == 3, "Gate must release for subsequent refreshes")
        print("PASS: 100 concurrent streams batch at 10 Hz without starvation; stale flush suppressed; 101 usage requests coalesce to 2 serial passes")
    }
}
'''
swift = swift.replace('SCHEDULE', method(capture, '    private func scheduleFlush()'))
swift = swift.replace('FLUSH', method(capture, '    private func flushLive()'))
swift = swift.replace('RELOAD', method(island, '    func reloadUsage()'))
with tempfile.TemporaryDirectory(prefix='claudebar-perf-') as folder:
    source = Path(folder) / 'Regression.swift'
    source.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
