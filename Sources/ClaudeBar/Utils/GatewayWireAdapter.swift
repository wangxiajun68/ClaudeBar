import Foundation
import Network

enum GatewayWireAdapter {
    enum Wire { case chat, responses, anthropic }
    enum Operation: String, CaseIterable {
        case images = "images/generations", speech = "audio/speech", embeddings, rerank
        var capability: GatewayMediaCapability {
            switch self {
            case .images: return .imageGeneration
            case .speech: return .speechSynthesis
            case .embeddings: return .embeddings
            case .rerank: return .rerank
            }
        }
    }
    struct Request {
        var wire: Wire
        var chat: [String: Any]
        var registry: CodexProxyTransform.ToolRegistry
        var stream: Bool
        var operation: Operation? = nil
        var requirementsBody: [String: Any]? = nil
    }

    static func supports(path: String) -> Bool {
        ["chat/completions", "responses", "messages", "messages/count_tokens"].contains { path == "/v1/" + $0 || path == "/" + $0 }
            || Operation.allCases.contains { path == "/v1/" + $0.rawValue || path == "/" + $0.rawValue }
    }

    static func request(_ json: [String: Any], path: String) throws -> Request {
        var registry = CodexProxyTransform.ToolRegistry()
        if let operation = Operation.allCases.first(where: { path == "/v1/" + $0.rawValue || path == "/" + $0.rawValue }) {
            return try nativeRequest(json, operation: operation)
        }
        let stream = json["stream"] as? Bool ?? false
        guard (json["n"] as? Int ?? 1) == 1, json["web_search_options"] == nil else { throw GatewayFailure.invalidRequest }
        let chatWire = path.hasSuffix("/chat/completions")
        if !chatWire {
            guard json["audio"] == nil, (json["modalities"] as? [String] ?? ["text"]).allSatisfy({ $0 == "text" }) else { throw GatewayFailure.invalidRequest }
        } else if (json["modalities"] as? [String] ?? []).contains("audio") {
            guard let audio = json["audio"] as? [String: Any], let voice = audio["voice"] as? String,
                  !voice.isEmpty, voice.utf8.count <= 100, let format = audio["format"] as? String,
                  GatewayMediaValidation.audioFormats.contains(format) else { throw GatewayFailure.invalidRequest }
        } else if json["audio"] != nil { throw GatewayFailure.invalidRequest }
        if path.hasSuffix("/messages") {
            var responses = try AgentProtocolBridge.request(json, model: "auto", allowDocuments: true)
            responses["input"] = try (responses["input"] as? [[String: Any]] ?? []).map { item in
                var value = item
                if let parts = value["content"] as? [[String: Any]] { value["content"] = try parts.map(normalizeResponsePart) }
                return value
            }
            var chat = CodexProxyTransform.responsesToChatRequest(responses, registry: &registry, allowMedia: true)
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
                    if value["type"] as? String == "message" {
                        if let parts = value["content"] as? [[String: Any]] { value["content"] = try parts.map(normalizeResponsePart) }
                        else if !(value["content"] is String) { throw GatewayFailure.invalidRequest }
                    }
                    if value["type"] as? String == "function_call_output", let parts = value["output"] as? [[String: Any]] {
                        guard parts.allSatisfy({ ["text", "input_text", "output_text", "input_image", "image_url"].contains($0["type"] as? String ?? "") }) else {
                            throw GatewayFailure.invalidRequest
                        }
                    }
                    return value
                }
            } else { throw GatewayFailure.invalidRequest }
            try validateResponsesTools(responses["tools"] as? [[String: Any]] ?? [])
            var chat = CodexProxyTransform.responsesToChatRequest(responses, registry: &registry, allowMedia: true)
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

