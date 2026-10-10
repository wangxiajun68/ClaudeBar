import SwiftUI

/// Directory stays in place. Configuration opens a focused sheet; selecting a
/// model stages intent until the user explicitly activates it.
struct ProvidersView: View {
    @ProviderState(.configuration) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @AppStorage("providersStack") private var clientRaw = "claude"
    @AppStorage("modelsSurface") private var surfaceRaw = "providers"
    @State private var query = ""
    @State private var category: ProviderCatalogEntry.Category?
    @State private var configuredOnly = false
    @State private var selectedID: UUID?
    @State private var connectionEdit: ProviderConnectionRoute?
    @State private var setupEntry: ProviderCatalogEntry?
    @State private var gatewayImport: GatewayProviderImportRoute?
    @State private var pendingGatewayEdit: UUID?
    /// What the last 导入 said. The store's `importSummary` is the same string,
    /// but the page cannot read it: the band is redrawn from `Facts`, which
    /// deliberately does not observe it, so a one-off outcome is local state
    /// that clears on the next import.
    @State private var importNote: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set by the window when another surface asked for the provider editor
    /// (the popup's 「管理模型」, a ⌘K provider result). Cleared once the sheet
    /// is up; see `MainWindowView.route(_:)`.
    @Binding var editorRequest: AppPage?

    private var client: ProviderClient { ProviderClient(rawValue: clientRaw) ?? .claude }

    /// The page's whole model, resolved once per body.
    ///
    /// These were computed properties, so `workspace`'s call tree re-derived
    /// each of them at every read: on the Codex client, `providers` maps and
    /// rebuilds every model of every provider — and it was read four times
    /// (the directory model, the count, and two `first(where:)` lookups).
    private struct Facts {
        var providers: [Provider] = []
        var activeID: UUID?
        var error: String?
    }

    private func facts() -> Facts {
        var out = Facts()
        if client == .claude {
            out.providers = providerStore.providers
            out.activeID = providerStore.activeProviderID
            out.error = providerStore.errorMessage
        } else {
            out.providers = codexStore.providers.map(\.asDisplayProvider)
            out.activeID = codexStore.activeProviderID
            out.error = codexStore.errorMessage
        }
        return out
    }

    /// The active provider's model name. `activeID` is passed in rather than
    /// re-read from the stores: `facts()` already resolved it for this body,
    /// and a second read here is exactly the duplicate work the `Facts` doc
    /// above describes.
    private func currentModel(_ p: Provider, activeID: UUID?) -> String? {
        client == .claude && p.id == activeID ? providerStore.currentEnv?.ANTHROPIC_MODEL ?? p.activeModel?.name : p.activeModel?.name
    }

