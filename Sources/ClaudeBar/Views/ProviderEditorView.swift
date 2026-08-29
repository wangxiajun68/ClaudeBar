import SwiftUI

/// Provider editor — layout only. All state, validation, and persistence live
/// in `ProviderEditorModel` (@Observable); this view binds and renders.
struct ProviderEditorView: View {
    @ObservedObject var providerStore: ProviderStore
    @State private var model = ProviderEditorModel()

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
            Text("PROVIDERS")
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
                            Text("\(provider.models.count) model\(provider.models.count == 1 ? "" : "s")")
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
                Button(action: { model.addNew() }) { Image(systemName: "plus") }
                    .buttonStyle(.glass).help("Add provider")
                Button(action: { model.duplicateSelected() }) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.glass)
                    .disabled(model.selectedID == nil).help("Duplicate")
                Button(action: { model.deleteSelected() }) { Image(systemName: "trash") }
                    .buttonStyle(.glass)
                    .disabled(model.selectedID == nil).help("Delete")
                Spacer()
            }
            .padding(.horizontal, Theme.Space.s8 + 2).padding(.vertical, Theme.Space.s8)
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
            Label("Provider Configuration", systemImage: "server.rack")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            EditorField(label: "Name", error: model.nameError) {
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
        }
        .padding(Theme.Space.s12)
        .panelCard()
    }

    private var modelConfigCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Model Configuration", systemImage: "cpu")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.bottom, Theme.Space.s12)
            HStack(alignment: .top, spacing: 0) {
                modelList
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
                Text("No models")
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
                TextField("Add…", text: $model.newModelName)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.bodySmall)
                    .onSubmit { model.addModel() }
                Button(action: { model.addModel() }) {
                    Image(systemName: "plus.circle.fill")
                        .font(Theme.Font.bodyLarge)
                }
                .buttonStyle(.glass)
                .disabled(model.newModelName.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add model")
            }
            .padding(Theme.Space.s8)
        }
        .frame(width: 170)
    }

    @ViewBuilder private var modelDetail: some View {
        if let idx = model.models.firstIndex(where: { $0.id == model.editingModelID }) {
            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                EditorField(label: "Model Name") {
                    TextField("e.g. deepseek-v4-pro[1m]", text: $model.models[idx].name)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.microMono)
                }
                HStack(alignment: .top, spacing: Theme.Space.s16) {
                    EditorField(label: "Context Tokens") {
                        TextField("1000000", text: $model.models[idx].contextTokens)
                            .textFieldStyle(.roundedBorder)
                    }
                    EditorField(label: "Auto Compact Window") {
                        TextField("1000000", text: $model.models[idx].autoCompactWindow)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Toggle("Disable Compact", isOn: $model.models[idx].disableCompact)
                    .font(Theme.Font.bodySmall)
                Toggle("Disable Experimental Betas", isOn: $model.models[idx].disableExperimentalBetas)
                    .font(Theme.Font.bodySmall)
            }
            .padding(Theme.Space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Select a model")
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
        .help(isDefault ? "默认模型:切换到该供应商时自动选用" : "右键设为默认")
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
                        Text("Save")
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(!model.canSave)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Save provider (⌘S)")
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
            Text("Select a provider or add a new one")
                .foregroundColor(Theme.textSecondary).font(Theme.Font.body)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Field

private struct EditorField<Content: View>: View {
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
