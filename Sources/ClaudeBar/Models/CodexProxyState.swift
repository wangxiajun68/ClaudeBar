import Foundation

/// Holds the upstream endpoint the local Codex proxy currently forwards to.
/// Set on the main actor by `CodexProviderStore.activate`; read by proxy
/// connection tasks off-main. The real baseURL/apiKey never touch disk.
actor CodexProxyState {
    struct UpstreamEndpoint: Sendable {
        var baseURL: String   // real upstream, e.g. https://api.deepseek.com
        var apiKey: String
        var wireAPI: String   // "responses" | "chat"
    }

    private(set) var upstream: UpstreamEndpoint?

    func setUpstream(_ e: UpstreamEndpoint?) {
        upstream = e
    }
}
