import Foundation
import Combine

/// Provider store for Codex — mirrors ProviderStore's load/save/activate
/// flow but only manages `~/.codex/config.toml` + `auth.json` (no sessions,
/// usage, or balance). Provider metadata lives in
/// `~/.claude/claude-bar-codex-providers.json`, separate from the Claude list.
///
/// Also owns the local routing proxy lifecycle: when routing is enabled,
/// config.toml points at `http://127.0.0.1:<port>/v1`, the real upstream
/// (baseURL/apiKey/wireAPI) lives only in `CodexProxyState`, and the proxy
/// fixes openai/codex#23186 (MCP namespace tools unusable on generic
/// Responses backends).
@MainActor
final class CodexProviderStore: ObservableObject {
    @Published var providers: [CodexProvider] = []
    @Published var activeProviderID: UUID? = nil
    @Published var activeKey: String = "custom"
    @Published var errorMessage: String? = nil
    @Published var proxyRunning: Bool = false

    let proxyState = CodexProxyState()
    private var proxyServer: CodexProxyServer?

    init() {}

    // MARK: - Load / Save

    func load() {
        if FileManager.default.fileExists(atPath: FilePaths.codexProvidersFile.path),
           let data = try? Data(contentsOf: FilePaths.codexProvidersFile),
           let file = try? JSONDecoder().decode(CodexProvidersFile.self, from: data) {
            providers = file.providers
            activeProviderID = file.activeProviderID
            activeKey = file.activeKey
        } else {
            providers = []
            activeProviderID = nil
        }

        // Aibox / GLM-style hosts used to be saved as wire_api=responses;
        // their Responses deserializer 400s on turn-2 function_call replay.
        var migrated = false
        for i in providers.indices {
            if providers[i].wireAPI != "chat",
               CodexProxyTransform.shouldBridgeToChat(
                baseURL: providers[i].baseURL,
                wireAPI: "responses",
                model: providers[i].activeModel?.name ?? "") {
                providers[i].wireAPI = "chat"
                migrated = true
            }
        }
        if migrated { save() }

        // Restore routing if it was enabled in a previous session.
        syncProxyWithPreferences()

        // Reconcile with the live config.toml: when the file on disk points
        // at a provider/model we know, adopt it as active (same trick as
        // ProviderStore.loadProviders detecting external switches). A
        // loopback base_url is OUR proxy config, not an external switch.
        guard let current = CodexConfigWriter.readCurrent() else { return }
        let viaProxy = current.baseURL.hasPrefix("http://127.0.0.1:")
        let routingOn = AppPreferences.shared.codexRoutingEnabled
        if viaProxy && !routingOn {
            // Stale proxy config after the toggle flipped (or a fresh
            // session with routing off): rewrite the real URL back.
            if activeProviderID != nil {
                reactivateActive()
            }
            return
        }
        for provider in providers {
            let ownsModel = provider.models.contains {
                $0.name.caseInsensitiveCompare(current.model) == .orderedSame
            }
            let isActiveForKey = (current.providerKey == activeKey && provider.id == activeProviderID)
            guard isActiveForKey || ownsModel else { continue }
            activeProviderID = provider.id
            if let idx = providers.firstIndex(where: { $0.id == provider.id }),
               let model = provider.models.first(where: {
                   $0.name.caseInsensitiveCompare(current.model) == .orderedSame
               }) {
                providers[idx].activeModelID = model.id
            }
            save()
            break
        }
    }

