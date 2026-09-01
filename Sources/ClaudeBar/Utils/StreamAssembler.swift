import Foundation

/// Incremental SSE parser. Callers feed complete lines (no trailing LF);
/// a blank line flushes one event. Handles both OpenAI (`data:` only) and
/// Anthropic (`event:` + `data:`) framing.
struct LineSSEParser {
    struct Event {
        var name: String
        var data: String
        var json: [String: Any]?
        var done: Bool
    }

    private var event = ""
    private var dataLines: [String] = []

    mutating func push(line: String) -> Event? {
        if line.isEmpty { return flush() }
        if line.hasPrefix("event:") {
            event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            dataLines.append(payload)
        }
        return nil
    }

    mutating func finish() -> Event? { flush() }

    private mutating func flush() -> Event? {
        defer {
            event = ""
            dataLines = []
        }
        let data = dataLines.joined()
        guard !data.isEmpty else { return nil }
        if data == "[DONE]" { return Event(name: event, data: data, json: nil, done: true) }
        let json = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any]
        return Event(name: event, data: data, json: json, done: false)
    }
}

/// Assembled assistant payload used by the Traffic page (content / thinking /
/// tools / usage). Protocol-specific `apply` methods share this buffer.
struct CaptureAssembler {
    var content = ""
    var reasoning = ""
    var model = ""
    var id = ""
    var finish = ""
    var promptTokens: Int?
    var completionTokens: Int?
    var cacheReadTokens: Int?
    var tools: [Tool] = []

    struct Tool: Equatable {
        var id: String
        var name: String
        var arguments: String
    }

    var snapshot: [Tool] { tools }

