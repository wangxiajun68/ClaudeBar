import Foundation
import Combine

struct ConnectivityOutcome: Equatable {
    enum State: Equatable {
        case idle, running, passed, failed
    }

    var state: State = .idle
    var detail: String = ""
    var latencyMS: Int? = nil

    static let idle = ConnectivityOutcome()
}

/// Owns in-flight connectivity tests and their last results. Shared by the
/// Settings page, provider tiles, and the editor so a test started in one
/// surface is visible in the others.
@MainActor
final class ConnectivityTestCenter: ObservableObject {
    static let shared = ConnectivityTestCenter()

    static let proxyKey = "proxy"
    static let editorKey = "editor"

    @Published private(set) var outcomes: [String: ConnectivityOutcome] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    func outcome(_ key: String) -> ConnectivityOutcome {
        outcomes[key] ?? .idle
    }

    static func vendorKey(_ id: UUID) -> String { "v:\(id.uuidString)" }

    func testProxy(port: Int, running: Bool) {
        run(Self.proxyKey) {
            if !running {
                return ConnectivityOutcome(
                    state: .failed,
                    detail: "本地代理未运行。请启用本地代理，或在供应商上开启流量记录。")
            }
            let hit = await ConnectivityProbe.proxy(port: port)
            return ConnectivityOutcome(
                state: hit.ok ? .passed : .failed,
                detail: hit.message,
                latencyMS: hit.ok ? hit.latencyMS : nil)
        }
    }

    static func vendorModelKey(_ providerID: UUID, _ modelID: UUID) -> String {
        "v:\(providerID.uuidString):\(modelID.uuidString)"
    }

    func testVendor(id: UUID, claude: Provider, model: ModelConfig?, codex: CodexProvider?) {
        let key = model.map { Self.vendorModelKey(id, $0.id) } ?? Self.vendorKey(id)
        run(key) {
            await Self.probeVendor(claude: claude, modelName: model?.name, codex: codex)
        }
    }

    func testEditor(baseURL: String, apiKey: String, modelName: String) {
        run(Self.editorKey) {
            let claude = Provider(name: "editor", authToken: apiKey, baseURL: baseURL,
                                  models: [ModelConfig(name: modelName)])
            return await Self.probeVendor(claude: claude, modelName: modelName, codex: nil)
        }
    }

    private func run(_ key: String, work: @escaping () async -> ConnectivityOutcome) {
        tasks[key]?.cancel()
        outcomes[key] = ConnectivityOutcome(state: .running, detail: "检测中…")
        tasks[key] = Task { [weak self] in
            let result = await work()
            guard !Task.isCancelled else { return }
            self?.outcomes[key] = result
            self?.tasks[key] = nil
        }
    }

    private static func probeVendor(claude: Provider, modelName: String?,
                                    codex: CodexProvider?) async -> ConnectivityOutcome {
        let name = (modelName ?? claude.activeModel?.name ?? "").trimmingCharacters(in: .whitespaces)
        if let codex {
            let url = codex.baseURL.trimmingCharacters(in: .whitespaces)
            var key = codex.apiKey.trimmingCharacters(in: .whitespaces)
            let slug = (modelName ?? codex.activeModel?.name ?? name).trimmingCharacters(in: .whitespaces)
            if url.isEmpty { return ConnectivityOutcome(state: .failed, detail: "未填写 Base URL") }
            // A loopback server has no auth to fail, so an empty key is not an
            // error there; the probe still needs a non-empty header to send.
            if key.isEmpty {
                guard ProviderCatalogEntry.isLocalEndpoint(url) else {
                    return ConnectivityOutcome(state: .failed, detail: "未填写 API Key")
                }
                key = ProviderCatalogEntry.localEndpointPlaceholderKey
            }
            if slug.isEmpty { return ConnectivityOutcome(state: .failed, detail: "未指定模型") }
            let hit = await ConnectivityProbe.openai(
                baseURL: url, apiKey: key, model: slug, wireAPI: codex.wireAPI)
            return ConnectivityOutcome(
                state: hit.ok ? .passed : .failed,
                detail: "Codex \(hit.ok ? "✓" : "✗") \(hit.summary)",
                latencyMS: hit.ok ? hit.latencyMS : nil)
        }

        if claude.baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return ConnectivityOutcome(state: .failed, detail: "未填写 Base URL")
        }
        var apiKey = claude.authToken.trimmingCharacters(in: .whitespaces)
        // Same rule as the Codex branch: no auth to fail on loopback, so do not
        // report "未填写 API Key" as a failure for a perfectly healthy local
        // server — that reads as a misconfiguration and sends users hunting.
        if apiKey.isEmpty {
            guard ProviderCatalogEntry.isLocalEndpoint(claude.baseURL) else {
                return ConnectivityOutcome(state: .failed, detail: "未填写 API Key")
            }
            apiKey = ProviderCatalogEntry.localEndpointPlaceholderKey
        }
        if name.isEmpty {
            return ConnectivityOutcome(state: .failed, detail: "未指定模型")
        }
        let hit = await ConnectivityProbe.anthropic(
            baseURL: claude.baseURL, apiKey: apiKey, model: name)
        return ConnectivityOutcome(
            state: hit.ok ? .passed : .failed,
            detail: "Claude \(hit.ok ? "✓" : "✗") \(hit.summary)",
            latencyMS: hit.ok ? hit.latencyMS : nil)
    }
}
