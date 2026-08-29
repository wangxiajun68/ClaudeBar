import SwiftUI

struct ProviderEditorView: View {
    @ObservedObject var providerStore: ProviderStore
    @State private var selectedID: UUID?
    @State private var editingName: String = ""
    @State private var editingAuthToken: String = ""
    @State private var editingBaseURL: String = ""
    @State private var editingModels: [EditableModel] = []
    @State private var activeModelID: UUID?
    @State private var newModelName: String = ""
    @State private var showSaveSuccess: Bool = false

    /// Local editable copy of a ModelConfig
    struct EditableModel: Identifiable {
        var id: UUID
        var name: String = ""
        var contextTokens: String = ""
        var disableCompact: Bool = true
        var disableExperimentalBetas: Bool = true
        var autoCompactWindow: String = ""
    }

    private var selected: Provider? {
        providerStore.providers.first { $0.id == selectedID }
    }

    /// ID of the model currently being edited in the detail area
    @State private var editingModelID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left Sidebar (fixed width, not draggable)
            VStack(alignment: .leading, spacing: 0) {
                Text("PROVIDERS")
                    .font(Theme.Font.labelSection)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)

                List(selection: $selectedID) {
                    ForEach(providerStore.providers) { provider in
                        HStack(spacing: 8) {
                            Image(systemName: "server.rack")
                                .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.name).font(Theme.Font.body)
                                    .lineLimit(1).truncationMode(.tail)
                                Text("\(provider.models.count) model\(provider.models.count == 1 ? "" : "s")")
                                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
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

                HStack(spacing: 6) {
                    Button(action: addNew) { Image(systemName: "plus") }
                        .buttonStyle(.glass).help("Add provider")
                    Button(action: duplicateSelected) { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.glass)
                        .disabled(selectedID == nil).help("Duplicate")
                    Button(action: deleteSelected) { Image(systemName: "trash") }
                        .buttonStyle(.glass)
                        .disabled(selectedID == nil).help("Delete")
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(width: 220)
            .background(Theme.base1.opacity(0.45))

            Divider()

            // MARK: - Right Panel
            if selected != nil {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {

                            // ========== PROVIDER CONFIGURATION ==========
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Provider Configuration", systemImage: "server.rack")
                                    .font(Theme.Font.titleSmall)
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                    .fixedSize()
                                EditorField(label: "Name") {
                                    TextField("e.g. DeepSeek", text: $editingName)
                                        .textFieldStyle(.roundedBorder)
                                }
                                EditorField(label: "API Key") {
                                    TextField("sk-...", text: $editingAuthToken)
                                        .textFieldStyle(.roundedBorder)
                                }
                                EditorField(label: "Base URL") {
                                    TextField("https://api.deepseek.com/anthropic", text: $editingBaseURL)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            .padding(12)
                            .panelCard()

                            // ========== MODEL CONFIGURATION (master-detail) ==========
                            VStack(alignment: .leading, spacing: 0) {
                                Label("Model Configuration", systemImage: "cpu")
                                    .font(Theme.Font.titleSmall)
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.bottom, 12)
                                HStack(alignment: .top, spacing: 0) {
                                    // Model list (left)
                                    VStack(spacing: 0) {
                                        if editingModels.isEmpty {
                                            Text("No models")
                                                .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
                                                .padding(.vertical, 12).frame(maxWidth: .infinity)
                                        } else {
                                            ScrollView {
                                                VStack(spacing: 2) {
                                                    ForEach(editingModels) { model in
                                                        modelRow(model)
                                                    }
                                                }
                                                .padding(.vertical, 6)
                                            }
                                        }

                                        Divider()
                                        HStack(spacing: 4) {
                                            TextField("Add…", text: $newModelName)
                                                .textFieldStyle(.roundedBorder)
                                                .font(Theme.Font.bodySmall)
                                                .onSubmit { addModel() }
                                            Button(action: addModel) {
                                                Image(systemName: "plus.circle.fill")
                                                    .font(Theme.Font.bodyLarge)
                                            }
                                            .buttonStyle(.glass)
                                            .disabled(newModelName.trimmingCharacters(in: .whitespaces).isEmpty)
                                            .help("Add model")
                                        }
                                        .padding(8)
                                    }
                                    .frame(width: 170)

                                    Divider()

                                    // Selected model detail (right)
                                    if let idx = editingModels.firstIndex(where: { $0.id == editingModelID }) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            EditorField(label: "Model Name") {
                                                TextField("e.g. deepseek-v4-pro[1m]", text: $editingModels[idx].name)
                                                    .textFieldStyle(.roundedBorder)
                                                    .font(Theme.Font.microMono)
                                            }
                                            HStack(alignment: .top, spacing: 16) {
                                                EditorField(label: "Context Tokens") {
                                                    TextField("1000000", text: $editingModels[idx].contextTokens)
                                                        .textFieldStyle(.roundedBorder)
                                                }
                                                EditorField(label: "Auto Compact Window") {
                                                    TextField("1000000", text: $editingModels[idx].autoCompactWindow)
                                                        .textFieldStyle(.roundedBorder)
                                                }
                                            }
                                            Toggle("Disable Compact", isOn: $editingModels[idx].disableCompact)
                                                .font(Theme.Font.bodySmall)
                                            Toggle("Disable Experimental Betas", isOn: $editingModels[idx].disableExperimentalBetas)
                                                .font(Theme.Font.bodySmall)
                                        }
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        Text("Select a model")
                                            .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                            }
                            .padding(12)
                            .panelCard()
                        }
                        .padding(16)
                    }

                    // Fixed footer
                    Divider()
                    HStack(spacing: 12) {
                        if showSaveSuccess {
                            Label("Saved ✓", systemImage: "checkmark.circle.fill")
                                .foregroundColor(Theme.statusBusy).font(Theme.Font.bodySmall.weight(.medium))
                                .transition(.scale.combined(with: .opacity))
                        }
                        Spacer()
                        Button("Save") { saveCurrent() }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.accent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("Save provider (⌘S)")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .animation(Theme.Animation.bouncy, value: showSaveSuccess)
                }
            } else {
                VStack(spacing: 12) {
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
        .frame(minWidth: 720, minHeight: 500)
        .onChange(of: selectedID) { old, new in if old != new { loadSelected() } }
        .onAppear {
            if selectedID == nil, let first = providerStore.providers.first {
                selectedID = first.id
            }
        }
    }

    // MARK: - Data

    private func loadSelected() {
        guard let p = selected else { return }
        editingName = p.name
        editingAuthToken = p.authToken
        editingBaseURL = p.baseURL
        editingModels = p.models.map { EditableModel(
            id: $0.id, name: $0.name, contextTokens: $0.contextTokens,
            disableCompact: $0.disableCompact,
            disableExperimentalBetas: $0.disableExperimentalBetas,
            autoCompactWindow: $0.autoCompactWindow
        )}
        activeModelID = p.activeModelID ?? p.models.first?.id
        editingModelID = activeModelID
        newModelName = ""
    }

    private func addModel() {
        let trimmed = newModelName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !editingModels.contains(where: { $0.name == trimmed }) else { return }
        let newModel = EditableModel(id: UUID(), name: trimmed)
        editingModels.append(newModel)
        if activeModelID == nil { activeModelID = newModel.id }
        editingModelID = newModel.id
        newModelName = ""
    }

    // MARK: - Model Row

    private func modelRow(_ model: EditableModel) -> some View {
        let isSelected = model.id == (editingModelID ?? editingModels.first?.id)
        let isDefault = model.id == activeModelID
        return Button(action: { withAnimation(Theme.Animation.bouncy) { editingModelID = model.id } }) {
            HStack(spacing: 6) {
                Text(model.name)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.clear)
                        .glassEffect(.regular.tint(Theme.claude.opacity(0.16)), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .buttonStyle(.plain)
        .help(isDefault ? "默认模型:切换到该供应商时自动选用" : "右键设为默认")
        .contextMenu {
            if !isDefault {
                Button("设为默认") { withAnimation(Theme.Animation.bouncy) { activeModelID = model.id } }
            }
            Button("删除", role: .destructive) {
                editingModels.removeAll { $0.id == model.id }
                if activeModelID == model.id { activeModelID = editingModels.first?.id }
                if editingModelID == model.id { editingModelID = editingModels.first?.id }
            }
        }
    }

    // MARK: - Actions

    private func saveCurrent() {
        guard var p = selected else { return }
        p.name = editingName
        p.authToken = editingAuthToken
        p.baseURL = editingBaseURL
        p.models = editingModels.map {
            ModelConfig(id: $0.id, name: $0.name, contextTokens: $0.contextTokens,
                        disableCompact: $0.disableCompact,
                        disableExperimentalBetas: $0.disableExperimentalBetas,
                        autoCompactWindow: $0.autoCompactWindow)
        }
        p.activeModelID = activeModelID ?? p.models.first?.id

        providerStore.updateProvider(p)

        // If active, re-apply current model
        if providerStore.activeProviderID == p.id,
           let model = p.models.first(where: { $0.id == p.activeModelID }) ?? p.models.first {
            providerStore.activateModel(providerID: p.id, modelID: model.id)
        }

        withAnimation(Theme.Animation.bouncy) { showSaveSuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(Theme.Animation.bouncy) { showSaveSuccess = false }
        }
    }

    private func addNew() {
        let p = Provider(name: "New Provider")
        providerStore.providers.append(p)
        providerStore.saveProviders()
        selectedID = p.id
    }

    private func deleteSelected() {
        guard let p = selected else { return }
        providerStore.deleteProvider(p)
        selectedID = providerStore.providers.first?.id
    }

    private func duplicateSelected() {
        guard let p = selected else { return }
        providerStore.duplicateProvider(p)
        if let last = providerStore.providers.last { selectedID = last.id }
    }
}

// MARK: - Subviews

private struct EditorSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(Theme.Font.labelSection).foregroundColor(Theme.textSecondary).padding(.top, 4)
    }
}

private struct EditorField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    init(label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
            content()
        }
    }
}
