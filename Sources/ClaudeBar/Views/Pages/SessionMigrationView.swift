import SwiftUI

/// Window-owned draft: switching between the two session pages preserves choices.
/// File work stays in the migration actor; cancellation never discards a record
/// that has already been written, including when opening the client fails.
@MainActor
final class SessionMigrationDraft: ObservableObject {
    @Published private(set) var source: MigrationSource?
    @Published var target: MigrationTarget = .codexCurrent
    @Published var officialModel = "gpt-6.1-sol"
    @Published var bridgeProviderID: UUID?
    @Published var bridgeModel = ""
    @Published var includeCompletedTools = false
    @Published var includeImages = false
    @Published private(set) var preview: MigrationPreview?
    @Published private(set) var preparedRecord: MigrationRecord?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var preparing = false
    @Published private(set) var opened = false
    private var work: Task<Void, Never>?
    private var generation = 0

    var canPrepare: Bool {
        BuildChannel.allowsSystemIntegration && preview != nil && !loading && !preparing
            && source?.isBusy == false && source?.isSubagent == false
            && !(target.client == .cursorCLI && includeImages)
            && !(target == .codexOfficial && officialModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !(target == .claudeCodexModel && (bridgeProviderID == nil || bridgeModel.isEmpty))
            && preparedRecord == nil
    }

    func resetPrepared() {
        guard !preparing else { return }
        preparedRecord = nil; opened = false
        load()
    }

    func select(_ source: MigrationSource) {
        guard self.source != source else { return }
        let changedIdentity = self.source?.id != source.id
        self.source = source
        if changedIdentity {
            preparedRecord = nil; opened = false
            target = source.client == .claude ? .codexCurrent : .claude
        }
        load()
    }

    func load() {
        cancel()
        preview = nil; error = nil
        guard let source, preparedRecord == nil, BuildChannel.allowsSystemIntegration,
              !source.isBusy, !source.isSubagent else { return }
        loading = true
        let revision = generation
        let tools = includeCompletedTools, images = includeImages
        work = Task {
            defer { if revision == generation { loading = false } }
            do {
                let result = try await SessionMigrationService.shared.preview(source,
                    includeCompletedTools: tools, includeImages: images)
                try Task.checkCancellation()
                guard revision == generation else { return }
                preview = result
            } catch is CancellationError {} catch {
                guard revision == generation else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func prepare(migrations: SessionMigrationModel, codexStore: CodexProviderStore) {
        guard canPrepare, let source, let preview else { return }
        preparing = true; error = nil
        let revision = generation
        let destination = target, model = officialModel
        let tools = includeCompletedTools, images = includeImages
        let providerID = bridgeProviderID, providerModel = bridgeModel
        work = Task {
            defer { preparing = false }
            do {
                let record = try await SessionMigrationService.shared.prepare(source: source, target: destination,
                    fingerprint: preview.fingerprint, officialModel: model,
                    includeCompletedTools: tools, includeImages: images,
                    bridgeProviderID: providerID, bridgeModel: providerModel)
                // Keep the committed result even if this task was cancelled.
                if self.source?.id == source.id { preparedRecord = record }
                // A committed record needs a refresh even after page cancellation.
                await Task { await migrations.refresh() }.value
                guard revision == generation else { return }
                try Task.checkCancellation()
                try await migrations.open(record, codexStore: codexStore)
                opened = true
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    func openPrepared(migrations: SessionMigrationModel, codexStore: CodexProviderStore) {
        guard let preparedRecord, !preparing else { return }
        preparing = true; error = nil
        work = Task {
            defer { preparing = false }
            do {
                try await migrations.open(preparedRecord, codexStore: codexStore)
                opened = true
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    func cancel() {
        generation += 1
        work?.cancel(); work = nil
        loading = false
    }
}

extension MigrationClient {
    var migrationMark: ProductBrandMark.Brand {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .cursorCLI, .cursorDesktop: return .cursor
        }
    }

    var migrationTint: Color {
        switch self {
        case .claude: return Theme.claude
        case .codex: return Theme.external
        case .cursorCLI, .cursorDesktop: return Theme.cursor
        }
    }
}

extension MigrationTarget {
    var migrationDetail: String {
        switch self {
        case .claude: return "当前配置"
        case .claudeCodexModel: return "Codex 自定义模型"
        case .codexCurrent: return "当前配置"
        case .codexOfficial: return "官方登录"
        case .cursorCLI: return "Auto · 终端"
        case .cursorDesktop: return "项目模型 · 桌面"
        }
    }
}

struct SessionMigrationView: View {
    let sources: [MigrationSource]
    @ObservedObject var draft: SessionMigrationDraft
    @EnvironmentObject private var migrations: SessionMigrationModel
    @EnvironmentObject private var codexStore: CodexProviderStore
    @State private var sourceSearch = ""
    @State private var historySearch = ""
    @State private var historyClient: MigrationClient?
    @State private var showsMessages = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectableSources: [MigrationSource] {
        var result = sources
        if let selected = migrations.selectedSource, !result.contains(where: { $0.id == selected.id }) {
            result.insert(selected, at: 0)
        }
        return result.filter {
            sourceSearch.isEmpty || ($0.title + " " + $0.cwd + " " + $0.client.label)
                .localizedCaseInsensitiveContains(sourceSearch)
        }
    }

    private var history: [MigrationRecord] {
        migrations.records.filter {
            (historyClient == nil || $0.target.client == historyClient)
                && (historySearch.isEmpty || ($0.source.title + " " + $0.source.cwd + " " + $0.model
                    + " " + $0.source.client.label + " " + $0.target.label)
                    .localizedCaseInsensitiveContains(historySearch))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                introduction
                VStack(alignment: .leading, spacing: 20) {
                    route
                    HairlineDivider()
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 24) {
                            sourcePicker.frame(width: 240)
                            Divider()
                            editor.frame(minWidth: 420, maxWidth: .infinity)
                        }
                        VStack(alignment: .leading, spacing: 20) {
                            sourcePicker
                            HairlineDivider()
                            editor
                        }
                    }
                    HairlineDivider()
                    commitBar
                }
                .padding(20)
                .panelCard()
                historySection
            }
            .padding(.horizontal, Theme.Space.s24)
            .padding(.bottom, Theme.Space.s24)
        }
        .scrollHoverGate()
        .onAppear {
            if let source = migrations.selectedSource { draft.select(currentSource(source)) }
            else if let source = sources.first(where: { !$0.isBusy && !$0.isSubagent }) {
                migrations.selectedSource = source
                draft.select(source)
            }
            if draft.preview == nil, draft.preparedRecord == nil { draft.load() }
        }
        .onChange(of: migrations.selectedSource) {
            if let source = migrations.selectedSource { draft.select(currentSource(source)) }
        }
        .onChange(of: sources) {
            if let source = draft.source { draft.select(currentSource(source)) }
        }
        .onChange(of: draft.includeCompletedTools) { draft.load() }
        .onChange(of: draft.includeImages) { draft.load() }
        .onChange(of: draft.bridgeProviderID) { draft.bridgeModel = "" }
        .onDisappear { draft.cancel() }
    }

    private func currentSource(_ source: MigrationSource) -> MigrationSource {
        sources.first(where: { $0.id == source.id }) ?? source
    }

    private var introduction: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("迁移会话").font(Theme.Font.displayHero).foregroundColor(Theme.textPrimary)
                Text("带着历史，在另一个客户端继续。原会话保留，项目目录不变。")
                    .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            if !BuildChannel.allowsSystemIntegration {
                Label("开发版 · 界面预览", systemImage: "eye")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    .padding(.top, 6)
                    .help("开发版不读取外部会话历史，也不写入或打开目标客户端。")
            }
        }
    }

    private var route: some View {
        HStack(spacing: 16) {
            endpoint(client: draft.source?.client, caption: "来源",
                     detail: draft.source.map { $0.title.isEmpty ? $0.client.label : $0.title } ?? "选择一个会话")
            routeConnector
            VStack(spacing: 6) {
                Image(systemName: draft.preparedRecord == nil ? "text.bubble" : "checkmark.circle.fill")
                    .font(.system(size: 22)).foregroundColor(Theme.Ink.claude)
                Text(draft.preview.map { "\($0.messages.count) 条消息" } ?? "会话历史")
                    .font(Theme.Font.chromeEmph).foregroundColor(Theme.textPrimary)
                Text(draft.preparedRecord == nil ? "复制到新会话" : "已创建新会话")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            .frame(minWidth: 104)
            routeConnector
            endpoint(client: draft.target.client, caption: "目标", detail: draft.target.migrationDetail)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var routeConnector: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Image(systemName: "chevron.right").font(Theme.Font.microSemibold)
                .foregroundColor(Theme.textTertiary())
        }
        .frame(minWidth: 12, maxWidth: 90)
        .accessibilityHidden(true)
    }

    private func endpoint(client: MigrationClient?, caption: String, detail: String) -> some View {
        HStack(spacing: 10) {
            GlyphWell(name: "rectangle.dashed", size: 36, mark: client?.migrationMark)
            VStack(alignment: .leading, spacing: 4) {
                Text(caption).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                Text(client?.label ?? "未选择").font(Theme.Font.chromeEmph).foregroundColor(Theme.textPrimary)
                Text(detail).font(Theme.Font.caption).foregroundColor(Theme.textSecondary).lineLimit(1)
                    .help(detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择来源").font(Theme.Font.chromeEmph).foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(selectableSources.count)").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            InstrumentSearchField(prompt: "搜索会话或项目", text: $sourceSearch)
            if selectableSources.isEmpty {
                Text(sourceSearch.isEmpty ? "没有可用来源。先在客户端开始会话，或从下方记录再次迁移。" : "没有匹配的会话。试试项目名称。")
                    .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(selectableSources) { source in
                            sourceRow(source)
                        }
                    }
                }
                .frame(height: 250)
            }
        }
        .disabled(draft.preparing)
    }

    private func sourceRow(_ source: MigrationSource) -> some View {
        let selected = draft.source?.id == source.id
        return Button { migrations.selectedSource = source; draft.select(source) } label: {
            HStack(alignment: .top, spacing: 8) {
                GlyphWell(name: "", size: 22, mark: source.client.migrationMark)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.title.isEmpty ? source.client.label : source.title)
                        .font(Theme.Font.chrome).foregroundColor(Theme.textPrimary).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(URL(fileURLWithPath: source.cwd).lastPathComponent)
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary).lineLimit(1)
                    Text(source.isSubagent ? "子代理 · 请选父会话" : source.isBusy ? "等待回合结束" : source.client.label)
                        .font(Theme.Font.micro).foregroundColor(source.isBusy ? Theme.Ink.warning : Theme.textSecondary)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.Ink.claude)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.claude.opacity(0.10) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(MigrationChoiceStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(source.cwd)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择目标").font(Theme.Font.chromeEmph).foregroundColor(Theme.textPrimary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
                ForEach(MigrationTarget.allCases) { target in
                    targetButton(target)
                }
            }
            .disabled(draft.preparing || draft.preparedRecord != nil || draft.source == nil)
            targetConfiguration
            HairlineDivider()
            HStack {
                Text("携带内容").font(Theme.Font.chromeEmph).foregroundColor(Theme.textPrimary)
                Spacer()
                Text("对话文本始终保留").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 20) {
                Toggle("已完成工具", isOn: $draft.includeCompletedTools)
                    .help("携带已完成工具的输入和结果，原工具不会重新执行。")
                Toggle("用户图片", isOn: $draft.includeImages)
                    .help("图片会发送给目标模型；文档、音频和 attachedFiles 不迁移。")
            }
            .toggleStyle(.instrument)
            .font(Theme.Font.bodySmall)
            .disabled(draft.preparing || draft.preparedRecord != nil || draft.source == nil
                      || draft.source?.client == .cursorCLI)
            if draft.includeImages && draft.target.client == .cursorCLI {
                notice("Cursor CLI 不能写入图片。请选择其他目标，或关闭用户图片。", warning: true)
            }
            if let preview = draft.preview { previewContent(preview) }
        }
    }

    private func targetButton(_ target: MigrationTarget) -> some View {
        let selected = draft.target == target
        let sameClaude = draft.source?.client == .claude && target == .claude
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { draft.target = target }
        } label: {
            HStack(spacing: 8) {
                GlyphWell(name: "", size: 24, mark: target.client.migrationMark)
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.client.label).font(Theme.Font.chromeEmph).foregroundColor(Theme.textPrimary)
                    Text(target.migrationDetail).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? Theme.Ink.claude : Theme.textTertiary())
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.claude.opacity(0.10) : Theme.fieldWell))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.claude.opacity(0.55) : Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(MigrationChoiceStyle())
        .disabled(sameClaude)
        .opacity(sameClaude ? 0.45 : 1)
        .accessibilityLabel(target.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(sameClaude ? "同一客户端可直接继续原会话" : target.label)
    }

