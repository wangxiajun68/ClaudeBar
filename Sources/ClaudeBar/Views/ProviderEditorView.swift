import SwiftUI

/// Provider editor — layout only. All state, validation, and persistence live
/// in `ProviderEditorModel` (@Observable); this view binds and renders.
struct ProviderEditorView: View {
    @ObservedObject var providerStore: ProviderStore
    @Binding var focusProviderID: UUID?
    var embedded: Bool = false
    var onBack: (() -> Void)? = nil
    @State private var model = ProviderEditorModel()
    @ObservedObject private var tests = ConnectivityTestCenter.shared

    init(providerStore: ProviderStore,
         focusProviderID: Binding<UUID?> = .constant(nil),
         embedded: Bool = false,
         onBack: (() -> Void)? = nil) {
        self.providerStore = providerStore
        _focusProviderID = focusProviderID
        self.embedded = embedded
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            if embedded { embeddedToolbar }
            HStack(spacing: 0) {
                sidebar
                Divider()
                if model.selected != nil {
                    detailPane
                } else {
                    emptyState
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selectedID) { _, _ in
            model.loadSelected()
        }
        .onChange(of: focusProviderID) { _, id in
            guard let id else { return }
            model.focusProvider(id: id)
            focusProviderID = nil
        }
        .onAppear { model.attach(store: providerStore) }
        .task(id: model.saveToken) {
            guard model.saveToken > 0 else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            model.clearSaveFlash()
        }
        .sheet(isPresented: $model.showModelImport) {
            ModelImportSheet(
                candidates: model.modelImportCandidates,
                existingNames: model.existingModelNames,
                onImport: { model.importSelectedModels($0) },
                onCancel: { model.cancelModelImport() }
            )
        }
    }

    private var embeddedToolbar: some View {
        HStack(spacing: Theme.Space.s12) {
            Button {
                onBack?()
            } label: {
                Label("返回列表", systemImage: "chevron.left")
                    .font(Theme.Font.bodySmall)
            }
            .adaptiveGlassButton()
            Text("管理供应商")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.s16)
        .padding(.vertical, Theme.Space.s8)
        .background(Theme.base1.opacity(0.45))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("列表")
                .font(Theme.Font.labelSection)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Theme.Space.s16 - 2).padding(.top, Theme.Space.s12).padding(.bottom, Theme.Space.s6)

            List(selection: $model.selectedID) {
                ForEach(providerStore.providers) { provider in
                    HStack(spacing: Theme.Space.s8) {
                        Image(systemName: "server.rack")
                            .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.name).font(Theme.Font.body)
                                .lineLimit(1).truncationMode(.tail)
                            Text("\(provider.models.count) 个模型")
                                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Theme.Space.s8)
                        if provider.id == providerStore.activeProviderID {
                            Image(systemName: "checkmark.circle.fill")
                                .font(Theme.Font.bodySmall).foregroundColor(Theme.statusBusy)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(provider.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            ProviderEditorSidebar(
                accent: Theme.claude,
                canDuplicateOrDelete: model.selectedID != nil,
                onNew: { model.addNew() },
                onPreset: { model.addFromPreset($0) },
                onDuplicate: { model.duplicateSelected() },
                onDelete: { model.deleteSelected() }
            )
        }
        .frame(width: 220)
        .background(Theme.base1.opacity(0.45))
    }

    // MARK: - Detail

    private var detailPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s16) {
                    providerConfigCard
                    modelConfigCard
                }
                .padding(Theme.Space.s16)
            }

