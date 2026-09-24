import SwiftUI

/// One saved connection, in the same form as catalog setup. The directory is
/// the provider list; this sheet never shows a second navigation column.
struct ProviderConnectionRoute: Identifiable {
    let id: UUID
    var isNew: Bool
}

struct ProviderConnectionModel: Identifiable, Equatable {
    var id: UUID
    var name: String
    var reasoningEffort = ""
    var contextWindow = ""
    var autoCompactTokenLimit = ""
    var contextTokens = ""
    var disableCompact = false
    var disableExperimentalBetas = false
}

struct ProviderConnectionDraft: Identifiable {
    var id: UUID
    var isNew: Bool
    var catalogID: String?
    var name: String
    var apiKey: String
    var baseURL: String
    var wireAPI: String
    var preserveOfficialLogin: Bool
    var disableResponseStorage: Bool
    var requiresOpenAIAuth: Bool
    var captureEnabled: Bool
    var profileID: UUID?
    var models: [ProviderConnectionModel]
    var activeModelID: UUID?
    var pendingModel = ""

    var entry: ProviderCatalogEntry? {
        ProviderCatalogEntry.entry(id: catalogID) ?? ProviderCatalogEntry.matching(baseURL: baseURL)
    }

    var modelNames: [String] {
        models.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写供应商名称。" }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { return "请填写有效的接口地址，不要在地址中附带密钥。" }
        // Same rule as the preset flow: a loopback endpoint needs no key.
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !ProviderCatalogEntry.isLocalEndpoint(trimmed) { return "请填写 API Key（自建网关填写网关 Key）。" }
        if modelNames.isEmpty { return "请至少保留一个模型 ID。" }
        let lowered = modelNames.map { $0.lowercased() }
        if Set(lowered).count != lowered.count { return "模型 ID 不能重复。" }
        return nil
    }

    static func custom(client: ProviderClient, id: UUID) -> ProviderConnectionDraft {
        ProviderConnectionDraft(
            id: id, isNew: true, catalogID: nil, name: "", apiKey: "", baseURL: "",
            wireAPI: client == .codex ? "responses" : "anthropic",
            preserveOfficialLogin: true, disableResponseStorage: true, requiresOpenAIAuth: false,
            captureEnabled: false, profileID: UUID(), models: [], activeModelID: nil)
    }
}

struct ProviderConnectionEditor: View {
    let client: ProviderClient
    @State var draft: ProviderConnectionDraft
    let onSave: (ProviderConnectionDraft) -> String?
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmDelete = false