    @ViewBuilder private var targetConfiguration: some View {
        if draft.target == .codexOfficial {
            TextField("官方账号可用的模型名称", text: $draft.officialModel)
                .textFieldStyle(InstrumentFieldStyle())
                .accessibilityLabel("官方模型名称")
                .disabled(draft.preparing || draft.preparedRecord != nil)
        } else if draft.target == .claudeCodexModel {
            HStack {
                Picker("供应商", selection: $draft.bridgeProviderID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach(codexStore.providers.filter { !$0.apiKey.isEmpty }) {
                        Text($0.name).tag(Optional($0.id))
                    }
                }
                if let provider = codexStore.providers.first(where: { $0.id == draft.bridgeProviderID }) {
                    Picker("模型", selection: $draft.bridgeModel) {
                        Text("请选择").tag("")
                        ForEach(provider.models) { Text($0.name).tag($0.name) }
                    }
                }
            }
            .disabled(draft.preparing || draft.preparedRecord != nil)
            notice("此会话通过 ClaudeBar 代理连接，继续时需保持 ClaudeBar 运行。")
        } else if draft.target == .cursorDesktop {
            notice("沿用此项目已有聊天的模型设置。创建后打开新聊天，历史名称以「ClaudeBar · 迁移」开头。")
        } else {
            notice(draft.target == .cursorCLI ? "将在终端打开 Cursor CLI。" : "使用目标客户端的账号、配置与权限。")
        }
    }

