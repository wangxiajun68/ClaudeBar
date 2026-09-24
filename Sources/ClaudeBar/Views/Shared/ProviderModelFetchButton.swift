import SwiftUI

/// Shared by quick setup and saved-provider details. Does not mutate providers
/// until the user explicitly imports the selected model IDs.
struct ProviderModelFetchButton: View {
    let baseURL: String
    let apiKey: String
    let wireAPI: String
    let existingNames: Set<String>
    let onImport: (Set<String>) -> Void
    @State private var loading = false
    @State private var message: String?
    @State private var candidates: [String] = []
    @State private var showPicker = false
    @State private var fetchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: fetch) {
                HStack(spacing: 6) {
                    if loading { ProgressView().controlSize(.mini) }
                    Label(loading ? "正在拉取" : "拉取模型", systemImage: "arrow.down.circle")
                }
            }.buttonStyle(ProviderActionStyle())
                .disabled(loading || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("使用当前地址与 Key 读取模型列表，再勾选添加")
            if let message {
                Text(message).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showPicker) {
            ModelImportSheet(candidates: candidates, existingNames: existingNames, onImport: {
                onImport($0)
                showPicker = false
            }, onCancel: { showPicker = false })
        }
        .onDisappear { cancel() }
        .onChange(of: baseURL) { _, _ in cancel() }
        .onChange(of: apiKey) { _, _ in cancel() }
        .onChange(of: wireAPI) { _, _ in cancel() }
    }
    private func cancel() {
        fetchTask?.cancel(); fetchTask = nil
        loading = false; candidates = []; message = nil; showPicker = false
    }
    private func fetch() {
        loading = true; message = nil
        let url = baseURL, key = apiKey, wire = wireAPI
        fetchTask = Task { @MainActor in
            let result = await ModelListFetcher.fetch(baseURL: url, apiKey: key, wireAPI: wire)
            guard !Task.isCancelled else { return }
            loading = false
            switch result {
            case .success(let payload): candidates = payload.models; showPicker = true
            case .failure(let error): message = error + "。也可手动填写模型 ID。"
            }
        }
    }
}
