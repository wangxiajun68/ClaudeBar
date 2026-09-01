import Foundation

/// Pull the actual chat turns out of a captured Anthropic / Chat / Responses
/// body. Claude Code and Codex wrap the user's text in scaffolding
/// (`system-reminder`, agent catalogs, `<environment_context>`, token
/// counters) — those are not conversation.
enum CaptureTranscript {
    struct Turn: Equatable {
        var role: String
        var text: String
        var name: String = ""
    }

    struct ToolCall: Equatable, Identifiable {
        var id: String
        var name: String
        var arguments: String
        var output: String = ""
    }

    // MARK: - Conversation

    static func turns(from raw: String?) -> [Turn] {
        guard let obj = object(raw) else { return [] }
        var out: [Turn] = []
        if let messages = obj["messages"] as? [[String: Any]] {
            for m in messages { appendMessage(m, into: &out) }
        } else if let input = obj["input"] as? [Any] {
            for item in input { appendInput(item, into: &out) }
        } else if let prompt = obj["prompt"] as? String {
            let text = stripScaffolding(prompt)
            if !isNoiseUser(text) { out.append(Turn(role: "user", text: text)) }
        }
        return out
    }

    /// This request's assistant reply (not the history sitting in `messages`).
    static func replyTurns(responseJSON: String?, live: CaptureLive?, streaming: Bool) -> [Turn] {
        if streaming {
            return turns(fromLive: live)
        }
        let fromLive = turns(fromLive: live)
        if !fromLive.isEmpty { return fromLive }
        return turns(fromResponse: responseJSON)
    }

    static func preview(from raw: String?) -> String {
        if let user = turns(from: raw).last(where: { $0.role == "user" }) {
            return clip(user.text)
        }
        return "(no messages)"
    }

