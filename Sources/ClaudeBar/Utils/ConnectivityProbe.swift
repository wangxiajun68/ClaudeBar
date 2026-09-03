import Foundation

/// Tiny HTTP probes for the local routing proxy and a vendor's Claude / Codex
/// endpoints. Does not go through the inspect proxy — the vendor tests hit
/// the real base URL so a failure is the upstream, not the loopback hop.
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
        for path in ["/health", "/v1/health"] {
            guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 4
            req.cachePolicy = .reloadIgnoringLocalCacheData
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

    // MARK: - Anthropic (Claude Code)

    static func anthropic(baseURL: String, apiKey: String, model: String) async -> Hit {
        let started = Date()
        guard let url = anthropicMessagesURL(baseURL) else {
            return Hit(ok: false, status: 0, latencyMS: 0, message: "Base URL 无效")
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8,
            "stream": false,
            "messages": [["role": "user", "content": "ping"]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await send(req, started: started, host: url.host ?? baseURL)
    }

    // MARK: - OpenAI-compat (Codex)

    static func openai(baseURL: String, apiKey: String, model: String, wireAPI: String) async -> Hit {
        let started = Date()
        let chat = wireAPI.lowercased() != "responses"
        guard let url = chat ? chatCompletionsURL(baseURL) : responsesURL(baseURL) else {
            return Hit(ok: false, status: 0, latencyMS: 0, message: "Base URL 无效")
        }
        let body: [String: Any]
        if chat {
            body = [
                "model": model,
                "max_tokens": 8,
                "stream": false,
                "messages": [["role": "user", "content": "ping"]],
            ]
        } else {
            body = [
                "model": model,
                "max_output_tokens": 8,
                "stream": false,
                "input": "ping",
            ]
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await send(req, started: started, host: url.host ?? baseURL)
    }

    // MARK: - URLs

    static func anthropicMessagesURL(_ raw: String) -> URL? {
        let s = trimSlash(raw)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower.hasSuffix("/messages") { return URL(string: s) }
        if s.range(of: #"/v\d+$"#, options: .regularExpression) != nil {
            return URL(string: s + "/messages")
        }
        return URL(string: s + "/v1/messages")
    }

    static func chatCompletionsURL(_ raw: String) -> URL? {
        let s = trimSlash(raw)
        guard !s.isEmpty else { return nil }
        if s.lowercased().hasSuffix("/chat/completions") { return URL(string: s) }
        if s.range(of: #"/v\d+$"#, options: .regularExpression) != nil {
            return URL(string: s + "/chat/completions")
        }
        return URL(string: s + "/v1/chat/completions")
    }

    static func responsesURL(_ raw: String) -> URL? {
        let s = trimSlash(raw)
        guard !s.isEmpty else { return nil }
        if s.lowercased().hasSuffix("/responses") { return URL(string: s) }
        if s.range(of: #"/v\d+$"#, options: .regularExpression) != nil {
            return URL(string: s + "/responses")
        }
        return URL(string: s + "/v1/responses")
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

    private static func send(_ req: URLRequest, started: Date, host: String) async -> Hit {
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ms = millis(since: started)
            if (200..<300).contains(status) {
                return Hit(ok: true, status: status, latencyMS: ms, message: "HTTP \(status)")
            }
            return Hit(ok: false, status: status, latencyMS: ms,
                       message: describeBody(data, status: status))
        } catch {
            return Hit(ok: false, status: 0, latencyMS: millis(since: started),
                       message: describeError(error, host: host))
        }
    }

    private static func proxyHealthDetail(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        var parts: [String] = ["本地代理正常"]
        if let name = obj["openai_upstream"] as? String, !name.isEmpty {
            parts.append("Codex → \(name)")
        }
        if let name = obj["anthropic_upstream"] as? String, !name.isEmpty {
            parts.append("Claude → \(name)")
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

    private static func trimSlash(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func clip(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= 160 { return flat }
        return String(flat.prefix(157)) + "…"
    }
}
