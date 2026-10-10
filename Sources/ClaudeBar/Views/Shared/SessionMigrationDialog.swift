import SwiftUI

@MainActor
final class SessionMigrationModel: ObservableObject {
    @Published private(set) var records: [MigrationRecord] = []
    @Published var selectedSource: MigrationSource?
    @Published private(set) var selectionRequest = UUID()
    @Published var error: String?
    @Published private(set) var opening: UUID?
    private var refreshGeneration = 0

    func requestMigration(_ source: MigrationSource) {
        selectedSource = source
        // A repeat click must navigate even when the selected source is unchanged.
        selectionRequest = UUID()
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let latest = try await SessionMigrationService.shared.records()
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            if records != latest { records = latest }
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration,
                  !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }

    func open(_ record: MigrationRecord, codexStore: CodexProviderStore) async throws {
        guard opening == nil else { throw MigrationFailure.busy }
        opening = record.id
        defer { opening = nil }
        let bridge: MigrationBridgeLaunch?
        if record.target == .claudeCodexModel {
            let endpoint = try await SessionMigrationService.shared.bridgeEndpoint(for: record)
            bridge = try await codexStore.prepareMigrationBridge(id: record.id, endpoint: endpoint)
        } else { bridge = nil }
        let command = try await SessionMigrationService.shared.command(for: record, bridge: bridge)
        try Task.checkCancellation()
        try TerminalLauncher.openMigratedSession(record, command: command)
    }
}

extension MigrationSource {
    init(_ session: SessionInfo) {
        self.init(client: .claude, sessionID: session.sessionId, cwd: session.cwd,
                  title: session.displayTitle, isBusy: session.isBusy || session.isWaiting || session.toolPending
                    || session.subagents.contains { $0.status == .running })
    }

    init(_ session: CursorSessionInfo) {
        self.init(client: .cursorDesktop, sessionID: session.composerId, cwd: session.cwd,
                  title: session.displayTitle, isBusy: session.isBusy || session.isWaiting
                    || session.subagents.contains { $0.status == .running })
    }

    init(_ session: ExternalSessionInfo, hasRunningChildren: Bool = false) {
        self.init(client: .codex, sessionID: session.sessionId, cwd: session.cwd,
                  title: session.displayName, isBusy: session.isActive || session.hasStalledTurn || hasRunningChildren,
                  isSubagent: session.isSubagent)
    }
}

/// Session cards route into the dedicated workspace. Inspecting the interface
/// is available in dev; the service still gates every external read and write.
struct SessionMigrationButton: View {
    let source: MigrationSource
    var labeled: Bool = false
    var actionTitle = "迁移会话"
    @EnvironmentObject private var migrations: SessionMigrationModel

    var body: some View {
        Group {
            if labeled {
                ActionButton(actionTitle, symbol: "arrow.triangle.branch") {
                    migrations.requestMigration(source)
                }
            } else {
                ActionIcon(symbol: "arrow.triangle.branch", tint: Theme.textSecondary) {
                    migrations.requestMigration(source)
                }
            }
        }
        .help("在迁移会话页面选择目标并预览历史")
        .accessibilityLabel(actionTitle)
    }
}
