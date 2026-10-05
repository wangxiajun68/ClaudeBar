import SwiftUI

@MainActor
final class SessionMigrationModel: ObservableObject {
    @Published private(set) var records: [MigrationRecord] = []
    @Published var error: String?
    @Published private(set) var opening: UUID?
    private var refreshGeneration = 0

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

/// Shared affordance for session cards and prepared migration cards.
///
/// Session cards pass `labeled` so the control stays on the card surface.
/// Migration cards label this「再次迁移」beside their「打开会话」action.
struct SessionMigrationButton: View {
    let source: MigrationSource
    var labeled: Bool = false
    var actionTitle = "迁移会话"
    @EnvironmentObject private var migrations: SessionMigrationModel
    @EnvironmentObject private var codexStore: CodexProviderStore
    @State private var showing = false

    private var available: Bool {
        BuildChannel.allowsSystemIntegration && !source.isBusy && !source.isSubagent
    }

    var body: some View {
        Button { showing = true } label: {
            if labeled {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(Theme.Font.micro)
                    Text(actionTitle)
                        .font(Theme.Font.caption)
                }
                .foregroundColor(available ? Theme.Ink.claude : Theme.textTertiary())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill((available ? Theme.claude : Theme.statusIdle).opacity(0.12)))
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 24, height: 24)
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .help(!BuildChannel.allowsSystemIntegration ? "会话迁移在正式版启用"
              : source.isBusy ? "等待当前回合结束后迁移"
              : source.isSubagent ? "请从父会话迁移" : "将会话历史迁移到所选客户端的新会话")
        .accessibilityLabel(actionTitle)
        .sheet(isPresented: $showing) {
            SessionMigrationDialog(source: source)
                .environmentObject(migrations)
                .environmentObject(codexStore)
        }
    }
}

private struct SessionMigrationDialog: View {
    let source: MigrationSource
    @EnvironmentObject private var migrations: SessionMigrationModel
    @EnvironmentObject private var codexStore: CodexProviderStore
    @Environment(\.dismiss) private var dismiss
    @State private var target: MigrationTarget = .codexCurrent
    @State private var officialModel = "gpt-6.1-sol"
    @State private var bridgeProviderID: UUID?
    @State private var bridgeModel = ""
    @State private var preview: MigrationPreview?
    @State private var error: String?
    @State private var preparing = false
    @State private var includeCompletedTools = false
    @State private var includeImages = false
    @State private var work: Task<Void, Never>?