    mutating func applyChat(_ parsed: [String: Any]) {
        if let m = parsed["model"] as? String, !m.isEmpty { model = m }
        if let i = parsed["id"] as? String, !i.isEmpty { id = i }
        if let usage = parsed["usage"] as? [String: Any] { ingestChatUsage(usage) }

        let choice = (parsed["choices"] as? [[String: Any]])?.first ?? [:]
        if let reason = choice["finish_reason"] as? String { finish = reason }
        let delta = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any]) ?? [:]
        if let c = delta["content"] as? String { content += c }
        if let r = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) {
            reasoning += r
        }
        for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
            upsertTool(tc)
        }
    }

    mutating func applyResponses(_ parsed: [String: Any]) {
        let type = (parsed["type"] as? String) ?? ""
        if let resp = parsed["response"] as? [String: Any] {
            if let m = resp["model"] as? String, !m.isEmpty { model = m }
            if let i = resp["id"] as? String, !i.isEmpty { id = i }
            if let usage = resp["usage"] as? [String: Any] { ingestResponsesUsage(usage) }
        }
        if type.hasSuffix("output_text.delta") {
            if let d = parsed["delta"] as? String { content += d }
        } else if type.contains("reasoning") && type.hasSuffix(".delta") {
            if let d = parsed["delta"] as? String { reasoning += d }
        } else if type == "response.function_call_arguments.delta" {
            let itemID = (parsed["item_id"] as? String) ?? ""
            let delta = (parsed["delta"] as? String) ?? ""
            if let idx = tools.firstIndex(where: { $0.id == itemID }) {
                tools[idx].arguments += delta
            } else if !itemID.isEmpty {
                tools.append(Tool(id: itemID, name: "", arguments: delta))
            }
        } else if type == "response.output_item.added",
                  let item = parsed["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call" {
            let itemID = (item["id"] as? String) ?? UUID().uuidString
            let name = (item["name"] as? String) ?? ""
            if let idx = tools.firstIndex(where: { $0.id == itemID }) {
                if !name.isEmpty { tools[idx].name = name }
            } else {
                tools.append(Tool(id: itemID, name: name, arguments: (item["arguments"] as? String) ?? ""))
            }
        } else if type == "response.completed" {
            if let resp = parsed["response"] as? [String: Any],
               let usage = resp["usage"] as? [String: Any] {
                ingestResponsesUsage(usage)
            }
        }
    }

    mutating func applyAnthropic(event: String, json: [String: Any]) {
        let type = event.isEmpty ? ((json["type"] as? String) ?? "") : event
        switch type {
        case "message_start":
            if let msg = json["message"] as? [String: Any] {
                id = (msg["id"] as? String) ?? id
                model = (msg["model"] as? String) ?? model
                if let usage = msg["usage"] as? [String: Any] { ingestAnthropicUsage(usage) }
            }
        case "content_block_start":
            if let block = json["content_block"] as? [String: Any],
               (block["type"] as? String) == "tool_use" {
                let tid = (block["id"] as? String) ?? UUID().uuidString
                let name = (block["name"] as? String) ?? ""
                tools.append(Tool(id: tid, name: name, arguments: ""))
            }
        case "content_block_delta":
            let delta = json["delta"] as? [String: Any] ?? [:]
            let dtype = (delta["type"] as? String) ?? ""
            if dtype == "text_delta", let t = delta["text"] as? String { content += t }
            if dtype == "thinking_delta", let t = delta["thinking"] as? String { reasoning += t }
            if dtype == "input_json_delta", let t = delta["partial_json"] as? String {
                if !tools.isEmpty { tools[tools.count - 1].arguments += t }
            }
        case "message_delta":
            if let usage = json["usage"] as? [String: Any] { ingestAnthropicUsage(usage) }
            if let delta = json["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                finish = reason
            }
        default:
            break
        }
    }

    func toResponseJSON() -> String {
        var message: [String: Any] = [
            "role": "assistant",
            "content": content,
        ]
        if !reasoning.isEmpty { message["reasoning"] = reasoning }
        if !tools.isEmpty {
            message["tool_calls"] = tools.map {
                ["id": $0.id, "name": $0.name, "arguments": $0.arguments]
            }
        }
        let obj: [String: Any] = [
            "id": id,
            "model": model,
            "finish_reason": finish,
            "message": message,
            "usage": [
                "prompt_tokens": promptTokens as Any,
                "completion_tokens": completionTokens as Any,
                "cache_read_tokens": cacheReadTokens as Any,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text.replacingOccurrences(of: "\\/", with: "/")
    }

    private mutating func upsertTool(_ tc: [String: Any]) {
        let index = (tc["index"] as? NSNumber)?.intValue ?? tools.count
        let fn = tc["function"] as? [String: Any] ?? [:]
        let tid = (tc["id"] as? String) ?? ""
        let name = (fn["name"] as? String) ?? ""
        let args = (fn["arguments"] as? String) ?? ""
        while tools.count <= index {
            tools.append(Tool(id: "", name: "", arguments: ""))
        }
        if !tid.isEmpty { tools[index].id = tid }
        if !name.isEmpty { tools[index].name += name }
        if !args.isEmpty { tools[index].arguments += args }
    }

    private mutating func ingestChatUsage(_ usage: [String: Any]) {
        promptTokens = intVal(usage["prompt_tokens"]) ?? promptTokens
        completionTokens = intVal(usage["completion_tokens"]) ?? completionTokens
        if let details = usage["prompt_tokens_details"] as? [String: Any] {
            cacheReadTokens = intVal(details["cached_tokens"]) ?? cacheReadTokens
        }
    }

    private mutating func ingestResponsesUsage(_ usage: [String: Any]) {
        promptTokens = intVal(usage["input_tokens"]) ?? intVal(usage["prompt_tokens"]) ?? promptTokens
        completionTokens = intVal(usage["output_tokens"]) ?? intVal(usage["completion_tokens"]) ?? completionTokens
        if let details = usage["input_tokens_details"] as? [String: Any] {
            cacheReadTokens = intVal(details["cached_tokens"]) ?? cacheReadTokens
        }
    }

    private mutating func ingestAnthropicUsage(_ usage: [String: Any]) {
        promptTokens = intVal(usage["input_tokens"]) ?? promptTokens
        completionTokens = intVal(usage["output_tokens"]) ?? completionTokens
        cacheReadTokens = intVal(usage["cache_read_input_tokens"]) ?? cacheReadTokens
    }

    private func intVal(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        return nil
    }
}
