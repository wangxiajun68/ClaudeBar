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
    @Published var quotaWindows: [CodexQuotaWindow] = []
    @Published var quotaLoading = false
    @Published var quotaNote: String? = nil

    let proxyState = CodexProxyState()
    private var proxyServer: CodexProxyServer?
    private var quotaTask: Task<Void, Never>?
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

        // Lists stay independent. Empty Codex is empty — import from Claude
        // only when the user taps「导入」in the editor.

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

        clearLegacyMaxReasoning()

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

    /// Old builds defaulted Codex reasoning to `"max"`. Empty means omit
    /// `model_reasoning_effort`; rewrite JSON and config.toml so stored
    /// `"max"` does not linger after the default change.
    private func clearLegacyMaxReasoning() {
        var changed = false
        for i in providers.indices {
            for j in providers[i].models.indices where providers[i].models[j].reasoningEffort == "max" {
                providers[i].models[j].reasoningEffort = ""
                changed = true
            }
        }
        let disk = (try? String(contentsOf: FilePaths.codexProvidersFile, encoding: .utf8)) ?? ""
        let diskHadMax = disk.range(
            of: #"\"reasoningEffort\"\s*:\s*\"max\""#,
            options: .regularExpression) != nil
        let toml = (try? String(contentsOf: FilePaths.codexConfigFile, encoding: .utf8)) ?? ""
        let tomlHadMax = toml.range(
            of: #"model_reasoning_effort\s*=\s*"max""#,
            options: .regularExpression) != nil
        if changed || diskHadMax { save() }
        if changed || diskHadMax || tomlHadMax { reactivateActive() }
    }

    @discardableResult
    func save() -> Bool {
        do {
            let data = try JSONEncoder().encode(CodexProvidersFile(providers: providers, activeProviderID: activeProviderID, activeKey: activeKey))
            try FileManager.default.createDirectory(at: FilePaths.claudeDir, withIntermediateDirectories: true)
            try PrivateFileWriter.write(data, to: FilePaths.codexProvidersFile)
            return true
        } catch {
            errorMessage = "保存供应商失败：\(error.localizedDescription)"
            return false
        }
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
        let viaAnthropic = prefs.codexRoutingEnabled || anthropicCapture
        let need = viaOpenAI || viaAnthropic

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

            if viaAnthropic, let c = claude {
                await proxyState.setAnthropic(.init(
                    baseURL: c.baseURL, apiKey: c.authToken, name: c.name))
            } else {
                await proxyState.setAnthropic(nil)
            }
            await proxyState.setCaptureAnthropic(anthropicCapture)

            if let p = self.resolvedThirdPartyOpenAI() {
                await proxyState.setThirdPartyOpenAI(.init(
                    baseURL: p.baseURL, apiKey: p.apiKey, wireAPI: p.wireAPI, name: p.name))
            } else {
                await proxyState.setThirdPartyOpenAI(nil)
            }
            if let c = self.resolvedThirdPartyAnthropic() {
                await proxyState.setThirdPartyAnthropic(.init(
                    baseURL: c.baseURL, apiKey: c.authToken, name: c.name))
            } else {
                await proxyState.setThirdPartyAnthropic(nil)
            }
        }
    }

    /// Settings toggle still calls this name.
    func syncProxyWithPreferences() { syncProxyRuntime() }

    var activeProvider: CodexProvider? {
        providers.first { $0.id == activeProviderID }
    }

    /// Third-party OpenAI picker; `nil` id follows the active Codex vendor.
    func resolvedThirdPartyOpenAI() -> CodexProvider? {
        let id = AppPreferences.shared.proxyThirdPartyOpenAIProviderID
        if let id, let p = providers.first(where: { $0.id == id }) { return p }
        return activeProvider
    }

    func resolvedThirdPartyAnthropic() -> Provider? {
        let id = AppPreferences.shared.proxyThirdPartyAnthropicProviderID
        let claude = claudePeer?.providers ?? []
        if let id, let p = claude.first(where: { $0.id == id }) { return p }
        return claude.first { $0.id == claudePeer?.activeProviderID }
    }

    /// Start the proxy. Returns whether it is listening.
    ///
    /// The result is load-bearing: `activate()` writes `config.toml` pointing
    /// Codex at `127.0.0.1:<port>` and replaces `base_url`/`experimental_
    /// bearer_token` with proxy values. Committing that while `start()` failed
    /// (port already taken, a "port" the listener rejects) leaves Codex aimed
    /// at a dead loopback address with the real credentials no longer in the
    /// file, and nothing repairs it until the next `load()`.
    @discardableResult
    func startProxy() -> Bool {
        guard proxyServer == nil else { proxyRunning = true; return true }
        let server = CodexProxyServer(port: UInt16(clamping: AppPreferences.shared.codexProxyPort), state: proxyState)
        do {
            try server.start()
            proxyServer = server
            proxyRunning = true
            // The token reads back from disk, so it exists by now; make sure
            // whatever `config.toml` points at the proxy carries it. Older
            // builds wrote `PROXY_MANAGED` there, which the token check now
            // rejects, so a launch that never re-activates must heal itself.
            if let active = activeProvider {
                let model = active.models.first(where: { $0.id == active.activeModelID })
                    ?? active.models.first
                if let model,
                   CodexConfigWriter.usesProxy(proxyBaseURL: LocalProxyAddress.codexBase),
                   !CodexConfigWriter.bearerIsProxyToken() {
                    try? CodexConfigWriter.write(provider: active, model: model,
                                                 key: activeKey,
                                                 proxyBaseURL: LocalProxyAddress.codexBase)
                }
            }
            return true
        } catch {
            errorMessage = "启动本地代理失败：\(error.localizedDescription)"
            proxyRunning = false
            return false
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
        claudePeer?.reactivateActive()
    }

    /// Re-apply the current active provider/model (rewrites config.toml with
    /// or without the proxy URL depending on the current preference).
    func reactivateActive() {
        guard let p = activeProvider else { return }
        let modelID = p.activeModelID ?? p.models.first?.id ?? UUID()
        activate(providerID: p.id, modelID: modelID, syncPeer: false)
    }

    /// Point Codex at the HTTP-only official provider and leave the ChatGPT
    /// login in `auth.json` in place. The vendor list stays; a later activate
    /// writes the third-party overlay again.
    func restoreOfficial() {
        do {
            try CodexConfigWriter.restoreOfficial()
            try CodexConfigWriter.restoreOfficialAuth()
        } catch {
            errorMessage = "还原官方配置失败：\(error.localizedDescription)"
            return
        }
        errorMessage = nil
        activeProviderID = nil
        save()
        syncProxyRuntime()
    }

    /// ChatGPT subscription windows (5 小时 / 7 天), read through the
    /// authenticated Codex App Server account API.
    func refreshQuota() {
        // `load()` is immediately followed by `ProviderStore.refresh()` at
        // launch, and refresh can also be tapped repeatedly. Never spawn two
        // app-server instances for the same account query: their completion
        // order previously let a transient failure overwrite valid windows.
        guard quotaTask == nil else { return }
        quotaLoading = true
        quotaTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.quotaTask = nil }
            let snapshot = await CodexQuotaFetcher.fetch()
            self.quotaWindows = snapshot.windows
            self.quotaNote = snapshot.note
            self.quotaLoading = false
        }
    }

    // MARK: - Activate

    func setCaptureEnabled(providerID: UUID, enabled: Bool) {
        guard let idx = providers.firstIndex(where: { $0.id == providerID }) else { return }
        providers[idx].captureEnabled = enabled
        save()
        if activeProviderID == providerID {
            reactivateActive()
        } else {
            syncProxyRuntime()
        }
    }

    func activate(providerID: UUID, modelID: UUID, syncPeer: Bool = true) {
        guard let provider = providers.first(where: { $0.id == providerID }),
              let model = provider.models.first(where: { $0.id == modelID }) ?? provider.models.first else { return }

        // Serialize activations. Two of them issued back to back (a tile tap,
        // plus the mirrored `claudePeer?.activateMatching` that
        // `setCaptureEnabled`/`load()` also trigger) interleave at the first
        // `await`, and the *last* writer wins — which can be the one that
        // computed `viaProxy` before the other changed the proxy's state, so
        // `config.toml` ends up pointing at a stopped proxy. The token makes
        // the loser of that race fail loudly instead of silently, but the
        // reentrancy itself is worth removing.
        guard activationTask == nil else {
            pendingActivation = (providerID, modelID, syncPeer)
            return
        }

        let viaProxy = AppPreferences.shared.codexRoutingEnabled || provider.captureEnabled
        let proxyBase: String? = viaProxy ? LocalProxyAddress.codexBase : nil

        activationTask = Task { @MainActor in
            defer {
                activationTask = nil
                if let next = pendingActivation {
                    pendingActivation = nil
                    activate(providerID: next.0, modelID: next.1, syncPeer: next.2)
                }
            }
            if viaProxy, !startProxy() {
                // Do not write a proxy URL we cannot serve: keep the vendor's
                // real endpoint and credentials in config.toml and surface the
                // failure instead.
                errorMessage = "本地代理未启动，已保留直连配置：\(errorMessage ?? "")"
                await proxyState.setUpstream(.init(
                    baseURL: provider.baseURL, apiKey: provider.apiKey,
                    wireAPI: provider.wireAPI, name: provider.name))
                await proxyState.setCaptureOpenAI(provider.captureEnabled)
                return
            }
            await proxyState.setUpstream(.init(
                baseURL: provider.baseURL, apiKey: provider.apiKey,
                wireAPI: provider.wireAPI, name: provider.name))
            await proxyState.setCaptureOpenAI(provider.captureEnabled)
            do {
                try CodexConfigWriter.write(provider: provider, model: model, key: activeKey, proxyBaseURL: proxyBase)
                try CodexConfigWriter.writeAuth(apiKey: provider.apiKey, preserveOfficialLogin: provider.preserveOfficialLogin)
            } catch {
                errorMessage = "写入 Codex 配置失败：\(error.localizedDescription)"
                return
            }
            activeProviderID = providerID
            if let idx = providers.firstIndex(where: { $0.id == providerID }) {
                providers[idx].activeModelID = model.id
            }
            save()
            syncProxyRuntime()
            if syncPeer {
                claudePeer?.activateMatching(codex: provider, model: model)
            }
        }
    }

    private var activationTask: Task<Void, Never>?
    private var pendingActivation: (UUID, UUID, Bool)?

    /// Mirror a Claude activation onto the matching Codex vendor/model.
    func activateMatching(claude: Provider, model: ModelConfig) {
        guard let dest = providers.first(where: { ProviderBridge.matches(claude, $0) }) else { return }
        let slug = ProviderBridge.stripClaudeModelSuffix(model.name)
        guard let mid = dest.models.first(where: {
            $0.name.caseInsensitiveCompare(slug) == .orderedSame
        })?.id else { return }
        if dest.id == activeProviderID, dest.activeModelID == mid { return }
        activate(providerID: dest.id, modelID: mid, syncPeer: false)
    }

    // MARK: - CRUD

    @discardableResult
    func addBlankProvider() -> CodexProvider {
        let placeholder = CodexModelConfig(name: "model-name")
        let p = CodexProvider(name: "新供应商", models: [placeholder], activeModelID: placeholder.id)
        addProvider(p)
        return p
    }

    func addFromPreset(_ preset: CodexProvider) {
        var p = preset
        p.id = UUID()
        p.apiKey = ""
        p.models = p.models.map { m in
            var m = m; m.id = UUID(); return m
        }
        p.activeModelID = p.models.first?.id
        addProvider(p)
    }

    func addProvider(_ provider: CodexProvider) {
        providers.append(provider)
        if activeProviderID == nil { activeProviderID = provider.id }
        save()
    }

    @discardableResult
    func updateProvider(_ provider: CodexProvider) -> Bool {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return false }
        let previous = providers[index]
        providers[index] = provider
        guard save() else {
            providers[index] = previous
            return false
        }
        return true
    }

    func deleteProvider(_ provider: CodexProvider) {
        providers.removeAll { $0.id == provider.id }
        if activeProviderID == provider.id { activeProviderID = providers.first?.id }
        save()
    }

    func duplicateProvider(_ provider: CodexProvider) {
        var copy = provider
        copy.id = UUID()
        copy.name = "\(provider.name) 副本"
        copy.models = provider.models.map { m in
            var m = m; m.id = UUID(); return m
        }
        copy.activeModelID = copy.models.first?.id
        providers.append(copy)
        save()
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