    private func previewContent(_ preview: MigrationPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label("\(preview.messages.count) 条消息", systemImage: "text.bubble")
                Text(ByteCountFormatter.string(fromByteCount: Int64(preview.textBytes), countStyle: .file))
                if preview.completedToolCount > 0 { Text("\(preview.completedToolCount) 项工具") }
                if preview.imageCount > 0 { Text("\(preview.imageCount) 张图片") }
                Spacer(minLength: 0)
            }
            .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            let users = preview.messages.filter { $0.role == .user }.count
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.claude).frame(width: proxy.size.width * CGFloat(users) / CGFloat(max(1, preview.messages.count)))
                    Rectangle().fill(Theme.cursor)
                }
            }
            .frame(height: 5).clipShape(Capsule()).accessibilityHidden(true)
            HStack {
                Text("用户 \(users) · 助手 \(preview.messages.count - users)")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                Spacer()
                Button(showsMessages ? "收起历史" : "预览历史") { showsMessages.toggle() }
                    .buttonStyle(.link).font(Theme.Font.caption)
            }
            if showsMessages {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(preview.messages.enumerated()), id: \.offset) { _, message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.tool.map { "工具 · " + $0.name } ?? (message.role == .user ? "用户" : "助手"))
                                    .font(Theme.Font.microSemibold).foregroundColor(Theme.textSecondary)
                                Text(message.text).font(Theme.Font.bodySmall).foregroundColor(Theme.textPrimary)
                                    .textSelection(.enabled)
                                if message.carriedImageCount > 0 {
                                    Label("\(message.carriedImageCount) 张图片", systemImage: "photo")
                                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                                }
                            }
                            HairlineDivider()
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(height: 210)
            }
            ForEach(preview.omissions, id: \.self) { notice($0, warning: true) }
        }
    }

    private var commitBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                commitStatus.frame(maxWidth: .infinity, alignment: .leading)
                commitActions
            }
            VStack(alignment: .leading, spacing: 12) {
                commitStatus
                HStack { Spacer(); commitActions }
            }
        }
    }

    private var commitStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = draft.error { notice(error, warning: true) }
            if draft.preparedRecord != nil {
                Label(draft.opened ? "已创建并打开 · 可以在目标客户端继续" : "新会话已创建 · 可以重新打开",
                      systemImage: "checkmark.circle.fill")
                    .font(Theme.Font.bodySmall).foregroundColor(Theme.Ink.success)
            } else if !BuildChannel.allowsSystemIntegration {
                notice("正式版可读取历史并执行迁移。开发版仅展示工作流程。")
            } else if draft.source?.isSubagent == true {
                notice("请从父会话迁移，子代理会话不能作为来源。", warning: true)
            } else if draft.source?.isBusy == true {
                notice("等待当前回合结束，并处理待确认操作后再迁移。", warning: true)
            } else if draft.loading {
                ProgressView("正在读取会话历史…").controlSize(.small).font(Theme.Font.caption)
            } else {
                Label(draft.preview == nil ? "选择来源后预览历史" : "历史已就绪 · 原会话保留", systemImage: "doc.on.doc")
                    .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var commitActions: some View {
        HStack(spacing: 8) {
            if draft.error != nil && draft.preparedRecord == nil {
                ActionButton("重新读取") { draft.load() }.disabled(draft.preparing)
            }
            if draft.preparedRecord != nil {
                ActionButton("新建迁移") { draft.resetPrepared() }.disabled(draft.preparing)
                ActionButton(draft.preparing ? "正在打开…" : "打开新会话", tone: .accent, emphasis: .primary) {
                    draft.openPrepared(migrations: migrations, codexStore: codexStore)
                }
                .disabled(draft.preparing || migrations.opening != nil || !BuildChannel.allowsSystemIntegration)
            } else {
                ActionButton(draft.preparing ? "正在迁移…" : "迁移并打开", symbol: "arrow.right", tone: .accent, emphasis: .primary) {
                    draft.prepare(migrations: migrations, codexStore: codexStore)
                }
                .disabled(!draft.canPrepare || migrations.opening != nil)
            }
        }
    }

    private func notice(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(Theme.Font.caption)
            .foregroundColor(warning ? Theme.Ink.warning : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("迁移记录").font(Theme.Font.chromeEmph).foregroundColor(Theme.textPrimary)
                Text("\(migrations.records.count)").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                Spacer()
                ActionButton("刷新", symbol: "arrow.clockwise") { Task { await migrations.refresh() } }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    historyFilter
                    Spacer(minLength: 0)
                    InstrumentSearchField(prompt: "搜索记录、项目或模型", text: $historySearch).frame(width: 240)
                }
                VStack(alignment: .leading, spacing: 12) {
                    historyFilter
                    InstrumentSearchField(prompt: "搜索记录、项目或模型", text: $historySearch)
                }
            }
            if history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(migrations.records.isEmpty ? "下一段旅程，从这里开始" : "没有匹配的迁移记录")
                        .font(Theme.Font.body).foregroundColor(Theme.textPrimary)
                    Text(migrations.records.isEmpty ? "完成迁移后，这里会保存来源、目标与模型。随时打开新会话，或继续迁移。" : "更换目标筛选，或清除搜索后重试。")
                        .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading).panelCard()
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(history) { record in
                        MigrationHistoryRow(record: record)
                        if record.id != history.last?.id { HairlineDivider().padding(.leading, 42) }
                    }
                }
                .padding(.horizontal, 16).panelCard()
            }
        }
    }

    private var historyFilter: some View {
        SegmentedCapsule(items: [nil] + MigrationClient.allCases.map { Optional($0) }, selection: historyClient,
                         title: { $0?.label ?? "全部目标" }, onSelect: { historyClient = $0 })
    }
}

