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
    @State private var connectionEdit: ProviderConnectionRoute?
    @State private var setupEntry: ProviderCatalogEntry?
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
                HStack(spacing: Theme.Space.s10) {
                    GlyphWell(name: "exclamationmark.circle", tint: Theme.Ink.error, size: 26)
                    Text(error)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: Theme.Space.s8)
                }
                .padding(.horizontal, Theme.Space.s12)
                .padding(.vertical, Theme.Space.s10)
                .panelCard(radius: Theme.Radius.md, tint: Theme.statusError)
                .padding(.horizontal, Theme.Space.s24)
                .padding(.bottom, Theme.Space.s12)
            }
            directoryToolbar
            connectionStrip(f)
            directory(f)
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
            onOpen: { connectionEdit = ProviderConnectionRoute(id: $0.id, isNew: false) }
        )
        .equatable()
        .onAppear { providerStore.refreshBalance() }
    }

    /// The page band. It was a hand-typed 26pt bold title with no page mark
    /// (`Text("供应商").font(.system(size: 26, weight: .bold, design: .rounded))`)
    /// — a *third* title scale in a file whose neighbour page uses
    /// `PageTitle` — over a subtitle and a bordered button. It is now the same
    /// `PageHeaderCard` the connectors page opens with: the page mark in a
    /// well, the destination's own hue as a wash, and the frame ring the grid
    /// below carries.
    private var header: some View {
        // The band's anatomy matches 连接器 and 概览: `PageTitle` + its subtitle
        // on the leading side, the band's own control on the trailing side,
        // both top-aligned.
        //
        // It used to stack the subtitle **above** the button in one trailing
        // column, which made this the tallest band in the app (74pt against
        // 68pt) and pushed the button's bottom edge down into the frame ring —
        // the "错乱/重叠" this page showed. A subtitle belongs under its title,
        // never stacked over a control that then has to fight it for the same
        // corner.
        PageHeaderCard(tint: Theme.Ink.cursor, faceTint: Theme.cursor) { engaged in
            HStack(alignment: .top, spacing: Theme.Space.s12) {
                VStack(alignment: .leading, spacing: 3) {
                    PageTitle(title: "模型", engaged: engaged)
                    Text("发现模型平台，为你的编程工具接入新能力。")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s12)
                Button { connectionEdit = ProviderConnectionRoute(id: UUID(), isNew: true) } label: {
                    Label("自定义", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .headerControl()
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, Theme.Space.s24)
        .padding(.top, Theme.Space.s8)
        .padding(.bottom, Theme.Space.s16)
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
        .padding(.horizontal, 24)
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
            Text("\(f.providers.count) 个已保存配置").rollingNumber().foregroundStyle(Theme.textSecondary).fixedSize()
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
        .padding(.horizontal, Theme.Space.s14)
        .padding(.vertical, Theme.Space.s10)
        .panelCard(radius: Theme.Radius.md, tint: live ? Theme.statusSuccess : nil)
        .padding(.horizontal, Theme.Space.s24)
        .padding(.bottom, Theme.Space.s12)
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
                                            disableExperimentalBetas: $0.disableExperimentalBetas)
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
                            disableExperimentalBetas: $0.disableExperimentalBetas, autoCompactWindow: $0.autoCompactTokenLimit)
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
        if client == .claude, let provider = providerStore.providers.first(where: { $0.id == id }) {
            providerStore.deleteProvider(provider)
        } else if let provider = codexStore.providers.first(where: { $0.id == id }) {
            codexStore.deleteProvider(provider)
        }
        if selectedID == id { selectedID = nil }
    }
    private func activate(_ p: Provider, modelID: UUID) {
        if client == .claude { providerStore.activateModel(providerID: p.id, modelID: modelID) }
        else { codexStore.activate(providerID: p.id, modelID: modelID) }
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
