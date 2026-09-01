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
    @Published var importSummary: String? = nil

    let proxyState = CodexProxyState()
    private var proxyServer: CodexProxyServer?
    /// Weak back-ref so proxy lifecycle can see Claude capture flags.
    weak var claudePeer: ProviderStore?

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

        if providers.isEmpty {
            let claude = ProviderBridge.readClaudeProviders()
            if !claude.isEmpty {
                let converted = claude.map { ProviderBridge.toCodex($0) }
                let result = ProviderBridge.merge(into: &providers, from: converted)
                if !result.isEmpty {
                    importSummary = "已从 Claude 导入 · \(result.summary)"
                    save()
                }
            }
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

        // Restore routing / capture if they were enabled in a previous session.
        syncProxyRuntime()

        // Reconcile with the live config.toml: when the file on disk points
        // at a provider/model we know, adopt it as active (same trick as
        // ProviderStore.loadProviders detecting external switches). A
        // loopback base_url is OUR proxy config, not an external switch.
        guard let current = CodexConfigWriter.readCurrent() else { return }
        let viaProxy = LocalProxyAddress.isLoopback(current.baseURL)
        let routingOn = AppPreferences.shared.codexRoutingEnabled
        let captureOn = activeProvider?.captureEnabled ?? false
        if viaProxy && !routingOn && !captureOn {
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

    /// Start/stop the proxy from routing preference + per-vendor capture.
    /// Idempotent; called from load(), activate, Settings, and Claude activate.
    func syncProxyRuntime() {
        let prefs = AppPreferences.shared
        let claude = claudePeer?.providers.first { $0.id == claudePeer?.activeProviderID }
        let openaiCapture = activeProvider?.captureEnabled ?? false
        let anthropicCapture = claude?.captureEnabled ?? false
        let viaOpenAI = prefs.codexRoutingEnabled || openaiCapture
        let need = viaOpenAI || anthropicCapture

        if need {
            startProxy()
        } else {
            stopProxy()
        }

        Task { [proxyState] in
            if viaOpenAI, let p = self.activeProvider {
                await proxyState.setUpstream(.init(
                    baseURL: p.baseURL, apiKey: p.apiKey, wireAPI: p.wireAPI, name: p.name))
            } else {
                await proxyState.setUpstream(nil)
            }
            await proxyState.setCaptureOpenAI(openaiCapture)

            if anthropicCapture, let c = claude {
                await proxyState.setAnthropic(.init(
                    baseURL: c.baseURL, apiKey: c.authToken, name: c.name))
            } else {
                await proxyState.setAnthropic(nil)
            }
            await proxyState.setCaptureAnthropic(anthropicCapture)
        }
    }

    /// Settings toggle still calls this name.
    func syncProxyWithPreferences() { syncProxyRuntime() }

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
        syncProxyRuntime()
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
        let captureOn = provider.captureEnabled
        let viaProxy = routingOn || captureOn
        let proxyBase: String? = viaProxy ? LocalProxyAddress.codexBase : nil

        // Upstream must be in place before config.toml points Codex at the
        // proxy. Capture flags come from the provider we're activating, not
        // the previous active row.
        Task { @MainActor in
            if viaProxy { startProxy() }
            await proxyState.setUpstream(.init(
                baseURL: provider.baseURL, apiKey: provider.apiKey,
                wireAPI: provider.wireAPI, name: provider.name))
            await proxyState.setCaptureOpenAI(captureOn)
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
            syncProxyRuntime()
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

    /// Rewrite this list as a projection of the unified Claude list, keeping
    /// Codex-only flags/reasoning on rows that already exist.
    func project(from claude: [Provider], extras: (Provider, ProviderBridge.CodexExtras)? = nil) {
        var next: [CodexProvider] = []
        for p in claude {
            guard !p.models.isEmpty else { continue }
            let extraForP: ProviderBridge.CodexExtras? = extras.flatMap { pair in
                pair.0.id == p.id || pair.0.name.caseInsensitiveCompare(p.name) == .orderedSame
                    ? pair.1 : nil
            }
            if let existing = providers.first(where: { ProviderBridge.matches(p, $0) }) {
                next.append(ProviderBridge.overlay(p, onto: existing, extras: extraForP))
            } else {
                var created = ProviderBridge.toCodex(p)
                if let extraForP {
                    created = ProviderBridge.overlay(p, onto: created, extras: extraForP)
                }
                next.append(created)
            }
        }
        let stillActive = next.contains { $0.id == activeProviderID }
        providers = next
        if !stillActive { activeProviderID = next.first?.id }
        save()
    }

    /// Activate the Codex twin of a Claude provider/model (same name/URL + slug).
    func activateMatching(claude: Provider, model: ModelConfig) {
        if providers.first(where: { ProviderBridge.matches(claude, $0) }) == nil {
            providers.append(ProviderBridge.toCodex(claude))
            save()
        }
        guard let provider = providers.first(where: { ProviderBridge.matches(claude, $0) }) else { return }
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx].captureEnabled = claude.captureEnabled
        }
        let slug = ProviderBridge.stripClaudeModelSuffix(model.name)
        let modelID = provider.models.first {
            $0.name.caseInsensitiveCompare(slug) == .orderedSame
        }?.id ?? provider.activeModelID ?? provider.models.first?.id
        guard let modelID else { return }
        activate(providerID: provider.id, modelID: modelID)
    }

    /// Import Claude Code providers (from the other store or from disk).
    /// Matching is by name or rewritten OpenAI-compatible URL; existing
    /// Codex-only fields (wire_api, reasoning) are kept on collision.
    @discardableResult
    func importFromClaude(_ source: [Provider]? = nil) -> ProviderBridge.ImportResult {
        let incoming = source ?? ProviderBridge.readClaudeProviders()
        let converted = incoming.map { ProviderBridge.toCodex($0) }
        let result = ProviderBridge.merge(into: &providers, from: converted)
        importSummary = result.summary
        if !result.isEmpty { save() }
        return result
    }
}
