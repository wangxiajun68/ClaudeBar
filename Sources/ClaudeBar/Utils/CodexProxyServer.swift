import Foundation
import Network
import Security
import Darwin

/// Local HTTP/1.1 proxy between Codex and the configured upstream
/// (cc-switch-style local routing; fixes openai/codex#23186).
///
/// - Listens on 127.0.0.1:<port> via NWListener.
/// - Codex always speaks Responses; the proxy rewrites proprietary tool
///   shapes (namespace MCP wrappers, additional_tools) before forwarding.
/// - Responses-native upstreams: SSE passthrough with per-event rewrite.
/// - Chat Completions clients (`messages`): passthrough, no Responses rewrite.
/// - Codex on Chat upstreams: Responses→Chat conversion and synthesized Responses SSE.
/// - Every response uses `Connection: close` — reqwest (Codex's client)
///   tolerates fresh connections, and skipping keep-alive removes all
///   re-parse hazards in v1.
final class CodexProxyServer: @unchecked Sendable {

    private let port: UInt16
    var listeningPort: UInt16 { port }
    private let state: CodexProxyState
    private let queue = DispatchQueue(label: "claudebar.proxy")
    private var listener: NWListener?

    /// Set for the duration of one connection's `handle()` call, when the user
    /// interrupts that *specific* call from the traffic page. `handle()` reads
    /// it when deciding whether to seal the capture as `.aborted` or as a
    /// plain upstream failure.
    @TaskLocal private static var interruptFlag: InterruptFlag?

    /// Cancel plumbing for one connection, shared with the traffic page.
    ///
    /// The page cancels the *capture handle*; the handle reaches back here to
    /// (a) flag the connection so `handle()` reports `.aborted`, and (b) close
    /// the loopback socket so the client sees the turn cut mid-stream.
    private final class InterruptFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var interrupted = false
        private let abort: () -> Void

        init(abort: @escaping () -> Void) { self.abort = abort }

        /// Called from `ProxyInflight.Handle.cancel`, possibly before the
        /// upstream request exists. `abort` closes the client socket there and
        /// then; the upstream task is cancelled separately, when it is built.
        func cancel() {
            lock.lock()
            guard !interrupted else { lock.unlock(); return }
            interrupted = true
            lock.unlock()
            abort()
        }

