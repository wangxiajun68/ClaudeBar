import Foundation

/// Fetches model IDs from an OpenAI-compatible `GET /models` endpoint.
enum ModelListFetcher {

    struct ModelListPayload {
        var models: [String]
        var source: String
    }

    enum Outcome {
        case success(ModelListPayload)
        case failure(String)
    }

    static func fetch(baseURL: String, apiKey: String, wireAPI: String = "chat") async -> Outcome {
        let urlText = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlText.isEmpty else { return .failure("请填写 Base URL") }
        guard let parsed = URL(string: urlText), parsed.host != nil,
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil
        else { return .failure("Base URL 无效，请勿在 URL 中附带 Key") }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastError = "未能从 API 获取模型列表"

        for candidate in candidateURLs(urlText, wireAPI: wireAPI) {
            guard !Task.isCancelled else { return .failure("已取消") }
            switch await requestModels(url: candidate.url, apiKey: key, authStyle: candidate.authStyle) {
            case .success(let models) where !models.isEmpty:
                return .success(ModelListPayload(models: models.sorted(), source: candidate.url.absoluteString))
            case .success:
                lastError = "接口返回空模型列表（\(candidate.url.path)）"
            case .failure(let message):
                lastError = message
            }
        }
        return .failure(lastError)
    }

    // MARK: - URL candidates

    private struct Candidate {
        var url: URL
        var authStyle: AuthStyle
    }

    private enum AuthStyle {
        case bearer
        case apiKeyHeader
        case both
    }

    private static func candidateURLs(_ raw: String, wireAPI: String) -> [Candidate] {
        var seen = Set<String>()
        var out: [Candidate] = []

        func append(_ url: URL?, auth: AuthStyle = .both) {
            guard let url, seen.insert(url.absoluteString).inserted else { return }
            out.append(Candidate(url: url, authStyle: auth))
        }

        // Follow the selected protocol's documented model-list route. Never
        // guess a different product/plan endpoint and send the same key there.
        var trimmed = trimSlash(raw)
        for suffix in ["/chat/completions", "/messages", "/responses"] where trimmed.hasSuffix(suffix) {
            trimmed = String(trimmed.dropLast(suffix.count)); break
        }
        if let entry = ProviderCatalogEntry.matching(baseURL: raw) {
            let endpoint = wireAPI == "anthropic" ? entry.claude : entry.codex
            if let endpoint,
               ProviderCatalogEntry.identityURL(endpoint.url(for: wireAPI)) == ProviderCatalogEntry.identityURL(raw),
               let modelsURL = endpoint.modelsURL {
                append(URL(string: modelsURL), auth: wireAPI == "anthropic" ? .both : .bearer)
                return out
            }
        }
        let auth: AuthStyle = wireAPI == "anthropic" ? .both : .bearer
        if trimmed.hasSuffix("/models") {
            append(URL(string: trimmed), auth: auth)
        } else {
            let path = URL(string: trimmed)?.path ?? ""
            if path.isEmpty || path == "/" || wireAPI == "anthropic" && !path.hasSuffix("/v1") {
                append(URL(string: trimmed + "/v1/models"), auth: auth)
            }
            append(URL(string: trimmed + "/models"), auth: auth)
        }

        return out
    }

    // MARK: - HTTP

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 25
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.waitsForConnectivity = false
        return URLSession(configuration: c, delegate: NoModelListRedirects(), delegateQueue: nil)
    }()

    private enum RequestOutcome {
        case success([String])
        case failure(String)
    }

    private static func requestModels(url: URL, apiKey: String, authStyle: AuthStyle) async -> RequestOutcome {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(apiKey, style: authStyle, to: &req)
        if authStyle != .bearer { req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }

        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                if authStyle == .both, !apiKey.isEmpty {
                    var retry = req
                    applyAuth(apiKey, style: .apiKeyHeader, to: &retry)
                    let (retryData, retryResponse) = try await session.data(for: retry)
                    let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                    if (200..<300).contains(retryStatus), let models = parseModelIDs(retryData), !models.isEmpty {
                        return .success(models)
                    }
                }
                return .failure("鉴权失败（HTTP \(status)）")
            }
            guard (200..<300).contains(status) else {
                let message = describeBody(data, status: status, path: url.path)
                return .failure(apiKey.isEmpty ? message : message.replacingOccurrences(of: apiKey, with: "[Key]"))
            }
            guard let models = parseModelIDs(data), !models.isEmpty else {
                return .success([])
            }
            return .success(models)
        } catch {
            return .failure(describeError(error, host: url.host ?? url.absoluteString))
        }
    }

    private static func applyAuth(_ apiKey: String, style: AuthStyle, to req: inout URLRequest) {
        req.setValue(nil, forHTTPHeaderField: "Authorization")
        req.setValue(nil, forHTTPHeaderField: "x-api-key")
        guard !apiKey.isEmpty else { return }
        switch style {
        case .bearer:
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .apiKeyHeader:
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .both:
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
    }

    // MARK: - Parsing

    private static func parseModelIDs(_ data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let dict = root as? [String: Any] {
            if let rows = dict["data"] as? [[String: Any]] {
                let ids = rows.compactMap { row -> String? in
                    (row["id"] as? String) ?? (row["model"] as? String) ?? (row["name"] as? String)
                }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !ids.isEmpty { return dedupe(ids) }
            }
            if let rows = dict["models"] as? [[String: Any]] {
                let ids = rows.compactMap { row -> String? in
                    (row["id"] as? String) ?? (row["model"] as? String) ?? (row["name"] as? String)
                }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !ids.isEmpty { return dedupe(ids) }
            }
            if let names = dict["models"] as? [String] {
                let ids = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !ids.isEmpty { return dedupe(ids) }
            }
        }

        if let rows = root as? [[String: Any]] {
            let ids = rows.compactMap { row -> String? in
                (row["id"] as? String) ?? (row["model"] as? String) ?? (row["name"] as? String)
            }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !ids.isEmpty { return dedupe(ids) }
        }

        return nil
    }

    private static func dedupe(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids {
            let key = id.lowercased()
            if seen.insert(key).inserted { out.append(id) }
        }
        return out
    }

    // MARK: - Errors

    private static func describeBody(_ data: Data, status: Int, path: String) -> String {
        let prefix: String
        switch status {
        case 404: prefix = "接口不存在"
        case 429: prefix = "限流"
        default: prefix = "HTTP \(status)"
        }
        if let msg = jsonError(data), !msg.isEmpty {
            return "\(prefix)（\(path)）：\(clip(msg))"
        }
        return "\(prefix)（\(path)）"
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
        return String(data: data.prefix(160), encoding: .utf8)
    }

    private static func describeError(_ error: Error, host: String) -> String {
        let e = error as NSError
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorTimedOut: return "请求超时（\(host)）"
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost: return "无法连接 \(host)"
            case NSURLErrorNotConnectedToInternet: return "无网络"
            default: break
            }
        }
        return clip(error.localizedDescription)
    }

    private static func trimSlash(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func clip(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= 140 { return flat }
        return String(flat.prefix(137)) + "…"
    }
}

/// A models endpoint must not redirect a credential-bearing request elsewhere.
private final class NoModelListRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
