import Foundation

struct MCPToolSummary: Identifiable, Sendable {
    let name: String
    let description: String
    let argumentNames: [String]
    var id: String { name }
}

/// Discovers metadata only. It never sends tools/call. Each request is bounded,
/// and the child process is closed when the detail view no longer needs it.
enum MCPToolDiscovery {
    private static let stdioQueue = DispatchQueue(label: "com.claudebar.mcp-discovery", qos: .utility,
                                                  attributes: .concurrent)
    private static let cancellationQueue = DispatchQueue(label: "com.claudebar.mcp-discovery.cancel", qos: .utility)

    /// Cancellation wakes the collector immediately. Process launch/stop are
    /// serialized so cancellation before, during or after launch cannot lose
    /// the child or terminate it twice. No process work runs on the UI caller.
    private final class StdioSession: @unchecked Sendable {
        let collector = JSONLineCollector()
        private let lock = NSLock()
        private let processLock = NSLock()
        private var cancelled = false
        private var process: Process?

        func checkCancellation() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
        }

        func start(_ child: Process) throws {
            processLock.lock(); defer { processLock.unlock() }
            try checkCancellation()
            try child.run()
            process = child
        }

        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            collector.finish()
            cancellationQueue.async { self.stop() }
        }

        func stop() {
            processLock.lock(); defer { processLock.unlock() }
            if let process, process.isRunning { process.terminate() }
            process = nil
        }
    }

    enum DiscoveryError: LocalizedError {
        case unavailable, unsupportedRunner, timedOut, invalidResponse, serverError
        var errorDescription: String? {
            switch self {
            case .unavailable: return "找不到 MCP 启动命令，请检查配置或安装路径。"
            case .unsupportedRunner: return "此 MCP 使用可能安装软件的运行器。请在原客户端确认安装后查看工具。"
            case .timedOut: return "MCP 服务没有及时回应。请确认服务可启动、凭据有效后重试。"
            case .invalidResponse: return "MCP 服务返回了无法读取的工具列表。"
            case .serverError: return "MCP 服务拒绝列出工具。请在原客户端检查连接状态。"
            }
        }
    }

    static func list(connection: MCPConnection, from config: URL) async throws -> [MCPToolSummary] {
        if let url = connection.url { return try await listHTTP(connection: connection, url: url) }
        let session = StdioSession()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // response() waits on a semaphore. Dispatch owns that blocking
                // work; the Swift task suspends without occupying its pool.
                stdioQueue.async {
                    do {
                        let tools = try listSync(connection: connection, from: config, session: session)
                        try session.checkCancellation()
                        continuation.resume(returning: tools)
                    } catch {
                        do { try session.checkCancellation() }
                        catch { continuation.resume(throwing: error); return }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            session.cancel()
        }
    }

    private static func listHTTP(connection: MCPConnection, url: URL) async throws -> [MCPToolSummary] {
        guard url.scheme == "https" || url.scheme == "http" else { throw DiscoveryError.unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (initialized, response) = try await postHTTP(
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "protocolVersion": "2025-06-18", "capabilities": [:] as [String: String],
                "clientInfo": ["name": "ClaudeBar", "version": "1.0"]
            ]], id: 1, session: session, url: url, headers: connection.headers)
        guard initialized["error"] == nil,
              let result = initialized["result"] as? [String: Any] else { throw DiscoveryError.serverError }
        let version = result["protocolVersion"] as? String ?? "2025-06-18"
        let sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id")
        _ = try await postHTTP(["jsonrpc": "2.0", "method": "notifications/initialized"],
                               id: nil, session: session, url: url, headers: connection.headers,
                               version: version, sessionID: sessionID)
        var tools: [MCPToolSummary] = []
        var cursor: String?
        for page in 0..<10 {
            let id = page + 2
            let params: [String: String] = cursor.map { ["cursor": $0] } ?? [:]
            let (message, _) = try await postHTTP(
                ["jsonrpc": "2.0", "id": id, "method": "tools/list", "params": params],
                id: id, session: session, url: url, headers: connection.headers,
                version: version, sessionID: sessionID)
            guard message["error"] == nil,
                  let payload = message["result"] as? [String: Any],
                  let entries = payload["tools"] as? [[String: Any]] else { throw DiscoveryError.serverError }
            tools += summarize(entries)
            cursor = payload["nextCursor"] as? String
            if cursor == nil || tools.count >= 500 { break }
        }
        return tools
    }

    private static func postHTTP(_ body: [String: Any], id: Int?, session: URLSession,
                                 url: URL, headers: [String: String], version: String? = nil,
                                 sessionID: String? = nil) async throws -> ([String: Any], HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (key, value) in headers where !key.isEmpty { request.setValue(value, forHTTPHeaderField: key) }
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else { throw DiscoveryError.serverError }
        if id == nil { return ([:], response) }
        guard data.count < 2_000_000 else { throw DiscoveryError.invalidResponse }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["id"] as? Int) == id { return (json, response) }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
               (json["id"] as? Int) == id { return (json, response) }
        }
        throw DiscoveryError.invalidResponse
    }

    private static func summarize(_ entries: [[String: Any]]) -> [MCPToolSummary] {
        entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let schema = entry["inputSchema"] as? [String: Any]
            let properties = schema?["properties"] as? [String: Any] ?? [:]
            return MCPToolSummary(name: name,
                                  description: entry["description"] as? String ?? "暂无描述",
                                  argumentNames: properties.keys.sorted())
        }
    }

    private static func listSync(connection: MCPConnection, from config: URL,
                                 session: StdioSession) throws -> [MCPToolSummary] {
        try session.checkCancellation()
        let command = connection.command
        let name = URL(fileURLWithPath: command).lastPathComponent
        guard !["npx", "pnpm", "yarn", "bunx", "uvx"].contains(name) else {
            throw DiscoveryError.unsupportedRunner
        }
        let environment = ProcessInfo.processInfo.environment.merging(connection.environment) { _, new in new }
        guard let executable = resolve(command, config: config, environment: environment) else {
            throw DiscoveryError.unavailable
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let collector = session.collector
        process.executableURL = executable
        process.arguments = connection.arguments
        process.environment = environment
        process.currentDirectoryURL = config.deletingLastPathComponent()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        // A write to a child that already exited raises SIGPIPE, whose default
        // disposition terminates the whole app — and an MCP server is the
        // third-party process most likely to exit early (a crash, an
        // npx/pnpm shim that quits, a server that rejects the initialized
        // frame). Same call `CodexAppServerClient` and `BatteryChargeController`
        // make on their child pipes; without it the `try send(...)` below
        // never throws, the process just dies.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; collector.finish() }
            else { collector.append(data) }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            session.stop()
        }
        try session.start(process)
        try session.checkCancellation()
        // **One budget per request, not one for the session.** A single
        // session-wide deadline covered `initialize` *and* up to ten
        // `tools/list` pages, so a server that answers every request briskly
        // but needs a moment to start (an `npx` shim, a cold JVM) got cut off
        // mid-pagination with 服务没有及时回应 — even though nothing ever
        // stalled. Ten seconds is what the HTTP transport in this file gives
        // each request (`timeoutIntervalForRequest`), and the doc above says
        // "each request is bounded"; the stdio path now means the same thing.
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:] as [String: String],
            "clientInfo": ["name": "ClaudeBar", "version": "1.0"]
        ]], to: input)
        let initialized: [String: Any]
        initialized = try response(session, id: 1, until: Date().addingTimeInterval(10))
        try session.checkCancellation()
        guard initialized["error"] == nil else { throw DiscoveryError.serverError }
        guard initialized["result"] as? [String: Any] != nil else { throw DiscoveryError.invalidResponse }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"], to: input)
        var tools: [MCPToolSummary] = []
        var cursor: String?
        for page in 0..<10 {
            try session.checkCancellation()
            let id = page + 2
            let params: [String: String] = cursor.map { ["cursor": $0] } ?? [:]
            try send(["jsonrpc": "2.0", "id": id, "method": "tools/list", "params": params], to: input)
            let message: [String: Any]
            message = try response(session, id: id, until: Date().addingTimeInterval(10))
            guard message["error"] == nil else { throw DiscoveryError.serverError }
            guard let result = message["result"] as? [String: Any],
                  let entries = result["tools"] as? [[String: Any]] else { throw DiscoveryError.invalidResponse }
            tools += summarize(entries)
            cursor = result["nextCursor"] as? String
            if cursor == nil || tools.count >= 500 { break }
        }
        return tools
    }

    private static func send(_ message: [String: Any], to pipe: Pipe) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try pipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// The collector reports transport failures generically; this is the one
    /// place they take on the error enum the connector sheet presents.
    private static func response(_ session: StdioSession, id: Int,
                                 until deadline: Date) throws -> [String: Any] {
        do { return try session.collector.response(id: id, until: deadline) }
        catch {
            try session.checkCancellation()
            if case JSONLineCollector.Failure.timedOut = error { throw DiscoveryError.timedOut }
            throw DiscoveryError.serverError
        }
    }

    private static func resolve(_ command: String, config: URL, environment: [String: String]) -> URL? {
        let fm = FileManager.default
        if command.contains("/") {
            let url = command.hasPrefix("/") ? URL(fileURLWithPath: command)
                : config.deletingLastPathComponent().appendingPathComponent(command)
            return fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
               "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for root in paths {
            let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(command)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