    private var title: String {
        if draft.isNew { return "自定义供应商" }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "配置供应商" : "配置 " + name
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    credentials
                    if client == .codex { codexOptions }
                    modelsSection
                    if let message = error ?? draft.validationError {
                        Label(message, systemImage: error == nil ? "info.circle" : "exclamationmark.circle")
                            .font(Theme.Font.caption)
                            .foregroundStyle(error == nil ? Theme.textSecondary : Theme.Ink.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 640, height: 680)
        .foregroundStyle(Theme.textPrimary)
        .background(Theme.cardSurface)
        .alert("删除这个供应商？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(draft.name)」会从 Claude Code 和 Codex 两边移除。正在使用它时，会回到官方连接。")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ProviderIdentityMark(entry: draft.entry, name: draft.name.isEmpty ? "自定义" : draft.name, size: 56)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(draft.entry?.detail ?? "名称、Key 和模型会同步到另一端。接口地址按各自协议保留。")
                    .font(Theme.Font.bodySmall).foregroundStyle(Theme.textSecondary)
                Label(client.title, systemImage: "terminal")
                    .font(Theme.Font.caption).foregroundStyle(ProviderCardState.ready.color)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(ProviderActionStyle()).help("关闭；未保存的修改不提交")
        }.padding(24)
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("连接凭据", systemImage: "key.horizontal").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let site = draft.entry?.website, let url = URL(string: site) {
                    Link(destination: url) { Label("获取 Key", systemImage: "arrow.up.right") }
                        .font(Theme.Font.caption).foregroundStyle(ProviderCardState.ready.color)
                }
            }
            field("配置名称") { TextField("供应商名称", text: $draft.name) }
            field("API Key") { APIKeyField(text: $draft.apiKey, localEndpoint: ProviderCatalogEntry.isLocalEndpoint(draft.baseURL)) }
            field("接口地址") { TextField("https://…", text: $draft.baseURL) }
        }
    }

    private var codexOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 协议", systemImage: "arrow.left.arrow.right").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(["responses", "chat"], id: \.self) { wire in
                    Button {
                        draft.wireAPI = wire
                    } label: {
                        Label(wire == "chat" ? "Chat Completions" : "Responses",
                              systemImage: draft.wireAPI == wire ? "checkmark.circle.fill" : "circle")
                    }.buttonStyle(ProviderActionStyle(prominent: draft.wireAPI == wire))
                }
                Spacer()
                Menu {
                    ForEach(reasoningOptions, id: \.self) { effort in
                        Button(effort.isEmpty ? "默认" : effort) { setReasoning(effort) }
                    }
                } label: {
                    Label(reasoningLabel, systemImage: "brain")
                }.menuStyle(.borderlessButton).fixedSize().help("当前模型的推理强度。默认不写入 model_reasoning_effort。")
            }
            Text(draft.wireAPI == "chat" ? "通过本地转换接入 Codex。" : "使用供应商原生 Responses 接口。")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Toggle("切换时保留官方登录", isOn: $draft.preserveOfficialLogin)
                .font(Theme.Font.bodySmall)
            Text("只决定 auth.json 留不留。有 Key 时这条路由写成 requires_openai_auth = false，不再用 ChatGPT 套餐额度锁住输入。")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Toggle("不向云端持久化 Responses", isOn: $draft.disableResponseStorage)
                .font(Theme.Font.bodySmall)
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("模型", systemImage: "square.stack.3d.up").font(.system(size: 15, weight: .semibold))
                    Text("已选 \(draft.modelNames.count) 个 · 带勾的是默认模型")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                ProviderModelFetchButton(baseURL: draft.baseURL, apiKey: draft.apiKey, wireAPI: draft.wireAPI,
                                          existingNames: Set(draft.modelNames.map { $0.lowercased() })) { names in
                    add(Array(names))
                }.frame(maxWidth: 220, alignment: .trailing)
            }
            HStack(spacing: 8) {
                TextField("添加模型 ID", text: $draft.pendingModel)
                    .textFieldStyle(ProviderInputStyle()).font(Theme.Font.bodySmall)
                    .onSubmit(addPending)
                Button("添加", action: addPending).buttonStyle(ProviderActionStyle())
                    .disabled(draft.pendingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(draft.models) { model in
                HStack(spacing: 8) {
                    Button { draft.activeModelID = model.id } label: {
                        Image(systemName: model.id == draft.activeModelID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.id == draft.activeModelID ? ProviderCardState.ready.color : Theme.textSecondary)
                    }.buttonStyle(.plain).help("设为默认模型")
                    Text(model.name).font(Theme.Font.bodySmall).lineLimit(1)
                    Spacer()
                    Button {
                        draft.models.removeAll { $0.id == model.id }
                        if draft.activeModelID == model.id { draft.activeModelID = draft.models.first?.id }
                    } label: { Image(systemName: "minus") }
                        .buttonStyle(ProviderActionStyle()).help("移除 " + model.name)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if onDelete != nil {
                Button("删除", role: .destructive) { confirmDelete = true }
                    .buttonStyle(ProviderActionStyle())
            }
            Spacer()
            Button("取消") { dismiss() }.buttonStyle(ProviderActionStyle()).keyboardShortcut(.cancelAction)
            Button {
                guard draft.validationError == nil else { return }
                if let failure = onSave(draft) { error = failure } else { dismiss() }
            } label: { Label("保存", systemImage: "checkmark") }
                .buttonStyle(ProviderActionStyle(prominent: true))
                .disabled(draft.validationError != nil)
                .keyboardShortcut(.defaultAction)
        }.padding(24).background(Theme.bgPrimary)
    }

    private var reasoningOptions: [String] { ["", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"] }
    private var reasoningLabel: String {
        let effort = draft.models.first { $0.id == draft.activeModelID }?.reasoningEffort ?? ""
        return effort.isEmpty ? "推理 · 默认" : "推理 · " + effort
    }

    private func setReasoning(_ effort: String) {
        guard let index = draft.models.firstIndex(where: { $0.id == draft.activeModelID }) else { return }
        draft.models[index].reasoningEffort = effort
    }

    private func addPending() {
        let name = draft.pendingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        add([name])
        draft.pendingModel = ""
    }

    private func add(_ names: [String]) {
        var existing = Set(draft.modelNames.map { $0.lowercased() })
        for name in names.sorted() {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, existing.insert(trimmed.lowercased()).inserted else { continue }
            let row = ProviderConnectionModel(id: UUID(), name: trimmed)
            draft.models.append(row)
            if draft.activeModelID == nil { draft.activeModelID = row.id }
        }
        error = nil
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            content().textFieldStyle(ProviderInputStyle()).font(Theme.Font.bodySmall)
        }
    }
}
