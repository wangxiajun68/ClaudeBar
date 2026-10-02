import Foundation

/// Tiny HTTP probe for the local routing proxy. GETs its loopback `/health`
/// endpoint and reads back the upstreams the proxy reports; it never dials a
/// vendor itself.
enum ConnectivityProbe {

    struct Hit: Sendable, Equatable {
        var ok: Bool
        var status: Int
        var latencyMS: Int
        var message: String

        var summary: String {
            if ok { return "\(latencyMS)ms · HTTP \(status)" }
            return message
        }
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
                    return Hit(ok: true, status: status, latencyMS: ms,
                               message: extra.isEmpty ? "本地代理正常" : extra)
                }
                if status != 404 {
                    return Hit(ok: false, status: status, latencyMS: ms,
                               message: describeBody(data, status: status))
                }
            } catch {
                return Hit(ok: false, status: 0, latencyMS: millis(since: started),
                           message: describeError(error, host: "127.0.0.1:\(port)"))
            }
        }
        return Hit(ok: false, status: 404, latencyMS: millis(since: started),
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

    private static func describeBody(_ data: Data, status: Int) -> String {
        let prefix: String
        switch status {
        case 401, 403: prefix = "鉴权失败"
        case 404: prefix = "接口不存在"
        case 429: prefix = "限流"
        default: prefix = "HTTP \(status)"
        }
        if let msg = jsonError(data), !msg.isEmpty {
            return "\(prefix)：\(clip(msg))"
        }
        return prefix
    }

    private static func jsonError(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let dict = obj as? [String: Any] {
            if let err = dict["error"] as? [String: Any] {
                if let m = err["message"] as? String { return m }
                if let m = err["msg"] as? String { return m }
            }
            if let m = dict["error"] as? String { return m }
            if let m = dict["message"] as? String { return m }
            if let m = dict["msg"] as? String { return m }
        }
        return String(data: data.prefix(180), encoding: .utf8)
    }

    private static func describeError(_ error: Error, host: String) -> String {
        let e = error as NSError
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorTimedOut: return "超时（\(host)）"
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "无法连接 \(host)"
            case NSURLErrorNotConnectedToInternet: return "无网络"
            case NSURLErrorNetworkConnectionLost: return "连接中断"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "TLS 失败（\(host)）"
            default: break
            }
        }
        return clip(error.localizedDescription)
    }

    private static func millis(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }

    private static func clip(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= 160 { return flat }
        return String(flat.prefix(157)) + "…"
    }
}
