import Foundation

/// The one place a response body is read into memory for a non-streaming
/// request, with a hard cap.
///
/// `URLSession.data(for:)` buffers whatever the server sends before any of it
/// is handed over, so a base URL answering with a large body — a vendor outage
/// serving an error page, or a URL pointing at a big non-API endpoint — is
/// fully materialised in this menu-bar app for as long as the link takes, and
/// only then refused. Every other bounded reader in the repo caps what it
/// buffers; this is the one that does it for `URLSession`.
///
/// A **session-level** delegate, not a per-call one: measured on this machine
/// (Swift 6.4), the completion-handler API resolves through a different code
/// path and the delegate callbacks never fire for it, while `bytes(for:)`'s
/// per-byte async sequence is ~12 µs/byte (~0.35 s for a 60 KB list at the
/// app's own `-O`). A delegate session with `data(for:)` has neither problem:
/// the callbacks fire and a 60 KB list costs microseconds, the same as the
/// unbounded path.
///
/// Cancellation of the surrounding task cancels in-flight requests, so the list
/// fetch stays interruptible.
final class BoundedResponseReader: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {

    /// The body was larger than the cap. Callers turn this into their own text.
    struct Overflow: Error {}

    private let cap: Int
    private let delegateQueue = OperationQueue()
    private let lock = NSLock()

    private struct Pending {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var body = Data()
        var response: HTTPURLResponse?
        var overflowed = false
    }
    private var pending: [Int: Pending] = [:]

    init(cap: Int) { self.cap = cap }

