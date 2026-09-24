import Foundation

/// One configuration, two clients. Name, key, and models travel together.
/// Each client keeps the base URL from its own vendor endpoint, and each
/// client keeps its own active provider.
@MainActor
enum ProviderProfileSync {
    private static var applying = false

    /// Link rows that were saved before profiles existed, copy a key only
    /// when the other side is empty, and union model lists. Base URLs and
    /// which provider is active stay on each client. A vendor that exists
    /// on only one side gets a twin on the other when that client has an
    /// endpoint; the twin is not activated.
    static func reconcile(claude: ProviderStore, codex: CodexProviderStore) {
        guard !applying else { return }
        applying = true
        defer { applying = false }

        var claudeRows = claude.providers
        var codexRows = codex.providers
        let originalClaude = claudeRows
        let originalCodex = codexRows
        link(&claudeRows, &codexRows)
        guard claudeRows != originalClaude || codexRows != originalCodex else { return }

        if claudeRows != originalClaude {
            claude.providers = claudeRows
            if !claude.saveProviders() { claude.providers = originalClaude }
        }
        if codexRows != originalCodex {
            codex.providers = codexRows
            if !codex.save() { codex.providers = originalCodex }
        }
    }

    private static func link(_ claude: inout [Provider], _ codex: inout [CodexProvider]) {
        var usedClaude = Set<Int>()
        var usedCodex = Set<Int>()
        var pairs: [(Int, Int)] = []

        func claim(_ c: Int, _ x: Int) {
            guard usedClaude.insert(c).inserted, usedCodex.insert(x).inserted else { return }
            pairs.append((c, x))
        }
        for (c, row) in claude.enumerated() {
            guard let id = row.profileID,
                  let x = codex.firstIndex(where: { $0.profileID == id }) else { continue }
            claim(c, x)
        }
        func claimUnique(_ matches: (Provider, CodexProvider) -> Bool) {
            let claudeOpen = claude.indices.filter { !usedClaude.contains($0) }
            let codexOpen = codex.indices.filter { !usedCodex.contains($0) }
            for c in claudeOpen where !usedClaude.contains(c) {
                let hits = codexOpen.filter { !usedCodex.contains($0) && matches(claude[c], codex[$0]) }
                guard hits.count == 1, let x = hits.first else { continue }
                let back = claudeOpen.filter { !usedClaude.contains($0) && matches(claude[$0], codex[x]) }
                guard back.count == 1 else { continue }
                claim(c, x)
            }
        }
        claimUnique { $0.name.caseInsensitiveCompare($1.name) == .orderedSame }
        claimUnique { lhs, rhs in
            guard let left = resolvedEntry(catalogID: lhs.catalogID, baseURL: lhs.baseURL)?.id,
                  let right = resolvedEntry(catalogID: rhs.catalogID, baseURL: rhs.baseURL)?.id else { return false }
            return left == right
        }
        claimUnique { lhs, rhs in
            let left = ProviderCatalogEntry.identityURL(lhs.baseURL)
            let right = ProviderCatalogEntry.identityURL(rhs.baseURL)
            return !left.isEmpty && left == right
        }

        for (c, x) in pairs {
            merge(&claude[c], &codex[x])
        }
        let claudeCount = claude.count
        let codexCount = codex.count
        for c in 0..<claudeCount where !usedClaude.contains(c) {
            let entry = resolvedEntry(catalogID: claude[c].catalogID, baseURL: claude[c].baseURL)
            guard entry?.codex != nil else { continue }
            if claude[c].profileID == nil { claude[c].profileID = UUID() }
            if claude[c].catalogID == nil { claude[c].catalogID = entry?.id }
            guard let created = makeCodex(from: claude[c], entry: entry) else { continue }
            codex.append(created)
        }
        for x in 0..<codexCount where !usedCodex.contains(x) {
            let entry = resolvedEntry(catalogID: codex[x].catalogID, baseURL: codex[x].baseURL)
            guard entry?.claude != nil else { continue }
            if codex[x].profileID == nil { codex[x].profileID = UUID() }
            if codex[x].catalogID == nil { codex[x].catalogID = entry?.id }
            guard let created = makeClaude(from: codex[x], entry: entry) else { continue }
            claude.append(created)
        }
    }

