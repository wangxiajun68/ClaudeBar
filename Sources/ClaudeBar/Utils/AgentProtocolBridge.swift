import Foundation

/// Anthropic Messages ↔ OpenAI Responses wire adapter. No I/O or credentials.
/// New model reasoning is not fabricated into Anthropic signed thinking.
enum AgentProtocolBridge {
    enum Failure: Error { case unsupported, malformed, tooLarge, incomplete }
    static let maxBytes = 16 * 1024 * 1024

    static func string(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    static func blocks(_ value: Any?) throws -> [[String: Any]] {
        if let text = value as? String { return [["type": "text", "text": text]] }
        guard let list = value as? [[String: Any]] else { throw Failure.malformed }
        return list
    }

    static func image(_ block: [String: Any]) throws -> String {
        guard let source = block["source"] as? [String: Any] else { throw Failure.malformed }
        if source["type"] as? String == "base64", let mime = source["media_type"] as? String,
           ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mime),
           let encoded = source["data"] as? String, encoded.utf8.count < maxBytes,
           let bytes = Data(base64Encoded: encoded), !bytes.isEmpty {
            return "data:" + mime + ";base64," + encoded
        }
        if source["type"] as? String == "url", let raw = source["url"] as? String,
           let url = URL(string: raw), ["https", "http"].contains(url.scheme) { return raw }
        throw Failure.unsupported
    }

