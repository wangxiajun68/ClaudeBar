import Foundation
import Observation
import SwiftUI

/// Editable mirror of a CodexModelConfig for the editor form.
struct EditableCodexModel: Identifiable, Equatable {
    var id: UUID
    var name: String = ""
    var reasoningEffort: String = ""
    var contextWindow: String = ""
    var autoCompactTokenLimit: String = ""
}

/// Editor form view-model for Codex providers — direct port of
/// `ProviderEditorModel`. The view (`CodexProviderEditorView`) is layout-only.
@Observable @MainActor
final class CodexProviderEditorModel {
    var selectedID: UUID?
    var name = ""
    var apiKey = ""
    var baseURL = ""
    var wireAPI = "responses"
    var requiresOpenAIAuth = true
    var preserveOfficialLogin = true
    var disableResponseStorage = true
    var captureEnabled = false
    var models: [EditableCodexModel] = []
    var activeModelID: UUID?
    var editingModelID: UUID?
    var newModelName = ""
    var isSaving = false
    var isFetchingModels = false
    var modelFetchMessage: String?
    var showModelImport = false
    var modelImportCandidates: [String] = []
    /// Monotonic token — each successful save bumps it; the view shows
    /// "Saved ✓" via a `.task(id:)` (see ProviderEditorView).
    var saveToken = 0
    private(set) var saveFlashUntil: Date?

    private unowned var store: CodexProviderStore?

    func attach(store: CodexProviderStore) {
        self.store = store
        if selectedID == nil {
            selectedID = store.providers.first?.id
        }
        if models.isEmpty || name.isEmpty {
            loadSelected()
        }
    }

    var selected: CodexProvider? {
        store?.providers.first { $0.id == selectedID }
    }

    // MARK: - Load

    func loadSelected() {
        guard let p = selected else { return }
        name = p.name
        apiKey = p.apiKey
        baseURL = p.baseURL
        wireAPI = p.wireAPI
        requiresOpenAIAuth = p.requiresOpenAIAuth
        preserveOfficialLogin = p.preserveOfficialLogin
        disableResponseStorage = p.disableResponseStorage
        captureEnabled = p.captureEnabled
        models = p.models.map { EditableCodexModel(
            id: $0.id, name: $0.name,
            reasoningEffort: $0.reasoningEffort,
            contextWindow: $0.contextWindow,
            autoCompactTokenLimit: $0.autoCompactTokenLimit
        )}
        activeModelID = p.activeModelID ?? p.models.first?.id
        editingModelID = activeModelID
        newModelName = ""
    }

    // MARK: - Derived validation

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

    var isSaveFlashActive: Bool {
        guard let until = saveFlashUntil else { return false }
        return until > Date()
    }

    // MARK: - Model CRUD

    func addModel() {
        let trimmed = newModelName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !models.contains(where: { $0.name == trimmed }) else { return }
        let newModel = EditableCodexModel(id: UUID(), name: trimmed)
        models.append(newModel)
        if activeModelID == nil { activeModelID = newModel.id }
        editingModelID = newModel.id
        newModelName = ""
    }

    func deleteModel(_ id: UUID) {
        models.removeAll { $0.id == id }
        if activeModelID == id { activeModelID = models.first?.id }
        sanitizeEditingSelection()
    }

    func setDefault(_ id: UUID) {
        activeModelID = id
    }

    func binding(for id: UUID, keyPath: WritableKeyPath<EditableCodexModel, String>) -> Binding<String> {
        Binding(
            get: { self.models.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let index = self.models.firstIndex(where: { $0.id == id }) else { return }
                self.models[index][keyPath: keyPath] = newValue
            }
        )
    }

    private func sanitizeEditingSelection() {
        if let id = editingModelID, models.contains(where: { $0.id == id }) { return }
        editingModelID = activeModelID ?? models.first?.id
    }

    var existingModelNames: Set<String> {
        Set(models.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    func fetchModelsFromAPI() {
        guard !isFetchingModels else { return }
        isFetchingModels = true
        modelFetchMessage = nil
        let url = baseURL
        let key = apiKey
        let wire = wireAPI
        Task {
            let result = await ModelListFetcher.fetch(baseURL: url, apiKey: key, wireAPI: wire)
            isFetchingModels = false
            switch result {
            case .success(let payload):
                modelImportCandidates = payload.models
                if payload.models.isEmpty {
                    modelFetchMessage = "接口未返回模型"
                } else {
                    showModelImport = true
                    modelFetchMessage = nil
                }
            case .failure(let message):
                modelFetchMessage = message
            }
        }
    }

    func importSelectedModels(_ names: Set<String>) {
        defer {
            showModelImport = false
            modelImportCandidates = []
        }
        guard !names.isEmpty else { return }
        let existing = existingModelNames
        var added = 0
        for name in names.sorted() {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !existing.contains(trimmed.lowercased()) else { continue }
            let item = EditableCodexModel(id: UUID(), name: trimmed)
            models.append(item)
            added += 1
            if activeModelID == nil { activeModelID = item.id }
        }
        sanitizeEditingSelection()
        modelFetchMessage = added > 0 ? "已导入 \(added) 个模型" : "所选模型均已存在"
    }

    func cancelModelImport() {
        showModelImport = false
        modelImportCandidates = []
    }

    // MARK: - Save

    func save() {
        guard canSave, let store, var p = selected else { return }
        isSaving = true
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.apiKey = apiKey
        p.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        p.wireAPI = wireAPI
        p.requiresOpenAIAuth = requiresOpenAIAuth
        p.preserveOfficialLogin = preserveOfficialLogin
        p.disableResponseStorage = disableResponseStorage
        p.captureEnabled = captureEnabled
        p.models = models.map {
            CodexModelConfig(id: $0.id, name: $0.name,
                             reasoningEffort: $0.reasoningEffort,
                             contextWindow: $0.contextWindow,
                             autoCompactTokenLimit: $0.autoCompactTokenLimit)
        }
        p.activeModelID = activeModelID ?? p.models.first?.id

        store.updateProvider(p)

        // If active, re-apply so config.toml/auth.json reflect the edit.
        if store.activeProviderID == p.id,
           let model = p.models.first(where: { $0.id == p.activeModelID }) ?? p.models.first {
            store.activate(providerID: p.id, modelID: model.id)
        }

        isSaving = false
        saveToken += 1
        saveFlashUntil = Date().addingTimeInterval(2)
    }

    // MARK: - Provider CRUD (delegate to store)

    func addNew() {
        guard let store else { return }
        let p = store.addBlankProvider()
        selectedID = p.id
        loadSelected()
    }

    func focusProvider(id: UUID) {
        selectedID = id
        loadSelected()
    }

    func clearSaveFlash() {
        saveFlashUntil = nil
    }

    func addFromPreset(_ preset: CodexProvider) {
        guard let store else { return }
        var p = preset
        p.id = UUID()
        p.apiKey = ""
        p.activeModelID = p.models.first?.id
        store.addProvider(p)
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

    func importFromClaude() {
        guard let store else { return }
        store.importFromClaude()
        if selectedID == nil { selectedID = store.providers.first?.id }
        loadSelected()
    }
}