    /// Shared profile and model list. A key moves across only to fill an
    /// empty side, so two different keys for the same name are left as saved.
    private static func merge(_ claude: inout Provider, _ codex: inout CodexProvider) {
        let profile = claude.profileID ?? codex.profileID ?? UUID()
        claude.profileID = profile
        codex.profileID = profile
        if claude.catalogID == nil {
            claude.catalogID = resolvedEntry(catalogID: nil, baseURL: claude.baseURL)?.id
        }
        if codex.catalogID == nil {
            codex.catalogID = resolvedEntry(catalogID: nil, baseURL: codex.baseURL)?.id
        }
        let claudeKey = claude.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexKey = codex.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if claudeKey.isEmpty, !codexKey.isEmpty { claude.authToken = codexKey }
        if codexKey.isEmpty, !claudeKey.isEmpty { codex.apiKey = claudeKey }
        unionModels(&claude, &codex)
    }

    private static func unionModels(_ claude: inout Provider, _ codex: inout CodexProvider) {
        var slugs = Set(codex.models.map { ProviderBridge.stripClaudeModelSuffix($0.name).lowercased() })
        for model in claude.models {
            let slug = ProviderBridge.stripClaudeModelSuffix(model.name)
            guard slugs.insert(slug.lowercased()).inserted else { continue }
            codex.models.append(CodexModelConfig(
                name: slug, contextWindow: model.contextTokens,
                autoCompactTokenLimit: model.disableCompact ? "" : model.autoCompactWindow))
        }
        var claudeSlugs = Set(claude.models.map { ProviderBridge.stripClaudeModelSuffix($0.name).lowercased() })
        for model in codex.models {
            let slug = ProviderBridge.stripClaudeModelSuffix(model.name)
            guard claudeSlugs.insert(slug.lowercased()).inserted else { continue }
            claude.models.append(ModelConfig(
                name: ProviderBridge.claudeModelName(fromCodex: model.name, contextWindow: model.contextWindow),
                contextTokens: model.contextWindow, disableCompact: false, disableExperimentalBetas: false,
                autoCompactWindow: model.autoCompactTokenLimit))
        }
    }

    static func pushClaude(_ provider: Provider, store: ProviderStore) {
        guard !applying, let peer = store.peer, let profileID = provider.profileID else { return }
        let entry = resolvedEntry(catalogID: provider.catalogID, baseURL: provider.baseURL)
        if let entry, entry.codex == nil { return }
        applying = true
        defer { applying = false }

        if let index = codexIndex(profileID: profileID, name: provider.name, entry: entry, providers: peer.providers) {
            var twin = peer.providers[index]
            fillCodex(&twin, from: provider, entry: entry, creating: false)
            let live = peer.activeProviderID == twin.id
            guard peer.updateProvider(twin, propagate: false) else { return }
            if live { rewriteCodex(peer, id: twin.id) }
        } else if let created = makeCodex(from: provider, entry: entry) {
            _ = peer.addConfiguredProvider(created, propagate: false)
        }
    }

    static func pushCodex(_ provider: CodexProvider, store: CodexProviderStore) {
        guard !applying, let peer = store.claudePeer, let profileID = provider.profileID else { return }
        let entry = resolvedEntry(catalogID: provider.catalogID, baseURL: provider.baseURL)
        if let entry, entry.claude == nil { return }
        applying = true
        defer { applying = false }

        if let index = claudeIndex(profileID: profileID, name: provider.name, entry: entry, providers: peer.providers) {
            var twin = peer.providers[index]
            fillClaude(&twin, from: provider, entry: entry, creating: false)
            let live = peer.activeProviderID == twin.id
            guard peer.updateProvider(twin, propagate: false) else { return }
            if live { rewriteClaude(peer, id: twin.id) }
        } else if let created = makeClaude(from: provider, entry: entry) {
            _ = peer.addConfiguredProvider(created, propagate: false)
        }
    }

