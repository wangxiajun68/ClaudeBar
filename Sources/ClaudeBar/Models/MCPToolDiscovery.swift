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
        return try await Task.detached(priority: .utility) {
            try listSync(connection: connection, from: config)
        }.value
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

    private static func listSync(connection: MCPConnection, from config: URL) throws -> [MCPToolSummary] {
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
        let collector = MCPLineCollector()
        process.executableURL = executable
        process.arguments = connection.arguments
        process.environment = environment
        process.currentDirectoryURL = config.deletingLastPathComponent()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; collector.finish() }
            else { collector.append(data) }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:] as [String: String],
            "clientInfo": ["name": "ClaudeBar", "version": "1.0"]
        ]], to: input)
        let initialized = try collector.response(id: 1, until: deadline)
        guard initialized["error"] == nil else { throw DiscoveryError.serverError }
        guard initialized["result"] is [String: Any] else { throw DiscoveryError.invalidResponse }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"], to: input)
        var tools: [MCPToolSummary] = []
        var cursor: String?
        for page in 0..<10 {
            let id = page + 2
            let params: [String: String] = cursor.map { ["cursor": $0] } ?? [:]
            try send(["jsonrpc": "2.0", "id": id, "method": "tools/list", "params": params], to: input)
            let message = try collector.response(id: id, until: deadline)
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

private final class MCPLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var messages: [Int: [String: Any]] = [:]
    private var closed = false

    func finish() {
        lock.lock()
        closed = true
        lock.unlock()
        signal.signal()
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        if buffer.count > 1_048_576 { buffer.removeAll(); lock.unlock(); signal.signal(); return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let id = json["id"] as? Int {
                messages[id] = json
                signal.signal()
            }
        }
        lock.unlock()
    }

    func response(id: Int, until deadline: Date) throws -> [String: Any] {
        while Date() < deadline {
            lock.lock()
            let value = messages.removeValue(forKey: id)
            let isClosed = closed
            lock.unlock()
            if let value { return value }
            if isClosed { throw MCPToolDiscovery.DiscoveryError.serverError }
            _ = signal.wait(timeout: .now() + 0.2)
        }
        throw MCPToolDiscovery.DiscoveryError.timedOut
    }
}