    private static func nativeRequest(_ body: [String: Any], operation: Operation) throws -> Request {
        guard (body["stream"] as? Bool ?? false) == false, body["stream_format"] == nil else { throw GatewayFailure.invalidRequest }
        let text: String
        switch operation {
        case .images:
            guard let prompt = body["prompt"] as? String, !prompt.isEmpty, (body["n"] as? Int ?? 1) == 1 else { throw GatewayFailure.invalidRequest }
            text = prompt
        case .speech:
            guard let input = body["input"] as? String, !input.isEmpty, let voice = body["voice"] as? String, !voice.isEmpty,
                  ["mp3", "opus", "aac", "flac", "wav", "pcm"].contains(body["response_format"] as? String ?? "mp3") else { throw GatewayFailure.invalidRequest }
            text = input
        case .embeddings:
            if let input = body["input"] as? String, !input.isEmpty { text = input }
            else if let inputs = body["input"] as? [String], !inputs.isEmpty, inputs.count <= 2048, inputs.allSatisfy({ !$0.isEmpty }) { text = inputs.joined(separator: "\n") }
            else { throw GatewayFailure.invalidRequest }
            guard ["float", "base64"].contains(body["encoding_format"] as? String ?? "float") else { throw GatewayFailure.invalidRequest }
        case .rerank:
            guard let query = body["query"] as? String, !query.isEmpty,
                  let documents = body["documents"] as? [String], !documents.isEmpty, documents.count <= 2048 else { throw GatewayFailure.invalidRequest }
            text = query + "\n" + documents.joined(separator: "\n")
        }
        guard text.utf8.count <= 1024 * 1024 else { throw GatewayFailure.invalidRequest }
        var requirements: [String: Any] = ["messages": [["role": "user", "content": text]], "max_tokens": 1]
        requirements["task_difficulty"] = body["task_difficulty"]
        if operation == .embeddings, body["task_difficulty"] == nil { requirements["task_difficulty"] = "medium" }
        return Request(wire: .chat, chat: body, registry: .init(), stream: false, operation: operation, requirementsBody: requirements)
    }

    static func validateNativeResponse(_ value: [String: Any], operation: Operation) throws {
        guard value["error"] == nil else { throw GatewayFailure.upstream(502) }
        switch operation {
        case .images:
            guard let rows = value["data"] as? [[String: Any]], !rows.isEmpty,
                  rows.allSatisfy({ ($0["b64_json"] as? String)?.isEmpty == false || ($0["url"] as? String)?.isEmpty == false }) else { throw GatewayFailure.upstream(502) }
        case .embeddings:
            guard let rows = value["data"] as? [[String: Any]], !rows.isEmpty,
                  rows.allSatisfy({ ($0["embedding"] as? [Double])?.isEmpty == false || ($0["embedding"] as? String)?.isEmpty == false }) else { throw GatewayFailure.upstream(502) }
        case .rerank:
            guard let rows = value["results"] as? [[String: Any]], rows.allSatisfy({ $0["index"] is Int && $0["relevance_score"] is NSNumber }) else { throw GatewayFailure.upstream(502) }
        case .speech: throw GatewayFailure.upstream(502)
        }
    }

    private static func normalizeResponsePart(_ part: [String: Any]) throws -> [String: Any] {
        switch part["type"] as? String {
        case "input_text", "output_text", "text", "refusal": return part
        case "input_image":
            try GatewayMediaValidation.resource(part["image_url"], kind: "image")
            return part
        case "input_audio": return part
        case "input_video":
            guard let url = part["video_url"] as? String else { throw GatewayFailure.invalidRequest }
            var output: [String: Any] = ["type": "video_url", "video_url": ["url": url]]
            if let processing = part["processing"] { output["processing"] = processing }
            return output
        case "input_file":
            guard part["file_id"] == nil, let data = part["file_data"] ?? part["file_url"] else { throw GatewayFailure.invalidRequest }
            return ["type": "file", "file": ["filename": part["filename"] as? String ?? "document.pdf", "file_data": data]]
        default: throw GatewayFailure.invalidRequest
        }
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
    var eventLimit = Self.maxEventBytes
    var totalLimit = AgentProtocolBridge.maxBytes
    private var line = [UInt8]()
    private var event = Data()
    private var hasData = false
    private var carriageReturn = false
    private var firstLine = true
    private var totalBytes = 0

    mutating func append(_ byte: UInt8) throws -> Data? {
        totalBytes += 1
        guard totalBytes <= totalLimit else { throw GatewayFailure.upstream(502) }
        if byte == 10, carriageReturn { carriageReturn = false; return nil }
        carriageReturn = byte == 13
        if byte == 10 || byte == 13 { return try finishLine() }
        guard line.count < eventLimit else { throw GatewayFailure.upstream(502) }
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
        guard event.count + line.count - offset + (hasData ? 1 : 0) <= eventLimit else { throw GatewayFailure.upstream(502) }
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