    func save() {
        let file = CodexProvidersFile(providers: providers, activeProviderID: activeProviderID, activeKey: activeKey)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: FilePaths.claudeDir, withIntermediateDirectories: true)
        try? data.write(to: FilePaths.codexProvidersFile, options: .atomic)
    }

    // MARK: - Local routing proxy

    /// Start/stop the proxy per AppPreferences. Idempotent; called from
    /// load() and the Settings toggle.
    func syncProxyWithPreferences() {
        let prefs = AppPreferences.shared
        if prefs.codexRoutingEnabled {
            startProxy()
            // Push the current active provider as upstream, if any.
            if let p = activeProvider {
                Task { await proxyState.setUpstream(.init(
                    baseURL: p.baseURL, apiKey: p.apiKey, wireAPI: p.wireAPI)) }
            }
        } else {
            stopProxy()
            Task { await proxyState.setUpstream(nil) }
        }
    }

    var activeProvider: CodexProvider? {
        providers.first { $0.id == activeProviderID }
    }

    func startProxy() {
        guard proxyServer == nil else { proxyRunning = true; return }
        let server = CodexProxyServer(port: UInt16(clamping: AppPreferences.shared.codexProxyPort), state: proxyState)
        do {
            try server.start()
            proxyServer = server
            proxyRunning = true
        } catch {
            errorMessage = "启动本地路由失败: \(error.localizedDescription)"
        }
    }

    func stopProxy() {
        proxyServer?.stop()
        proxyServer = nil
        proxyRunning = false
    }

    /// Restart the proxy (port change) and rewrite config.toml so the new
    /// port takes effect.
    func restartProxyAndReactivate() {
        stopProxy()
        if AppPreferences.shared.codexRoutingEnabled { startProxy() }
        reactivateActive()
    }

    /// Re-apply the current active provider/model (rewrites config.toml with
    /// or without the proxy URL depending on the current preference).
    func reactivateActive() {
        guard let p = activeProvider else { return }
        let modelID = p.activeModelID ?? p.models.first?.id ?? UUID()
        activate(providerID: p.id, modelID: modelID)
    }

    // MARK: - Activate

    func activate(providerID: UUID, modelID: UUID) {
        guard let provider = providers.first(where: { $0.id == providerID }),
              let model = provider.models.first(where: { $0.id == modelID }) ?? provider.models.first else { return }

        let routingOn = AppPreferences.shared.codexRoutingEnabled
        let proxyBase: String? = routingOn ? "http://127.0.0.1:\(AppPreferences.shared.codexProxyPort)/v1" : nil

        // Order matters: upstream must be in place before config.toml points
        // Codex at the proxy (no window where the proxy has no upstream).
        Task { @MainActor in
            if routingOn {
                startProxy()
                await proxyState.setUpstream(.init(
                    baseURL: provider.baseURL, apiKey: provider.apiKey, wireAPI: provider.wireAPI))
            } else {
                await proxyState.setUpstream(nil)
            }
            do {
                try CodexConfigWriter.write(provider: provider, model: model, key: activeKey, proxyBaseURL: proxyBase)
                try CodexConfigWriter.writeAuth(apiKey: provider.apiKey, preserveOfficialLogin: provider.preserveOfficialLogin)
            } catch {
                errorMessage = "写入 Codex 配置失败: \(error.localizedDescription)"
                load()
                return
            }
            activeProviderID = providerID
            if let idx = providers.firstIndex(where: { $0.id == providerID }) {
                providers[idx].activeModelID = model.id
            }
            save()
        }
    }

    // MARK: - CRUD

    func addProvider(_ provider: CodexProvider) {
        providers.append(provider)
        if activeProviderID == nil { activeProviderID = provider.id }
        save()
    }

    func updateProvider(_ provider: CodexProvider) {
        guard let idx = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[idx] = provider
        save()
    }

    func deleteProvider(_ provider: CodexProvider) {
        providers.removeAll { $0.id == provider.id }
        if activeProviderID == provider.id { activeProviderID = providers.first?.id }
        save()
    }

    func duplicateProvider(_ provider: CodexProvider) {
        var copy = provider
        copy.id = UUID()
        copy.name = "\(provider.name) Copy"
        copy.models = provider.models.map { m in
            var m = m; m.id = UUID(); return m
        }
        copy.activeModelID = copy.models.first?.id
        providers.append(copy)
        save()
    }
}