            footer
        }
    }

    private var providerConfigCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Label("供应商", systemImage: "server.rack")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            EditorField(label: "名称", error: model.nameError) {
                TextField("e.g. DeepSeek", text: $model.name)
                    .textFieldStyle(.roundedBorder)
            }
            EditorField(label: "API Key") {
                SecureField("sk-...", text: $model.authToken)
                    .textFieldStyle(.roundedBorder)
            }
            EditorField(label: "Base URL", error: model.urlError) {
                TextField("https://api.deepseek.com/anthropic", text: $model.baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Codex 将写入：\(ProviderBridge.openaiCompatibleURL(model.baseURL))")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(alignment: .top, spacing: Theme.Space.s16) {
                EditorField(label: "Codex 上游格式") {
                    Picker("", selection: $model.wireAPI) {
                        Text("Responses").tag("responses")
                        Text("Chat").tag("chat")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            Toggle("切换第三方供应商时保留官方登录", isOn: $model.preserveOfficialLogin)
                .font(Theme.Font.bodySmall)
            Toggle("requires_openai_auth", isOn: $model.requiresOpenAIAuth)
                .font(Theme.Font.bodySmall)
            Toggle(isOn: $model.disableResponseStorage) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("不向云端持久化 Responses")
                        .font(Theme.Font.bodySmall)
                    Text("对应 disable_response_storage。开启后上游不保存 Responses 会话，第三方中转建议开启。关闭后，官方 API 可跨请求续写同一条 Response。")
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textTertiary())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ConnectivityProbeButton(
                title: "检测连通性",
                help: "使用当前表单中的地址、密钥与所选模型发送最短请求，无需先保存。",
                outcome: tests.outcome(ConnectivityTestCenter.editorKey)
            ) {
                let name = model.models.first(where: { $0.id == model.editingModelID })?.name
                    ?? model.models.first(where: { $0.id == model.activeModelID })?.name
                    ?? model.models.first?.name
                    ?? ""
                tests.testEditor(baseURL: model.baseURL, apiKey: model.authToken,
                                 modelName: name, wireAPI: model.wireAPI)
            }
        }
        .padding(Theme.Space.s12)
        .panelCard()
    }

    private var modelConfigCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s8) {
                Label("模型", systemImage: "cpu")
                    .font(Theme.Font.titleSmall)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Button(action: { model.fetchModelsFromAPI() }) {
                    if model.isFetchingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("拉取模型", systemImage: "arrow.down.circle")
                            .font(Theme.Font.caption)
                    }
                }
                .adaptiveGlassButton()
                .disabled(model.isFetchingModels || model.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("请求 Base URL 下的 /models 接口，勾选后导入")
            }
            .padding(.bottom, Theme.Space.s12)
            if let note = model.modelFetchMessage {
                Text(note)
                    .font(Theme.Font.caption)
                    .foregroundColor(note.contains("失败") || note.contains("鉴权") || note.contains("无法")
                                    ? Theme.statusError : Theme.textSecondary)
                    .lineLimit(2)
                    .padding(.bottom, Theme.Space.s8)
            }
            HStack(alignment: .top, spacing: 0) {
                modelList
                    .frame(height: 220)
                Divider()
                modelDetail
            }
        }
        .padding(Theme.Space.s12)
        .panelCard()
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            if model.models.isEmpty {
                Text("暂无模型")
                    .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
                    .padding(.vertical, Theme.Space.s12).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.models) { m in
                            modelRow(m)
                        }
                    }
                    .padding(.vertical, Theme.Space.s6)
                }
            }

            Divider()
            HStack(spacing: Theme.Space.s4) {
                TextField("添加模型", text: $model.newModelName)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.bodySmall)
                    .onSubmit { model.addModel() }
                Button(action: { model.addModel() }) {
                    Image(systemName: "plus.circle.fill")
                        .font(Theme.Font.bodyLarge)
                }
                .adaptiveGlassButton()
                .disabled(model.newModelName.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("添加模型")
            }
            .padding(Theme.Space.s8)
        }
        .frame(width: 170)
    }

    @ViewBuilder private var modelDetail: some View {
        if let editingID = model.editingModelID,
           model.models.contains(where: { $0.id == editingID }) {
            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                EditorField(label: "模型名称") {
                    TextField("e.g. deepseek-v4-pro[1m]", text: model.binding(for: editingID, keyPath: \.name))
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.microMono)
                }
                HStack(alignment: .top, spacing: Theme.Space.s16) {
                    EditorField(label: "上下文窗口") {
                        TextField("1000000", text: model.binding(for: editingID, keyPath: \.contextTokens))
                            .textFieldStyle(.roundedBorder)
                    }
                    EditorField(label: "自动压缩阈值") {
                        TextField("1000000", text: model.binding(for: editingID, keyPath: \.autoCompactWindow))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                EditorField(label: "推理强度") {
                    Picker("", selection: model.binding(for: editingID, keyPath: \.reasoningEffort)) {
                        Text("默认").tag("")
                        Text("none").tag("none")
                        Text("minimal").tag("minimal")
                        Text("low").tag("low")
                        Text("medium").tag("medium")
                        Text("high").tag("high")
                        Text("xhigh").tag("xhigh")
                        Text("max").tag("max")
                        Text("ultra").tag("ultra")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 160, alignment: .leading)
                }
                Text("选择「默认」则不写入 model_reasoning_effort，由 Codex 或模型目录决定。")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("禁用压缩", isOn: model.binding(for: editingID, keyPath: \.disableCompact))
                    .font(Theme.Font.bodySmall)
                Toggle("禁用实验性 Beta", isOn: model.binding(for: editingID, keyPath: \.disableExperimentalBetas))
                    .font(Theme.Font.bodySmall)
            }
            .padding(Theme.Space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(editingID)
        } else {
            Text("请选择模型")
                .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func modelRow(_ m: EditableModel) -> some View {
        let isSelected = m.id == (model.editingModelID ?? model.models.first?.id)
        let isDefault = m.id == model.activeModelID
        return Button(action: { withAnimation(Theme.Animation.bouncy) { model.editingModelID = m.id } }) {
            HStack(spacing: Theme.Space.s6) {
                Text(m.name)
                    .font(Theme.Font.microMono)
                    .lineLimit(1)
                Spacer()
                if isDefault {
                    Text("默认")
                        .font(Theme.Font.microSemibold)
                        .foregroundColor(Theme.statusWarning)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.statusWarning.opacity(0.15)))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, Theme.Space.s8 + 2)
            .padding(.vertical, Theme.Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionTint(isSelected, color: Theme.claude, corner: 5)
        }
        .buttonStyle(.plain)
        .help(isDefault ? "默认模型：切换到该供应商时自动选用" : "右键设为默认")
        .contextMenu {
            if !isDefault {
                Button("设为默认") { withAnimation(Theme.Animation.bouncy) { model.setDefault(m.id) } }
            }
            Button("删除", role: .destructive) { model.deleteModel(m.id) }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Space.s12) {
                if let err = model.duplicateModelError {
                    Text(err)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.statusError)
                } else if model.isSaveFlashActive {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.statusBusy)
                        .transition(.opacity.combined(with: .scale))
                }
                Spacer()
                Button {
                    model.save()
                } label: {
                    if model.isSaving {
                        ProgressView().controlSize(.small)
                    } else if model.isSaveFlashActive {
                        Label("已保存", systemImage: "checkmark")
                    } else {
                        Text("保存")
                    }
                }
                .adaptiveGlassButton(prominent: true)
                .tint(model.isSaveFlashActive ? Theme.statusBusy : Theme.accent)
                .disabled(!model.canSave || model.isSaving)
                .keyboardShortcut(.return, modifiers: .command)
                .help("保存供应商 (⌘S)")
                .sensoryFeedback(.success, trigger: model.saveToken)
            }
            .padding(.horizontal, Theme.Space.s16 + Theme.Space.s4).padding(.vertical, Theme.Space.s12)
            .animation(Theme.Animation.bouncy, value: model.saveToken)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.s12) {
            Spacer()
            Image(systemName: "server.rack")
                .font(Theme.Font.titleMedium).foregroundColor(Theme.textSecondary.opacity(0.5))
            Text("请选择供应商，或从预设添加")
                .foregroundColor(Theme.textSecondary).font(Theme.Font.body)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Field

struct EditorField<Content: View>: View {
    let label: String
    var error: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text(label).font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            content()
            if let error {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.statusError)
                    .transition(.opacity)
            }
        }
    }
}