    static func request(_ body: [String: Any], model: String) throws -> [String: Any] {
        guard let messages = body["messages"] as? [[String: Any]], messages.count <= 8000,
              let maximum = body["max_tokens"] as? Int, maximum > 0, maximum <= 200_000 else { throw Failure.malformed }
        if let stops = body["stop_sequences"] as? [String], !stops.isEmpty { throw Failure.unsupported }
        var instructions: [String] = []
        if let system = body["system"] {
            let parts = try blocks(system)
            guard parts.allSatisfy({ $0["type"] as? String == "text" && $0["text"] is String }) else { throw Failure.unsupported }
            instructions.append(parts.compactMap { $0["text"] as? String }.joined(separator:"\n"))
        }
        var input: [[String: Any]] = []
        for message in messages {
            guard let role = message["role"] as? String else { throw Failure.malformed }
            if role == "system" || role == "developer" {
                // CC 2.1.288 also emits runtime system messages in the list for
                // a custom host. Preserve their instruction priority.
                let parts = try blocks(message["content"])
                guard parts.allSatisfy({ $0["type"] as? String == "text" && $0["text"] is String }) else { throw Failure.unsupported }
                instructions.append(parts.compactMap { $0["text"] as? String }.joined(separator:"\n"))
                continue
            }
            guard ["user", "assistant"].contains(role) else { throw Failure.malformed }
            var textBlocks: [[String: Any]] = []
            func flush() {
                if !textBlocks.isEmpty { input.append(["type": "message", "role": role, "content": textBlocks]); textBlocks = [] }
            }
            for block in try blocks(message["content"]) {
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String else { throw Failure.malformed }
                    textBlocks.append(["type": role == "user" ? "input_text" : "output_text", "text": text])
                case "image":
                    guard role == "user" else { throw Failure.unsupported }
                    textBlocks.append(["type": "input_image", "image_url": try image(block)])
                case "tool_use":
                    guard role == "assistant", let id = block["id"] as? String, !id.isEmpty,
                          let name = block["name"] as? String, let arguments = block["input"] as? [String: Any] else { throw Failure.malformed }
                    flush(); input.append(["type": "function_call", "call_id": id, "name": name, "arguments": try string(arguments)])
                case "tool_result":
                    guard role == "user", let id = block["tool_use_id"] as? String, !id.isEmpty else { throw Failure.malformed }
                    flush()
                    var result = "", images: [[String: Any]] = []
                    for output in try blocks(block["content"] ?? "") {
                        switch output["type"] as? String {
                        case "text": result += (output["text"] as? String ?? "") + "\n"
                        case "image": images.append(["type": "input_image", "image_url": try image(output)])
                        default: throw Failure.unsupported
                        }
                    }
                    input.append(["type": "function_call_output", "call_id": id,
                                  "output": try string(["content": result, "is_error": block["is_error"] as? Bool ?? false])])
                    if !images.isEmpty { input.append(["type": "message", "role": "user", "content": images]) }
                case "thinking", "redacted_thinking":
                    continue // Foreign signatures cannot authenticate another model.
                default: throw Failure.unsupported
                }
            }
            flush()
        }
        var out: [String: Any] = ["model": model, "input": input, "store": false, "stream": true, "max_output_tokens": maximum]
        if !instructions.isEmpty { out["instructions"] = instructions.joined(separator:"\n") }
        if let tools = body["tools"] as? [[String: Any]], !tools.isEmpty {
            guard tools.count <= 1024 else { throw Failure.tooLarge }
            out["tools"] = try tools.map { tool -> [String: Any] in
                guard let name = tool["name"] as? String, !name.isEmpty, name.utf8.count <= 64,
                      name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                      let schema = tool["input_schema"] as? [String: Any] else { throw Failure.unsupported }
                return ["type": "function", "name": name, "description": tool["description"] as? String ?? "", "parameters": schema, "strict": false]
            }
        }
        if let choice = body["tool_choice"] as? [String: Any] {
            switch choice["type"] as? String {
            case "auto": out["tool_choice"] = "auto"
            case "any": out["tool_choice"] = "required"
            case "none": out["tool_choice"] = "none"
            case "tool":
                guard let name = choice["name"] as? String else { throw Failure.malformed }
                out["tool_choice"] = ["type": "function", "name": name]
            default: throw Failure.unsupported
            }
            if let disabled = choice["disable_parallel_tool_use"] as? Bool { out["parallel_tool_calls"] = !disabled }
        }
        for key in ["temperature", "top_p"] { if let value = body[key] as? NSNumber { out[key] = value } }
        _ = try string(out)
        return out
    }

    static func usage(_ raw: [String: Any]) -> [String: Int] {
        let input = max(0, (raw["input_tokens"] as? Int) ?? 0)
        let cached = min(input, max(0, (raw["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0))
        return ["input_tokens": input - cached, "cache_read_input_tokens": cached,
                "cache_creation_input_tokens": 0, "output_tokens": max(0, (raw["output_tokens"] as? Int) ?? 0)]
    }

    struct Stream {
        struct Block {
            var index: Int
            var kind: String
            var buffer = ""
            var closed = false
        }
        let model: String
        var started = false, terminal = false, hasTool = false
        var content: [Int: Block] = [:]
        var byteCount = 0

        mutating func begin(_ response: [String: Any] = [:]) -> [[String: Any]] {
            guard !started else { return [] }; started = true
            return [["type": "message_start", "message": ["id": "msg_bridge_" + UUID().uuidString.lowercased(),
                "type": "message", "role": "assistant", "model": model, "content": [Any](),
                "stop_reason": NSNull(), "stop_sequence": NSNull(), "usage": AgentProtocolBridge.usage(response["usage"] as? [String: Any] ?? [:])]]]
        }

        mutating func open(_ slot: Int, item: [String: Any]) throws -> [[String: Any]] {
            if content[slot] != nil { return [] }
            guard content.count < 1024 else { throw Failure.tooLarge }
            let type = item["type"] as? String ?? "message", index = content.count
            let block: [String: Any]
            if type == "function_call" {
                guard let id = item["call_id"] as? String, !id.isEmpty, let name = item["name"] as? String else { throw Failure.malformed }
                hasTool = true
                block = ["type": "tool_use", "id": id, "name": name, "input": [String: Any]()]
            } else if type == "message" { block = ["type": "text", "text": ""] }
            else if type == "reasoning" { return [] }
            else { throw Failure.unsupported }
            content[slot] = .init(index: index, kind: type)
            return [["type": "content_block_start", "index": index, "content_block": block]]
        }

        mutating func delta(_ slot: Int, value: String) throws -> [[String: Any]] {
            guard var block = content[slot], !block.closed else { throw Failure.malformed }
            byteCount += value.utf8.count; guard byteCount <= AgentProtocolBridge.maxBytes else { throw Failure.tooLarge }
            block.buffer += value; content[slot] = block
            return [["type": "content_block_delta", "index": block.index, "delta": block.kind == "function_call"
                ? ["type": "input_json_delta", "partial_json": value] : ["type": "text_delta", "text": value]]]
        }

        mutating func close(_ slot: Int) throws -> [[String: Any]] {
            guard var block = content[slot], !block.closed else { return [] }
            if block.kind == "function_call" {
                guard let data = block.buffer.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw Failure.malformed }
            }
            block.closed = true; content[slot] = block
            return [["type": "content_block_stop", "index": block.index]]
        }

        mutating func apply(_ event: [String: Any]) throws -> [[String: Any]] {
            guard !terminal else { throw Failure.malformed }
            let type = event["type"] as? String ?? ""
            var out: [[String: Any]] = []
            switch type {
            case "response.created", "response.in_progress":
                out += begin(event["response"] as? [String: Any] ?? [:])
            case "response.output_item.added":
                guard let slot = event["output_index"] as? Int, let item = event["item"] as? [String: Any] else { throw Failure.malformed }
                out += begin(); out += try open(slot, item: item)
            case "response.output_text.delta":
                guard let slot = event["output_index"] as? Int, let value = event["delta"] as? String else { throw Failure.malformed }
                out += begin(); out += try open(slot, item: ["type": "message"]); out += try delta(slot, value: value)
            case "response.function_call_arguments.delta":
                guard let slot = event["output_index"] as? Int, let value = event["delta"] as? String else { throw Failure.malformed }
                out += try delta(slot, value: value)
            case "response.output_item.done":
                guard let slot = event["output_index"] as? Int, let item = event["item"] as? [String: Any] else { throw Failure.malformed }
                out += begin(); out += try finishItem(slot, item: item)
            case "response.completed", "response.incomplete":
                guard let response = event["response"] as? [String: Any] else { throw Failure.malformed }
                out += begin(response)
                for (slot, item) in (response["output"] as? [[String: Any]] ?? []).enumerated() { out += try finishItem(slot, item: item) }
                for slot in content.keys.sorted() { out += try close(slot) }
                let incomplete = type == "response.incomplete"
                if incomplete, (response["incomplete_details"] as? [String: Any])?["reason"] as? String != "max_output_tokens" { throw Failure.incomplete }
                let reason = incomplete ? "max_tokens" : (hasTool ? "tool_use" : "end_turn")
                out.append(["type": "message_delta", "delta": ["stop_reason": reason, "stop_sequence": NSNull()],
                            "usage": AgentProtocolBridge.usage(response["usage"] as? [String: Any] ?? [:])])
                out.append(["type": "message_stop"]); terminal = true
            case "response.failed", "error": throw Failure.incomplete
            default: break
            }
            return out
        }

        mutating func finishItem(_ slot: Int, item: [String: Any]) throws -> [[String: Any]] {
            if item["type"] as? String == "reasoning" { return [] }
            if content[slot]?.closed == true { return [] }
            var out = try open(slot, item: item)
            if content[slot]?.buffer.isEmpty == true {
                let value: String
                if item["type"] as? String == "function_call" { value = item["arguments"] as? String ?? "{}" }
                else { value = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined() }
                if !value.isEmpty { out += try delta(slot, value: value) }
            }
            out += try close(slot); return out
        }
    }

    static func sse(_ event: [String: Any]) throws -> Data {
        Data(("event: " + (event["type"] as? String ?? "error") + "\ndata: " + (try string(event)) + "\n\n").utf8)
    }

    static func message(_ response: [String: Any], model: String) throws -> [String: Any] {
        guard response["status"] as? String == "completed" || response["status"] == nil else { throw Failure.incomplete }
        var blocks: [[String: Any]] = []
        for item in response["output"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "message":
                let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
            case "function_call":
                guard let id = item["call_id"] as? String, let name = item["name"] as? String,
                      let arguments = item["arguments"] as? String, let data = arguments.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.malformed }
                blocks.append(["type": "tool_use", "id": id, "name": name, "input": object])
            case "reasoning": break
            default: throw Failure.unsupported
            }
        }
        return ["id": "msg_bridge_" + UUID().uuidString.lowercased(), "type": "message", "role": "assistant", "model": model,
                "content": blocks, "stop_reason": blocks.contains(where: { $0["type"] as? String == "tool_use" }) ? "tool_use" : "end_turn",
                "stop_sequence": NSNull(), "usage": usage(response["usage"] as? [String: Any] ?? [:])]
    }

    /// Chat has no response.completed envelope. Finish only after a declared
    /// finish_reason; EOF without one is an upstream interruption.
    struct ChatStream {
        var stream: Stream
        var reason: String?
        var totals: [String: Any] = [:]
        var calls: [Int: (id: String, name: String, arguments: String)] = [:]
        var argumentBytes = 0

        mutating func apply(_ chunk: [String: Any]) throws -> [[String: Any]] {
            if let usage = chunk["usage"] as? [String: Any] {
                totals = ["input_tokens": usage["prompt_tokens"] ?? 0, "output_tokens": usage["completion_tokens"] ?? 0,
                          "input_tokens_details": usage["prompt_tokens_details"] ?? ["cached_tokens": usage["prompt_cache_hit_tokens"] ?? 0]]
            }
            guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return [] }
            if let finish = choice["finish_reason"] as? String { reason = finish }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            var events = stream.begin()
            if let text = delta["content"] as? String, !text.isEmpty {
                events += try stream.open(0, item: ["type": "message"])
                events += try stream.delta(0, value: text)
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                guard let index = call["index"] as? Int, (0..<1024).contains(index) else { throw Failure.malformed }
                let function = call["function"] as? [String: Any] ?? [:]
                var value = calls[index] ?? (id: "", name: "", arguments: "")
                if let id = call["id"] as? String, id != value.id {
                    value.id = id.hasPrefix(value.id) ? id : value.id + id
                }
                if let name = function["name"] as? String, name != value.name {
                    value.name = name.hasPrefix(value.name) ? name : value.name + name
                }
                if let arguments = function["arguments"] as? String {
                    argumentBytes += arguments.utf8.count
                    guard argumentBytes + stream.byteCount <= AgentProtocolBridge.maxBytes else { throw Failure.tooLarge }
                    value.arguments += arguments
                }
                calls[index] = value
            }
            return events
        }

        mutating func finish() throws -> [[String: Any]] {
            guard let reason, ["stop", "tool_calls", "length"].contains(reason) else { throw Failure.incomplete }
            var events: [[String: Any]] = []
            // Chat permits fragmented function names as well as arguments.
            // Buffer these calls until finish; normal text remains live streamed.
            for (slot, call) in calls.sorted(by: { $0.key < $1.key }) {
                guard !call.id.isEmpty, !call.name.isEmpty else { throw Failure.malformed }
                events += try stream.open(slot + 1, item: ["type":"function_call","call_id":call.id,"name":call.name])
                events += try stream.delta(slot + 1, value: call.arguments)
            }
            events += try stream.apply(["type": reason == "length" ? "response.incomplete" : "response.completed",
                "response": ["output": [Any](), "usage": totals, "incomplete_details": ["reason": "max_output_tokens"]]])
            return events
        }
    }

    /// Accumulate the converted stream only when the client asked for JSON.
    struct MessageAccumulator {
        var message: [String: Any] = [:]
        var content: [Int: [String: Any]] = [:]
        var buffers: [Int: String] = [:]
        var complete = false
        mutating func apply(_ event: [String: Any]) throws {
            switch event["type"] as? String {
            case "message_start": message = event["message"] as? [String: Any] ?? [:]
            case "content_block_start":
                guard let i = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { throw Failure.malformed }
                content[i] = block; buffers[i] = ""
            case "content_block_delta":
                guard let i = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { throw Failure.malformed }
                buffers[i, default: ""] += delta["text"] as? String ?? delta["partial_json"] as? String ?? ""
            case "content_block_stop":
                guard let i = event["index"] as? Int, var block = content[i] else { throw Failure.malformed }
                if block["type"] as? String == "tool_use" {
                    guard let bytes = buffers[i]?.data(using: .utf8), let input = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.malformed }
                    block["input"] = input
                } else { block["text"] = buffers[i] ?? "" }
                content[i] = block
            case "message_delta":
                for (key, value) in event["delta"] as? [String: Any] ?? [:] { message[key] = value }
                if let usage = event["usage"] { message["usage"] = usage }
            case "message_stop": complete = true
            default: break
            }
        }
        func result() throws -> [String: Any] {
            guard complete, !message.isEmpty else { throw Failure.incomplete }
            var result = message; result["content"] = content.keys.sorted().compactMap { content[$0] }; return result
        }
    }

}
