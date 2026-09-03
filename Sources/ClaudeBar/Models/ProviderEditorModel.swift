import Foundation
import Observation

/// Editable mirror of a ModelConfig for the editor form.
struct EditableModel: Identifiable, Equatable {
    var id: UUID
    var name: String = ""
    var contextTokens: String = ""
    var disableCompact: Bool = true
    var disableExperimentalBetas: Bool = true
    var autoCompactWindow: String = ""
    var reasoningEffort: String = ""
}

/// Editor form view-model: owns all editing state, derived validation, and
/// the save path. The view (`ProviderEditorView`) is layout-only.
@Observable @MainActor
final class ProviderEditorModel {
    var selectedID: UUID?
    var name = ""
    var authToken = ""
    var baseURL = ""
    var models: [EditableModel] = []
    var activeModelID: UUID?
    var editingModelID: UUID?
    var newModelName = ""
    var isSaving = false
    /// Monotonic token — each successful save bumps it; the view runs a
    /// `.task(id:)` to show "Saved ✓" for 2s (no asyncAfter, no Timer).
    var saveToken = 0

    var wireAPI = "chat"
    var requiresOpenAIAuth = false
    var preserveOfficialLogin = true
    var disableResponseStorage = true
    var captureEnabled = false

    private unowned var store: ProviderStore?

    func attach(store: ProviderStore) {
        self.store = store
        if selectedID == nil {
            selectedID = store.providers.first?.id
        }
        if models.isEmpty || name.isEmpty {
            loadSelected()
        }
    }

    var selected: Provider? {
        store?.providers.first { $0.id == selectedID }
    }

    // MARK: - Load

    func loadSelected() {
        guard let p = selected else { return }
        name = p.name
        authToken = p.authToken
        baseURL = p.baseURL
        models = p.models.map { EditableModel(
            id: $0.id, name: $0.name, contextTokens: $0.contextTokens,
            disableCompact: $0.disableCompact,
            disableExperimentalBetas: $0.disableExperimentalBetas,
            autoCompactWindow: $0.autoCompactWindow
        )}
        activeModelID = p.activeModelID ?? p.models.first?.id
        editingModelID = activeModelID
        newModelName = ""
        loadCodexExtras(for: p)
    }

    private func loadCodexExtras(for claude: Provider) {
        guard let twin = store?.peer?.providers.first(where: { ProviderBridge.matches(claude, $0) }) else {
            wireAPI = ProviderBridge.openaiCompatibleURL(claude.baseURL).lowercased().contains("api.openai.com")
                ? "responses" : "chat"
            requiresOpenAIAuth = false
            preserveOfficialLogin = true
            disableResponseStorage = true
            captureEnabled = claude.captureEnabled
            return
        }
        let extras = ProviderBridge.extras(from: twin)
        wireAPI = extras.wireAPI
        requiresOpenAIAuth = extras.requiresOpenAIAuth
        preserveOfficialLogin = extras.preserveOfficialLogin
        disableResponseStorage = extras.disableResponseStorage
        captureEnabled = claude.captureEnabled
        for i in models.indices {
            let slug = ProviderBridge.stripClaudeModelSuffix(models[i].name).lowercased()
            models[i].reasoningEffort = extras.reasoningBySlug[slug] ?? models[i].reasoningEffort
        }
    }

    // MARK: - Derived validation (craft-floor error states)

    var nameError: String? {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "请填写名称" : nil
    }

    var urlError: String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "请填写 Base URL" }
        return URL(string: trimmed)?.host == nil ? "Base URL 无效" : nil
    }

    var duplicateModelError: String? {
        let names = models.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        let dupes = names.filter { name in names.filter { $0 == name }.count > 1 }
        return dupes.isEmpty ? nil : "模型名称重复：\(dupes.first ?? "")"
    }

    var canSave: Bool {
        nameError == nil && urlError == nil && duplicateModelError == nil
            && !models.isEmpty && !isSaving
    }

    // MARK: - Model CRUD

    func addModel() {
        let trimmed = newModelName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !models.contains(where: { $0.name == trimmed }) else { return }
        let newModel = EditableModel(id: UUID(), name: trimmed)
        models.append(newModel)
        if activeModelID == nil { activeModelID = newModel.id }
        editingModelID = newModel.id
        newModelName = ""
    }

    func deleteModel(_ id: UUID) {
        models.removeAll { $0.id == id }
        if activeModelID == id { activeModelID = models.first?.id }
        if editingModelID == id { editingModelID = models.first?.id }
    }

    func setDefault(_ id: UUID) {
        activeModelID = id
    }

    // MARK: - Save

    func save() {
        guard canSave, let store, var p = selected else { return }
        isSaving = true
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.authToken = authToken
        p.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        p.models = models.map {
            ModelConfig(id: $0.id, name: $0.name, contextTokens: $0.contextTokens,
                        disableCompact: $0.disableCompact,
                        disableExperimentalBetas: $0.disableExperimentalBetas,
                        autoCompactWindow: $0.autoCompactWindow)
        }
        p.activeModelID = activeModelID ?? p.models.first?.id
        p.captureEnabled = captureEnabled

        store.updateProvider(p, extras: currentExtras)

        // If active, re-apply current model (writes Claude + Codex live configs).
        if store.activeProviderID == p.id,
           let model = p.models.first(where: { $0.id == p.activeModelID }) ?? p.models.first {
            store.activateModel(providerID: p.id, modelID: model.id)
        }

        isSaving = false
        saveToken += 1
    }

    // MARK: - Provider CRUD (delegate to store)

    func addNew() {
        guard let store else { return }
        let p = Provider(name: "New Provider")
        store.providers.append(p)
        store.saveProviders()
        selectedID = p.id
        loadSelected()
    }

    func deleteSelected() {
        guard let store, let p = selected else { return }
        store.deleteProvider(p)
        selectedID = store.providers.first?.id
        loadSelected()
    }

    func duplicateSelected() {
        guard let store, let p = selected else { return }
        store.duplicateProvider(p)
        if let last = store.providers.last {
            selectedID = last.id
            loadSelected()
        }
    }

    private var currentExtras: ProviderBridge.CodexExtras {
        var map: [String: String] = [:]
        for m in models {
            map[ProviderBridge.stripClaudeModelSuffix(m.name).lowercased()] = m.reasoningEffort
        }
        return ProviderBridge.CodexExtras(
            wireAPI: wireAPI,
            requiresOpenAIAuth: requiresOpenAIAuth,
            preserveOfficialLogin: preserveOfficialLogin,
            disableResponseStorage: disableResponseStorage,
            reasoningBySlug: map)
    }

    func addFromPreset(_ preset: CodexProvider) {
        guard let store else { return }
        store.addFromCodexPreset(preset)
        selectedID = store.providers.last?.id
        loadSelected()
    }
}
