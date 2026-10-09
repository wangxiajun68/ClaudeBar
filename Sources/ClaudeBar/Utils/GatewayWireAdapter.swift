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
        return 502
    }
}