    var body: some View {
        let f = facts()
        return workspace(f)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPrimary)
        .onChange(of: clientRaw) { _, _ in selectedID = nil }
        .onChange(of: category) { _, _ in selectedID = nil }
        .onChange(of: query) { _, _ in selectedID = nil }
        .onChange(of: configuredOnly) { _, _ in selectedID = nil }
        .onChange(of: editorRequest) { _, page in
            guard page == .providers else { return }
            editorRequest = nil
            openRequestedEditor(f)
        }
        .onAppear {
            // The window sets the flag on the same pass that installs this
            // page, so the change above can arrive before `onChange` exists.
            guard editorRequest == .providers else { return }
            editorRequest = nil
            openRequestedEditor(f)
        }
        .sheet(item: $connectionEdit) { route in
            if let draft = connectionDraft(route) {
                ProviderConnectionEditor(client: client, draft: draft, onSave: saveConnection,
                                         onDelete: route.isNew ? nil : { deleteConnection(route.id) })
            }
        }
        .sheet(item: $gatewayImport, onDismiss: {
            if let id = pendingGatewayEdit { pendingGatewayEdit = nil; editGatewayProvider(id) }
        }) { route in
            GatewayProviderImportView(providerIDs: route.providerIDs, onEditProvider: { pendingGatewayEdit = $0 })
        }
        .sheet(item: $setupEntry) { entry in
            ProviderQuickSetup(draft: .init(entry: entry, client: client), onSave: saveSetup)
        }
    }

    /// Open the editor another surface asked for (the popup's 「管理模型」, a ⌘K
    /// provider result).
    ///
    /// With no active provider the request used to be dropped silently — the
    /// page opened with no sheet at all. That is exactly the state a user is in
    /// when they reach for this: the popup's entry point for an unconfigured
    /// install is 「去添加供应商」, and Codex starts with nothing active. So an
    /// empty active slot opens the *new connection* form instead of nothing.
    private func openRequestedEditor(_ f: Facts) {
        if let id = f.activeID {
            connectionEdit = ProviderConnectionRoute(id: id, isNew: false)
        } else {
            connectionEdit = ProviderConnectionRoute(id: UUID(), isNew: true)
        }
    }

    private func workspace(_ f: Facts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = f.error {
                // A raw red `Label` was the one error in the app with no band
                // behind it; every other page states a failure on a surface.
                // Dismissal clears whichever store phrased this one — the
                // same "clear on dismiss" the connectors page uses.
                messageBanner(error, symbol: "exclamationmark.circle.fill",
                              tint: Theme.Ink.error) { clearError() }
            }
            if let importNote {
                // An import that found nothing is not a failure, but it still
                // has to say so or the button reads as broken.
                messageBanner(importNote, symbol: "arrow.left.arrow.right",
                              tint: Theme.Ink.success) { self.importNote = nil }
            }
            if surfaceRaw == "gateway" {
                FreeModelGatewayView(onAddOpenRouter: {
                    clientRaw = "codex"
                    setupEntry = ProviderCatalogEntry.all.first { $0.id == "openrouter" }
                }, onEditProvider: editGatewayProvider)
            } else {
                VStack(spacing: 12) {
                    directoryToolbar
                    HairlineDivider()
                    connectionStrip(f)
                }.padding(14).panelCard(radius: Theme.Radius.md)
                    .padding(.horizontal, Theme.Space.s24).padding(.bottom, Theme.Space.s16)
                directory(f)
            }
        }
    }

    private func directory(_ f: Facts) -> some View {
        ProviderDirectoryHost(
            model: ProviderDirectoryModel(
                client: client, providers: f.providers,
                activeID: f.activeID, selectedID: selectedID,
                query: query, category: category, configuredOnly: configuredOnly,
                balances: providerStore.balanceAmounts),
            onActivate: { activate($0, modelID: $1) },
            onUseOfficial: {
                if client == .claude { providerStore.restoreOfficial() } else { codexStore.restoreOfficial() }
                // The official connection has no provider card, so a card
                // selection is stale the moment it is restored. Read through
                // `Facts` rather than a second live property: `Facts` is what
                // this body already renders from.
                if f.error == nil { selectedID = nil }
            },
            onClearFilters: { query = ""; category = nil; configuredOnly = false },
            onSelect: { setupEntry = $0 },
            onOpen: { connectionEdit = ProviderConnectionRoute(id: $0.id, isNew: false) },
            onToggleCapture: { setCapture($0, enabled: $1) },
            onImportToAuto: { gatewayImport = .init(providerIDs: $0.map(\.id)) }
        )
        .equatable()
        // Not in the mount frame: `refreshBalance` flips `balanceLoading`
        // before it awaits, and that write is a configuration invalidation
        // landing inside the page-switch transaction.
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            providerStore.refreshBalance()
        }
    }

    /// One page heading owns workspace navigation. Supplier actions only
    /// appear in their workspace, rather than becoming a second gateway bar.
    private var header: some View {
        PageHeaderCard(tint: Theme.textSecondary) { engaged in
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    PageTitle(title: "模型", engaged: engaged)
                    surfaceTabs
                    Spacer(minLength: 12)
                    if surfaceRaw == "providers" { providerActions }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { PageTitle(title: "模型", engaged: engaged); Spacer(); surfaceTabs }
                    if surfaceRaw == "providers" { providerActions }
                }
            }
        }.foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Space.s24).padding(.top, Theme.Space.s8).padding(.bottom, Theme.Space.s16)
    }
    private var surfaceTabs: some View {
        SegmentedCapsule(items: ["providers", "gateway"], selection: surfaceRaw,
            title: { $0 == "providers" ? "供应商" : "自动网关" }, tint: Theme.Ink.cursor) { surfaceRaw = $0 }
    }
    private var providerActions: some View {
        HStack(spacing: 8) {
            ActionButton(client == .claude ? "导入 Codex" : "导入 Claude", symbol: "arrow.left.arrow.right") {
                let result = client == .claude ? providerStore.importFromCodex() : codexStore.importFromClaude()
                importNote = result.summary
            }.help("转换另一客户端已保存的供应商配置")
            ActionButton("自定义", symbol: "plus") { connectionEdit = ProviderConnectionRoute(id: UUID(), isNew: true) }
        }
    }
    private func editGatewayProvider(_ id: UUID) {
        clientRaw = codexStore.providers.contains { $0.id == id } ? "codex" : "claude"
        connectionEdit = ProviderConnectionRoute(id: id, isNew: false)
    }

    /// Dismiss the error the current client's store is showing.
    private func clearError() {
        if client == .claude { providerStore.errorMessage = nil } else { codexStore.errorMessage = nil }
    }

    /// The band both the failure and the import outcome are stated on.
    /// Same anatomy as `ConnectorsView`'s local helper — a page that reports an
    /// action's result on a bare `Text` is the shape this page's error band was
    /// introduced to end.
    private func messageBanner(_ message: String, symbol: String, tint: Color,
                               onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.s10) {
            GlyphWell(name: symbol, tint: tint, size: 26)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: Theme.Space.s8)
            Button("关闭", action: onDismiss)
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s10)
        .panelCard(radius: Theme.Radius.md, tint: tint)
        .padding(.horizontal, Theme.Space.s24)
        .padding(.bottom, Theme.Space.s12)
    }

    private var clientSwitcher: some View {
        SegmentedCapsule(items: ProviderClient.allCases,
                         selection: client,
                         title: \.title,
                         tint: Theme.Ink.claude,
                         itemTint: { $0 == .claude ? Theme.Ink.claude : Theme.Ink.codex },
                         brand: { $0 == .codex },
                         onSelect: { item in
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { clientRaw = item.rawValue }
        })
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
    }

    /// The live connection strip. It used to be a bare dot and a line of text
    /// floating straight on the canvas — no surface, a 6pt `Circle` for a
    /// status mark, and 28pt side padding where every sibling row uses 24. It
    /// is now a band from the same family as the rest of the page: the mark in
    /// a `GlyphWell`, the state in a `StatusPill`, and the whole row on a
    /// `panelCard` so it reads as the page's summary line rather than as stray
    /// text above the grid.
    private func connectionStrip(_ f: Facts) -> some View {
        let active = f.providers.first { $0.id == f.activeID }
        let live = f.activeID != nil
        let face = live ? Theme.statusSuccess : Theme.textSecondary
        return HStack(spacing: Theme.Space.s12) {
            GlyphWell(name: live ? "bolt.fill" : "bolt.slash",
                      tint: live ? Theme.Ink.success : Theme.textSecondary, size: 28)
            HStack(spacing: Theme.Space.s6) {
                Text("当前连接").foregroundStyle(Theme.textSecondary)
                Text(active?.name ?? "官方 / 默认")
                    .fontWeight(.semibold).lineLimit(1)
            }
            StatusPill(label: live ? "使用中" : "未选择",
                       tint: face,
                       ink: live ? Theme.Ink.success : Theme.textSecondary)
            Text("\(f.providers.count) 个已保存配置").rollingNumber("\(f.providers.count) 个已保存配置").foregroundStyle(Theme.textSecondary).fixedSize()
            if let provider = active, let model = currentModel(provider, activeID: f.activeID) {
                Text(model).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            Toggle("仅显示已配置", isOn: $configuredOnly)
                .toggleStyle(.instrument)
                .foregroundStyle(Theme.textSecondary).fixedSize()
        }
        .font(Theme.Font.caption).foregroundStyle(Theme.textPrimary)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: f.activeID)
    }

    private func connectionDraft(_ route: ProviderConnectionRoute) -> ProviderConnectionDraft? {
        if route.isNew { return .custom(client: client, id: route.id) }
        if client == .claude, let provider = providerStore.providers.first(where: { $0.id == route.id }) {
            return ProviderConnectionDraft(
                id: provider.id, isNew: false, catalogID: provider.catalogID, name: provider.name,
                apiKey: provider.authToken, baseURL: provider.baseURL, wireAPI: "anthropic",
                preserveOfficialLogin: true, disableResponseStorage: true, requiresOpenAIAuth: false,
                captureEnabled: provider.captureEnabled, profileID: provider.profileID,
                models: provider.models.map {
                    ProviderConnectionModel(id: $0.id, name: $0.name, autoCompactTokenLimit: $0.autoCompactWindow,
                                            contextTokens: $0.contextTokens, disableCompact: $0.disableCompact,
                                            disableExperimentalBetas: $0.disableExperimentalBetas,
                                            maxConcurrentSubagents: $0.maxConcurrentSubagents,
                                            workflowMaxConcurrentAgents: $0.workflowMaxConcurrentAgents)
                },
                activeModelID: provider.activeModelID ?? provider.models.first?.id)
        }
        if client == .codex, let provider = codexStore.providers.first(where: { $0.id == route.id }) {
            return ProviderConnectionDraft(
                id: provider.id, isNew: false, catalogID: provider.catalogID, name: provider.name,
                apiKey: provider.apiKey, baseURL: provider.baseURL, wireAPI: provider.wireAPI,
                preserveOfficialLogin: provider.preserveOfficialLogin,
                disableResponseStorage: provider.disableResponseStorage,
                requiresOpenAIAuth: provider.requiresOpenAIAuth, captureEnabled: provider.captureEnabled,
                profileID: provider.profileID,
                models: provider.models.map {
                    ProviderConnectionModel(id: $0.id, name: $0.name, reasoningEffort: $0.reasoningEffort,
                                            contextWindow: $0.contextWindow, autoCompactTokenLimit: $0.autoCompactTokenLimit)
                },
                activeModelID: provider.activeModelID ?? provider.models.first?.id)
        }
        return nil
    }
    private func saveConnection(_ draft: ProviderConnectionDraft) -> String? {
        if let error = draft.validationError { return error }
        if client == .claude {
            let models = draft.models.map {
                ModelConfig(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                            contextTokens: $0.contextTokens, disableCompact: $0.disableCompact,
                            disableExperimentalBetas: $0.disableExperimentalBetas, autoCompactWindow: $0.autoCompactTokenLimit,
                            maxConcurrentSubagents: $0.maxConcurrentSubagents.trimmingCharacters(in: .whitespacesAndNewlines),
                            workflowMaxConcurrentAgents: $0.workflowMaxConcurrentAgents.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            var provider = providerStore.providers.first { $0.id == draft.id } ?? Provider(name: draft.name)
            provider.id = draft.id
            provider.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            provider.authToken = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            provider.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            provider.models = models
            provider.activeModelID = draft.activeModelID ?? models.first?.id
            provider.captureEnabled = draft.captureEnabled
            provider.profileID = draft.profileID ?? provider.profileID ?? UUID()
            provider.catalogID = draft.catalogID ?? provider.catalogID
            let saved = draft.isNew ? providerStore.addConfiguredProvider(provider) : providerStore.updateProvider(provider)
            guard saved else { return providerStore.errorMessage ?? "保存失败，请重试。" }
            if providerStore.activeProviderID == provider.id, let modelID = provider.activeModelID {
                providerStore.activateModel(providerID: provider.id, modelID: modelID)
            }
        } else {
            let models = draft.models.map {
                CodexModelConfig(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 reasoningEffort: $0.reasoningEffort, contextWindow: $0.contextWindow,
                                 autoCompactTokenLimit: $0.autoCompactTokenLimit)
            }
            var provider = codexStore.providers.first { $0.id == draft.id }
                ?? CodexProvider(name: draft.name, requiresOpenAIAuth: false)
            provider.id = draft.id
            provider.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            provider.apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            provider.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            provider.wireAPI = draft.wireAPI
            provider.preserveOfficialLogin = draft.preserveOfficialLogin
            provider.disableResponseStorage = draft.disableResponseStorage
            provider.requiresOpenAIAuth = draft.requiresOpenAIAuth
            provider.captureEnabled = draft.captureEnabled
            provider.profileID = draft.profileID ?? provider.profileID ?? UUID()
            provider.catalogID = draft.catalogID ?? provider.catalogID
            provider.models = models
            provider.activeModelID = draft.activeModelID ?? models.first?.id
            let saved = draft.isNew ? codexStore.addConfiguredProvider(provider) : codexStore.updateProvider(provider)
            guard saved else { return codexStore.errorMessage ?? "保存失败，请重试。" }
            if codexStore.activeProviderID == provider.id, let modelID = provider.activeModelID {
                codexStore.activate(providerID: provider.id, modelID: modelID)
            }
        }
        selectedID = draft.id
        return nil
    }
    private func deleteConnection(_ id: UUID) {
        // Deleting the configuration the client is *currently pointed at* has
        // to take the client off it, exactly like the sibling select/activate
        // paths (`onUseOfficial`, `activate`). Removing only the row left
        // settings.json / config.toml pointing at a vendor that no longer
        // exists in the list — and, because no row carries the id any more,
        // nothing could ever activate it back off. The store keeps the list
        // entry while the delete path may fail, so the row is only removed
        // here once the client is back on the official connection.
        if client == .claude, let provider = providerStore.providers.first(where: { $0.id == id }) {
            if providerStore.activeProviderID == id { providerStore.restoreOfficial() }
            providerStore.deleteProvider(provider)
        } else if let provider = codexStore.providers.first(where: { $0.id == id }) {
            if codexStore.activeProviderID == id { codexStore.restoreOfficial() }
            codexStore.deleteProvider(provider)
        }
        if selectedID == id { selectedID = nil }
    }
    private func activate(_ p: Provider, modelID: UUID) {
        if client == .claude { providerStore.activateModel(providerID: p.id, modelID: modelID) }
        else { codexStore.activate(providerID: p.id, modelID: modelID) }
    }
    /// The card's 抓包 switch, and the editor's 「记录请求报文」 toggle, write the
    /// same fact. Both go through the stores' `setCaptureEnabled`, which owns
    /// the side effects (re-publish the widget snapshot, push the twin profile,
    /// and — when the row is live — rewrite the client config through the local
    /// proxy so capture actually takes effect without a re-activation).
    private func setCapture(_ p: Provider, enabled: Bool) {
        if client == .claude { providerStore.setCaptureEnabled(providerID: p.id, enabled: enabled) }
        else { codexStore.setCaptureEnabled(providerID: p.id, enabled: enabled) }
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
}