    private var targets: [MigrationTarget] {
        MigrationTarget.allCases.filter { !(source.client == .claude && $0 == .claude) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            Text("迁移会话").font(Theme.Font.rowTitle).foregroundColor(Theme.textPrimary)
            Text(source.title.isEmpty ? source.client.label : source.title)
                .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary).lineLimit(2)
            Text(source.cwd).font(Theme.Font.captionMono).foregroundColor(Theme.textTertiary())
                .lineLimit(2).truncationMode(.middle)
            Picker("迁移到", selection: $target) {
                ForEach(targets) { Text($0.label).tag($0) }
            }
            .disabled(preparing)
            if target == .claudeCodexModel {
                Picker("自定义供应商", selection: $bridgeProviderID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach(codexStore.providers.filter { !$0.apiKey.isEmpty }) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }.disabled(preparing)
                if let provider = codexStore.providers.first(where: { $0.id == bridgeProviderID }) {
                    Picker("模型", selection: $bridgeModel) {
                        Text("请选择").tag("")
                        ForEach(provider.models) { Text($0.name).tag($0.name) }
                    }.disabled(preparing)
                }
                Text("沿用所选供应商和模型。此会话通过 ClaudeBar 代理连接，继续时需保持 ClaudeBar 运行。")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            if target == .codexOfficial {
                TextField("官方模型名称", text: $officialModel)
                    .textFieldStyle(.roundedBorder).disabled(preparing)
            }
            Text("将会话历史复制到目标客户端的新会话，保留原会话。新会话沿用原项目目录，使用目标客户端的账号与权限。")
                .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            if source.client == .claude || source.client == .codex || source.client == .cursorDesktop {
                Toggle("包含已完成工具的输入与结果", isOn: $includeCompletedTools)
                    .font(Theme.Font.bodySmall).disabled(preparing)
                if includeCompletedTools {
                    Text("工具记录会随历史发送给目标模型；原工具不会重新执行。")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
                Toggle("包含用户图片", isOn: $includeImages)
                    .font(Theme.Font.bodySmall).disabled(preparing)
                if includeImages {
                    Text(target.client == .cursorCLI
                         ? "Cursor CLI 还不能写入图片。请改选 Claude Code、Codex 或 Cursor 桌面，或关闭此选项。"
                         : "图片写入目标会话的对应图片字段，并会发送给目标模型。文档、音频和 Cursor 的 attachedFiles 仍不迁移。工具结果里的图片只在同时包含已完成工具时携带。")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
            }
            if target == .cursorCLI {
                Text("将在终端打开 Cursor CLI。")
                    .font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
            }
            if target == .cursorDesktop {
                Text("使用 Cursor 此项目已有聊天的模型设置，创建后直接打开迁移聊天。若客户端未响应，可在历史搜索「ClaudeBar · 迁移」。")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            if let preview {
                Text("\(preview.messages.count) 条消息 · \(max(1, preview.textBytes / 1024)) KB")
                    .font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary)
                if preview.completedToolCount > 0 {
                    Text("包含 \(preview.completedToolCount) 项已完成工具记录")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
                if preview.imageCount > 0 {
                    Text("包含 \(preview.imageCount) 张图片")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
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
                ActionButton("取消") { work?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if error != nil && preview == nil {
                    ActionButton("重新读取") { load() }
                }
                ActionButton(preparing ? "正在迁移…" : "迁移并打开", tone: .accent, emphasis: .primary) { prepare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview == nil || preparing || source.isBusy
                              || (target.client == .cursorCLI && includeImages)
                              || (target == .codexOfficial && officialModel.trimmingCharacters(in: .whitespaces).isEmpty)
                              || (target == .claudeCodexModel && (bridgeProviderID == nil || bridgeModel.isEmpty)))
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
        .onChange(of: includeCompletedTools) { load() }
        .onChange(of: includeImages) { load() }
        .onChange(of: bridgeProviderID) { bridgeModel = "" }
    }

    private func load() {
        work?.cancel()
        error = nil; preview = nil
        work = Task {
            do {
                let result = try await SessionMigrationService.shared.preview(source, includeCompletedTools: includeCompletedTools, includeImages: includeImages)
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
                    fingerprint: preview.fingerprint, officialModel: officialModel, includeCompletedTools: includeCompletedTools,
                    includeImages: includeImages,
                    bridgeProviderID: bridgeProviderID, bridgeModel: bridgeModel)
                try Task.checkCancellation()
                await migrations.refresh()
                try await migrations.open(record, codexStore: codexStore)
                dismiss()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct SessionMigrationHistoryView: View {
    @EnvironmentObject private var migrations: SessionMigrationModel

    var body: some View {
        if !migrations.records.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                SectionHeader(icon: "arrow.triangle.branch", title: "迁移会话",
                              tint: Theme.claude, ink: Theme.Ink.claude,
                              count: migrations.records.count)
                TileGrid(.pageSession) {
                    ForEach(migrations.records.prefix(12)) { record in
                        SessionMigrationHistoryCard(record: record)
                    }
                }
            }
        }
    }
}

private struct SessionMigrationHistoryCard: View {
    let record: MigrationRecord
    @EnvironmentObject private var migrations: SessionMigrationModel
    @EnvironmentObject private var codexStore: CodexProviderStore
    @State private var isHovered = false

    private var tint: Color {
        switch record.target.client {
        case .claude: return Theme.claude
        case .codex: return Theme.external
        case .cursorCLI, .cursorDesktop: return Theme.cursor
        }
    }

    private func clientMark(_ client: MigrationClient) -> ProductBrandMark.Brand {
        switch client {
        case .claude: return .claude
        case .codex: return .codex
        case .cursorCLI, .cursorDesktop: return .cursor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text(record.source.title.isEmpty ? record.source.client.label : record.source.title)
                .font(Theme.Font.rowTitle).foregroundColor(Theme.textPrimary)
                .lineLimit(1).help(record.source.title)
            HStack(spacing: Theme.Space.s6) {
                GlyphWell(name: "", size: 20, mark: clientMark(record.source.client))
                Text(record.source.client.label)
                Image(systemName: "arrow.right")
                    .font(Theme.Font.micro).foregroundColor(Theme.textTertiary())
                    .accessibilityHidden(true)
                GlyphWell(name: "", size: 20, mark: clientMark(record.target.client))
                Text(record.target.client.label)
            }
            .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(record.source.client.label + "迁移到" + record.target.label)
            .help(record.source.client.label + " → " + record.target.label)
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                Label(record.model, systemImage: "cpu")
                    .font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary)
                    .lineLimit(1).help(record.model)
                Label(record.source.cwd, systemImage: "folder")
                    .font(Theme.Font.captionMono).foregroundColor(Theme.textTertiary())
                    .lineLimit(1).truncationMode(.middle).help(record.source.cwd)
                HStack(spacing: Theme.Space.s12) {
                    Label("\(record.messageCount) 条消息", systemImage: "text.bubble")
                    Spacer(minLength: 0)
                    Label {
                        Text(record.createdAt, style: .relative)
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
                .font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
                .lineLimit(1)
            }
            HStack(spacing: Theme.Space.s8) {
                Text(record.target.label.components(separatedBy: " · ").last ?? record.target.label)
                    .font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                Spacer(minLength: 0)
                SessionMigrationButton(source: record.targetSource, labeled: true, actionTitle: "再次迁移")
                ActionButton(migrations.opening == record.id ? "正在打开…" : "打开会话") {
                    Task {
                        do { try await migrations.open(record, codexStore: codexStore) }
                        catch { migrations.error = error.localizedDescription }
                    }
                }
                .disabled(migrations.opening != nil || !BuildChannel.allowsSystemIntegration)
                .help(record.target == .cursorDesktop
                      ? "打开迁移聊天；历史名称：" + record.desktopTitle
                      : "打开迁移后的会话")
            }
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile(tint: tint, hovered: isHovered)
        .hoverState($isHovered)
    }
}
