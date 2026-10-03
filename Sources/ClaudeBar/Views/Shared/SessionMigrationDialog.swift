import SwiftUI

@MainActor
final class SessionMigrationModel: ObservableObject {
    @Published private(set) var records: [MigrationRecord] = []
    @Published var error: String?
    @Published private(set) var opening: UUID?

    func refresh() async {
        do { records = try await SessionMigrationService.shared.records() }
        catch { self.error = error.localizedDescription }
    }

    func open(_ record: MigrationRecord) async throws {
        guard opening == nil else { throw MigrationFailure.busy }
        opening = record.id
        defer { opening = nil }
        let command = try await SessionMigrationService.shared.command(for: record)
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
                  title: session.displayTitle, isBusy: session.isBusy || session.isWaiting)
    }

    init(_ session: ExternalSessionInfo, hasRunningChildren: Bool = false) {
        self.init(client: .codex, sessionID: session.sessionId, cwd: session.cwd,
                  title: session.displayName, isBusy: session.isActive || session.hasStalledTurn || hasRunningChildren,
                  isSubagent: session.isSubagent)
    }
}

/// Shared affordance for all four page card shapes and prepared target rows.
struct SessionMigrationButton: View {
    let source: MigrationSource
    @EnvironmentObject private var migrations: SessionMigrationModel
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(!BuildChannel.allowsSystemIntegration || source.isBusy || source.isSubagent)
        .help(!BuildChannel.allowsSystemIntegration ? "会话迁移在正式版启用"
              : source.isBusy ? "等待当前回合结束后迁移" : "继续于其他客户端")
        .accessibilityLabel("继续于其他客户端")
        .sheet(isPresented: $showing) {
            SessionMigrationDialog(source: source)
                .environmentObject(migrations)
        }
    }
}

private struct SessionMigrationDialog: View {
    let source: MigrationSource
    @EnvironmentObject private var migrations: SessionMigrationModel
    @Environment(\.dismiss) private var dismiss
    @State private var target: MigrationTarget = .codexCurrent
    @State private var officialModel = "gpt-6.1-sol"
    @State private var preview: MigrationPreview?
    @State private var error: String?
    @State private var preparing = false
    @State private var work: Task<Void, Never>?

    private var targets: [MigrationTarget] {
        MigrationTarget.allCases.filter { !(source.client == .claude && $0 == .claude) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            Text("继续于…").font(Theme.Font.rowTitle).foregroundColor(Theme.textPrimary)
            Text(source.title.isEmpty ? source.client.label : source.title)
                .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary).lineLimit(2)
            Text(source.cwd).font(Theme.Font.captionMono).foregroundColor(Theme.textTertiary())
                .lineLimit(2).truncationMode(.middle)
            Picker("目标", selection: $target) {
                ForEach(targets) { Text($0.label).tag($0) }
            }
            .disabled(preparing)
            if target == .codexOfficial {
                TextField("官方模型名称", text: $officialModel)
                    .textFieldStyle(.roundedBorder).disabled(preparing)
            }
            Text("正文历史转入新会话，在原项目目录继续，使用目标客户端的账号与权限。")
                .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            if target == .cursorCLI {
                Text("将在终端打开 Cursor CLI。Cursor 桌面接收尚未接入。")
                    .font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
            }
            if let preview {
                Text("\(preview.messages.count) 条消息 · \(max(1, preview.textBytes / 1024)) KB")
                    .font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary)
                ForEach(preview.omissions, id: \.self) {
                    Text($0).font(Theme.Font.caption).foregroundColor(Theme.Ink.warning)
                }
            } else if error == nil {
                ProgressView("正在读取会话…")
            }
            if let error {
                Text(error).font(Theme.Font.bodySmall).foregroundColor(Theme.Ink.error)
            }
            HStack {
                Button("取消") { work?.cancel(); dismiss() }
                Spacer()
                if error != nil && preview == nil {
                    Button("重试") { load() }
                }
                Button(preparing ? "正在准备…" : "创建并打开") { prepare() }
                    .buttonStyle(.borderedProminent)
                    .disabled(preview == nil || preparing || source.isBusy
                              || (target == .codexOfficial && officialModel.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(Theme.Space.s24)
        .frame(width: 480)
        .background(Theme.bgPrimary)
        .onAppear {
            target = source.client == .claude ? .codexCurrent : .claude
            load()
        }
        .onDisappear { work?.cancel() }
    }

    private func load() {
        work?.cancel()
        error = nil; preview = nil
        work = Task {
            do {
                let result = try await SessionMigrationService.shared.preview(source)
                try Task.checkCancellation()
                preview = result
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func prepare() {
        guard let preview, !preparing else { return }
        preparing = true; error = nil
        work = Task {
            defer { preparing = false }
            do {
                let record = try await SessionMigrationService.shared.prepare(source: source, target: target,
                    fingerprint: preview.fingerprint, officialModel: officialModel)
                try Task.checkCancellation()
                await migrations.refresh()
                try await migrations.open(record)
                dismiss()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct SessionMigrationHistoryView: View {
    @EnvironmentObject private var migrations: SessionMigrationModel

    var body: some View {
        if !migrations.records.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                Text("迁移记录").font(Theme.Font.rowTitle).foregroundColor(Theme.textPrimary)
                ForEach(migrations.records.prefix(12)) { record in
                    HStack(spacing: Theme.Space.s12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.source.client.label + " → " + record.target.label)
                                .font(Theme.Font.bodySmall).foregroundColor(Theme.textPrimary)
                            Text(record.source.title + " · " + record.model + " · 已准备")
                                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary).lineLimit(1)
                            Text(record.source.cwd).font(Theme.Font.captionMono)
                                .foregroundColor(Theme.textTertiary()).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        SessionMigrationButton(source: record.targetSource)
                        Button("继续") {
                            Task {
                                do { try await migrations.open(record) }
                                catch { migrations.error = error.localizedDescription }
                            }
                        }
                            .disabled(migrations.opening != nil || !BuildChannel.allowsSystemIntegration)
                    }
                    .padding(Theme.Space.s12)
                    .tile(tint: Theme.claude)
                }
            }
        }
    }
}
