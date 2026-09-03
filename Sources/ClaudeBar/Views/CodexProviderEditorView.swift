import SwiftUI

/// Codex provider editor — layout only. All state, validation, and
/// persistence live in `CodexProviderEditorModel` (@Observable). Mirrors
/// `ProviderEditorView` with Codex-specific fields (wire_api, reasoning
/// effort, preserve-official-login).
struct CodexProviderEditorView: View {
    @ObservedObject var codexStore: CodexProviderStore
    @State private var model = CodexProviderEditorModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if model.selected != nil {
                detailPane
            } else {
                emptyState
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .onChange(of: model.selectedID) { _, _ in
            model.loadSelected()
        }
        .onAppear { model.attach(store: codexStore) }
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

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Codex 供应商")
                .font(Theme.Font.labelSection)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Theme.Space.s16 - 2).padding(.top, Theme.Space.s12).padding(.bottom, Theme.Space.s6)

            List(selection: $model.selectedID) {
                ForEach(codexStore.providers) { provider in
                    HStack(spacing: Theme.Space.s8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.name).font(Theme.Font.body)
                                .lineLimit(1).truncationMode(.tail)
                            Text("\(provider.models.count) 个模型")
                                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Theme.Space.s8)
                        if provider.id == codexStore.activeProviderID {
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
                accent: Theme.codex,
                canDuplicateOrDelete: model.selectedID != nil,
                onNew: { model.addNew() },
                onPreset: { model.addFromPreset($0) },
                onDuplicate: { model.duplicateSelected() },
                onDelete: { model.deleteSelected() },
                onImportFromClaude: { model.importFromClaude() }
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
            Label("供应商配置", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            EditorField(label: "名称", error: model.nameError) {
                TextField("e.g. DeepSeek", text: $model.name)
                    .textFieldStyle(.roundedBorder)
            }
            EditorField(label: "API Key") {
                TextField("sk-...", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.microMono)
            }
            EditorField(label: "Base URL", error: model.urlError) {
                TextField("https://api.deepseek.com", text: $model.baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top, spacing: Theme.Space.s16) {
                EditorField(label: "协议") {
                    Picker("", selection: $model.wireAPI) {
                        Text("Responses（原生）").tag("responses")
                        Text("Chat Completions").tag("chat")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                EditorField(label: "推理强度") {
                    Picker("", selection: modelReasoningEffortBinding) {
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
                    .frame(width: 120)
                }
            }
            Text("选择「默认」则不写入 model_reasoning_effort。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
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
            Text("保留官方登录时，第三方密钥写入 OPENAI_API_KEY，官方令牌保持不变。桌面端模型选择器的限制由上游决定，CLI 不受影响。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
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
                    .frame(height: 220) // fixed: unbounded inner ScrollView was inflating card height
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
                    TextField("e.g. deepseek-chat", text: model.binding(for: editingID, keyPath: \.name))
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.microMono)
                }
                HStack(alignment: .top, spacing: Theme.Space.s16) {
                    EditorField(label: "上下文窗口") {
                        TextField("400000", text: model.binding(for: editingID, keyPath: \.contextWindow))
                            .textFieldStyle(.roundedBorder)
                    }
                    EditorField(label: "自动压缩阈值") {
                        TextField("360000", text: model.binding(for: editingID, keyPath: \.autoCompactTokenLimit))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Text("对应 Claude 的上下文窗口与自动压缩阈值。Codex 将压缩上限限制为窗口的 90%。留空则不写入，运行时按窗口 × 90% 计算。")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
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

    private func modelRow(_ m: EditableCodexModel) -> some View {
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
            .selectionTint(isSelected, color: Theme.codex, corner: 5)
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
                }
                if let note = codexStore.importSummary {
                    Text(note)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                if let err = codexStore.errorMessage {
                    Text(err)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.statusError)
                        .lineLimit(1)
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
                .tint(model.isSaveFlashActive ? Theme.statusBusy : Theme.codex)
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
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(Theme.Font.titleMedium).foregroundColor(Theme.textSecondary.opacity(0.5))
            Text("请选择供应商，或从预设添加")
                .foregroundColor(Theme.textSecondary).font(Theme.Font.body)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modelReasoningEffortBinding: Binding<String> {
        if let editingID = model.editingModelID {
            return model.binding(for: editingID, keyPath: \.reasoningEffort)
        }
        return .constant("")
    }
}
