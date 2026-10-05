#!/usr/bin/env python3
"""Production connector scheduling and migration read/publication lifecycle.
All file reads use a temporary directory; no clients or user configuration are opened.
"""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline-ref')
p.add_argument('--probe', action='store_true')
p.add_argument('--keep-fixture', type=Path)
p.add_argument('--output-json', type=Path)
a = p.parse_args()


def read(path):
    return subprocess.check_output(['git', 'show', f'{a.baseline_ref}:{path}'], cwd=root, text=True) if a.baseline_ref else (root / path).read_text()


def decl(source, marker):
    start = source.index(marker); end = source.index('{', start) + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]


source = read('Sources/ClaudeBar/Models/ConnectorManager.swift')
connector = source[source.index('@MainActor final class ConnectorManager'):source.index('    func remove(')]
connector += '    func requestsForTest() -> Int { scanGeneration }\n}\n'
model = read('Sources/ClaudeBar/Views/Shared/SessionMigrationDialog.swift')
model = decl(model, 'final class SessionMigrationModel:').replace(decl(model, '    func open('), '')
storage = read('Sources/ClaudeBar/Utils/MigrationStorage.swift')
records = decl(storage, '    static func records(at')
bounded = decl(storage, '    static func readBounded(').replace('        let handle: FileHandle', '        Reads.begin()\n        let handle: FileHandle', 1)
migration_types = read('Sources/ClaudeBar/Models/SessionMigration.swift')
swift = r'''
import Foundation
import Combine
enum ConnectorKind: CaseIterable { case plugin, skill, mcp }
enum ConnectorPlatform: CaseIterable { case claude, codex, cursor }
struct ConnectorRecord: Equatable, Sendable { let id: String; var kind = ConnectorKind.plugin; var platforms: [ConnectorPlatform] = [.claude] }
struct PluginBundleContents: Equatable, Sendable { let value: String }
typealias LocalCLIRecord = String
enum ScanIO {
    static let lock = NSLock(), firstGate = DispatchSemaphore(value: 0)
    static var calls = 0, active = 0, maxActive = 0, cliCalls = 0
    static var files: [URL] = []
    static func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
    static func reset() { lock.lock(); defer { lock.unlock() }; calls = 0; maxActive = 0; cliCalls = 0 }
    static func scan(_ path: String?) -> [ConnectorRecord] {
        lock.lock(); calls += 1; let first = calls == 1; active += 1; maxActive = max(maxActive, active); lock.unlock()
        if first { _ = firstGate.wait(timeout: .now() + 10) }
        precondition(!Thread.isMainThread, "Connector file work must stay off main thread")
        for file in files { _ = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) }
        lock.lock(); active -= 1; lock.unlock()
        return [.init(id: path ?? "personal")]
    }
}
enum ConnectorInventory {
    static func scan(projectPath: String?) -> [ConnectorRecord] { ScanIO.scan(projectPath) }
    static func bundledContents(of records: [ConnectorRecord]) -> [String: PluginBundleContents] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.id, .init(value: $0.id)) })
    }
}
enum LocalCLIInventory {
    static func scan() -> [String] {
        ScanIO.lock.lock(); ScanIO.cliCalls += 1; ScanIO.lock.unlock()
        return ["fixture-cli"]
    }
}
CONNECTOR
MIGRATION_TYPES
actor SessionMigrationService {
    static let shared = SessionMigrationService()
    var pending: [CheckedContinuation<[MigrationRecord], Error>] = []
    func records() async throws -> [MigrationRecord] { try await withCheckedThrowingContinuation { pending.append($0) } }
    func count() -> Int { pending.count }
    func finish(_ index: Int, _ result: Result<[MigrationRecord], Error>) { pending[index].resume(with: result) }
}
@MainActor
MIGRATION_MODEL
enum MigrationHistory { static let maxFileBytes = 1024 * 1024 }
enum Reads {
    static let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    static var count = 0, blockFirst = false
    static func reset(block: Bool = false) { lock.lock(); count = 0; blockFirst = block; lock.unlock() }
    static func total() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    static func begin() {
        lock.lock(); count += 1; let hold = blockFirst && count == 1; lock.unlock()
        if hold { _ = gate.wait(timeout: .now() + 10) }
    }
}
enum MigrationStorage { RECORDS
BOUNDED
}
func require(_ ok: @autoclosure () -> Bool, _ message: String) {
    if !ok() { if PROBE { print("BASELINE VIOLATION:", message) } else { fatalError(message) } }
}
func record(_ n: Int) -> MigrationRecord {
    .init(id: UUID(), logicalConversationID: UUID(), createdAt: Date(timeIntervalSince1970: Double(n)),
          source: .init(client: .claude, sessionID: UUID().uuidString, cwd: "/synthetic", title: "fixture"),
          sourceFingerprint: "fixture", target: .codexCurrent, targetSessionID: UUID().uuidString,
          nativePath: "/synthetic", messageCount: n, omissions: [], model: "fixture", providerKey: "fixture",
          configurationFingerprint: nil, executablePath: "/synthetic")
}
@main struct Regression {
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<10000 { if condition() { return }; try? await Task.sleep(for: .milliseconds(1)) }
        fatalError("fixture did not settle")
    }
    @MainActor static func pending(_ count: Int) async {
        for _ in 0..<10000 {
            if await SessionMigrationService.shared.count() >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        fatalError("service did not settle")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scanRoot = root.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        for i in 0..<200 {
            let file = scanRoot.appendingPathComponent("\(i).json")
            try Data("{\"name\":\"synthetic\",\"entries\":[1,2,3]}".utf8).write(to: file)
            ScanIO.files.append(file)
        }
        let manager = ConnectorManager()
        var loadingUpdates = 0, recordUpdates = 0
        let loadingToken = manager.$isLoading.dropFirst().sink { _ in loadingUpdates += 1 }
        let recordsToken = manager.$records.dropFirst().sink { _ in recordUpdates += 1 }
        let first = Task { await manager.refresh(projectPath: "old", scanCLIs: true) }
        await until { ScanIO.count() == 1 }
        var tasks: [Task<Void, Never>] = []
        for i in 0..<100 {
            tasks.append(Task { await manager.refresh(projectPath: "latest-\(i)", scanCLIs: i == 40) })
        }
        await until { manager.requestsForTest() == 101 }
        // Wait for the original implementation's nonblocked calls to finish.
        try? await Task.sleep(for: .milliseconds(120))
        require(manager.isLoading, "Loading must cover the active scan and all pending work")
        ScanIO.firstGate.signal()
        await first.value; for task in tasks { await task.value }
        let burstCalls = ScanIO.count(), peak = ScanIO.maxActive, burstLoading = loadingUpdates
        require(burstCalls == 2 && peak == 1, "Burst must use one active scan plus one latest scan")
        require(manager.records.map(\.id) == ["latest-99"], "Newest project must win")
        require(manager.pluginContents.keys.sorted() == ["latest-99"], "Plugin contents must match the published project")
        require(manager.localCLIs == ["fixture-cli"], "Full CLI request must survive later project-only requests")
        require(loadingUpdates == 2 && recordUpdates == 1, "Burst must not repeatedly publish loading or obsolete records")
        let writes = recordUpdates
        await manager.refresh(projectPath: "latest-99", scanCLIs: false)
        require(ScanIO.count() == burstCalls + 1 && recordUpdates == writes, "Post-mutation rescan must run even for the same path; equal results must not publish")
        let cancelled = Task { await manager.refresh(projectPath: "cancelled", scanCLIs: false) }
        cancelled.cancel(); await cancelled.value
        require(ScanIO.count() == burstCalls + 1, "Already cancelled caller must not start a scan")
        await manager.refresh(projectPath: nil, scanCLIs: false)
        require(manager.records.map(\.id) == ["personal"] && manager.localCLIs == ["fixture-cli"], "Clearing project scope must preserve the CLI inventory")
        withExtendedLifetime((loadingToken, recordsToken)) {}
        // An obsolete full scan followed only by a project-only request must
        // carry CLI results without launching another CLI scan.
        ScanIO.reset()
        let scoped = ConnectorManager()
        let full = Task { await scoped.refresh(projectPath: "scope-old", scanCLIs: true) }
        await until { ScanIO.count() == 1 }
        let scopeOnly = Task { await scoped.refresh(projectPath: "scope-new", scanCLIs: false) }
        await until { scoped.requestsForTest() == 2 }
        ScanIO.firstGate.signal(); await full.value; await scopeOnly.value
        require(scoped.localCLIs == ["fixture-cli"] && ScanIO.cliCalls == 1,
                "Superseded full scan must carry CLI results into a project-only pass")

        let history = SessionMigrationModel(), service = SessionMigrationService.shared
        let old = record(1), newest = record(2)
        let oldTask = Task { await history.refresh() }; await pending(1)
        let newTask = Task { await history.refresh() }; await pending(2)
        await service.finish(1, .success([newest])); await newTask.value
        await service.finish(0, .success([old])); await oldTask.value
        require(history.records == [newest], "Old history completion must not replace the newest refresh")
        var historyWrites = 0
        let historyToken = history.$records.dropFirst().sink { _ in historyWrites += 1 }
        let same = Task { await history.refresh() }; await pending(3)
        await service.finish(2, .success(history.records)); await same.value
        let unchangedWrites = historyWrites
        require(historyWrites == 0, "Unchanged history must not invalidate cards")
        let cancelledHistory = Task { await history.refresh() }; await pending(4)
        cancelledHistory.cancel(); await service.finish(3, .failure(MigrationFailure.missing)); await cancelledHistory.value
        require(history.error == nil, "Cancelled history must not publish an error")
        let cancelledSuccess = Task { await history.refresh() }; await pending(5)
        cancelledSuccess.cancel(); await service.finish(4, .success([record(99)])); await cancelledSuccess.value
        require(history.records == [newest], "Cancelled history success must not replace current cards")
        let staleError = Task { await history.refresh() }; await pending(6)
        let latestSuccess = Task { await history.refresh() }; await pending(7)
        await service.finish(6, .success([newest])); await latestSuccess.value
        await service.finish(5, .failure(MigrationFailure.missing)); await staleError.value
        require(history.error == nil, "Obsolete history error must not replace current status")
        withExtendedLifetime(historyToken) {}

        let historyRoot = root.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        let samples = (0..<300).map(record)
        for item in samples { try JSONEncoder().encode(item).write(to: historyRoot.appendingPathComponent(item.id.uuidString + ".json")) }
        let sorted = try MigrationStorage.records(at: historyRoot)
        require(sorted == samples.sorted { $0.createdAt > $1.createdAt }, "Manifest validation, fields and sorting must remain exact")
        Reads.reset()
        let preCancelled = Task { @MainActor in try MigrationStorage.records(at: historyRoot) }
        preCancelled.cancel()
        do { _ = try await preCancelled.value; require(false, "Precancelled read must throw") } catch is CancellationError {} catch { throw error }
        let precancelReads = Reads.total()
        require(precancelReads == 0, "Precancelled history must not read files")
        Reads.reset(block: true)
        let midCancelled = Task.detached { try MigrationStorage.records(at: historyRoot) }
        await until { Reads.total() == 1 }
        midCancelled.cancel(); Reads.gate.signal()
        do { _ = try await midCancelled.value; require(false, "Cancelled loop must throw") } catch is CancellationError {} catch { throw error }
        let midReads = Reads.total()
        require(midReads == 1, "Cancellation must stop after the in-progress bounded file read")
        Reads.reset()
        let invalid = historyRoot.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{}".utf8).write(to: invalid)
        do { _ = try MigrationStorage.records(at: historyRoot); fatalError("Invalid manifest was accepted") }
        catch MigrationFailure.invalidHistory {} catch { throw error }
        let metrics: [String: Any] = ["connector_burst_scans": burstCalls, "connector_peak_scans": peak,
            "connector_loading_publications": burstLoading, "unchanged_history_publications": unchangedWrites,
            "pre_cancel_manifest_reads": precancelReads, "mid_cancel_manifest_reads": midReads]
        print("METRICS " + String(data: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), encoding: .utf8)!)
        if !PROBE { print("PASS production connector coalescing, CLI retention, migration publication and bounded cancellation") }
    }
}
'''
for key, value in {'CONNECTOR': connector, 'MIGRATION_TYPES': migration_types,
                   'MIGRATION_MODEL': model, 'RECORDS': records, 'BOUNDED': bounded,
                   'PROBE': 'true' if a.probe else 'false'}.items():
    swift = swift.replace(key, value)
with tempfile.TemporaryDirectory(prefix='claudebar-module-scheduling-') as temporary:
    out = a.keep_fixture or Path(temporary); out.mkdir(parents=True, exist_ok=True)
    path = out / 'probe.swift'; path.write_text(swift)
    binary = out / 'probe'
    subprocess.run(['swiftc', '-O', '-g', '-parse-as-library', '-target', 'arm64-apple-macos15.0', str(path), '-o', str(binary)], check=True)
    result = subprocess.check_output([str(binary)], text=True)
    print(result, end='', flush=True)
    if a.output_json:
        metrics = next(json.loads(line[8:]) for line in result.splitlines() if line.startswith('METRICS '))
        a.output_json.write_text(json.dumps(metrics, indent=2) + '\n')