    static func clip(_ text: String, cap: Int = 160) -> String {
        let folded = text
            .split(whereSeparator: { $0.isNewline || $0 == "\r" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if folded.count <= cap { return folded }
        return String(folded.prefix(cap)) + "…"
    }

    // MARK: - Tools (invocations, not the 30+ schema dump)

    static func toolCalls(request: String?, response: String?) -> [ToolCall] {
        var map: [String: ToolCall] = [:]
        var order: [String] = []

        func upsert(id: String, name: String, arguments: String) {
            let key = id.isEmpty ? "anon-\(order.count)" : id
            if map[key] == nil { order.append(key) }
            var row = map[key] ?? ToolCall(id: key, name: name, arguments: arguments)
            if !name.isEmpty { row.name = name }
            if !arguments.isEmpty { row.arguments = arguments }
            map[key] = row
        }
        func setOutput(id: String, text: String) {
            let key = id.isEmpty ? (order.last ?? "anon-\(order.count)") : id
            if map[key] == nil {
                order.append(key)
                map[key] = ToolCall(id: key, name: "", arguments: "")
            }
            var row = map[key] ?? ToolCall(id: key, name: "", arguments: "")
            row.output = text
            map[key] = row
        }

        collectTools(from: object(request), upsert: upsert, setOutput: setOutput)
        collectTools(from: object(response), upsert: upsert, setOutput: setOutput)
        if let resp = object(response),
           let message = resp["message"] as? [String: Any],
           let calls = message["tool_calls"] as? [[String: Any]] {
            for c in calls {
                upsert(
                    id: (c["id"] as? String) ?? "",
                    name: (c["name"] as? String) ?? "",
                    arguments: stringifyJSON(c["arguments"]) )
            }
        }
        return order.compactMap { map[$0] }
    }

    static func mergingLive(_ calls: [ToolCall], live: [CaptureAssembler.Tool]) -> [ToolCall] {
        guard !live.isEmpty else { return calls }
        var out = calls
        for t in live {
            if let idx = out.firstIndex(where: { $0.id == t.id && !t.id.isEmpty }) {
                if !t.name.isEmpty { out[idx].name = t.name }
                if !t.arguments.isEmpty { out[idx].arguments = t.arguments }
            } else {
                out.append(ToolCall(id: t.id, name: t.name, arguments: t.arguments))
            }
        }
        return out
    }

    static func declaredToolCount(from raw: String?) -> Int {
        guard let obj = object(raw) else { return 0 }
        return (obj["tools"] as? [Any])?.count ?? 0
    }

    // MARK: - Internals

    private static func turns(fromLive live: CaptureLive?) -> [Turn] {
        guard let live else { return [] }
        var out: [Turn] = []
        if !live.reasoning.isEmpty { out.append(Turn(role: "thinking", text: live.reasoning)) }
        if !live.content.isEmpty { out.append(Turn(role: "assistant", text: live.content)) }
        for t in live.tools where !t.name.isEmpty || !t.arguments.isEmpty {
            out.append(Turn(role: "tool", text: t.arguments, name: t.name))
        }
        return out
    }

    private static func turns(fromResponse raw: String?) -> [Turn] {
        guard let obj = object(raw) else { return [] }
        var out: [Turn] = []
        if let message = obj["message"] as? [String: Any] {
            if let r = message["reasoning"] as? String, !r.isEmpty {
                out.append(Turn(role: "thinking", text: r))
            }
            let content = stringifyLeaf(message["content"])
            if !content.isEmpty { out.append(Turn(role: "assistant", text: content)) }
            if let calls = message["tool_calls"] as? [[String: Any]] {
                for c in calls {
                    out.append(Turn(
                        role: "tool",
                        text: stringifyJSON(c["arguments"]),
                        name: (c["name"] as? String) ?? ""))
                }
            }
        }
        return out
    }

    private static func appendMessage(_ m: [String: Any], into out: inout [Turn]) {
        let role = (m["role"] as? String) ?? ""
        if role == "system" || role == "developer" { return }
        if role == "tool" {
            // OpenAI tool-role rows are results; conversation skips them.
            return
        }
        appendContent(m["content"], role: role.isEmpty ? "user" : role, into: &out)
    }

    private static func appendInput(_ item: Any, into out: inout [Turn]) {
        guard let d = item as? [String: Any] else { return }
        let type = (d["type"] as? String) ?? ""
        if type == "function_call" {
            out.append(Turn(
                role: "tool",
                text: stringifyJSON(d["arguments"]),
                name: (d["name"] as? String) ?? ""))
            return
        }
        if type == "function_call_output" { return }
        let role = (d["role"] as? String) ?? ""
        if role == "system" || role == "developer" { return }
        appendContent(d["content"], role: role.isEmpty ? "user" : role, into: &out)
    }

    private static func appendContent(_ any: Any?, role: String, into out: inout [Turn]) {
        if let s = any as? String {
            emitText(s, role: role, into: &out)
            return
        }
        guard let parts = any as? [[String: Any]] else { return }
        var texts: [String] = []
        var thinking: [String] = []
        var tools: [Turn] = []
        for p in parts {
            let type = (p["type"] as? String) ?? ""
            switch type {
            case "thinking", "reasoning":
                if let t = (p["thinking"] as? String) ?? (p["text"] as? String), !t.isEmpty {
                    thinking.append(t)
                }
            case "tool_use":
                tools.append(Turn(
                    role: "tool",
                    text: stringifyJSON(p["input"]),
                    name: (p["name"] as? String) ?? ""))
            case "tool_result", "function_call_output":
                continue
            case "image", "image_url", "input_image":
                texts.append("[image]")
            case "text", "input_text", "output_text", "":
                if let t = p["text"] as? String { texts.append(t) }
            default:
                if let t = p["text"] as? String { texts.append(t) }
            }
        }
        for t in thinking where !t.isEmpty {
            out.append(Turn(role: "thinking", text: t))
        }
        emitText(texts.joined(separator: "\n"), role: role, into: &out)
        out.append(contentsOf: tools)
    }

    private static func emitText(_ raw: String, role: String, into out: inout [Turn]) {
        let text = stripScaffolding(raw)
        guard !text.isEmpty else { return }
        if role == "user" && isNoiseUser(text) { return }
        out.append(Turn(role: role, text: text))
    }

    private static func collectTools(
        from obj: [String: Any]?,
        upsert: (String, String, String) -> Void,
        setOutput: (String, String) -> Void
    ) {
        guard let obj else { return }
        if let messages = obj["messages"] as? [[String: Any]] {
            for m in messages { collectContentTools(m["content"], upsert: upsert, setOutput: setOutput) }
        }
        if let input = obj["input"] as? [Any] {
            for item in input {
                guard let d = item as? [String: Any] else { continue }
                let type = (d["type"] as? String) ?? ""
                if type == "function_call" {
                    upsert(
                        (d["call_id"] as? String) ?? (d["id"] as? String) ?? "",
                        (d["name"] as? String) ?? "",
                        stringifyJSON(d["arguments"]))
                } else if type == "function_call_output" {
                    setOutput(
                        (d["call_id"] as? String) ?? (d["id"] as? String) ?? "",
                        stringifyLeaf(d["output"]))
                } else {
                    collectContentTools(d["content"], upsert: upsert, setOutput: setOutput)
                }
            }
        }
        if let message = obj["message"] as? [String: Any] {
            collectContentTools(message["content"], upsert: upsert, setOutput: setOutput)
            if let calls = message["tool_calls"] as? [[String: Any]] {
                for c in calls {
                    upsert(
                        (c["id"] as? String) ?? "",
                        (c["name"] as? String) ?? "",
                        stringifyJSON(c["arguments"]))
                }
            }
        }
    }

    private static func collectContentTools(
        _ any: Any?,
        upsert: (String, String, String) -> Void,
        setOutput: (String, String) -> Void
    ) {
        guard let parts = any as? [[String: Any]] else { return }
        for p in parts {
            let type = (p["type"] as? String) ?? ""
            if type == "tool_use" {
                upsert(
                    (p["id"] as? String) ?? "",
                    (p["name"] as? String) ?? "",
                    stringifyJSON(p["input"]))
            } else if type == "tool_result" {
                setOutput(
                    (p["tool_use_id"] as? String) ?? (p["id"] as? String) ?? "",
                    stringifyLeaf(p["content"]))
            }
        }
    }

    // MARK: - Scaffolding

    static func stripScaffolding(_ s: String) -> String {
        var t = s
        t = stripTag(t, named: "system-reminder")
        t = stripTag(t, named: "environment_context")
        t = stripTag(t, named: "total_tokens")
        t = stripTag(t, named: "local-command-caveat")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTag(_ s: String, named tag: String) -> String {
        var out = s
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        while let a = out.range(of: open, options: .caseInsensitive),
              let b = out.range(of: close, options: .caseInsensitive, range: a.upperBound..<out.endIndex) {
            out.removeSubrange(a.lowerBound..<b.upperBound)
        }
        return out
    }

    private static func isNoiseUser(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        let lower = t.lowercased()
        if lower.hasPrefix("the user stepped away") { return true }
        if lower.hasPrefix("caveat:") { return true }
        if t.hasPrefix("<") && t.hasSuffix(">") && !t.contains("\n") && t.count < 120 {
            return true
        }
        return false
    }

    private static func object(_ raw: String?) -> [String: Any]? {
        guard let raw, !raw.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
    }

    private static func stringifyLeaf(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let parts = any as? [[String: Any]] {
            return parts.compactMap { p -> String? in
                if let t = p["text"] as? String { return t }
                return nil
            }.joined(separator: "\n")
        }
        return stringifyJSON(any)
    }

    private static func stringifyJSON(_ any: Any?) -> String {
        guard let any else { return "" }
        if let s = any as? String { return s }
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s.replacingOccurrences(of: "\\/", with: "/")
    }
}
