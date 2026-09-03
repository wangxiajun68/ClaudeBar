import SwiftUI

/// Provider editor — layout only. All state, validation, and persistence live
/// in `ProviderEditorModel` (@Observable); this view binds and renders.
struct ProviderEditorView: View {
    @ObservedObject var providerStore: ProviderStore
    @State private var model = ProviderEditorModel()
    @State private var showPresets = false
    @ObservedObject private var tests = ConnectivityTestCenter.shared

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selectedID) { _, _ in
            model.loadSelected()
        }
        .onAppear { model.attach(store: providerStore) }
        // Hold the "saving" affordance briefly so a fast save still registers.
        .task(id: model.saveToken) {
            guard model.saveToken > 0 else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("供应商")
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

            HStack(spacing: Theme.Space.s6) {
                Button(action: { showPresets.toggle() }) { Image(systemName: "sparkles") }
                    .buttonStyle(.glass).help("从预设添加")
                Button(action: { model.addNew() }) { Image(systemName: "plus") }
                    .buttonStyle(.glass).help("添加供应商")
                Button(action: { model.duplicateSelected() }) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.glass)
                    .disabled(model.selectedID == nil).help("复制")
                Button(action: { model.deleteSelected() }) { Image(systemName: "trash") }
                    .buttonStyle(.glass)
                    .disabled(model.selectedID == nil).help("删除")
                Spacer()
            }
            .padding(.horizontal, Theme.Space.s8 + 2).padding(.vertical, Theme.Space.s8)
        }
        .frame(width: 220)
        .background(Theme.base1.opacity(0.45))
        .overlay(alignment: .bottom) {
            if showPresets { presetMenu }
        }
    }

    private var presetMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(CodexPreset.all, id: \.label) { preset in
                Button(action: {
                    model.addFromPreset(preset.provider)
                    showPresets = false
                }) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.label).font(Theme.Font.body)
                        Text(preset.provider.baseURL)
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.Space.s8).padding(.vertical, Theme.Space.s6)
            }
        }
        .padding(Theme.Space.s6)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.base1)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
        )
        .padding(Theme.Space.s8)
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
            Label("模型", systemImage: "cpu")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.bottom, Theme.Space.s12)
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
                .buttonStyle(.glass)
                .disabled(model.newModelName.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("添加模型")
            }
            .padding(Theme.Space.s8)
        }
        .frame(width: 170)
    }

    @ViewBuilder private var modelDetail: some View {
        if let idx = model.models.firstIndex(where: { $0.id == model.editingModelID }) {
            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                EditorField(label: "模型名称") {
                    TextField("e.g. deepseek-v4-pro[1m]", text: $model.models[idx].name)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.microMono)
                }
                HStack(alignment: .top, spacing: Theme.Space.s16) {
                    EditorField(label: "上下文窗口") {
                        TextField("1000000", text: $model.models[idx].contextTokens)
                            .textFieldStyle(.roundedBorder)
                    }
                    EditorField(label: "自动压缩阈值") {
                        TextField("1000000", text: $model.models[idx].autoCompactWindow)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                EditorField(label: "推理强度") {
                    Picker("", selection: $model.models[idx].reasoningEffort) {
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
                Toggle("禁用压缩", isOn: $model.models[idx].disableCompact)
                    .font(Theme.Font.bodySmall)
                Toggle("禁用实验性 Beta", isOn: $model.models[idx].disableExperimentalBetas)
                    .font(Theme.Font.bodySmall)
            }
            .padding(Theme.Space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                }
                Spacer()
                Button {
                    model.save()
                } label: {
                    if model.isSaving {
                        ProgressView().scaleEffect(0.5)
                    } else {
                        Text("保存")
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(!model.canSave)
                .keyboardShortcut(.return, modifiers: .command)
                .help("保存供应商 (⌘S)")
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