    /// Build the session this reader owns. `data(for:)` must be called on it,
    /// and the session must not be reused for other work.
    func makeSession(_ configuration: URLSessionConfiguration) -> URLSession {
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func load(_ request: URLRequest, in session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending[task.taskIdentifier] = Pending(continuation: continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - URLSessionTaskDelegate

    /// A request carrying a credential must not be re-pointed elsewhere.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var overflowed = false
        if var entry = pending[dataTask.taskIdentifier] {
            if entry.body.count + data.count > cap {
                entry.overflowed = true
                entry.body.removeAll()
                overflowed = true
            } else {
                entry.body.append(data)
            }
            pending[dataTask.taskIdentifier] = entry
        }
        lock.unlock()
        if overflowed { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let entry else { return }
        if entry.overflowed {
            entry.continuation.resume(throwing: Overflow())
        } else if let error {
            entry.continuation.resume(throwing: error)
        } else if let response = entry.response {
            entry.continuation.resume(returning: (entry.body, response))
        } else {
            entry.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

/// Fetches model IDs from an OpenAI-compatible `GET /models` endpoint.
enum ModelListFetcher {

    struct ModelListPayload {
        var models: [String]
    }

    enum Outcome {
        case success(ModelListPayload)
        case failure(String)
    }

    /// The message the 拉取模型 button shows for one outcome, or nil when it
    /// should show none. Here rather than in the button so the wording is a
    /// value a regression can read: the button itself is a view, and the
    /// 「也可手动填写」 suffix is the one thing a failure must always say —
    /// a fetch that cannot run never means the user cannot type the ids.
    static func buttonMessage(for outcome: Outcome) -> String? {
        switch outcome {
        case .success: return nil
        case .failure(let text): return text + "。也可手动填写模型 ID。"
        }
    }

    /// A models list is ids and metadata, tens of KB even for a large vendor.
    /// The cap is well above that and far below "this will not fit in a
    /// menu-bar app's memory".
    private static let responseCap = 4 * 1024 * 1024

    static func fetch(baseURL: String, apiKey: String, wireAPI: String = "chat") async -> Outcome {
        let urlText = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlText.isEmpty else { return .failure("请填写 Base URL") }
        guard let parsed = URL(string: urlText), parsed.host != nil,
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil
        else { return .failure("Base URL 无效，请勿在 URL 中附带 Key") }
        // The key travels in `Authorization` and `x-api-key` on every request
        // below, so a plaintext `http://` to a public host would put it on the
        // wire readable. Loopback and private-space endpoints keep the
        // escape hatch (Ollama / LM Studio speak http).
        guard allowsKeyTransport(urlText) else {
            return .failure("仅本机或内网端点可用 http，公网地址请使用 https。")
        }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // The user's own base URL is tried first (`candidateURLs` returns it
        // ahead of the guessed `/models` variants), so its typed 401/403 — the
        // one answer that says 换个 Key — is kept and returned even when every
        // other candidate fails for a reason of its own. Without this the last
        // endpoint's 404 masked the real cause and the user edited the URL.
        var definitiveAuth: String?
        var lastError = "未能从 API 获取模型列表"

        for (index, candidate) in candidateURLs(urlText, wireAPI: wireAPI).enumerated() {
            guard !Task.isCancelled else { return .failure("已取消") }
            switch await requestModels(url: candidate.url, apiKey: key, authStyle: candidate.authStyle) {
            case .success(let models) where !models.isEmpty:
                return .success(ModelListPayload(models: models.sorted()))
            case .success:
                lastError = "接口返回空模型列表（\(candidate.url.path)）"
            case .failure(let message):
                if message.hasPrefix("鉴权失败"), index == 0, definitiveAuth == nil {
                    definitiveAuth = message
                }
                lastError = message
            }
        }
        return .failure(definitiveAuth ?? lastError)
    }

    /// Whether a request carrying an API key may go to this URL. https always;
    /// http only when `ProviderCatalogEntry.isLocalEndpoint` recognises the
    /// host as loopback, RFC 1918 or a `.local` name. Pure, so the rule is
    /// testable without a network.
    static func allowsKeyTransport(_ raw: String) -> Bool {
        guard let scheme = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?
            .scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ProviderCatalogEntry.isLocalEndpoint(raw)
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

    /// The URLs one fetch may try, in order. The first is always the address
    /// the user typed or the catalog's documented models route; the rest are
    /// path guesses. `fetch` relies on that first slot for its auth verdict.
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
        return reader.makeSession(c)
    }()

    private static let reader = BoundedResponseReader(cap: responseCap)

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
            let (data, response) = try await reader.load(req, in: session)
            let status = response.statusCode
            if status == 401 || status == 403 {
                if authStyle == .both, !apiKey.isEmpty {
                    var retry = req
                    applyAuth(apiKey, style: .apiKeyHeader, to: &retry)
                    let (retryData, retryResponse) = try await reader.load(retry, in: session)
                    if (200..<300).contains(retryResponse.statusCode),
                       let models = parseModelIDs(retryData), !models.isEmpty {
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
            if error is BoundedResponseReader.Overflow { return .failure("响应过大") }
            return .failure(HTTPErrorText.describe(error, host: url.host ?? url.absoluteString))
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
                let ids = extractIDs(from: rows)
                if !ids.isEmpty { return dedupe(ids) }
            }
            if let rows = dict["models"] as? [[String: Any]] {
                let ids = extractIDs(from: rows)
                if !ids.isEmpty { return dedupe(ids) }
            }
            if let names = dict["models"] as? [String] {
                let ids = extractIDs(from: names)
                if !ids.isEmpty { return dedupe(ids) }
            }
        }

        if let rows = root as? [[String: Any]] {
            let ids = extractIDs(from: rows)
            if !ids.isEmpty { return dedupe(ids) }
        }

        return nil
    }

    /// Lists spell the model id `id`, `model` or `name` depending on the vendor;
    /// the first key present wins, so a display name never overrides the real id.
    private static func extractIDs(from rows: [[String: Any]]) -> [String] {
        rows.compactMap { row -> String? in
            (row["id"] as? String) ?? (row["model"] as? String) ?? (row["name"] as? String)
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func extractIDs(from names: [String]) -> [String] {
        names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
            return "\(prefix)（\(path)）：\(HTTPErrorText.clip(msg))"
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

    private static func trimSlash(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
