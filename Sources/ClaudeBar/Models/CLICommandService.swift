import Foundation

/// Routes local requests through the same production stores used by the app.
@MainActor
final class CLICommandService {
    private let store: ProviderStore
    private let codex: CodexProviderStore
    private let presentation: () -> [String: Any]
    private var mutationInProgress = false
    init(store: ProviderStore, codex: CodexProviderStore, presentation: @escaping () -> [String: Any]) {
        self.store = store; self.codex = codex; self.presentation = presentation
    }
    func execute(_ request: CLIControl.Request) async -> CLIControl.Response {
        let mutation = CLIControlPolicy.isMutation(request)
        do {
            try CLIControlPolicy.validate(request)
            try Task.checkCancellation()
            guard !mutation || !mutationInProgress else { throw CLIControlFailure(message: "Another control action is in progress; check status and retry") }
            if mutation { mutationInProgress = true }
            defer { if mutation { mutationInProgress = false; store.publishCLISnapshot() } }
            let result = try await perform(request)
            return CLIControl.response(request, message: "Completed", result: result)
        } catch let error as CLIControlFailure {
            return .init(id: request.id, ok: false, code: error.code, message: error.message)
        } catch {
            // Do not expose core log lines, configuration bodies, or process stderr.
            return .init(id: request.id, ok: false, code: 5, message: "Control operation failed; check the application's diagnostics")
        }
    }
    private func perform(_ r: CLIControl.Request) async throws -> Any {
        let action = r.arguments.first ?? "status"
        switch r.command {
        case "mode":
            guard ["status", "desktop", "performance"].contains(action), r.arguments.count <= 1 else { throw badArguments() }
            if action != "status" {
                AppPreferences.shared.performanceMode = action == "performance"
                // Presentation destruction is deferred past SwiftUI's initiating event.
                for _ in 0..<100 {
                    if presentation()["mode"] as? String == action { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard presentation()["mode"] as? String == action else { throw CLIControlFailure(message: "Presentation transition is still pending") }
            }
            return presentation()
        case "providers", "models": return try await providers(r)
        case "vpn": return try await vpn(r)
        case "connectors": return try await connectors(r)
        case "proxy": return try await proxy(r)
        case "config": return try await config(r)
        default: throw badArguments()
        }
    }
    private func badArguments() -> CLIControlFailure { .init(message: "Unsupported control arguments", code: 2) }
    private func bool(_ value: String) throws -> Bool {
        switch value { case "on", "true": return true; case "off", "false": return false; default: throw badArguments() }
    }
    private func agent(_ r: CLIControl.Request) throws -> String {
        let value = r.agent ?? "claude"
        guard ["claude", "codex"].contains(value) else { throw CLIControlFailure(message: "Provider/model operations support --agent claude or codex", code: 2) }
        return value
    }
    private func providerID(_ selector: String?, agent: String) throws -> UUID {
        if let selector {
            let rows = agent == "claude" ? store.providers.map { (id: $0.id.uuidString, name: $0.name) }
                : codex.providers.map { (id: $0.id.uuidString, name: $0.name) }
            return UUID(uuidString: try CLIControlPolicy.select(selector, from: rows))!
        }
        guard let id = agent == "claude" ? store.activeProviderID : codex.activeProviderID else {
            throw CLIControlFailure(message: "No active provider; specify --provider or use providers use")
        }
        return id
    }
    private func catalog(_ selectedAgent: String?) -> [[String: Any]] {
        let claude: [[String: Any]] = store.providers.map { p in
            ["id": p.id.uuidString, "name": p.name, "agent": "claude", "active": p.id == store.activeProviderID,
             "capture": p.captureEnabled, "models": p.models.map { m in
                 ["id": m.id.uuidString, "name": m.name, "active": m.id == p.activeModelID] as [String: Any]
             }]
        }
        let other: [[String: Any]] = codex.providers.map { p in
            ["id": p.id.uuidString, "name": p.name, "agent": "codex", "active": p.id == codex.activeProviderID,
             "capture": p.captureEnabled, "models": p.models.map { m in
                 ["id": m.id.uuidString, "name": m.name, "active": m.id == p.activeModelID] as [String: Any]
             }]
        }
        return (claude + other).filter { selectedAgent == nil || $0["agent"] as? String == selectedAgent }
    }
    private func providers(_ r: CLIControl.Request) async throws -> Any {
        let action = r.arguments.first ?? "catalog"
        if ["catalog", "list"].contains(action) {
            guard r.arguments.count == 1, r.agent == nil || ["claude", "codex"].contains(r.agent!) else { throw badArguments() }
            return ["providers": catalog(r.agent)]
        }
        let selectedAgent = try agent(r)
        if action == "official", r.command == "providers", r.arguments.count == 1 {
            if selectedAgent == "claude" {
                store.errorMessage = nil; store.restoreOfficial()
                guard store.errorMessage == nil, store.activeProviderID == nil else { throw CLIControlFailure(message: "Could not restore Claude official configuration") }
            } else {
                codex.errorMessage = nil; codex.restoreOfficial()
                guard codex.errorMessage == nil, codex.activeProviderID == nil else { throw CLIControlFailure(message: "Could not restore Codex official configuration") }
            }
            return ["agent": selectedAgent, "official": true]
        }
        if action == "capture", r.command == "providers", r.arguments.count == 3 {
            let id = try providerID(r.arguments[1], agent: selectedAgent)
            let enabled = try bool(r.arguments[2])
            if selectedAgent == "claude" { store.errorMessage = nil; store.setCaptureEnabled(providerID: id, enabled: enabled) }
            else { codex.errorMessage = nil; codex.setCaptureEnabled(providerID: id, enabled: enabled) }
            guard (selectedAgent == "claude" ? store.errorMessage : codex.errorMessage) == nil else {
                throw CLIControlFailure(message: "Capture preference could not be saved")
            }
            return ["agent": selectedAgent, "provider": id.uuidString, "capture": enabled]
        }
        guard action == "use", r.arguments.count == 2 else { throw badArguments() }
        let provider = try providerID(r.command == "providers" ? r.arguments[1] : r.provider, agent: selectedAgent)
        let selector = r.command == "models" ? r.arguments[1] : r.model
        let model: UUID
        if selectedAgent == "claude" {
            guard let p = store.providers.first(where: { $0.id == provider }) else { throw badArguments() }
            if let selector { model = UUID(uuidString: try CLIControlPolicy.select(selector, from: p.models.map { (id: $0.id.uuidString, name: $0.name) }))! }
            else if let id = p.activeModel?.id { model = id }
            else { throw CLIControlFailure(message: "Provider has no configured models") }
            store.errorMessage = nil; store.activateModel(providerID: provider, modelID: model)
            guard store.errorMessage == nil, store.activeProviderID == provider,
                  store.providers.first(where: { $0.id == provider })?.activeModelID == model else {
                throw CLIControlFailure(message: "Claude model activation did not complete")
            }
        } else {
            guard let p = codex.providers.first(where: { $0.id == provider }) else { throw badArguments() }
            if let selector { model = UUID(uuidString: try CLIControlPolicy.select(selector, from: p.models.map { (id: $0.id.uuidString, name: $0.name) }))! }
            else if let id = p.activeModel?.id { model = id }
            else { throw CLIControlFailure(message: "Provider has no configured models") }
            try await codex.activateForCLI(providerID: provider, modelID: model)
        }
        return ["agent": selectedAgent, "provider": provider.uuidString, "model": model.uuidString]
    }
    private func vpn(_ r: CLIControl.Request) async throws -> Any {
        let manager = VpnManager.shared, prefs = AppPreferences.shared
        let action = r.arguments.first ?? "status"
        if action == "preview" {
            guard r.arguments.count == 1 else { throw badArguments() }
            let subscriptions = VpnSubscriptionStore.shared
            guard let id = subscriptions.activeID else { return ["source": "subscription", "nodes": [], "groups": []] }
            let preview = await subscriptions.previewAsync(for: id)
            return ["source": "subscription", "nodes": preview.proxyNames.map { ["name": $0] },
                    "groups": preview.groups.map { ["name": $0.name, "nodes": $0.nodes] as [String: Any] }]
        }
        if action == "nodes" || action == "groups" {
            guard r.arguments.count == 1 else { throw badArguments() }
            await manager.refreshProxies()
            return ["source": "runtime", "running": manager.isRunning,
                    "nodes": manager.proxies.map { ["name": $0.name, "delayMs": $0.delay as Any? ?? NSNull(), "selected": $0.name == manager.liveLeafName] as [String: Any] },
                    "groups": manager.groups.map { ["name": $0.name, "type": $0.type, "selected": $0.current, "nodes": $0.nodes] as [String: Any] }]
        }
        if action == "select", r.arguments.count == 2 {
            guard manager.isRunning else { throw CLIControlFailure(message: "VPN is stopped; use vpn start first") }
            await manager.refreshProxies()
            try Task.checkCancellation()
            let name = r.group ?? manager.primaryGroup?.name
            guard let group = manager.groups.first(where: { $0.name == name }), group.type == "Selector", group.nodes.contains(r.arguments[1]) else {
                throw CLIControlFailure(message: "Node is not in a selectable group; use vpn groups and --group")
            }
            guard await manager.selectNode(group: group.name, node: r.arguments[1]) else { throw CLIControlFailure(message: "VPN node switch failed") }
            return ["group": group.name, "node": r.arguments[1]]
        }
        if action == "test", r.arguments.count == 2 {
            guard manager.isRunning else { throw CLIControlFailure(message: "VPN is stopped; use vpn start first") }
            await manager.refreshProxies()
            guard manager.proxies.contains(where: { $0.name == r.arguments[1] }) || manager.groups.contains(where: { $0.name == r.arguments[1] }) else { throw CLIControlFailure(message: "Node not found") }
            guard let delay = await manager.testDelay(node: r.arguments[1]), delay > 0 else { throw CLIControlFailure(message: "Node latency test failed or timed out") }
            return ["node": r.arguments[1], "delayMs": delay]
        }
        if action == "proxy" || action == "tun", r.arguments.count == 2 {
            let enabled = try bool(r.arguments[1])
            if action == "proxy" { prefs.vpnSystemProxyEnabled = enabled; syncSystemProxy() }
            else { prefs.vpnTunEnabled = enabled; manager.reloadConfig() }
            return ["setting": action, "enabled": enabled]
        }
        guard r.arguments.count == 1 else { throw badArguments() }
        switch action {
        case "start", "restart":
            prefs.vpnEnabled = true; prefs.vpnSystemProxyEnabled = true
            // reloadConfig waits for the owned core to release its ports before restarting.
            if action == "restart" { manager.reloadConfig() } else { manager.syncRuntime() }
            for _ in 0..<750 {
                if manager.isRunning { break }
                if case .failed = manager.state { break }
                if case .missingCore = manager.state { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard manager.isRunning else { throw CLIControlFailure(message: "VPN did not start; check vpn status and application diagnostics") }
            syncSystemProxy()
        case "stop": prefs.vpnEnabled = false; VpnProxyGuard.shared.stop(); manager.syncRuntime()
        case "reload": manager.reloadConfig()
        default: throw badArguments()
        }
        return ["enabled": prefs.vpnEnabled, "running": manager.isRunning]
    }
    private func syncSystemProxy() {
        let prefs = AppPreferences.shared
        if prefs.vpnSystemProxyEnabled && VpnManager.shared.isRunning {
            VpnSystemProxyController.applySystemProxy(port: prefs.vpnMixedPort)
            if prefs.vpnGuardEnabled { VpnProxyGuard.shared.start() }
        } else { VpnProxyGuard.shared.stop(); VpnSystemProxyController.clearSystemProxyAsync() }
    }
    private func connectors(_ r: CLIControl.Request) async throws -> Any {
        let manager = ConnectorManager.shared
        let action = r.arguments.first ?? "list"
        if action == "refresh" || r.project != nil || !manager.hasScanned { await manager.refresh(projectPath: r.project) }
        try Task.checkCancellation()
        if ["list", "refresh"].contains(action), r.arguments.count == 1 {
            return ["connectors": manager.records.map { record in
                ["id": record.id, "name": record.name, "kind": record.kind.rawValue,
                 "platforms": record.platforms.map(\.rawValue), "enabled": record.enabled as Any? ?? NSNull(),
                 "controllable": record.batchCapability != .none, "removable": record.canRemove] as [String: Any]
            }]
        }
        guard ["enable", "disable", "remove", "show"].contains(action), r.arguments.count == 2 else { throw badArguments() }
        let id = try CLIControlPolicy.select(r.arguments[1], from: manager.records.map { (id: $0.id, name: $0.name) })
        guard let record = manager.records.first(where: { $0.id == id }) else { throw badArguments() }
        if action == "show" {
            return ["id": record.id, "name": record.name, "kind": record.kind.rawValue,
                    "platforms": record.platforms.map(\.rawValue), "enabled": record.enabled as Any? ?? NSNull(),
                    "controllable": record.batchCapability != .none, "removable": record.canRemove]
        }
        if action == "remove", r.confirmed != true { throw CLIControlFailure(message: "Connector removal requires --yes", code: 2) }
        if action == "remove", !record.canRemove { throw CLIControlFailure(message: "This connector cannot be removed through ClaudeBar") }
        if action != "remove", record.batchCapability == .none { throw CLIControlFailure(message: "This connector cannot be toggled; it must be managed in its native client") }
        let mutation: ConnectorBatchAction = action == "enable" ? .enable : (action == "disable" ? .disable : .remove)
        let outcome = await manager.batch(mutation, over: [record], projectPath: r.project)
        guard outcome.failures.isEmpty else { throw CLIControlFailure(message: "Connector mutation failed; check the connector's permissions and native client") }
        return ["id": id, "action": action, "changed": outcome.hasWork,
                "nativeCommand": outcome.cursorCommands > 0, "skipped": outcome.skipped]
    }
    private func proxy(_ r: CLIControl.Request) async throws -> Any {
        guard r.arguments.count == 1 else { throw badArguments() }
        let action = r.arguments[0], prefs = AppPreferences.shared
        switch action {
        case "start", "on":
            prefs.codexRoutingEnabled = true
            if let p = codex.activeProvider, let m = p.activeModel { try await codex.activateForCLI(providerID: p.id, modelID: m.id) }
            try Task.checkCancellation()
            guard codex.startProxy() else { throw CLIControlFailure(message: "Local model proxy failed to start") }
        case "stop", "off":
            guard !codex.proxyIsRequiredByCaptureOrBridge else { throw CLIControlFailure(message: "Proxy is required by capture, Chat API, or a session bridge; disable capture or change provider first") }
            prefs.codexRoutingEnabled = false
            if let p = codex.activeProvider, let m = p.activeModel { try await codex.activateForCLI(providerID: p.id, modelID: m.id) }
            try Task.checkCancellation()
            codex.stopProxy()
        default: throw badArguments()
        }
        return ["running": codex.proxyRunning, "routingEnabled": prefs.codexRoutingEnabled]
    }
    private func config(_ r: CLIControl.Request) async throws -> Any {
        guard r.arguments.count == 3, r.arguments[0] == "set" else { throw badArguments() }
        let key = r.arguments[1], value = r.arguments[2], prefs = AppPreferences.shared
        switch key {
        case "appearance": guard let mode = AppearanceMode(rawValue: value) else { throw badArguments() }; prefs.appearance = mode
        case "token-units": guard let style = TokenUnitStyle(rawValue: value) else { throw badArguments() }; prefs.tokenUnitStyle = style
        case "weather-city": prefs.weatherCity = value; WeatherStore.shared.refreshCityForCLI()
        case "vpn-guard": prefs.vpnGuardEnabled = try bool(value); syncSystemProxy()
        default: throw CLIControlFailure(message: "Supported keys: appearance, token-units, weather-city, vpn-guard", code: 2)
        }
        return ["key": key, "value": value]
    }
}
