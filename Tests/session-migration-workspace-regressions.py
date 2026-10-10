#!/usr/bin/env python3
"""Exercise the production workspace state with an in-memory migration actor.

No client files, process launch, account configuration or app startup.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
workspace = (root / 'Sources/ClaudeBar/Views/Pages/SessionMigrationView.swift').read_text()
draft = workspace[workspace.index('@MainActor'):workspace.index('extension MigrationClient')]
models = (root / 'Sources/ClaudeBar/Models/SessionMigration.swift').read_text()
history_model = (root / 'Sources/ClaudeBar/Views/Shared/SessionMigrationDialog.swift').read_text()
start = history_model.index('    func requestMigration(')
end = history_model.index('    func refresh()', start)
request_method = history_model[start:end]
source = 'import SwiftUI\n' + models + r'''
enum BuildChannel { static var allowsSystemIntegration = true }
@MainActor final class CodexProviderStore: ObservableObject {}
@MainActor final class SessionMigrationModel: ObservableObject {
    var records: [MigrationRecord] = []
    var opening: UUID?
    @Published var selectedSource: MigrationSource?
    @Published var selectionRequest = UUID()
    __REQUEST_METHOD__
    var failOpen = true
    var opened: [UUID] = []
    func refresh() async { records = await SessionMigrationService.shared.records }
    func open(_ record: MigrationRecord, codexStore: CodexProviderStore) async throws {
        try Task.checkCancellation()
        if failOpen { throw MigrationFailure.unavailable("Fixture client") }
        opened.append(record.id)
    }
}
actor SessionMigrationService {
    static let shared = SessionMigrationService()
    var previews = 0
    var prepares = 0
    var records: [MigrationRecord] = []
    var holdPrepare = false
    var pending: CheckedContinuation<Void, Never>?
    func setHold(_ hold: Bool) { holdPrepare = hold }
    func release() { pending?.resume(); pending = nil }
    func waiting() -> Bool { pending != nil }
    func preview(_ source: MigrationSource, includeCompletedTools: Bool,
                 includeImages: Bool) async throws -> MigrationPreview {
        previews += 1
        try await Task.sleep(for: .milliseconds(15))
        return .init(source: source, messages: [.init(role: .user, text: source.title)],
            fingerprint: source.id, omissions: [], completedToolCount: includeCompletedTools ? 1 : 0)
    }
    func prepare(source: MigrationSource, target: MigrationTarget, fingerprint: String,
                 officialModel: String, includeCompletedTools: Bool, includeImages: Bool,
                 bridgeProviderID: UUID?, bridgeModel: String) async throws -> MigrationRecord {
        prepares += 1
        if holdPrepare { await withCheckedContinuation { pending = $0 } }
        let record = MigrationRecord(id: UUID(), logicalConversationID: UUID(), createdAt: Date(),
            source: source, sourceFingerprint: fingerprint, target: target,
            targetSessionID: UUID().uuidString, nativePath: "/synthetic/history",
            messageCount: 1, omissions: [], model: officialModel, providerKey: "",
            configurationFingerprint: nil, executablePath: "/synthetic/client")
        records.append(record)
        return record
    }
}
''' + draft + r'''
@main struct Probe {
    @MainActor static func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Fixture wait timed out")
    }
    @MainActor static func main() async throws {
        let service = SessionMigrationService.shared
        let migrations = SessionMigrationModel(), codex = CodexProviderStore()
        let first = MigrationSource(client: .claude, sessionID: UUID().uuidString,
                                    cwd: "/synthetic/project", title: "First")
        let second = MigrationSource(client: .codex, sessionID: UUID().uuidString,
                                     cwd: "/synthetic/project", title: "Second")
        let request = migrations.selectionRequest
        migrations.requestMigration(first)
        let nextRequest = migrations.selectionRequest
        migrations.requestMigration(first)
        precondition(request != nextRequest && nextRequest != migrations.selectionRequest)
        precondition(migrations.selectedSource == first)
        let draft = SessionMigrationDraft()
        draft.select(first)
        draft.select(second)
        try await wait { draft.preview != nil }
        precondition(draft.preview?.source == second && draft.target == .claude)
        precondition(draft.canPrepare)
        draft.target = .codexOfficial; draft.officialModel = " \n "
        precondition(!draft.canPrepare)
        draft.officialModel = "fixture-model"
        precondition(draft.canPrepare)
        draft.target = .claudeCodexModel
        precondition(!draft.canPrepare)
        draft.bridgeProviderID = UUID(); draft.bridgeModel = "fixture-bridge"
        precondition(draft.canPrepare)
        draft.target = .cursorCLI; draft.includeImages = true
        precondition(!draft.canPrepare)
        draft.includeImages = false; draft.target = .codexCurrent
        draft.includeCompletedTools = true; draft.load()
        try await wait { draft.preview?.completedToolCount == 1 }

        // An open failure retains the already-written result. Retry never prepares again.
        draft.prepare(migrations: migrations, codexStore: codex)
        draft.prepare(migrations: migrations, codexStore: codex)
        try await wait { !draft.preparing }
        precondition(draft.preparedRecord != nil && draft.error != nil && !draft.canPrepare)
        let committed = draft.preparedRecord!.id
        precondition(migrations.records.count == 1)
        let writes = await service.prepares; precondition(writes == 1)
        migrations.failOpen = false
        draft.openPrepared(migrations: migrations, codexStore: codex)
        try await wait { !draft.preparing }
        precondition(draft.opened && migrations.opened == [committed])
        let retriedWrites = await service.prepares; precondition(retriedWrites == 1)
        draft.resetPrepared()
        try await wait { draft.preview != nil }
        precondition(draft.preparedRecord == nil && !draft.opened && draft.canPrepare)

        var busy = second; busy.isBusy = true
        draft.select(busy)
        precondition(!draft.canPrepare && draft.preview == nil)
        var child = second; child.isSubagent = true
        draft.select(child)
        precondition(!draft.canPrepare && draft.preview == nil)
        BuildChannel.allowsSystemIntegration = false
        let count = await service.previews
        draft.select(first)
        precondition(!draft.canPrepare && !draft.loading)
        let gatedCount = await service.previews; precondition(gatedCount == count)
        BuildChannel.allowsSystemIntegration = true
        draft.load(); draft.cancel()
        try await Task.sleep(for: .milliseconds(35))
        precondition(draft.preview == nil && !draft.loading)

        // Cancel while the actor commits: refresh history, retain committed record,
        // but never launch a client after the page disappeared.
        draft.load()
        try await wait { draft.preview != nil }
        await service.setHold(true)
        draft.prepare(migrations: migrations, codexStore: codex)
        for _ in 0..<100 {
            if await service.waiting() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await service.waiting(); precondition(waiting)
        draft.cancel()
        await service.release()
        try await wait { !draft.preparing }
        precondition(draft.preparedRecord?.source == first)
        precondition(migrations.records.count == 2 && migrations.opened == [committed])

        // Switching source while a cancelled commit completes must not attach
        // the old record to the new source's editor.
        draft.resetPrepared()
        try await wait { draft.preview != nil }
        draft.prepare(migrations: migrations, codexStore: codex)
        for _ in 0..<100 {
            if await service.waiting() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        draft.cancel(); draft.select(second)
        await service.release()
        try await wait { !draft.preparing && draft.preview != nil }
        precondition(draft.source == second && draft.preparedRecord == nil)
        precondition(migrations.records.count == 3 && migrations.opened == [committed])
        print("PASS: migration workspace validation, cancellation, stale results, committed-record retention and open retry")
    }
}
'''
source = source.replace('__REQUEST_METHOD__', request_method)
with tempfile.TemporaryDirectory(prefix='claudebar-migration-workspace-') as temp:
    folder = Path(temp)
    path = folder / 'Probe.swift'
    binary = folder / 'probe'
    path.write_text(source)
    subprocess.run(['/usr/bin/swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                    str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