    /// Drop the other client's copy. If that copy is the one currently in
    /// use, return that client to its official login instead of activating
    /// a different saved provider.
    static func removeCodex(profileID: UUID, store: ProviderStore) {
        guard !applying, let peer = store.peer,
              let twin = peer.providers.first(where: { $0.profileID == profileID }) else { return }
        applying = true
        defer { applying = false }
        let live = peer.activeProviderID == twin.id
        peer.deleteProvider(twin, propagate: false, reassignActive: false)
        if live { peer.restoreOfficial() }
    }

    static func removeClaude(profileID: UUID, store: CodexProviderStore) {
        guard !applying, let peer = store.claudePeer,
              let twin = peer.providers.first(where: { $0.profileID == profileID }) else { return }
        applying = true
        defer { applying = false }
        let live = peer.activeProviderID == twin.id
        peer.deleteProvider(twin, propagate: false, reassignActive: false)
        if live { peer.restoreOfficial() }
    }

    /// An existing row with the same profile, or the one saved configuration
    /// of this vendor from before profiles existed. A second key for the same
    /// vendor is left alone.
    private static func codexIndex(profileID: UUID, name: String, entry: ProviderCatalogEntry?,
                                   providers: [CodexProvider]) -> Int? {
        if let index = providers.firstIndex(where: { $0.profileID == profileID }) { return index }
        let open = providers.indices.filter { providers[$0].profileID == nil || providers[$0].profileID == profileID }
        if let entry {
            let same = open.filter {
                providers[$0].catalogID == entry.id
                    || ProviderCatalogEntry.matching(baseURL: providers[$0].baseURL)?.id == entry.id
            }
            if same.count == 1 { return same[0] }
            return same.first {
                providers[$0].name.caseInsensitiveCompare(name) == .orderedSame
            }
        }
        let named = open.filter { providers[$0].name.caseInsensitiveCompare(name) == .orderedSame }
        return named.count == 1 ? named[0] : nil
    }

    private static func claudeIndex(profileID: UUID, name: String, entry: ProviderCatalogEntry?,
                                    providers: [Provider]) -> Int? {
        if let index = providers.firstIndex(where: { $0.profileID == profileID }) { return index }
        let open = providers.indices.filter { providers[$0].profileID == nil || providers[$0].profileID == profileID }
        if let entry {
            let same = open.filter {
                providers[$0].catalogID == entry.id
                    || ProviderCatalogEntry.matching(baseURL: providers[$0].baseURL)?.id == entry.id
            }
            if same.count == 1 { return same[0] }
            return same.first {
                providers[$0].name.caseInsensitiveCompare(name) == .orderedSame
            }
        }
        let named = open.filter { providers[$0].name.caseInsensitiveCompare(name) == .orderedSame }
        return named.count == 1 ? named[0] : nil
    }

    private static func resolvedEntry(catalogID: String?, baseURL: String) -> ProviderCatalogEntry? {
        if let entry = ProviderCatalogEntry.entry(id: catalogID) { return entry }
        return ProviderCatalogEntry.matching(baseURL: baseURL)
    }

    private static func makeCodex(from source: Provider, entry: ProviderCatalogEntry?) -> CodexProvider? {
        guard entry?.codex != nil || entry == nil else { return nil }
        var twin = CodexProvider(name: source.name, apiKey: source.authToken, requiresOpenAIAuth: false,
                                 profileID: source.profileID, catalogID: source.catalogID ?? entry?.id)
        fillCodex(&twin, from: source, entry: entry, creating: true)
        guard !twin.baseURL.isEmpty else { return nil }
        return twin
    }

