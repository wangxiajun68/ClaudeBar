import Foundation
import Observation
import SwiftUI

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
    var isFetchingModels = false
    var modelFetchMessage: String?
    var showModelImport = false
    var modelImportCandidates: [String] = []
    /// Monotonic token — each successful save bumps it; the view runs a
    /// `.task(id:)` to show "Saved ✓" for 2s (no asyncAfter, no Timer).
    var saveToken = 0
    private(set) var saveFlashUntil: Date?

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
        captureEnabled = p.captureEnabled
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

    var isSaveFlashActive: Bool {
        guard let until = saveFlashUntil else { return false }
        return until > Date()
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
        sanitizeEditingSelection()
    }

    func setDefault(_ id: UUID) {
        activeModelID = id
    }

    func binding(for id: UUID, keyPath: WritableKeyPath<EditableModel, String>) -> Binding<String> {
        Binding(
            get: { self.models.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let index = self.models.firstIndex(where: { $0.id == id }) else { return }
                self.models[index][keyPath: keyPath] = newValue
            }
        )
    }

    func binding(for id: UUID, keyPath: WritableKeyPath<EditableModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { self.models.first(where: { $0.id == id })?[keyPath: keyPath] ?? false },
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
        let key = authToken
        Task {
            let result = await ModelListFetcher.fetch(baseURL: url, apiKey: key)
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
            let item = EditableModel(id: UUID(), name: trimmed)
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

        store.updateProvider(p)

        // If active, re-apply so settings.json matches the edited row.
        if store.activeProviderID == p.id,
           let model = p.models.first(where: { $0.id == p.activeModelID }) ?? p.models.first {
            store.activateModel(providerID: p.id, modelID: model.id)
        }

        isSaving = false
        saveToken += 1
        saveFlashUntil = Date().addingTimeInterval(2)
    }

    func focusProvider(id: UUID) {
        selectedID = id
        loadSelected()
    }

    func clearSaveFlash() {
        saveFlashUntil = nil
    }

    // MARK: - Provider CRUD (delegate to store)

    func addNew() {
        guard let store else { return }
        let p = store.addBlankProvider()
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

    func addFromPreset(_ preset: CodexProvider) {
        guard let store else { return }
        store.addFromCodexPreset(preset)
        selectedID = store.providers.last?.id
        loadSelected()
    }

    func importFromCodex() {
        store?.importFromCodex()
    }
}
