import Foundation

/// Tiny HTTP probe for the local routing proxy. GETs its loopback `/health`
/// endpoint and reads back the upstreams the proxy reports; it never dials a
/// vendor itself.
enum ConnectivityProbe {

    struct Hit: Sendable, Equatable {
        var ok: Bool
        var latencyMS: Int
        var message: String
    }

    // MARK: - Proxy

    /// GET `http://127.0.0.1:<port>/health` (falls back to `/v1/health`).
    static func proxy(port: Int) async -> Hit {
        let started = Date()
        let token = CodexProxyServer.configuredToken
        for path in ["/health", "/v1/health"] {
            guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 4
            req.cachePolicy = .reloadIgnoringLocalCacheData
            // /health is behind the same token as everything else — an
            // unauthenticated health endpoint is a free "what is this port"
            // for any scanner, so the probe presents the token too.
            if !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, response) = try await session.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let ms = millis(since: started)
                if (200..<300).contains(status) {
                    let extra = proxyHealthDetail(data)
                    return Hit(ok: true, latencyMS: ms,
                               message: extra.isEmpty ? "本地代理正常" : extra)
                }
                if status != 404 {
                    return Hit(ok: false, latencyMS: ms,
                               message: describeBody(data, status: status))
                }
            } catch {
                return Hit(ok: false, latencyMS: millis(since: started),
                           message: describeError(error, host: "127.0.0.1:\(port)"))
            }
        }
        return Hit(ok: false, latencyMS: millis(since: started),
                   message: "代理无 /health 响应")
    }

    // MARK: - Internals

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 25
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private static func proxyHealthDetail(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        var parts: [String] = ["本地代理正常"]
        // Keys mirror `CodexProxyServer.serveHealth`.
        if let name = obj["codex_upstream"] as? String, !name.isEmpty {
            parts.append("Codex → \(name)")
        }
        if let name = obj["claude_upstream"] as? String, !name.isEmpty {
            parts.append("Claude → \(name)")
        }
        if let name = obj["third_party_openai"] as? String, !name.isEmpty {
            parts.append("第三方 OpenAI → \(name)")
        }
        if let name = obj["third_party_anthropic"] as? String, !name.isEmpty {
            parts.append("第三方 Anthropic → \(name)")
        }
        return parts.joined(separator: " · ")
    }

    // The error-response and NSError text lives in `HTTPErrorText`, shared with
    // `ModelListFetcher` — the two probes used to carry near-identical copies
    // that had already drifted (the fetcher's was missing 连接中断 / TLS 失败).
    private static func describeBody(_ data: Data, status: Int) -> String {
        HTTPErrorText.describeBody(data, status: status)
    }

    private static func describeError(_ error: Error, host: String) -> String {
        HTTPErrorText.describe(error, host: host)
    }

    private static func millis(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }
}