        var isInterrupted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return interrupted
        }
    }

    /// True when this connection was interrupted from the traffic page.
    private static func wasInterrupted() -> Bool {
        interruptFlag?.isInterrupted ?? false
    }

    /// Wire a capture's interrupt handle to this connection. Called right after
    /// `begin` so the button works for the whole life of the call, including
    /// the window before the upstream request is issued.
    private func bindInterrupt(_ tap: CaptureTap?, connection: NWConnection) {
        guard let tap, let flag = Self.interruptFlag else { return }
        tap.attachClientAbort {
            flag.cancel()
            connection.cancel()
        }
    }

    /// Attach the upstream data task so an interrupt kills the request too.
    /// Called as soon as `URLSession` hands one back.
    private static func attachUpstream(_ tap: CaptureTap?, task: URLSessionDataTask) {
        tap?.attachUpstreamAbort { task.cancel() }
        gatewayLifetime?.attach(task)
    }

    /// Raised before issuing an upstream request when the interrupt already
    /// landed — the connection is gone, so the request would be pure waste.
    private static func throwIfInterrupted(_ tap: CaptureTap?) throws {
        try Task.checkCancellation()
        if wasInterrupted() || tap?.isInterrupted == true { throw URLError(.cancelled) }
    }

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

    /// Per-run bearer token. Every accepted connection must present it, and a
    /// caller that presents *its own* credential for the upstream no longer
    /// reaches the proxy's injected key.
    ///
    /// `requiredInterfaceType` below is not a bind restriction — it only
    /// constrains which interface the listener prefers. On its own the socket
    /// came up as a wildcard `*:<port>` (verified with `lsof`), which is why
    /// `requiredLocalEndpoint` is set below: a LAN peer must not reach this
    /// key-injecting proxy. Mode 0600 plus `O_EXCL`/`O_NOFOLLOW` in
    /// `loadOrCreateToken` is what keeps other local users off the token file;
    /// it is a same-user secret, not a root secret.
    private let tokenPath: URL

    init(port: UInt16, state: CodexProxyState, tokenPath: URL = FilePaths.proxyTokenFile) {
        self.port = port
        self.state = state
        self.tokenPath = tokenPath
    }

    func start(healConfigurations: Bool = true) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let portValue = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "CodexProxy", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid proxy port \(port)"])
        }
        // Keep the interface hint, but bind explicitly: `requiredLocalEndpoint`
        // is the one that actually holds the listener to loopback. Without it
        // NWListener publishes 0.0.0.0/:: and a LAN client can reach the proxy.
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: portValue)
        _ = try Self.loadOrCreateToken(at: tokenPath)
        // Config repair belongs here rather than in the caller: the token only
        // exists once this has run, and a `config.toml` written before the
        // token requirement (or by a build that has since moved which table it
        // manages) leaves threads pinned to a proxy table holding
        // `PROXY_MANAGED` — every turn 401s until the file is rewritten.
        if healConfigurations {
            for table in CodexConfigWriter.healProxyTokens(proxyBaseURL: "http://127.0.0.1:\(port)/v1") {
                print("[CodexProxy] refreshed proxy token in [\(table)]")
            }
        }
        let listener = try NWListener(using: parameters)
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

    func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try Task.checkCancellation()
            guard let listener else { throw MigrationFailure.storage }
            if case .ready = listener.state { return }
            if case .failed = listener.state { throw MigrationFailure.storage }
            if case .cancelled = listener.state { throw MigrationFailure.storage }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw MigrationFailure.storage
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // One task per connection; all socket I/O for this connection stays
        // inside this connection's task. The interrupt flag rides along as a
        // task-local so `handle()`'s catch arm can tell "user interrupted" from
        // "upstream failed" without any shared lookup.
        let flag = InterruptFlag { connection.cancel() }
        Task { [weak self] in
            await Self.$interruptFlag.withValue(flag) {
                await self?.handle(connection)
            }
        }
    }

    // MARK: - Auth

    /// Bearer token gating every connection (the `/health` probe included —
    /// an unauthenticated health check tells a scanner exactly what it wants
    /// to know).
    ///
    /// The token exists so that a local process cannot *use* this proxy, not
    /// to hide it: a same-user process reads the file directly. It closes the
    /// drive-by case — an npm/pip postinstall, an editor extension, another
    /// app — that would otherwise get the active provider's key by sending any
    /// request. `O_EXCL` + `O_NOFOLLOW` keep a pre-planted file or symlink
    /// from being adopted as the token, and `0600` keeps other local users off
    /// the path.
    static let tokenByteCount = 32

    static func loadOrCreateToken(at url: URL) throws -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= tokenByteCount {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "CodexProxy", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "SecRandomCopyBytes failed"])
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try? handle.write(contentsOf: Data(token.utf8))
        } else if errno == EEXIST {
            // Lost a race with another launch — the winner's token is the
            // live one, and it is also what Codex's config.toml now carries.
            if let raced = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !raced.isEmpty {
                return raced
            }
        }
        return token
    }

    /// The credential this proxy is configured with, for writing into
    /// Codex's `config.toml`. Reads the same file `start()` seeds.
    static var configuredToken: String {
        (try? loadOrCreateToken(at: FilePaths.proxyTokenFile)) ?? ""
    }

    /// `Authorization: Bearer <token>`, or `x-api-key: <token>`.
    ///
    /// A request that carries the active provider's own key in either header
    /// is not trusted to skip the check: the proxy injects that key, so
    /// presenting it is not proof of anything. Anything else must match the
    /// token, and the injected credential is never written back out.
    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let expected = try? Self.loadOrCreateToken(at: tokenPath) else { return false }
        if let auth = request.headers["authorization"],
           auth.hasPrefix("Bearer "),
           Self.constantTimeEquals(String(auth.dropFirst("Bearer ".count)), expected) {
            return true
        }
        if let key = request.headers["x-api-key"],
           Self.constantTimeEquals(key, expected) {
            return true
        }
        return false
    }

    /// Length-checked, branch-free comparison — the token is not a secret the
    /// timing of which matters much, but a comparison that short-circuits on
    /// the first differing byte is a habit worth not shipping.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private func denyUnauthorized(_ connection: NWConnection, request: HTTPRequest) async {
        let miss = await startLog(request, source: .codex, kind: .other, provider: "")
        miss.finish(status: 401, error: "unauthorized")
        await respond(connection, status: "401 Unauthorized", contentType: "application/json",
                      body: Data(#"{"error":{"message":"missing or invalid proxy token; see ClaudeBar 设置 → 本地代理"}}"#.utf8))
        connection.cancel()
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) async {
        // 1. Read until end of headers, then content-length body bytes.
        guard let request = await readRequest(connection) else {
            connection.cancel()
            return
        }

        // 1b. Authenticate before any routing, so an unauthorized caller
        // cannot probe which upstreams exist and never reaches the key
        // injector in `forwardAnthropic` / `forwardNativeChat`.
        guard isAuthorized(request) else {
            await denyUnauthorized(connection, request: request)
            return
        }

        // 2. Route.
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path

        if path.hasPrefix("/migration/") {
            await forwardMigration(connection, request: request, path: path)
            return
        }

        let isAnthropicPath = path.contains("/messages") || path.contains("/complete")
        let hasAnthropicHeaders = request.headers["anthropic-version"] != nil
            || (request.headers["x-api-key"] != nil
                && !path.contains("/responses")
                && !path.contains("/chat/completions"))

        if request.method == "GET" || request.method == "HEAD" {
            if path == "/health" || path == "/v1/health" {
                let tap = await startLog(request, source: .codex, kind: .health, provider: "")
                await serveHealth(connection)
                tap.finish(status: 200)
                return
            }
            if path.hasSuffix("/models") {
                if isAnthropicPath || hasAnthropicHeaders {
                    await forwardAnthropic(connection, request: request, inspect: false)
                    return
                }
                // Served from the on-disk model catalog ClaudeBar writes
                // (`CodexModelCatalog.readJSON()`), not forwarded upstream —
                // so there is no token to strip from the client's headers.
                // An empty catalog therefore reads as "no models", which is
                // the file-missing case, not an upstream failure.
                let tap = await startLog(request, source: .codex, kind: .models, provider: "")
                await serveModels(connection, thirdParty: CaptureSource.isThirdPartyClient(headers: request.headers))
                tap.finish(status: 200)
                return
            }
        }

        if request.method == "POST", CaptureSource.isThirdPartyClient(headers: request.headers),
           ["/v1/chat/completions", "/chat/completions", "/v1/responses", "/responses", "/v1/messages", "/messages", "/v1/messages/count_tokens", "/messages/count_tokens"].contains(path),
           let body = request.body,
           let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           await FreeModelGateway.shared.handles(model: json["model"] as? String ?? "", thirdParty: true) {
            await forwardGateway(connection, request: request, json: json, path: path)
            connection.cancel()
            return
        }

        if isAnthropicPath || hasAnthropicHeaders {
            await forwardAnthropic(connection, request: request, inspect: request.method == "POST")
            return
        }

        guard path.contains("/responses") || path.hasSuffix("/chat/completions") else {
            let miss = await startLog(request, source: .codex, kind: .other, provider: "")
            miss.finish(status: 404, error: "not found")
            await respond(connection, status: "404 Not Found", contentType: "application/json",
                    body: Data(#"{"error":{"message":"not found"}}"#.utf8))
            return
        }

        let thirdParty = CaptureSource.isThirdPartyClient(headers: request.headers)
        let openaiKind: ProxyLogKind = path.hasSuffix("/chat/completions") ? .openaiChat : .openaiResponses
        let upstream = await state.openaiUpstream(thirdParty: thirdParty)
        let openaiTap = await startLog(
            request, source: .codex, kind: openaiKind,
            provider: upstream?.name ?? "")
        defer { openaiTap.finish(status: 0, error: "interrupted") }

        guard let upstream, !upstream.baseURL.isEmpty else {
            openaiTap.finish(status: 502, error: "no upstream configured")
            let acceptSSE = request.headers["accept"]?.contains("text/event-stream") ?? false
            if acceptSSE {
                await write(connection, data: sseHead())
                await write(connection, data: CodexProxyTransform.synthesizeFailed(message: "本地代理没有已激活的上游。请在「模型」页选择 Codex 供应商，或在设置里为第三方指定 OpenAI 上游。"))
            } else {
                await respond(connection, status: "502 Bad Gateway", contentType: "application/json",
                        body: Data(#"{"error":{"message":"no upstream configured"}}"#.utf8))
            }
            connection.cancel()
            return
        }

        // Whether a response head has gone out on this socket. Once it has, a
        // fresh `respond(502 JSON)` would land a second `HTTP/1.1` status line
        // inside an open body, so the catch arm has to keep speaking SSE.
        var headWritten = false
        // 3. Parse body.
        guard let body = request.body,
              var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            openaiTap.finish(status: 400, error: "invalid json")
            await respond(connection, status: "400 Bad Request", contentType: "application/json",
                    body: Data(#"{"error":{"message":"invalid json"}}"#.utf8))
            connection.cancel()
            return
        }

        do {
            let model = (json["model"] as? String) ?? ""
            // Native Chat Completions only: path + `messages`, and no Responses
            // `input`. Codex is always configured with wire_api=responses when
            // using this proxy, so it hits `/v1/responses` and never this arm.
            if path.hasSuffix("/chat/completions"),
               json["messages"] != nil,
               json["input"] == nil {
                try await forwardNativeChat(connection, request: request, json: json,
                                            upstream: upstream, log: openaiTap,
                                            headWritten: &headWritten)
            } else if CodexProxyTransform.shouldBridgeToChat(
                baseURL: upstream.baseURL, wireAPI: upstream.wireAPI, model: model) {
                try await forwardViaChat(connection, request: request, json: &json, upstream: upstream, log: openaiTap,
                                         headWritten: &headWritten)
            } else {
                do {
                    try await forwardResponses(connection, request: request, json: &json, upstream: upstream, log: openaiTap,
                                               headWritten: &headWritten)
                } catch {
                    // Responses-lite gateway (Aibox/GLM wrappers): first turn
                    // of messages works, turn 2 replays function_call and the
                    // untagged ResponseInput enum 400s. Codex++ protocol_proxy
                    // and cc-switch Chat both convert instead of forwarding.
                    guard CodexProxyTransform.isResponseInputReject(error),
                          !Self.wasInterrupted() else { throw error }
                    try await forwardViaChat(connection, request: request, json: &json, upstream: upstream, log: openaiTap,
                                             headWritten: &headWritten)
                }
            }
        } catch {
            openaiTap.finish(status: Self.statusFromProxyError(error),
                             error: Self.wasInterrupted() ? "已中断" : error.localizedDescription)
            // Interrupt = hard stop. The client socket is already down (the
            // abort hook closed it), so there is nothing to answer; writing a
            // synthesized failure here would only race that teardown.
            if !Self.wasInterrupted(), !headWritten {
                // Nothing is on the wire yet, so a real HTTP error response is
                // still possible — but the client must get the framing it
                // asked for. A streaming client would read a JSON error as a
                // malformed event stream, so it gets a terminal SSE event
                // instead. `headWritten` covers the case the Accept header
                // misses: a forwarder that already flushed an SSE or
                // upstream-error head (the client need not have sent
                // `Accept: text/event-stream`), where a second `HTTP/1.1` line
                // would corrupt the response.
                let acceptSSE = request.headers["accept"]?.contains("text/event-stream") ?? false
                if acceptSSE {
                    await write(connection, data: sseHead())
                    await write(connection, data: CodexProxyTransform.synthesizeFailed(message: "上游请求失败：\(error.localizedDescription)"))
                } else {
                    await respond(connection, status: "502 Bad Gateway", contentType: "application/json",
                            body: Data("{\"error\":{\"message\":\"\(error.localizedDescription)\"}}".utf8))
                }
            }
        }
        connection.cancel()
    }

    /// Passthrough for OpenAI Chat Completions clients (Cursor, curl, etc.).
    /// Body and response stay Chat-shaped; no Responses rewrite.
    /// `headWritten` flips once a response head is flushed on the socket, so
    /// `handle()`'s failure arm knows a raw HTTP error is no longer writable.
    private func forwardNativeChat(_ connection: NWConnection, request: HTTPRequest,
                                   json: [String: Any], upstream: CodexProxyState.UpstreamEndpoint,
                                   log: ProxyLogTap, headWritten: inout Bool) async throws {
        let outData = try JSONSerialization.data(withJSONObject: json)
        let wantsStream = (json["stream"] as? Bool) ?? false
        let tap = await makeOpenAITap(
            kind: .openaiChat, request: request, json: json,
            rewritten: outData, stream: wantsStream, upstream: upstream)
        var tokens = TokenTotals()
        var capState = CaptureState.done
        var capError: String?
        var statusCode = 200
        defer {
            tap?.finish(state: capState, status: statusCode, error: capError)
            if capState != .error { log.finish(status: statusCode, tokens: tokens) }
        }
        guard let upstreamURL = chatCompletionsURL(upstream.baseURL) else {
            throw AgentProtocolBridge.Failure.malformed
        }
        bindInterrupt(tap, connection: connection)

        do {
            if wantsStream {
                // Sends no client headers at all: this upstream is a
                // third-party one, and the only credential it should ever see
                // is the proxy's injected key.
                var req = URLRequest(url: upstreamURL)
                req.httpMethod = "POST"
                req.setValue("Bearer \(upstream.apiKey)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.httpBody = outData
                try Self.throwIfInterrupted(tap)
                let (bytes, response) = try await Self.upstreamSession.bytes(for: req)
                Self.attachUpstream(tap, task: bytes.task)
                let http = response as? HTTPURLResponse
                statusCode = http?.statusCode ?? 200
                let ctype = http?.value(forHTTPHeaderField: "Content-Type") ?? "text/event-stream"
                headWritten = true
                await write(connection, data: streamHead(status: statusCode, contentType: ctype))
                if statusCode >= 400 {
                    var errBody = Data()
                    for try await byte in bytes.prefix(4096) { errBody.append(byte) }
                    await write(connection, data: errBody)
                    capState = .error
                    capError = String(data: errBody, encoding: .utf8)
                    return
                }
                var batch = Data()
                for try await line in bytes.lines {
                    batch.append(contentsOf: line.utf8)
                    batch.append(10)
                    if line.hasPrefix("data:"),
                       let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                       let delta = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                        tap?.applyChat(delta)
                        tokens.applyChat(delta)
                        log.note(tokens: tokens)
                    }
                    if line.isEmpty || batch.count >= 4096 {
                        await write(connection, data: batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                if !batch.isEmpty { await write(connection, data: batch) }
            } else {
                try Self.throwIfInterrupted(tap)
                let (data, status) = try await postJSON(
                    url: upstreamURL, apiKey: upstream.apiKey, body: outData,
                    onTask: { Self.attachUpstream(tap, task: $0) })
                statusCode = Int(status) ?? 200
                if statusCode >= 400 {
                    capState = .error
                    capError = String(data: data, encoding: .utf8)
                } else if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    tap?.applyChat(parsed)
                    tokens.applyChat(parsed)
                }
                let reason = statusCode >= 400 ? "Error" : "OK"
                await respond(connection, status: "\(statusCode) \(reason)", contentType: "application/json", body: data)
            }
        } catch {
            if Self.wasInterrupted() {
                // User interrupt, not an upstream fault: the capture keeps the
                // partial stream and reads as aborted, and the access line is
                // sealed with no status rather than a synthesized 502.
                capState = .aborted
                capError = "已中断"
                statusCode = 0
            } else {
                capState = .error
                capError = error.localizedDescription
                statusCode = Self.statusFromProxyError(error)
            }
            throw error
        }
    }

    // MARK: - Responses-native upstream

    /// Responses-native upstream. `headWritten` flips once the SSE head is on
    /// the socket so `handle()`'s failure arm knows not to write a raw HTTP
    /// error over it.
    private func forwardResponses(_ connection: NWConnection, request: HTTPRequest,
                                  json: inout [String: Any], upstream: CodexProxyState.UpstreamEndpoint,
                                  log: ProxyLogTap, headWritten: inout Bool) async throws {
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

        let wantsStream = (json["stream"] as? Bool) ?? false
        let tap = await makeOpenAITap(
            kind: .openaiResponses, request: request, json: json,
            rewritten: outData, stream: wantsStream, upstream: upstream)
        var tokens = TokenTotals()
        var capState = CaptureState.done
        var capError: String?
        var statusCode = 200
        defer {
            tap?.finish(state: capState, status: statusCode, error: capError)
            // Leave the access log pending on error so handle() can retry
            // Responses→Chat without sealing the line as a 400.
            if capState != .error {
                log.finish(status: statusCode,
                           error: capState == .aborted ? capError : nil,
                           tokens: tokens)
            }
        }

        let upstreamURL = joinURL(upstream.baseURL, path: request.path)
        bindInterrupt(tap, connection: connection)

        do {
        if wantsStream {
            // Connect upstream *before* writing the SSE head to Codex, so a
            // ResponseInput 400 can be retried as Chat without corrupting the
            // client stream.
            try Self.throwIfInterrupted(tap)
            let (lines, task) = try await streamSSE(url: upstreamURL, apiKey: upstream.apiKey, body: outData)
            Self.attachUpstream(tap, task: task)
            headWritten = true
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
                    tokens.applyResponses(ev)
                    log.note(tokens: tokens)
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
            try Self.throwIfInterrupted(tap)
            let (data, status) = try await postJSON(
                url: upstreamURL, apiKey: upstream.apiKey, body: outData,
                onTask: { Self.attachUpstream(tap, task: $0) })
            statusCode = Int(status) ?? 200
            var out: [String: Any] = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            out = CodexProxyTransform.rewriteResponsesEvent(out, registry: registry)
            CodexProxyTransform.normalizeUsage(&out)
            tap?.applyResponses(out)
            tokens.applyResponses(out)
            let fixed = (try? JSONSerialization.data(withJSONObject: out)) ?? data
            await respond(connection, status: "\(status) OK", contentType: "application/json", body: fixed)
        }
        } catch {
            if Self.wasInterrupted() {
                // User interrupt, not an upstream fault: the capture keeps the
                // partial stream and reads as aborted, and the access line is
                // sealed with no status rather than a synthesized 502.
                capState = .aborted
                capError = "已中断"
                statusCode = 0
            } else {
                capState = .error
                capError = error.localizedDescription
                statusCode = Self.statusFromProxyError(error)
            }
            throw error
        }
    }

    /// Responses→Chat bridge. `headWritten` flips once the SSE head is on the
    /// socket so `handle()`'s failure arm knows not to write a raw HTTP error
    /// over it.
    private func forwardViaChat(_ connection: NWConnection, request: HTTPRequest,
                                json: inout [String: Any], upstream: CodexProxyState.UpstreamEndpoint,
                                log: ProxyLogTap, headWritten: inout Bool) async throws {
        var registry = CodexProxyTransform.ToolRegistry()
        let chatBody = CodexProxyTransform.responsesToChatRequest(json, registry: &registry)
        let outData = try JSONSerialization.data(withJSONObject: chatBody)
        let tap = await makeOpenAITap(
            kind: .openaiChat, request: request, json: json,
            rewritten: outData, stream: true, upstream: upstream)
        var tokens = TokenTotals()
        var capState = CaptureState.done
        var capError: String?
        var statusCode = 200
        defer {
            tap?.finish(state: capState, status: statusCode, error: capError)
            // Leave the access log pending on error so handle() can retry
            // Responses→Chat without sealing the line as a 400.
            if capState != .error {
                log.finish(status: statusCode,
                           error: capState == .aborted ? capError : nil,
                           tokens: tokens)
            }
        }
        // Always hit /chat/completions when bridging — posting a Chat body
        // to /v1/responses is how the original 400 happens.
        guard let upstreamURL = chatCompletionsURL(upstream.baseURL) else {
            throw AgentProtocolBridge.Failure.malformed
        }
        bindInterrupt(tap, connection: connection)

        do {
        try Self.throwIfInterrupted(tap)
        let (chatLines, chatTask) = try await streamSSE(url: upstreamURL, apiKey: upstream.apiKey, body: outData)
        Self.attachUpstream(tap, task: chatTask)
        headWritten = true
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
            tokens.applyChat(delta)
            log.note(tokens: tokens)
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
            if Self.wasInterrupted() {
                // User interrupt, not an upstream fault: the capture keeps the
                // partial stream and reads as aborted, and the access line is
                // sealed with no status rather than a synthesized 502.
                capState = .aborted
                capError = "已中断"
                statusCode = 0
            } else {
                capState = .error
                capError = error.localizedDescription
                statusCode = Self.statusFromProxyError(error)
            }
            throw error
        }
    }

    // MARK: - Third-party free-model gateway

    /// Owns only the Auto request's transport task. Peer closure must remove a
    /// queued waiter even when no upstream/capture has been created yet.
    private final class GatewayConnectionLifetime: @unchecked Sendable {
        private let lock = NSLock()
        private let connection: NWConnection
        private var operation: Task<Void, Never>?
        private var upstream: URLSessionDataTask?
        private var cancelled = false
        private var finished = false
        init(_ connection: NWConnection) { self.connection = connection }
        func bind(_ operation: Task<Void, Never>) {
            lock.lock(); let cancel = cancelled || finished
            if !cancel { self.operation = operation }
            lock.unlock()
            if cancel { operation.cancel() }
        }
        func attach(_ task: URLSessionDataTask) {
            lock.lock(); let cancel = cancelled || finished
            if !cancel { upstream = task }
            lock.unlock()
            if cancel { task.cancel() }
        }
        func watch() {
            connection.stateUpdateHandler = { [weak self] state in
                switch state { case .failed, .cancelled: self?.cancel(); default: break }
            }
            // The complete HTTP body has already been consumed. This proxy
            // closes after each response; it does not accept pipelined calls.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, ended, error in
                if ended || error != nil || data?.isEmpty == false { self?.cancel() }
            }
        }
        func cancel() {
            lock.lock()
            guard !finished, !cancelled else { lock.unlock(); return }
            cancelled = true
            let operation = operation, upstream = upstream
            self.operation = nil; self.upstream = nil
            lock.unlock()
            operation?.cancel(); upstream?.cancel()
        }
        func finish() {
            lock.lock(); finished = true; operation = nil; upstream = nil; lock.unlock()
            connection.stateUpdateHandler = nil
        }
    }
    @TaskLocal private static var gatewayLifetime: GatewayConnectionLifetime?

    private func forwardGateway(_ connection: NWConnection, request: HTTPRequest,
                                json: [String: Any], path: String) async {
        let lifetime = GatewayConnectionLifetime(connection)
        let operation = Task {
            await Self.$gatewayLifetime.withValue(lifetime) {
                await runGateway(connection, request: request, json: json, path: path)
            }
        }
        lifetime.bind(operation); lifetime.watch()
        await withTaskCancellationHandler { await operation.value } onCancel: { lifetime.cancel() }
        lifetime.finish()
        connection.cancel()
    }

    private func runGateway(_ connection: NWConnection, request: HTTPRequest,
                                json: [String: Any], path: String) async {
        let gateway = FreeModelGateway.shared
        var plan: FreeModelGateway.Plan?
        var headWritten = false
        let anthropic = path.hasSuffix("/messages")
        do {
            if path.hasSuffix("/messages/count_tokens") {
                var estimate = json; estimate["max_tokens"] = 1
                let adapted = try GatewayWireAdapter.request(estimate, path: "/v1/messages")
                let requirements = try GatewayRequirements(chat: adapted.chat)
                await respond(connection, status: "200 OK", contentType: "application/json",
                    body: try JSONSerialization.data(withJSONObject: ["input_tokens": max(1, requirements.context - requirements.output - 1024)]))
                return // conservative local estimate; no quota or upstream I/O
            }
            let adapted = try GatewayWireAdapter.request(json, path: path)
            let requirements = try GatewayRequirements(chat: adapted.chat)
            let selected = try await gateway.begin(requirements, requestBytes: request.body?.count ?? 0)
            plan = selected
            let deadline = Date().addingTimeInterval(60)
            var lastFailure: Error = GatewayFailure.coolingDown
            var remaining = selected.candidates
            while !remaining.isEmpty {
                try Self.throwIfInterrupted(nil)
                guard Date() < deadline else { break }
                guard let candidate = try await gateway.acquireAttempt(remaining, plan: selected,
                    waitTimeout: deadline.timeIntervalSinceNow) else { break }
                remaining.removeAll { $0.member.id == candidate.member.id }
                do {
                    try await forwardGatewayCandidate(connection, request: request, adapted: adapted,
                        candidate: candidate, plan: selected, headWritten: &headWritten)
                    await gateway.finish(selected)
                    return
                } catch {
                    lastFailure = error
                    let code = GatewayWireAdapter.status(error)
                    // A second model must never write into a partially delivered
                    // stream, nor retry an invalid request. Account failures
                    // cool the provider, so another provider can still serve it.
                    guard !headWritten, !Self.wasInterrupted(), code != 0,
                          FreeModelGateway.retryable(status: code) else { throw error }
                }
            }
            throw lastFailure
        } catch {
            if !Self.wasInterrupted(), !(error is CancellationError) {
                let code = GatewayWireAdapter.status(error)
                if code == 0 { if let plan { await gateway.finish(plan) }; return }
                let message = (error as? GatewayFailure)?.localizedDescription
                    ?? "自动网关请求失败，请检查模型池或稍后重试。"
                let failure = error as? GatewayFailure
                let event: [String: Any] = ["type": "error", "error": ["type": "gateway_error", "code": failure?.code ?? "gateway_error", "message": message]]
                if headWritten {
                    if anthropic { try? await writeMigration(connection, data: AgentProtocolBridge.sse(event)) }
                    else if path.hasSuffix("/responses") {
                        try? await writeMigration(connection, data: CodexProxyTransform.synthesizeFailed(message: message))
                    } else {
                        try? await writeMigration(connection, data: CodexProxyTransform.sse(event))
                        try? await writeMigration(connection, data: CodexProxyTransform.sseRaw("[DONE]"))
                    }
                } else {
                    // Before any head is sent, preserve a real HTTP error even
                    // for stream clients; never pretend a failed request is 200.
                    await respond(connection, status: "\(max(400, code)) Error", contentType: "application/json",
                        body: (try? JSONSerialization.data(withJSONObject: event)) ?? Data(), retryAfter: failure?.retryAfter)
                }
            }
        }
        if let plan { await gateway.finish(plan) }
    }

    private func forwardGatewayCandidate(_ connection: NWConnection, request: HTTPRequest,
        adapted: GatewayWireAdapter.Request, candidate: FreeModelGateway.Candidate,
        plan: FreeModelGateway.Plan, headWritten: inout Bool) async throws {
        let started = Date()
        let streamUpstream = adapted.stream || adapted.wire != .chat
        let outbound = FreeModelGateway.outbound(adapted.chat, candidate: candidate, stream: streamUpstream)
        let outData = try JSONSerialization.data(withJSONObject: outbound)
        let upstream = CodexProxyState.UpstreamEndpoint(baseURL: candidate.endpoint.baseURL,
            apiKey: candidate.endpoint.apiKey, wireAPI: "chat", name: candidate.endpoint.name)
        var logRequest = request
        var routedJSON = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] ?? [:]
        routedJSON["model"] = candidate.member.model
        logRequest.body = try JSONSerialization.data(withJSONObject: routedJSON)
        let kind: ProxyLogKind = adapted.wire == .anthropic ? .anthropic
            : (adapted.wire == .responses ? .openaiResponses : .openaiChat)
        let log = await startLog(logRequest, source: .codex, kind: kind, provider: candidate.endpoint.name)
        let tap = await makeOpenAITap(kind: .openaiChat, request: request, json: routedJSON,
            rewritten: outData, stream: adapted.stream, upstream: upstream)
        bindInterrupt(tap, connection: connection)
        var totals = TokenTotals()
        var task: URLSessionDataTask?
        var retryAfter: Double?
        defer { task?.cancel() }
        do {
            guard let url = chatCompletionsURL(candidate.endpoint.baseURL) else { throw GatewayFailure.invalidRequest }
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"; req.httpBody = outData
            req.setValue("Bearer \(candidate.endpoint.apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            req.setValue(streamUpstream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
            try Self.throwIfInterrupted(tap)
            let lifetime = Self.gatewayLifetime
            let (bytes, response) = try await GatewayNetwork.shared.session.bytes(for: req,
                delegate: InterruptWatcher {
                    Self.attachUpstream(tap, task: $0)
                    // Delegate callbacks do not inherit the caller's task locals.
                    lifetime?.attach($0)
                })
            task = bytes.task
            Self.attachUpstream(tap, task: bytes.task)
            guard let http = response as? HTTPURLResponse else { throw GatewayFailure.upstream(502) }
            retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            guard (200..<300).contains(http.statusCode) else { throw GatewayFailure.upstream(http.statusCode) }
            await FreeModelGateway.shared.receivedHeaders(candidate, plan: plan)
            let latency = Date().timeIntervalSince(started)
            if !streamUpstream {
                var data = Data()
                for try await byte in bytes {
                    try Self.throwIfInterrupted(tap)
                    guard data.count < AgentProtocolBridge.maxBytes else { throw GatewayFailure.invalidRequest }
                    data.append(byte)
                }
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      value["error"] == nil, let choices = value["choices"] as? [[String: Any]],
                      choices.first?["message"] is [String: Any], choices.first?["finish_reason"] is String else {
                    throw GatewayFailure.upstream(502)
                }
                tap?.applyChat(value); totals.applyChat(value)
                await FreeModelGateway.shared.receivedOutput(candidate, plan: plan)
                headWritten = true
                await respond(connection, status: "200 OK", contentType: "application/json", body: data)
            } else {
                guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                    throw GatewayFailure.upstream(502)
                }
                var chatState = CodexProxyTransform.ChatStreamState()
                chatState.registry = adapted.registry
                var anthropic = AgentProtocolBridge.ChatStream(stream: .init(model: candidate.member.model))
                var message = AgentProtocolBridge.MessageAccumulator()
                var responseBody: [String: Any]?
                var terminal = false
                var sawData = false
                var accumulatedBytes = 0
                var lastVisualOutput = Date.distantPast
                func deliver(_ events: [[String: Any]]) async throws {
                    for event in events {
                        if adapted.stream {
                            try await writeMigration(connection, data: adapted.wire == .anthropic
                                ? AgentProtocolBridge.sse(event) : CodexProxyTransform.sse(event))
                        } else if adapted.wire == .anthropic { try message.apply(event) }
                        else if event["type"] as? String == "response.completed" {
                            responseBody = event["response"] as? [String: Any]
                        }
                    }
                }
                for try await line in bytes.lines {
                    try Self.throwIfInterrupted(tap)
                    guard line.utf8.count <= AgentProtocolBridge.maxBytes else { throw GatewayFailure.invalidRequest }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          var delta = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw GatewayFailure.upstream(502)
                    }
                    if let error = delta["error"] as? [String: Any] {
                        throw GatewayFailure.upstream(error["code"] as? Int ?? 502)
                    }
                    accumulatedBytes += data.count
                    guard accumulatedBytes <= AgentProtocolBridge.maxBytes else { throw GatewayFailure.invalidRequest }
                    // Delay the client head until the first valid data frame.
                    // OpenRouter can report a provider error in a 200 stream.
                    if !sawData, adapted.stream {
                        headWritten = true
                        try await writeMigration(connection, data: sseHead())
                    }
                    sawData = true
                    let visualNow = Date()
                    if visualNow.timeIntervalSince(lastVisualOutput) >= 0.125 {
                        lastVisualOutput = visualNow
                        await FreeModelGateway.shared.receivedOutput(candidate, plan: plan, now: visualNow)
                    }
                    tap?.applyChat(delta); totals.applyChat(delta); log.note(tokens: totals)
                    if (delta["choices"] as? [[String: Any]] ?? []).contains(where: { $0["finish_reason"] is String }) { terminal = true }
                    switch adapted.wire {
                    case .chat:
                        try await writeMigration(connection, data: CodexProxyTransform.sse(delta))
                    case .responses:
                        // Usage may arrive before the finish marker. Complete
                        // once, after EOF has proved the response is terminal.
                        delta.removeValue(forKey: "usage")
                        try await deliver(CodexProxyTransform.chatDeltaToResponsesEvents(delta, state: &chatState))
                    case .anthropic:
                        try await deliver(anthropic.apply(delta))
                    }
                }
                guard sawData, terminal else { throw GatewayFailure.incomplete }
                if adapted.wire == .responses {
                    let result: [String: Any] = ["id": chatState.responseID, "object": "response",
                        "created_at": Int(Date().timeIntervalSince1970), "status": "completed",
                        "model": candidate.member.model, "usage": ["input_tokens": (totals.input ?? 0) + (totals.cacheRead ?? 0) + (totals.cacheWrite ?? 0),
                            "output_tokens": totals.output ?? 0, "total_tokens": totals.total ?? 0,
                            "input_tokens_details": ["cached_tokens": totals.cacheRead ?? 0]]]
                    try await deliver(CodexProxyTransform.completedEvents(state: &chatState, response: result))
                } else if adapted.wire == .anthropic { try await deliver(anthropic.finish()) }
                if adapted.stream, adapted.wire != .anthropic {
                    try await writeMigration(connection, data: CodexProxyTransform.sseRaw("[DONE]"))
                } else if !adapted.stream {
                    let value = adapted.wire == .anthropic ? try message.result() : (responseBody ?? [:])
                    headWritten = true
                    await respond(connection, status: "200 OK", contentType: "application/json",
                        body: try JSONSerialization.data(withJSONObject: value))
                }
            }
            tap?.finish(state: .done, status: 200, error: nil)
            log.finish(status: 200, tokens: totals)
            task?.cancel()
            await FreeModelGateway.shared.report(candidate, plan: plan, status: 200, latency: latency)
        } catch {
            let interrupted = Self.wasInterrupted() || GatewayWireAdapter.status(error) == 0
            let status = interrupted ? 0 : GatewayWireAdapter.status(error)
            tap?.finish(state: interrupted ? .aborted : .error, status: status,
                        error: interrupted ? "已中断" : "自动路由失败（HTTP \(status)）")
            log.finish(status: status, error: interrupted ? "已中断" : "自动路由失败（HTTP \(status)）", tokens: totals)
            task?.cancel()
            await FreeModelGateway.shared.report(candidate, plan: plan, status: status,
                latency: Date().timeIntervalSince(started), retryAfter: retryAfter)
            throw error
        }
    }

    // MARK: - Per-conversation model bridge

    private func forwardMigration(_ connection: NWConnection, request: HTTPRequest, path: String) async {
        guard BuildChannel.allowsSystemIntegration,
              let route = MigrationBridgeConfiguration.route(path), request.method == "POST",
              let endpoint = await state.migrationEndpoint(for: route.id) else {
            await respond(connection, status: "404 Not Found", contentType: "application/json",
                body: Data(#"{"error":{"type":"not_found_error","message":"迁移连接不可用，请从 ClaudeBar 的迁移会话区域重新打开会话。"}}"#.utf8))
            connection.cancel(); return
        }
        var headWritten = false
        var upstreamTask: URLSessionDataTask?
        var upstreamStarted = false
        defer { upstreamTask?.cancel(); connection.cancel() }
        do {
            guard let bodyData = request.body else { throw AgentProtocolBridge.Failure.malformed }
            guard bodyData.count <= AgentProtocolBridge.maxBytes else { throw AgentProtocolBridge.Failure.tooLarge }
            guard let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                throw AgentProtocolBridge.Failure.malformed
            }
            if route.countTokens {
                // The upstream Responses API has no Anthropic token-count endpoint.
                // Conservative local estimate, never represented as vendor billing.
                let count = max(1, bodyData.count / 2 + 1)
                await respond(connection, status: "200 OK", contentType: "application/json",
                    body: try JSONSerialization.data(withJSONObject: ["input_tokens": count]))
                return
            }
            var responses = try AgentProtocolBridge.request(body, model: endpoint.model)
            if !endpoint.reasoningEffort.isEmpty { responses["reasoning"] = ["effort": endpoint.reasoningEffort] }
            var registry = CodexProxyTransform.ToolRegistry()
            let outbound = endpoint.wireAPI == "chat"
                ? CodexProxyTransform.responsesToChatRequest(responses, registry: &registry) : responses
            let outData = try JSONSerialization.data(withJSONObject: outbound)
            guard let url = endpoint.wireAPI == "chat" ? chatCompletionsURL(endpoint.baseURL)
                : MigrationBridgeConfiguration.responsesURL(endpoint.baseURL) else { throw AgentProtocolBridge.Failure.malformed }
            let (lines, task) = try await streamSSE(url: url, apiKey: endpoint.apiKey, body: outData)
            upstreamTask = task
            upstreamStarted = true
            let wantsStream = body["stream"] as? Bool ?? false
            if wantsStream { try await writeMigration(connection, data: sseHead()); headWritten = true }
            var stream = AgentProtocolBridge.Stream(model: endpoint.model)
            var chat = AgentProtocolBridge.ChatStream(stream: .init(model: endpoint.model))
            var accumulated = AgentProtocolBridge.MessageAccumulator()
            func deliver(_ events: [[String: Any]]) async throws {
                for event in events {
                    try Task.checkCancellation()
                    if wantsStream { try await writeMigration(connection, data: AgentProtocolBridge.sse(event)) }
                    else { try accumulated.apply(event) }
                }
            }
            for try await line in lines {
                try Task.checkCancellation()
                if Self.wasInterrupted() { throw CancellationError() }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard payload.utf8.count <= AgentProtocolBridge.maxBytes,
                      let data = payload.data(using: .utf8),
                      let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AgentProtocolBridge.Failure.malformed
                }
                if endpoint.wireAPI == "chat" { try await deliver(chat.apply(event)) }
                else {
                    try await deliver(stream.apply(event))
                    if stream.terminal { break }
                }
            }
            if endpoint.wireAPI == "chat" { try await deliver(chat.finish()) }
            else if !stream.terminal { throw AgentProtocolBridge.Failure.incomplete }
            if !wantsStream {
                await respond(connection, status: "200 OK", contentType: "application/json",
                    body: try JSONSerialization.data(withJSONObject: accumulated.result()))
            }
        } catch {
            // Do not expose the upstream error body, URL or credentials, and
            // never write a second HTTP status line after a streaming head.
            let inputFailure = !upstreamStarted && error is AgentProtocolBridge.Failure
            let tooLarge = !upstreamStarted && (error as? AgentProtocolBridge.Failure) == .tooLarge
            let status = tooLarge ? "413 Payload Too Large" : (inputFailure ? "400 Bad Request" : "502 Bad Gateway")
            let event: [String: Any] = ["type": "error", "error": ["type": inputFailure ? "invalid_request_error" : "api_error",
                "message": inputFailure ? "请求包含暂不支持的工具或附件格式，请调整模型与工具配置。"
                    : "模型请求失败或响应中断，请重试或选择兼容模型。"]]
            if headWritten { try? await writeMigration(connection, data: AgentProtocolBridge.sse(event)) }
            else {
                await respond(connection, status: status, contentType: "application/json",
                    body: (try? JSONSerialization.data(withJSONObject: event)) ?? Data())
            }
        }
    }

    private func writeMigration(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    // MARK: - Upstream I/O

    /// Stream an upstream SSE response as decoded `data:` payload lines, along
    /// with the underlying task so the caller can cancel it on interrupt.
    private func streamSSE(url: URL, apiKey: String, body: Data) async throws
        -> (lines: AsyncLineSequence<URLSession.AsyncBytes>, task: URLSessionDataTask) {
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
        return (bytes.lines, bytes.task)
    }

    /// Non-stream upstream call. `onTask` receives the data task the moment it
    /// exists, before the body has been read, so an interrupt can cancel it.
    private func postJSON(url: URL, apiKey: String, body: Data,
                          onTask: ((URLSessionDataTask) -> Void)? = nil) async throws -> (Data, String) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await Self.upstreamSession.data(for: req, delegate: onTask.map(InterruptWatcher.init))
        let status = (response as? HTTPURLResponse).map { "\($0.statusCode)" } ?? "200"
        return (data, status)
    }

    /// Bridges `URLSession.data(for:delegate:)` to a raw-task callback. The
    /// per-task delegate is the only hook that fires before the body arrives,
    /// which is what makes a non-stream request interruptible.
    private final class InterruptWatcher: NSObject, URLSessionTaskDelegate {
        private let onTask: (URLSessionDataTask) -> Void
        init(_ onTask: @escaping (URLSessionDataTask) -> Void) { self.onTask = onTask }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            guard let dataTask = task as? URLSessionDataTask else { return }
            onTask(dataTask)
        }
    }

    private func joinURL(_ base: String, path: String) -> URL {
        let s = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var suffix = path.split(separator: "?").first.map(String.init) ?? path
        if suffix.hasPrefix("/") { suffix.removeFirst() }
        // Codex sends /v1/responses; drop a duplicated /v1 when the base already
        // ends with it.
        if s.hasSuffix("/v1") && (suffix == "v1" || suffix.hasPrefix("v1/")) {
            suffix = suffix == "v1" ? "" : String(suffix.dropFirst(3))
        }
        if suffix.isEmpty { return URL(string: s) ?? URL(string: "http://127.0.0.1")! }
        return URL(string: s + "/" + suffix) ?? URL(string: "http://127.0.0.1")!
    }

    /// Chat Completions URL for an OpenAI-compat root. Bases that already end
    /// in a version segment (`/v1`, `/v4`, …) append `/chat/completions`;
    /// bare hosts get `/v1/chat/completions`.
    ///
    /// Single joined rule shared with the migration bridge (see
    /// `MigrationBridgeConfiguration.url`), so the two wire paths cannot drift.
    /// `nil` means the base could not be turned into a URL; callers fail the
    /// request instead of falling back to any fabricated host.
    private func chatCompletionsURL(_ base: String) -> URL? {
        MigrationBridgeConfiguration.chatCompletionsURL(base)
    }

    // MARK: - Anthropic passthrough (Claude Code)

    /// Forward Claude Code's Anthropic Messages traffic. Body is not rewritten;
    /// client headers (`x-api-key`, `anthropic-version`, `anthropic-beta`) pass
    /// through so official and `/anthropic` gateways keep working.
    private func forwardAnthropic(_ connection: NWConnection, request: HTTPRequest, inspect: Bool) async {
        let thirdParty = CaptureSource.isThirdPartyClient(headers: request.headers)
        let log = await startLog(
            request, source: .claude, kind: request.path.hasSuffix("/models") ? .models : .anthropic,
            provider: await state.anthropicUpstream(thirdParty: thirdParty)?.name ?? "")
        defer { log.finish(status: 0, error: "interrupted") }

        guard let upstream = await state.anthropicUpstream(thirdParty: thirdParty) else {
            log.finish(status: 502, error: "no anthropic upstream")
            await respond(connection, status: "502 Bad Gateway", contentType: "application/json",
                    body: Data(#"{"error":{"message":"no anthropic upstream — 请在「模型」页选择 Claude Code 供应商，或在设置里为第三方指定 Anthropic 上游"}}"#.utf8))
            connection.cancel()
            return
        }

        // The access log parses the body for model/stream, so reuse that read
        // instead of deserializing the whole conversation a second time.
        let peek = Self.peekJSON(request.body)
        let wantsStream = peek.stream
        let model = peek.model

        let tap: CaptureTap?
        if inspect, await shouldCaptureAnthropic(request.headers) {
            tap = ProxyCaptureStore.shared.begin(
                kind: .anthropic,
                source: CaptureSource.infer(headers: request.headers, route: .claude),
                provider: upstream.name,
                model: model,
                path: request.path,
                stream: wantsStream,
                requestJSON: request.body.flatMap { String(data: $0, encoding: .utf8) },
                rewrittenJSON: nil,
                requestHeaders: request.headers)
        } else {
            tap = nil
        }
        var tokens = TokenTotals()
        var capState = CaptureState.done
        var capError: String?
        var statusCode = 200
        var userInterrupted = false
        defer {
            tap?.finish(state: capState, status: statusCode, error: capError)
            // An interrupt is not an upstream fault — log it with no status
            // rather than a synthesized 502.
            if capState == .error {
                log.finish(status: statusCode >= 400 ? statusCode : 502,
                           error: capError, tokens: tokens)
            } else {
                log.finish(status: statusCode,
                           error: userInterrupted ? capError : nil,
                           tokens: tokens)
            }
        }
        bindInterrupt(tap, connection: connection)

        var req = URLRequest(url: joinAnthropic(upstream.baseURL, path: request.path))
        req.httpMethod = request.method
        req.httpBody = request.body
        req.timeoutInterval = 600
        copyClientHeaders(request.headers, onto: &req)
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // Always inject. The client presented the proxy token in whichever
        // header it had room for, so "the client sent a credential" no longer
        // means "the client brought its own upstream key".
        if !upstream.apiKey.isEmpty {
            req.setValue(upstream.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("Bearer \(upstream.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            if wantsStream {
                try Self.throwIfInterrupted(tap)
                let (bytes, response) = try await Self.upstreamSession.bytes(for: req)
                Self.attachUpstream(tap, task: bytes.task)
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
                try await pipeAnthropicSSE(bytes, to: connection, tap: tap, log: log, tokens: &tokens)
            } else {
                try Self.throwIfInterrupted(tap)
                let (data, response) = try await Self.upstreamSession.data(
                    for: req, delegate: InterruptWatcher { Self.attachUpstream(tap, task: $0) })
                let http = response as? HTTPURLResponse
                statusCode = http?.statusCode ?? 200
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    tap?.ingestAnthropicMessage(json)
                    tokens.applyAnthropicMessage(json)
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
            if Self.wasInterrupted() {
                capState = .aborted
                capError = "已中断"
                statusCode = 0
                userInterrupted = true
            } else {
                capState = .error
                capError = error.localizedDescription
                if !(wantsStream) {
                    await respond(connection, status: "502 Bad Gateway", contentType: "application/json",
                            body: Data("{\"error\":{\"message\":\"\(error.localizedDescription)\"}}".utf8))
                }
            }
        }
        connection.cancel()
    }

    /// Headers a client may pass through to the upstream. Everything else is
    /// dropped, not merely overridden.
    ///
    /// Two reasons this is an allowlist rather than a skip-list:
    ///   * the client's `Authorization` is the *proxy token* (the client
    ///     stores the proxy token where it would have stored an API key), so
    ///     forwarding it hands the token to a third-party upstream; and
    ///   * the credentials below are the proxy's to set. A client-chosen
    ///     upstream key must not survive the hop, or the injector's "only when
    ///     the client sent neither header" rule reopens the hole the token
    ///     closes.
    private static let forwardedHeaderAllowlist: Set<String> = [
        "content-type", "accept", "user-agent",
        "anthropic-version", "anthropic-beta", "anthropic-dangerous-direct-browser-access",
        "openai-beta", "openai-organization", "openai-project", "x-stainless-arch",
        "x-stainless-lang", "x-stainless-os", "x-stainless-package-version",
        "x-stainless-runtime", "x-stainless-runtime-version", "x-stainless-retry-count",
        "x-request-id", "idempotency-key",
    ]

    /// Headers that must never be copied, whatever else changes — the two the
    /// proxy owns the credential for, plus the token itself.
    private static let credentialHeaders: Set<String> = [
        "authorization", "x-api-key", "proxy-authorization", "cookie",
    ]

    private func copyClientHeaders(_ headers: [String: String], onto req: inout URLRequest) {
        for (key, value) in headers {
            guard Self.forwardedHeaderAllowlist.contains(key),
                  !Self.credentialHeaders.contains(key) else { continue }
            req.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func streamHead(status: Int, contentType: String) -> Data {
        let reason = status >= 400 ? "Error" : "OK"
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\nX-Accel-Buffering: no\r\nConnection: close\r\n\r\n".utf8)
    }

    /// Forward SSE as complete events. Flush on each blank line so Claude
    /// Code sees `message_start` immediately instead of a half-frame.
    ///
    /// `tokens` (and `log`) are updated on the way through, so the access-log
    /// console carries token counts even when traffic recording is off and
    /// there is no capture tap.
    private func pipeAnthropicSSE(_ bytes: URLSession.AsyncBytes, to connection: NWConnection,
                                  tap: CaptureTap?, log: ProxyLogTap,
                                  tokens: inout TokenTotals) async throws {
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
                tokens.applyAnthropic(event: name, json: json)
                log.note(tokens: tokens)
            }
        }
        if !batch.isEmpty {
            await write(connection, data: batch)
            tap?.appendRaw(batch)
        }
        if let ev = parser.finish(), !ev.done, let json = ev.json {
            let name = ev.name.isEmpty ? ((json["type"] as? String) ?? "") : ev.name
            tap?.applyAnthropic(event: name, json: json)
            tokens.applyAnthropic(event: name, json: json)
            log.note(tokens: tokens)
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
        guard await shouldCaptureOpenAI(request.headers) else { return nil }
        return ProxyCaptureStore.shared.begin(
            kind: kind,
            source: CaptureSource.infer(headers: request.headers, route: .codex),
            provider: upstream.name,
            model: (json["model"] as? String) ?? "",
            path: request.path,
            stream: stream,
            requestJSON: request.body.flatMap { String(data: $0, encoding: .utf8) },
            rewrittenJSON: String(data: rewritten, encoding: .utf8),
            requestHeaders: request.headers)
    }

    /// Access log only — never the request/response body, just routing metadata.
    private func startLog(_ request: HTTPRequest, source: ProxyLogSource, kind: ProxyLogKind,
                          provider: String) async -> ProxyLogTap {
        guard shouldRecordTraffic(request.headers) else { return .noop }
        await ProxyAccessLog.shared.prepareForRequests()
        let peek = Self.peekJSON(request.body)
        let resolved = resolveLogSource(request.headers, route: source)
        return ProxyAccessLog.shared.begin(
            method: request.method,
            path: request.path,
            source: resolved,
            kind: kind,
            provider: provider,
            model: peek.model,
            stream: peek.stream,
            bytesIn: request.body?.count ?? 0)
    }

    private func shouldRecordTraffic(_ headers: [String: String]) -> Bool {
        guard CaptureSource.isThirdPartyClient(headers: headers) else { return true }
        return AppPreferences.shared.proxyThirdPartyTrafficEnabled
    }

    /// CC/Codex 仍走供应商「流量记录」；第三方仅受设置里的「记录第三方流量」控制。
    private func shouldCaptureOpenAI(_ headers: [String: String]) async -> Bool {
        guard shouldRecordTraffic(headers) else { return false }
        if CaptureSource.isThirdPartyClient(headers: headers) { return true }
        return await state.captureOpenAI
    }

    private func shouldCaptureAnthropic(_ headers: [String: String]) async -> Bool {
        guard shouldRecordTraffic(headers) else { return false }
        if CaptureSource.isThirdPartyClient(headers: headers) { return true }
        return await state.captureAnthropic
    }

    private func resolveLogSource(_ headers: [String: String], route: ProxyLogSource) -> ProxyLogSource {
        if CaptureSource.isThirdPartyClient(headers: headers) { return .other }
        return route
    }

    private static func peekJSON(_ body: Data?) -> (model: String, stream: Bool) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ("", false)
        }
        return ((json["model"] as? String) ?? "", (json["stream"] as? Bool) ?? false)
    }

    private static func statusFromProxyError(_ error: Error) -> Int {
        let ns = error as NSError
        if ns.domain == "CodexProxy", (400...599).contains(ns.code) { return ns.code }
        return 502
    }

    private func serveHealth(_ connection: NWConnection) async {
        var obj: [String: Any] = ["ok": true]
        if let name = await state.upstream?.name { obj["codex_upstream"] = name }
        if let name = await state.anthropic?.name { obj["claude_upstream"] = name }
        if let name = await state.thirdPartyOpenAI?.name { obj["third_party_openai"] = name }
        if let name = await state.thirdPartyAnthropic?.name { obj["third_party_anthropic"] = name }
        let body = (try? JSONSerialization.data(withJSONObject: obj))
            ?? Data(#"{"ok":true}"#.utf8)
        await respond(connection, status: "200 OK", contentType: "application/json", body: body)
        connection.cancel()
    }

    private func serveModels(_ connection: NWConnection, thirdParty: Bool = false) async {
        var body = CodexModelCatalog.readJSON()
            ?? Data(#"{"object":"list","data":[],"models":[]}"#.utf8)
        let ids = thirdParty ? await FreeModelGateway.shared.advertisedModels() : []
        if !ids.isEmpty {
            var catalog = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            var rows = catalog["data"] as? [[String: Any]] ?? []
            for id in ids where !rows.contains(where: { $0["id"] as? String == id }) {
                rows.append(["id": id, "object": "model", "created": 0, "owned_by": "claudebar"])
            }
            catalog["object"] = "list"; catalog["data"] = rows
            body = (try? JSONSerialization.data(withJSONObject: catalog)) ?? body
        }
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
        // The declared length is untrusted input arriving **before**
        // `isAuthorized` runs, and both of the ways it can be hostile were
        // reachable: a negative value traps in `prefix(_:)` ("Can't take a
        // prefix of negative length") and kills the whole menu-bar process for
        // anyone who can reach the loopback port; a huge one drove the loop
        // below past `cap`, which the header loop had already stopped reading
        // at, so the documented 64 MiB ceiling did not exist for the body.
        let declared = Int(headers["content-length"] ?? "0") ?? 0
        guard declared >= 0, declared <= cap else { return nil }
        while body.count < declared {
            guard let chunk = await receive(connection) else { break }
            body.append(chunk)
        }
        return HTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: body.prefix(declared)
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

    private func respond(_ connection: NWConnection, status: String, contentType: String, body: Data, retryAfter: Int? = nil) async {
        let retry = retryAfter.map { "Retry-After: \(max(1, $0))\r\n" } ?? ""
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\(retry)Connection: close\r\n\r\n"
        await write(connection, data: Data(head.utf8) + body)
    }
}
