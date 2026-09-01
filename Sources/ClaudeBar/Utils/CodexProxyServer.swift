import Foundation
import Network

/// Local HTTP/1.1 proxy between Codex and the configured upstream
/// (cc-switch-style local routing; fixes openai/codex#23186).
///
/// - Listens on 127.0.0.1:<port> via NWListener.
/// - Codex always speaks Responses; the proxy rewrites proprietary tool
///   shapes (namespace MCP wrappers, additional_tools) before forwarding.
/// - Responses-native upstreams: SSE passthrough with per-event rewrite.
/// - Chat upstreams: full Responses→Chat request conversion and synthesized
///   Responses SSE back.
/// - Every response uses `Connection: close` — reqwest (Codex's client)
///   tolerates fresh connections, and skipping keep-alive removes all
///   re-parse hazards in v1.
final class CodexProxyServer: @unchecked Sendable {

    private let port: UInt16
    private let state: CodexProxyState
    private let queue = DispatchQueue(label: "claudebar.proxy")
    private var listener: NWListener?

    /// Ephemeral session that does not advertise gzip. URLSession.shared
    /// sets `Accept-Encoding: gzip` and can hold the first SSE event until
    /// the decoder sees a flush — Claude Code then reports "streaming
    /// response ended before any complete data" and retries without stream.
    private static let upstreamSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 3600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        return URLSession(configuration: c)
    }()

    /// Monotonic SSE sequence numbers are per-stream (CodexProxyTransform
    /// handles them); server-level state is only the listener.
    init(port: UInt16, state: CodexProxyState) {
        self.port = port
        self.state = state
    }

    var isRunning: Bool { listener != nil }

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] newState in
            if case .failed = newState {
                self?.listener = nil
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // One task per connection; all socket I/O for this connection stays
        // inside this task (plus the connection.send calls it issues).
        Task { [weak self] in
            await self?.handle(connection)
        }
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) async {
        // 1. Read until end of headers, then content-length body bytes.
        guard let request = await readRequest(connection) else {
            connection.cancel()
            return
        }

        // 2. Route.
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path

        let isAnthropicPath = path.contains("/messages") || path.contains("/complete")
        let hasAnthropicHeaders = request.headers["anthropic-version"] != nil
            || (request.headers["x-api-key"] != nil
                && !path.contains("/responses")
                && !path.contains("/chat/completions"))

        if request.method == "GET" || request.method == "HEAD" {
            if path.hasSuffix("/models") {
                if isAnthropicPath || hasAnthropicHeaders {
                    await forwardAnthropic(connection, request: request, inspect: false)
                    return
                }
                await serveModels(connection)
                return
            }
        }

        if isAnthropicPath || hasAnthropicHeaders {
            await forwardAnthropic(connection, request: request, inspect: request.method == "POST")
            return
        }

        guard path.contains("/responses") || path.hasSuffix("/chat/completions") else {
            await respond(connection, status: "404 Not Found", contentType: "application/json",
                    body: Data(#"{"error":{"message":"not found"}}"#.utf8))
            return
        }

        guard let upstream = await state.upstream, !upstream.baseURL.isEmpty else {
            let acceptSSE = request.headers["accept"]?.contains("text/event-stream") ?? false
            if acceptSSE {
                await write(connection, data: sseHead())
                await write(connection, data: CodexProxyTransform.synthesizeFailed(message: "本地路由没有已激活的上游 — 请在 Axon 设置中配置 Codex 供应商"))
            } else {
                await respond(connection, status: "502 Bad Gateway", contentType: "application/json",
                        body: Data(#"{"error":{"message":"no upstream configured"}}"#.utf8))
            }
            connection.cancel()
            return
        }

        // 3. Parse body.
        guard let body = request.body,
              var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            await respond(connection, status: "400 Bad Request", contentType: "application/json",
                    body: Data(#"{"error":{"message":"invalid json"}}"#.utf8))
            connection.cancel()
            return
        }

        do {
            let model = (json["model"] as? String) ?? ""
            if CodexProxyTransform.shouldBridgeToChat(
                baseURL: upstream.baseURL, wireAPI: upstream.wireAPI, model: model) {
                try await forwardViaChat(connection, request: request, json: &json, upstream: upstream)
            } else {
                do {
                    try await forwardResponses(connection, request: request, json: &json, upstream: upstream)
                } catch {
                    // Responses-lite gateway (Aibox/GLM wrappers): first turn
                    // of messages works, turn 2 replays function_call and the
                    // untagged ResponseInput enum 400s. Codex++ protocol_proxy
                    // and cc-switch Chat both convert instead of forwarding.
                    guard CodexProxyTransform.isResponseInputReject(error) else { throw error }
                    try await forwardViaChat(connection, request: request, json: &json, upstream: upstream)
                }
            }
        } catch {
            let acceptSSE = request.headers["accept"]?.contains("text/event-stream") ?? false
            if acceptSSE {
                await write(connection, data: CodexProxyTransform.synthesizeFailed(message: "上游请求失败: \(error.localizedDescription)"))
            } else {
                await respond(connection, status: "502 Bad Gateway", contentType: "application/json",
                        body: Data("{\"error\":{\"message\":\"\(error.localizedDescription)\"}}".utf8))
            }
        }
        connection.cancel()
    }

    // MARK: - Responses-native upstream

    private func forwardResponses(_ connection: NWConnection, request: HTTPRequest,
                                  json: inout [String: Any], upstream: CodexProxyState.UpstreamEndpoint) async throws {
        var registry = CodexProxyTransform.ToolRegistry()
        // Official OpenAI Responses understands `type:namespace` natively;
        // flattening would break dispatch. Every other Responses peer is the
        // openai/codex#23186 case and needs the flatten+restore pass.
        let rewritten: [String: Any]
        if upstream.baseURL.contains("api.openai.com") {
            rewritten = json
        } else {
            rewritten = CodexProxyTransform.rewriteRequestBody(json, wireAPI: "responses", registry: &registry)
        }
        let outData = try JSONSerialization.data(withJSONObject: rewritten)
        dumpRequest(outData)

        let wantsStream = (json["stream"] as? Bool) ?? false
        let tap = await makeOpenAITap(
            kind: .openaiResponses, request: request, json: json,
            rewritten: outData, stream: wantsStream, upstream: upstream)
        var capState = CaptureState.done
        var capError: String?
        defer { tap?.finish(state: capState, status: 200, error: capError) }

        let upstreamURL = joinURL(upstream.baseURL, path: request.path)

        do {
        if wantsStream {
            // Connect upstream *before* writing the SSE head to Codex, so a
            // ResponseInput 400 can be retried as Chat without corrupting the
            // client stream.
            let lines = try await streamSSE(url: upstreamURL, apiKey: upstream.apiKey, body: outData)
            await write(connection, data: sseHead())
            var sawTerminal = false
            var sawCreated = false
            var lastSequence = 0
            for try await rawLine in lines {
                // SSE frames are "event: X" / "data: Y" line pairs — only
                // data: lines carry JSON; re-emitting event: lines as data
                // payloads corrupts the stream. Codex dispatches on the JSON
                // type field, so dropping the event: line is safe.
                guard rawLine.hasPrefix("data:") else { continue }
                let event = rawLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let data = event.data(using: .utf8) else { continue }
                if event == "[DONE]" {
                    if !sawTerminal {
                        await write(connection, data: CodexProxyTransform.synthesizeCompletedZeroUsage())
                    } else {
                        await write(connection, data: CodexProxyTransform.sseRaw("[DONE]"))
                    }
                    sawTerminal = true
                    break
                }
                if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    var ev = parsed
                    if let type = ev["type"] as? String {
                        if type == "response.created" || type == "response.in_progress" { sawCreated = true }
                        if type == "response.completed" || type == "response.failed" || type == "response.incomplete" {
                            sawTerminal = true
                        }
                    }
                    if let seq = (ev["sequence_number"] as? NSNumber)?.intValue, seq > lastSequence {
                        lastSequence = seq
                    }
                    ev = CodexProxyTransform.rewriteResponsesEvent(ev, registry: registry)
                    tap?.applyResponses(ev)
                    await write(connection, data: CodexProxyTransform.sse(ev))
                } else {
                    await write(connection, data: CodexProxyTransform.sseRaw(event))
                }
            }
            // Incomplete upstreams (relay stations) often end by EOF without
            // response.created / response.completed — synthesize both so
            // Codex doesn't report "stream closed before response.completed"
            // (same as cc-switch's ensureStreamLifecycle).
            let synth = CodexProxyTransform.synthesizeLifecycle(sawCreated: sawCreated, sawTerminal: sawTerminal, lastSequence: lastSequence)
            if !synth.isEmpty { await write(connection, data: synth) }
        } else {
            let (data, status) = try await postJSON(url: upstreamURL, apiKey: upstream.apiKey, body: outData)
            var out: [String: Any] = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            out = CodexProxyTransform.rewriteResponsesEvent(out, registry: registry)
            CodexProxyTransform.normalizeUsage(&out)
            tap?.applyResponses(out)
            let fixed = (try? JSONSerialization.data(withJSONObject: out)) ?? data
            await respond(connection, status: "\(status) OK", contentType: "application/json", body: fixed)
        }
        } catch {
            capState = .error
            capError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Chat upstream

    private func forwardViaChat(_ connection: NWConnection, request: HTTPRequest,
                                json: inout [String: Any], upstream: CodexProxyState.UpstreamEndpoint) async throws {
        var registry = CodexProxyTransform.ToolRegistry()
        let chatBody = CodexProxyTransform.responsesToChatRequest(json, registry: &registry)
        let outData = try JSONSerialization.data(withJSONObject: chatBody)
        dumpRequest(outData)
        let tap = await makeOpenAITap(
            kind: .openaiChat, request: request, json: json,
            rewritten: outData, stream: true, upstream: upstream)
        var capState = CaptureState.done
        var capError: String?
        defer { tap?.finish(state: capState, status: 200, error: capError) }
        // Always hit /chat/completions when bridging — posting a Chat body
        // to /v1/responses is how the original 400 happens.
        let upstreamURL = chatCompletionsURL(upstream.baseURL)

        do {
        let chatLines = try await streamSSE(url: upstreamURL, apiKey: upstream.apiKey, body: outData)
        await write(connection, data: sseHead())
        var streamState = CodexProxyTransform.ChatStreamState()
        streamState.registry = registry
        var sawTerminal = false
        for try await rawLine in chatLines {
            // Same data:-line filtering as the Responses path.
            guard rawLine.hasPrefix("data:") else { continue }
            let line = rawLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if line == "[DONE]" { break }
            guard let data = line.data(using: .utf8),
                  let delta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            tap?.applyChat(delta)
            let events = CodexProxyTransform.chatDeltaToResponsesEvents(delta, state: &streamState)

            for ev in events {
                if (ev["type"] as? String)?.hasPrefix("response.completed") == true
                    || (ev["type"] as? String) == "response.failed" {
                    sawTerminal = true
                }
                await write(connection, data: CodexProxyTransform.sse(ev))
            }
        }
        if !sawTerminal {
            let resp: [String: Any] = [
                "id": streamState.responseID, "object": "response",
                "created_at": Int(Date().timeIntervalSince1970),
                "status": "completed", "model": json["model"] ?? "", "output": [],
                "usage": ["input_tokens": 0, "output_tokens": 0, "total_tokens": 0],
            ]
            var state = streamState
            for ev in CodexProxyTransform.completedEvents(state: &state, response: resp) {
                await write(connection, data: CodexProxyTransform.sse(ev))
            }
        }
        await write(connection, data: CodexProxyTransform.sseRaw("[DONE]"))
        } catch {
            capState = .error
            capError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Upstream I/O

    /// Stream an upstream SSE response as decoded `data:` payload lines.
    private func streamSSE(url: URL, apiKey: String, body: Data) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await Self.upstreamSession.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
                        guard http.statusCode < 400 else {
            var message = "upstream HTTP \(http.statusCode)"
            var errBody = Data()
            for try await byte in bytes.prefix(2048) {
                errBody.append(byte)
            }
            if let text = String(data: errBody, encoding: .utf8), !text.isEmpty {
                message += ": \(text.prefix(500))"
            }
            throw NSError(domain: "CodexProxy", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        return bytes.lines
    }

    private func postJSON(url: URL, apiKey: String, body: Data) async throws -> (Data, String) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await Self.upstreamSession.data(for: req)
        let status = (response as? HTTPURLResponse).map { "\($0.statusCode)" } ?? "200"
        return (data, status)
    }

    private func joinURL(_ base: String, path: String) -> URL {
        let s = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var suffix = path.split(separator: "?").first.map(String.init) ?? path
        if suffix.hasPrefix("/") { suffix.removeFirst() }
        // Codex sends /v1/responses; drop a duplicated /v1 when the base already
        // ends with it. Versioned roots that are not /v1 (e.g. /paas/v4) keep
        // their own suffix and only append the last path component.
        if s.hasSuffix("/v1") && (suffix == "v1" || suffix.hasPrefix("v1/")) {
            suffix = suffix == "v1" ? "" : String(suffix.dropFirst(3))
        }
        if suffix.isEmpty { return URL(string: s) ?? URL(string: "http://127.0.0.1")! }
        return URL(string: s + "/" + suffix) ?? URL(string: "http://127.0.0.1")!
    }

    /// Chat Completions URL for an OpenAI-compat root. Bases that already end
    /// in a version segment (`/v1`, `/v4`, …) append `/chat/completions`;
    /// bare hosts get `/v1/chat/completions`.
    private func chatCompletionsURL(_ base: String) -> URL {
        let s = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if s.hasSuffix("/chat/completions") {
            return URL(string: s) ?? URL(string: "http://127.0.0.1")!
        }
        if s.range(of: #"/v\d+$"#, options: .regularExpression) != nil {
            return URL(string: s + "/chat/completions") ?? URL(string: "http://127.0.0.1")!
        }
        return URL(string: s + "/v1/chat/completions") ?? URL(string: "http://127.0.0.1")!
    }

    // MARK: - Anthropic passthrough (Claude Code)

    /// Forward Claude Code's Anthropic Messages traffic. Body is not rewritten;
    /// client headers (`x-api-key`, `anthropic-version`, `anthropic-beta`) pass
    /// through so official and `/anthropic` gateways keep working.
    private func forwardAnthropic(_ connection: NWConnection, request: HTTPRequest, inspect: Bool) async {
        guard let upstream = await state.anthropic else {
            await respond(connection, status: "502 Bad Gateway", contentType: "application/json",
                    body: Data(#"{"error":{"message":"no anthropic upstream — enable capture on the active provider"}}"#.utf8))
            connection.cancel()
            return
        }

        let wantsStream: Bool = {
            guard let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
            return (json["stream"] as? Bool) ?? false
        }()
        let model: String = {
            guard let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
            return (json["model"] as? String) ?? ""
        }()

        let tap: CaptureTap?
        if inspect, await state.captureAnthropic {
            tap = ProxyCaptureStore.shared.begin(
                kind: .anthropic,
                source: .claude,
                provider: upstream.name,
                model: model,
                path: request.path,
                stream: wantsStream,
                requestJSON: request.body.flatMap { String(data: $0, encoding: .utf8) },
                rewrittenJSON: nil)
        } else {
            tap = nil
        }
        var capState = CaptureState.done
        var capError: String?
        var statusCode = 200
        defer { tap?.finish(state: capState, status: statusCode, error: capError) }

        var req = URLRequest(url: joinAnthropic(upstream.baseURL, path: request.path))
        req.httpMethod = request.method
        req.httpBody = request.body
        req.timeoutInterval = 600
        copyClientHeaders(request.headers, onto: &req)
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if request.headers["authorization"] == nil, request.headers["x-api-key"] == nil, !upstream.apiKey.isEmpty {
            req.setValue(upstream.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("Bearer \(upstream.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            if wantsStream {
                let (bytes, response) = try await Self.upstreamSession.bytes(for: req)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                statusCode = http.statusCode
                let ctype = http.value(forHTTPHeaderField: "Content-Type") ?? "text/event-stream"
                await write(connection, data: streamHead(status: http.statusCode, contentType: ctype))
                if http.statusCode >= 400 {
                    var errBody = Data()
                    for try await byte in bytes.prefix(4096) { errBody.append(byte) }
                    await write(connection, data: errBody)
                    capState = .error
                    capError = String(data: errBody, encoding: .utf8)
                    connection.cancel()
                    return
                }
                try await pipeAnthropicSSE(bytes, to: connection, tap: tap)
            } else {
                let (data, response) = try await Self.upstreamSession.data(for: req)
                let http = response as? HTTPURLResponse
                statusCode = http?.statusCode ?? 200
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    tap?.ingestAnthropicMessage(json)
                }
                if statusCode >= 400 {
                    capState = .error
                    capError = String(data: data, encoding: .utf8)
                }
                let ctype = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
                await respond(connection, status: "\(statusCode) \(statusCode >= 400 ? "Error" : "OK")",
                              contentType: ctype, body: data)
            }
        } catch {
            capState = .error
            capError = error.localizedDescription
            if !(wantsStream) {
                await respond(connection, status: "502 Bad Gateway", contentType: "application/json",
                        body: Data("{\"error\":{\"message\":\"\(error.localizedDescription)\"}}".utf8))
            }
        }
        connection.cancel()
    }

    private func copyClientHeaders(_ headers: [String: String], onto req: inout URLRequest) {
        let skip: Set<String> = ["host", "connection", "content-length", "transfer-encoding", "accept-encoding"]
        for (key, value) in headers where !skip.contains(key) {
            req.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func streamHead(status: Int, contentType: String) -> Data {
        let reason = status >= 400 ? "Error" : "OK"
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\nX-Accel-Buffering: no\r\nConnection: close\r\n\r\n".utf8)
    }

    /// Forward SSE as complete events. Flush on each blank line so Claude
    /// Code sees `message_start` immediately instead of a half-frame.
    private func pipeAnthropicSSE(_ bytes: URLSession.AsyncBytes, to connection: NWConnection, tap: CaptureTap?) async throws {
        var parser = LineSSEParser()
        var batch = Data()
        batch.reserveCapacity(4096)
        for try await line in bytes.lines {
            batch.append(contentsOf: line.utf8)
            batch.append(10)
            if line.isEmpty || batch.count >= 4096 {
                await write(connection, data: batch)
                tap?.appendRaw(batch)
                batch.removeAll(keepingCapacity: true)
            }
            if let ev = parser.push(line: line), !ev.done, let json = ev.json {
                let name = ev.name.isEmpty ? ((json["type"] as? String) ?? "") : ev.name
                tap?.applyAnthropic(event: name, json: json)
            }
        }
        if !batch.isEmpty {
            await write(connection, data: batch)
            tap?.appendRaw(batch)
        }
        if let ev = parser.finish(), !ev.done, let json = ev.json {
            let name = ev.name.isEmpty ? ((json["type"] as? String) ?? "") : ev.name
            tap?.applyAnthropic(event: name, json: json)
        }
    }

    private func joinAnthropic(_ base: String, path: String) -> URL {
        let s = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var suffix = String(parts.first ?? "")
        let query = parts.count > 1 ? "?\(parts[1])" : ""
        if suffix.hasPrefix("/") { suffix.removeFirst() }
        if s.hasSuffix("/v1") && (suffix == "v1" || suffix.hasPrefix("v1/")) {
            suffix = suffix == "v1" ? "" : String(suffix.dropFirst(3))
        }
        let joined = suffix.isEmpty ? s : s + "/" + suffix
        return URL(string: joined + query) ?? URL(string: "http://127.0.0.1")!
    }

    private func makeOpenAITap(kind: CaptureKind, request: HTTPRequest, json: [String: Any],
                               rewritten: Data, stream: Bool,
                               upstream: CodexProxyState.UpstreamEndpoint) async -> CaptureTap? {
        guard await state.captureOpenAI else { return nil }
        return ProxyCaptureStore.shared.begin(
            kind: kind,
            source: .codex,
            provider: upstream.name,
            model: (json["model"] as? String) ?? "",
            path: request.path,
            stream: stream,
            requestJSON: request.body.flatMap { String(data: $0, encoding: .utf8) },
            rewrittenJSON: String(data: rewritten, encoding: .utf8))
    }

    private func dumpRequest(_ body: Data) {
        let url = URL(fileURLWithPath: "/tmp/claudebar-codex-last-request.json")
        try? body.write(to: url, options: .atomic)
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            var lines: [String] = ["keys=\(obj.keys.sorted().joined(separator: ","))"]
            if let input = obj["input"] as? [Any] {
                lines.append("input[\(input.count)]")
                for (i, item) in input.enumerated() {
                    guard let d = item as? [String: Any] else { lines.append("[\(i)] <non-object>"); continue }
                    let type = (d["type"] as? String) ?? "(no type)"
                    let keys = d.keys.sorted().joined(separator: ",")
                    var extra = ""
                    if type == "message", let content = d["content"] as? [[String: Any]] {
                        extra = " parts=" + content.map { ($0["type"] as? String) ?? "?" }.joined(separator: "+")
                    }
                    if type == "function_call" { extra = " name=\(d["name"] ?? "")" }
                    lines.append("[\(i)] \(type) keys=\(keys)\(extra)")
                }
            }
            if let messages = obj["messages"] as? [[String: Any]] {
                lines.append("messages[\(messages.count)]")
                for (i, m) in messages.enumerated() {
                    let role = (m["role"] as? String) ?? "?"
                    let nTools = (m["tool_calls"] as? [Any])?.count ?? 0
                    let contentLen = ((m["content"] as? String) ?? "").count
                    lines.append("[\(i)] role=\(role) content=\(contentLen) tool_calls=\(nTools)")
                }
            }
            try? lines.joined(separator: "\n").write(
                toFile: "/tmp/claudebar-codex-last-request.input.txt", atomically: true, encoding: .utf8)
        }
    }

    private func serveModels(_ connection: NWConnection) async {
        let body = CodexModelCatalog.readJSON()
            ?? Data(#"{"object":"list","data":[],"models":[]}"#.utf8)
        await respond(connection, status: "200 OK", contentType: "application/json", body: body)
        connection.cancel()
    }

    // MARK: - HTTP parsing / writing

    struct HTTPRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data?
    }

    private func readRequest(_ connection: NWConnection) async -> HTTPRequest? {
        var buffer = Data()
        // Headers + body, with a generous cap (Codex bodies with big model
        // catalogs can be a few MB).
        let cap = 64 * 1024 * 1024
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil, buffer.count < cap {
            guard let chunk = await receive(connection) else { return nil }
            buffer.append(chunk)
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        var body = buffer[headerEnd.upperBound...]
        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            return nil // 411-equivalent: Codex always sends content-length
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < contentLength {
            guard let chunk = await receive(connection) else { break }
            body.append(chunk)
        }
        return HTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: body.prefix(contentLength)
        )
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil) // complete or error
                }
            }
        }
    }

    private func sseHead() -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8)
    }

    /// Awaited send: completion fires before we proceed. Without this,
    /// connection.cancel() right after a fire-and-forget send drops queued
    /// bytes — the client sees the stream cut off mid-body.
    private func write(_ connection: NWConnection, data: Data) async {
        guard !data.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func writeRaw(_ connection: NWConnection, data: Data) {
        Task { await write(connection, data: data) }
    }

    private func respond(_ connection: NWConnection, status: String, contentType: String, body: Data) async {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        await write(connection, data: Data(head.utf8) + body)
    }
}
