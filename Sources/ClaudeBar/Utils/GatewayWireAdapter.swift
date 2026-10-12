import Foundation
import Network

enum GatewayWireAdapter {
    enum Wire { case chat, responses, anthropic }
    struct Request {
        var wire: Wire
        var chat: [String: Any]
        var registry: CodexProxyTransform.ToolRegistry
        var stream: Bool
    }

    static func request(_ json: [String: Any], path: String) throws -> Request {
        var registry = CodexProxyTransform.ToolRegistry()
        let stream = json["stream"] as? Bool ?? false
        guard (json["n"] as? Int ?? 1) == 1, json["web_search_options"] == nil,
              json["audio"] == nil,
              (json["modalities"] as? [String] ?? ["text"]).allSatisfy({ $0 == "text" }) else { throw GatewayFailure.invalidRequest }
        if path.hasSuffix("/messages") {
            let responses = try AgentProtocolBridge.request(json, model: "auto")
            var chat = CodexProxyTransform.responsesToChatRequest(responses, registry: &registry)
            carryParameters(responses, into: &chat)
            chat["task_difficulty"] = json["task_difficulty"]
            return Request(wire: .anthropic, chat: chat, registry: registry, stream: stream)
        }
        if path.hasSuffix("/responses") {
            // A stateless pool cannot retrieve a previous provider's hidden
            // conversation. Require the actual history rather than dropping it.
            guard json["previous_response_id"] == nil, json["conversation"] == nil else { throw GatewayFailure.invalidRequest }
            var responses = json
            if let text = responses["input"] as? String {
                responses["input"] = [["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]
            } else if let items = responses["input"] as? [[String: Any]] {
                responses["input"] = try items.map { item -> [String: Any] in
                    var value = item
                    if value["type"] == nil, value["role"] is String { value["type"] = "message" }
                    guard ["message", "function_call", "function_call_output", "reasoning"].contains(value["type"] as? String ?? "") else {
                        throw GatewayFailure.invalidRequest
                    }
                    return value
                }
            }
            try validateResponsesTools(responses["tools"] as? [[String: Any]] ?? [])
            var chat = CodexProxyTransform.responsesToChatRequest(responses, registry: &registry)
            carryParameters(json, into: &chat)
            chat["task_difficulty"] = json["task_difficulty"]
            return Request(wire: .responses, chat: chat, registry: registry, stream: stream)
        }
        guard json["messages"] is [[String: Any]] else { throw GatewayFailure.invalidRequest }
        // Hosted tools may incur separate fees; the Auto pool only delegates
        // client-executed function tools, never paid web/image services.
        if json["functions"] != nil { throw GatewayFailure.invalidRequest }
        if let tools = json["tools"] as? [[String: Any]], tools.contains(where: { $0["type"] as? String != "function" }) {
            throw GatewayFailure.invalidRequest
        }
        return Request(wire: .chat, chat: json, registry: registry, stream: stream)
    }

    private static func validateResponsesTools(_ tools: [[String: Any]], depth: Int = 0) throws {
        guard depth < 8 else { throw GatewayFailure.invalidRequest }
        for tool in tools {
            switch tool["type"] as? String {
            case "function", "custom": break
            case "namespace":
                try validateResponsesTools(tool["tools"] as? [[String: Any]] ?? tool["children"] as? [[String: Any]] ?? [], depth: depth + 1)
            default: throw GatewayFailure.invalidRequest
            }
        }
    }

    private static func carryParameters(_ responses: [String: Any], into chat: inout [String: Any]) {
        if let max = responses["max_output_tokens"] { chat["max_tokens"] = max }
        for key in ["temperature", "top_p", "parallel_tool_calls"] {
            if let value = responses[key] { chat[key] = value }
        }
        if var choice = chat["tool_choice"] as? [String: Any],
           choice["type"] as? String == "function", let name = choice.removeValue(forKey: "name") {
            choice["function"] = ["name": name]; chat["tool_choice"] = choice
        }
        if var format = (responses["text"] as? [String: Any])?["format"] as? [String: Any] {
            let type = format["type"] as? String ?? "text"
            if type == "json_schema" { format.removeValue(forKey: "type"); chat["response_format"] = ["type": type, "json_schema": format] }
            else if type == "json_object" { chat["response_format"] = ["type": type] }
        }
    }

    /// Only normalize the server's error codes; raw response bodies may contain
    /// credentials, request excerpts or account identifiers and are never logged.
    static func status(_ error: Error) -> Int {
        if let failure = error as? GatewayFailure { return failure.status }
        if error is CancellationError || error is NWError || (error as? URLError)?.code == .cancelled { return 0 }
        if error is AgentProtocolBridge.Failure { return 400 }
        if (error as? URLError)?.code == .timedOut { return 504 }
        return 502
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value, value.utf8.count <= 128 else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return min(3600, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: value) else { return nil }
        return min(3600, max(0, date.timeIntervalSince(now)))
    }

    static func validateChunk(_ value: [String: Any]) throws {
        guard let choices = value["choices"] as? [[String: Any]] else { throw GatewayFailure.upstream(502) }
        if choices.isEmpty {
            guard value["usage"] is [String: Any] else { throw GatewayFailure.upstream(502) }
        } else {
            guard choices.count == 1, let first = choices.first,
                  (first["index"] as? Int ?? 0) == 0,
                  first["delta"] is [String: Any] || first["finish_reason"] is String else {
                throw GatewayFailure.upstream(502)
            }
        }
    }
}

/// Incremental SSE framing bounds memory before a newline arrives, including
/// ignored fields/comments. Each input byte is visited once; no growing scans.
struct GatewaySSEDecoder {
    static let maxEventBytes = 1024 * 1024
    private var line = [UInt8]()
    private var event = Data()
    private var hasData = false
    private var carriageReturn = false
    private var firstLine = true
    private var totalBytes = 0

    mutating func append(_ byte: UInt8) throws -> Data? {
        totalBytes += 1
        guard totalBytes <= AgentProtocolBridge.maxBytes else { throw GatewayFailure.upstream(502) }
        if byte == 10, carriageReturn { carriageReturn = false; return nil }
        carriageReturn = byte == 13
        if byte == 10 || byte == 13 { return try finishLine() }
        guard line.count < Self.maxEventBytes else { throw GatewayFailure.upstream(502) }
        line.append(byte)
        return nil
    }
    private mutating func finishLine() throws -> Data? {
        defer { line.removeAll(keepingCapacity: true); firstLine = false }
        if firstLine, line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        if line.isEmpty {
            guard hasData else { return nil }
            let result = event
            event = Data(); hasData = false
            return result
        }
        guard line.starts(with: [100, 97, 116, 97]), line.count == 4 || line[4] == 58 else { return nil }
        var offset = min(5, line.count)
        if offset < line.count, line[offset] == 32 { offset += 1 }
        guard event.count + line.count - offset + (hasData ? 1 : 0) <= Self.maxEventBytes else { throw GatewayFailure.upstream(502) }
        if hasData { event.append(10) }
        event.append(contentsOf: line[offset...]); hasData = true
        return nil
    }
}

/// One attempt owns both clocks. A trickle of SSE comments cannot extend the
/// first-output deadline; accepted output only disarms that clock, not total time.
final class GatewayDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var expired = false
    private var firstOutput = false
    private var stopped = false
    private var timers: [Task<Void, Never>] = []
    private let onTotalTimeout: @Sendable () -> Void

    init(firstOutput: TimeInterval, total: TimeInterval, onTotalTimeout: @escaping @Sendable () -> Void = {}) {
        self.onTotalTimeout = onTotalTimeout
        timers = [(firstOutput, true), (total, false)].map { seconds, first in
            Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0.001, seconds))) } catch { return }
                self?.expire(first: first)
            }
        }
    }
    func attach(_ task: URLSessionTask) {
        lock.lock(); self.task = task; let cancel = expired; lock.unlock()
        if cancel { task.cancel() }
    }
    func receivedOutput() { lock.lock(); firstOutput = true; lock.unlock() }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    func stop() {
        lock.lock(); stopped = true; task = nil; lock.unlock()
        timers.forEach { $0.cancel() }
    }
    private func expire(first: Bool) {
        lock.lock()
        guard !stopped, !first || (!firstOutput && !expired) else { lock.unlock(); return }
        expired = true; let task = task; lock.unlock()
        task?.cancel()
        if !first { onTotalTimeout() }
    }
    deinit { timers.forEach { $0.cancel() } }
}
