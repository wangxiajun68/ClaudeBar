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

    func testVendor(id: UUID, claude: Provider, model: ModelConfig?, codex: CodexProvider?) {
        run(Self.vendorKey(id)) {
            await Self.probeVendor(claude: claude, modelName: model?.name, codex: codex)
        }
    }

    func testEditor(baseURL: String, apiKey: String, modelName: String, wireAPI: String) {
        run(Self.editorKey) {
            let claude = Provider(name: "editor", authToken: apiKey, baseURL: baseURL,
                                  models: [ModelConfig(name: modelName)])
            let openaiURL = ProviderBridge.openaiCompatibleURL(baseURL)
            let slug = ProviderBridge.stripClaudeModelSuffix(modelName)
            let twin = CodexProvider(name: "editor", apiKey: apiKey, baseURL: openaiURL,
                                     wireAPI: wireAPI,
                                     models: [CodexModelConfig(name: slug)])
            return await Self.probeVendor(claude: claude, modelName: modelName, codex: twin)
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
        if claude.baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return ConnectivityOutcome(state: .failed, detail: "未填写 Base URL")
        }
        if claude.authToken.trimmingCharacters(in: .whitespaces).isEmpty {
            return ConnectivityOutcome(state: .failed, detail: "未填写 API Key")
        }
        if name.isEmpty {
            return ConnectivityOutcome(state: .failed, detail: "未指定模型")
        }

        let slug = ProviderBridge.stripClaudeModelSuffix(name)
        let openaiURL = (codex?.baseURL).flatMap { $0.isEmpty ? nil : $0 }
            ?? ProviderBridge.openaiCompatibleURL(claude.baseURL)
        let openaiKey = (codex?.apiKey).flatMap { $0.isEmpty ? nil : $0 } ?? claude.authToken
        let wire = codex?.wireAPI ?? (openaiURL.lowercased().contains("api.openai.com") ? "responses" : "chat")

        async let claudeHit = ConnectivityProbe.anthropic(
            baseURL: claude.baseURL, apiKey: claude.authToken, model: name)
        async let openaiHit = ConnectivityProbe.openai(
            baseURL: openaiURL, apiKey: openaiKey, model: slug, wireAPI: wire)
        let (c, o) = await (claudeHit, openaiHit)

        let ok = c.ok && o.ok
        var parts: [String] = []
        parts.append("Claude \(c.ok ? "✓" : "✗") \(c.summary)")
        parts.append("Codex \(o.ok ? "✓" : "✗") \(o.summary)")
        let latency = [c, o].filter(\.ok).map(\.latencyMS).min()
        return ConnectivityOutcome(
            state: ok ? .passed : .failed,
            detail: parts.joined(separator: "  ·  "),
            latencyMS: latency)
    }
}
