import SwiftUI

/// Directory stays in place. Configuration opens a focused sheet; selecting a
/// model stages intent until the user explicitly activates it.
struct ProvidersView: View {
    @ProviderState(.configuration) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @AppStorage("providersStack") private var clientRaw = "claude"
    @State private var query = ""
    @State private var category: ProviderCatalogEntry.Category?
    @State private var configuredOnly = false
    @State private var selectedID: UUID?
    @State private var showEditor = false
    @State private var editorFocusProviderID: UUID?
    @State private var singleProviderEditor = false
    @State private var editorTitle = "供应商配置"
    @State private var setupEntry: ProviderCatalogEntry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionAnimation

    private var client: ProviderClient { ProviderClient(rawValue: clientRaw) ?? .claude }
    private var tint: Color { client == .claude ? Theme.claude : Theme.codex }
    private var providers: [Provider] { client == .claude ? providerStore.providers : codexStore.providers.map(\.asDisplayProvider) }
    private var activeID: UUID? { client == .claude ? providerStore.activeProviderID : codexStore.activeProviderID }
    private var selected: Provider? { providers.first { $0.id == selectedID } }
    private var error: String? { client == .claude ? providerStore.errorMessage : codexStore.errorMessage }

    var body: some View {
        workspace
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPrimary)
        .onChange(of: clientRaw) { _, _ in selectedID = nil }
        .onChange(of: category) { _, _ in selectedID = nil }
        .onChange(of: query) { _, _ in selectedID = nil }
        .onChange(of: configuredOnly) { _, _ in selectedID = nil }
        .onReceive(NotificationCenter.default.publisher(for: .openProvidersEditor)) { _ in edit(selected?.id) }
        .sheet(isPresented: $showEditor) {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(editorTitle).font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("保存后，Key、名称和模型会写到 Claude Code 与 Codex 两边；接口地址按各自协议保留。激活只改变当前这一端。")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button { showEditor = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(ProviderActionStyle()).keyboardShortcut(.cancelAction)
                        .help("关闭；未保存的表单修改不提交")
                }.padding(24)
                Divider()
                if client == .codex {
                    CodexProviderEditorView(codexStore: codexStore, focusProviderID: editorFocusProviderID,
                                            singleProvider: singleProviderEditor)
                } else {
                    ProviderEditorView(providerStore: providerStore, focusProviderID: $editorFocusProviderID,
                                       singleProvider: singleProviderEditor)
                }
            }
            .frame(width: singleProviderEditor ? 700 : 940, height: 680)
            .foregroundStyle(Theme.textPrimary).background(Theme.cardSurface)
            .interactiveDismissDisabled()
        }
        .sheet(item: $setupEntry) { entry in
            ProviderQuickSetup(draft: .init(entry: entry, client: client), onSave: saveSetup)
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Ink.error)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            directoryToolbar
            connectionStrip
            directory
        }
    }

    private var directory: some View {
        ProviderDirectoryHost(
            model: ProviderDirectoryModel(
                client: client, providers: providers, activeID: activeID, selectedID: selectedID,
                query: query, category: category, configuredOnly: configuredOnly,
                balances: providerStore.balanceAmounts),
            onActivate: { activate($0, modelID: $1) },
            onUseOfficial: {
                if client == .claude { providerStore.restoreOfficial() } else { codexStore.restoreOfficial() }
                if error == nil { selectedID = nil }
            },
            onClearFilters: { query = ""; category = nil; configuredOnly = false },
            onSelect: { setupEntry = $0 },
            onOpen: { edit($0.id) }
        )
        .equatable()
        .onAppear { providerStore.refreshBalance() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("供应商").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("发现模型平台，为你的编程工具接入新能力。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button { customProvider() } label: { Label("自定义", systemImage: "plus") }
                .buttonStyle(ProviderActionStyle())
            Menu {
                Button("高级管理") { edit(selected?.id) }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).fixedSize().help("更多管理操作")
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
        .foregroundStyle(Theme.textPrimary)
    }

    private var clientSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(ProviderClient.allCases) { item in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { clientRaw = item.rawValue }
                } label: {
                    HStack(spacing: 7) {
                        ProductBrandMark(codex: item == .codex).frame(width: 17, height: 17)
                        Text(item.title).font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(client == item ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 132, height: 34)
                    .background {
                        if client == item {
                            RoundedRectangle(cornerRadius: 9).fill(Theme.cardSurface)
                                .matchedGeometryEffect(id: "client", in: selectionAnimation)
                        }
                    }
                }.buttonStyle(.plain).accessibilityAddTraits(client == item ? .isSelected : [])
            }
        }.padding(4).background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 13))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var directoryToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                clientSwitcher
                ProviderCategoryFilter(category: $category).fixedSize()
                Spacer(minLength: 0)
                ProviderDirectorySearch(query: $query).frame(width: 190)
            }
            HStack(spacing: 12) {
                clientSwitcher
                ProviderCategoryFilter(category: $category, compact: true)
                Spacer(minLength: 0)
                ProviderDirectorySearch(query: $query).frame(minWidth: 130, maxWidth: 190)
            }
        }
        .padding(.horizontal, 24)
    }

    private var connectionStrip: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(activeID == nil ? Theme.textSecondary : Theme.statusSuccess).frame(width: 6, height: 6)
                Text("当前连接").foregroundStyle(Theme.textSecondary)
                Text(providers.first { $0.id == activeID }?.name ?? "官方 / 默认")
                    .fontWeight(.semibold).lineLimit(1)
            }
            Text("\(providers.count) 个已保存配置").foregroundStyle(Theme.textSecondary).fixedSize()
            if let provider = providers.first(where: { $0.id == activeID }), let model = currentModel(provider) {
                Text(model).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            Toggle("仅显示已配置", isOn: $configuredOnly).toggleStyle(.checkbox)
                .foregroundStyle(Theme.textSecondary).fixedSize()
        }
        .font(Theme.Font.caption).foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 16)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: activeID)
    }

    private func currentModel(_ p: Provider) -> String? {
        client == .claude && p.id == activeID ? providerStore.currentEnv?.ANTHROPIC_MODEL ?? p.activeModel?.name : p.activeModel?.name
    }
    private func edit(_ id: UUID?) {
        editorFocusProviderID = id
        singleProviderEditor = id != nil
        editorTitle = id.flatMap { target in providers.first { $0.id == target }?.name } ?? "管理供应商"
        showEditor = true
    }
    private func customProvider() {
        let id = client == .claude ? providerStore.addBlankProvider().id : codexStore.addBlankProvider().id
        edit(id)
    }
    private func activate(_ p: Provider, modelID: UUID) {
        if client == .claude { providerStore.activateModel(providerID: p.id, modelID: modelID) }
        else { codexStore.activate(providerID: p.id, modelID: modelID) }
    }
    private func toggleCapture(_ p: Provider) {
        if client == .claude { providerStore.setCaptureEnabled(providerID: p.id, enabled: !p.captureEnabled) }
        else { codexStore.setCaptureEnabled(providerID: p.id, enabled: !p.captureEnabled) }
    }
    private func test(_ p: Provider, model: ModelConfig) {
        ConnectivityTestCenter.shared.testVendor(id: p.id, claude: p, model: model,
                         codex: client == .codex ? codexStore.providers.first { $0.id == p.id } : nil)
    }
    private func saveSetup(_ draft: ProviderSetupDraft) -> String? {
        if let error = draft.validationError { return error }
        let existing = draft.client == .claude ? providerStore.providers : codexStore.providers.map(\.asDisplayProvider)
        if existing.contains(where: {
            ProviderCatalogEntry.normalize($0.baseURL) == ProviderCatalogEntry.normalize(draft.baseURL)
                && $0.authToken == draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        }) { return "相同地址与 Key 的配置已存在，请在该厂商卡片中打开配置，再添加模型。" }
        let id: UUID
        if draft.client == .claude {
            let provider = draft.makeClaude()
            guard providerStore.addConfiguredProvider(provider) else { return providerStore.errorMessage ?? "保存失败，请重试。" }
            id = provider.id
        } else {
            let provider = draft.makeCodex()
            guard codexStore.addConfiguredProvider(provider) else { return codexStore.errorMessage ?? "保存失败，请重试。" }
            id = provider.id
        }
        selectedID = id
        return nil
    }
    private func addModels(_ names: Set<String>, to provider: Provider) {
        if client == .claude {
            guard var updated = providerStore.providers.first(where: { $0.id == provider.id }) else { return }
            let existing = Set(updated.models.map { $0.name.lowercased() })
            updated.models += names.sorted().filter { !existing.contains($0.lowercased()) }.map {
                ModelConfig(name: $0, disableCompact: false, disableExperimentalBetas: false)
            }
            if updated.activeModelID == nil { updated.activeModelID = updated.models.first?.id }
            providerStore.updateProvider(updated)
        } else {
            guard var updated = codexStore.providers.first(where: { $0.id == provider.id }) else { return }
            let existing = Set(updated.models.map { $0.name.lowercased() })
            updated.models += names.sorted().filter { !existing.contains($0.lowercased()) }.map { CodexModelConfig(name: $0) }
            if updated.activeModelID == nil { updated.activeModelID = updated.models.first?.id }
            codexStore.updateProvider(updated)
        }
    }
    static func modelToTest(_ provider: Provider, envModel: String?) -> ModelConfig? {
        provider.models.first { $0.name.caseInsensitiveCompare(envModel ?? "") == .orderedSame } ?? provider.activeModel ?? provider.models.first
    }
}