    private static func makeClaude(from source: CodexProvider, entry: ProviderCatalogEntry?) -> Provider? {
        guard entry?.claude != nil || entry == nil else { return nil }
        var twin = Provider(name: source.name, authToken: source.apiKey,
                            profileID: source.profileID, catalogID: source.catalogID ?? entry?.id)
        fillClaude(&twin, from: source, entry: entry, creating: true)
        guard !twin.baseURL.isEmpty else { return nil }
        return twin
    }

    private static func fillCodex(_ twin: inout CodexProvider, from source: Provider,
                                  entry: ProviderCatalogEntry?, creating: Bool) {
        twin.name = source.name
        twin.apiKey = source.authToken
        twin.captureEnabled = source.captureEnabled
        twin.profileID = source.profileID
        if twin.catalogID == nil { twin.catalogID = source.catalogID ?? entry?.id }
        if creating, let endpoint = entry?.codex {
            twin.baseURL = endpoint.url(for: endpoint.wireAPI)
            twin.wireAPI = endpoint.wireAPI
        } else if creating {
            twin.baseURL = source.baseURL
        }
        let models = source.models.map { model -> CodexModelConfig in
            let slug = ProviderBridge.stripClaudeModelSuffix(model.name)
            if let old = twin.models.first(where: { $0.name.caseInsensitiveCompare(slug) == .orderedSame }) {
                var copy = old
                copy.name = slug
                copy.contextWindow = model.contextTokens
                copy.autoCompactTokenLimit = model.disableCompact ? "" : model.autoCompactWindow
                return copy
            }
            return CodexModelConfig(name: slug, contextWindow: model.contextTokens,
                                    autoCompactTokenLimit: model.disableCompact ? "" : model.autoCompactWindow)
        }
        twin.models = models
        let slug = ProviderBridge.stripClaudeModelSuffix(source.activeModel?.name ?? "")
        twin.activeModelID = models.first { $0.name.caseInsensitiveCompare(slug) == .orderedSame }?.id
            ?? models.first?.id
    }

    private static func fillClaude(_ twin: inout Provider, from source: CodexProvider,
                                   entry: ProviderCatalogEntry?, creating: Bool) {
        twin.name = source.name
        twin.authToken = source.apiKey
        twin.captureEnabled = source.captureEnabled
        twin.profileID = source.profileID
        if twin.catalogID == nil { twin.catalogID = source.catalogID ?? entry?.id }
        if creating, let endpoint = entry?.claude {
            twin.baseURL = endpoint.baseURL
        } else if creating {
            twin.baseURL = source.baseURL
        }
        let models = source.models.map { model -> ModelConfig in
            let name = ProviderBridge.claudeModelName(fromCodex: model.name, contextWindow: model.contextWindow)
            if let old = twin.models.first(where: {
                ProviderBridge.stripClaudeModelSuffix($0.name).caseInsensitiveCompare(model.name) == .orderedSame
            }) {
                var copy = old
                copy.name = name
                copy.contextTokens = model.contextWindow
                copy.autoCompactWindow = model.autoCompactTokenLimit
                return copy
            }
            return ModelConfig(name: name, contextTokens: model.contextWindow,
                               disableCompact: false, disableExperimentalBetas: false,
                               autoCompactWindow: model.autoCompactTokenLimit)
        }
        twin.models = models
        let slug = source.activeModel?.name ?? ""
        twin.activeModelID = models.first {
            ProviderBridge.stripClaudeModelSuffix($0.name).caseInsensitiveCompare(slug) == .orderedSame
        }?.id ?? models.first?.id
    }

    private static func rewriteCodex(_ store: CodexProviderStore, id: UUID) {
        guard let provider = store.providers.first(where: { $0.id == id }),
              let modelID = provider.activeModelID ?? provider.models.first?.id else { return }
        store.activate(providerID: id, modelID: modelID)
    }

    private static func rewriteClaude(_ store: ProviderStore, id: UUID) {
        guard let provider = store.providers.first(where: { $0.id == id }),
              let modelID = provider.activeModelID ?? provider.models.first?.id else { return }
        store.activateModel(providerID: id, modelID: modelID)
    }
}