/// Selection controls keep their geometry while hover and press explain the hit area.
private struct MigrationChoiceStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hovered ? Theme.claude.opacity(0.45) : .clear, lineWidth: 1))
            .onHover { hovered = $0 }
    }
}

private struct MigrationHistoryRow: View {
    let record: MigrationRecord
    @EnvironmentObject private var migrations: SessionMigrationModel
    @EnvironmentObject private var codexStore: CodexProviderStore
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    summary
                    actions
                }
                VStack(alignment: .leading, spacing: 12) {
                    summary
                    HStack { Spacer(); actions }
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Label(record.source.cwd, systemImage: "folder")
                        .font(Theme.Font.captionMono).textSelection(.enabled)
                    Text("目标配置：" + record.target.label + " · " + record.model).font(Theme.Font.caption)
                    Text(record.createdAt, format: .dateTime.year().month().day().hour().minute()).font(Theme.Font.caption)
                    ForEach(record.omissions, id: \.self) {
                        Text($0).font(Theme.Font.caption).foregroundColor(Theme.Ink.warning)
                    }
                }
                .foregroundColor(Theme.textSecondary).padding(.leading, 28)
            }
        }
        .padding(.vertical, 16)
    }

    private var summary: some View {
        Button { expanded.toggle() } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(Theme.Font.microSemibold).foregroundColor(Theme.textSecondary)
                    .frame(width: 16, height: 22)
                VStack(alignment: .leading, spacing: 8) {
                    Text(record.source.title.isEmpty ? record.source.client.label : record.source.title)
                        .font(Theme.Font.chromeEmph).foregroundColor(Theme.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        GlyphWell(name: "", size: 18, mark: record.source.client.migrationMark)
                        Text(record.source.client.label)
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                        GlyphWell(name: "", size: 18, mark: record.target.client.migrationMark)
                        Text(record.target.client.label)
                        Text("· \(record.messageCount) 条消息")
                    }
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(record.model).lineLimit(1).truncationMode(.middle)
                        Text("·")
                        Text(record.createdAt, style: .relative)
                    }
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(record.source.title)，\(record.source.client.label) 迁移到 \(record.target.label)，\(record.messageCount) 条消息")
        .accessibilityValue(expanded ? "详情已展开" : "详情已收起")
        .help(expanded ? "收起迁移详情" : "查看项目、配置和迁移详情")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            SessionMigrationButton(source: record.targetSource, labeled: true, actionTitle: "再次迁移")
            ActionButton(migrations.opening == record.id ? "正在打开…" : "打开会话") {
                Task {
                    do { try await migrations.open(record, codexStore: codexStore) }
                    catch { migrations.error = error.localizedDescription }
                }
            }
            .disabled(migrations.opening != nil || !BuildChannel.allowsSystemIntegration)
        }
    }
}
