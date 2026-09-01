import Foundation

/// Loopback addresses the inspect/routing proxy advertises to clients.
enum LocalProxyAddress {
    static var port: Int { AppPreferences.shared.codexProxyPort }
    /// Claude Code appends `/v1/messages` itself.
    static var claudeBase: String { "http://127.0.0.1:\(port)" }
    /// Codex `base_url` includes `/v1`; it then hits `/v1/responses`.
    static var codexBase: String { "http://127.0.0.1:\(port)/v1" }

    static func isLoopback(_ url: String) -> Bool {
        let s = url.lowercased()
        return s.contains("127.0.0.1") || s.contains("localhost")
    }
}

/// Holds the upstream endpoints the local proxy currently forwards to.
/// Set on the main actor by the provider stores; read by proxy connection
/// tasks off-main. Real baseURL/apiKey never touch disk.
actor CodexProxyState {
    struct UpstreamEndpoint: Sendable {
        var baseURL: String   // real OpenAI-compat root
        var apiKey: String
        var wireAPI: String   // "responses" | "chat"
        var name: String
    }

    struct AnthropicUpstream: Sendable {
        var baseURL: String   // real Anthropic-compat root (may end in /anthropic)
        var apiKey: String
        var name: String
    }

    private(set) var upstream: UpstreamEndpoint?
    private(set) var anthropic: AnthropicUpstream?
    private(set) var captureOpenAI = false
    private(set) var captureAnthropic = false

    func setUpstream(_ e: UpstreamEndpoint?) {
        upstream = e
    }

    func setAnthropic(_ e: AnthropicUpstream?) {
        anthropic = e
    }

    func setCaptureOpenAI(_ on: Bool) { captureOpenAI = on }
    func setCaptureAnthropic(_ on: Bool) { captureAnthropic = on }
}
