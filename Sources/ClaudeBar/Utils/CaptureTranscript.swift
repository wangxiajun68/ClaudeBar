import Foundation

/// Pull chat turns out of a captured Anthropic / Chat / Responses body.
/// `.conversation` strips agent scaffolding; `.full` renders the request body as-is.
enum CaptureTranscript {
    enum ParseMode {
        case conversation
        case full
    }

    struct Turn: Equatable {
        var role: String
        var text: String
        var name: String = ""
        var images: [CaptureMedia.EmbeddedImage] = []
    }

    struct ToolCall: Equatable, Identifiable {
        var id: String
        var name: String
        var arguments: String
        var output: String = ""
    }

    // MARK: - Conversation

    static func turns(from raw: String?, mode: ParseMode = .conversation, mediaDir: URL? = nil) -> [Turn] {
        guard let raw, !raw.isEmpty else { return [] }
        guard let obj = object(raw) else {
            return mode == .full ? [Turn(role: "request", text: raw)] : []
        }
        var out: [Turn] = []
        if mode == .full {
            appendRootFields(obj, into: &out)
        } else if let system = obj["system"] {
            appendContent(system, role: "system", mode: mode, mediaDir: mediaDir, into: &out)
        } else if let instructions = obj["instructions"] as? String, !instructions.isEmpty {
            let text = stripScaffolding(instructions)
            if !text.isEmpty { out.append(Turn(role: "system", text: text, name: "instructions")) }
        }
        if let messages = obj["messages"] as? [[String: Any]] {
            for m in messages { appendMessage(m, mode: mode, mediaDir: mediaDir, into: &out) }
        } else if let input = obj["input"] as? [Any] {
            for item in input { appendInput(item, mode: mode, mediaDir: mediaDir, into: &out) }
        } else if let prompt = obj["prompt"] as? String {
            emitText(prompt, role: "user", mode: mode, into: &out)
        }
        if mode == .full, raw.contains("[truncated]"), out.isEmpty == false {
            out.append(Turn(role: "request",
                            text: "请求体超过 \(CaptureMedia.payloadCapLabel) 已截断，部分内容可能缺失。"))
        }
        if mode == .conversation { compactConversation(&out) }
        return out
    }

    /// This request's assistant reply (not the history sitting in `messages`).
    static func replyTurns(
        responseJSON: String?,
        live: CaptureLive?,
        streaming: Bool,
        mode: ParseMode = .conversation
    ) -> [Turn] {
        if streaming {
            return turns(fromLive: live)
        }
        let fromLive = turns(fromLive: live)
        if !fromLive.isEmpty { return fromLive }
        return turns(fromResponse: responseJSON, mode: mode)
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
                let parsed = toolCallFields(c)
                upsert(id: parsed.id, name: parsed.name, arguments: parsed.arguments)
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

    private static func turns(fromResponse raw: String?, mode: ParseMode) -> [Turn] {
        guard let raw, !raw.isEmpty else { return [] }
        guard let obj = object(raw) else {
            return mode == .full ? [Turn(role: "response", text: raw)] : []
        }
        var out: [Turn] = []
        if let message = obj["message"] as? [String: Any] {
            appendMessage(message, mode: mode, mediaDir: nil, into: &out)
        } else if let choices = obj["choices"] as? [[String: Any]] {
            for c in choices {
                if let m = c["message"] as? [String: Any] {
                    appendMessage(m, mode: mode, mediaDir: nil, into: &out)
                }
            }
        } else if let output = obj["output"] as? [Any] {
            for item in output { appendInput(item, mode: mode, mediaDir: nil, into: &out) }
        }
        if mode == .full, out.isEmpty {
            out.append(Turn(role: "response", text: stringifyJSON(obj)))
        }
        return out
    }

    private static func appendRootFields(_ obj: [String: Any], into out: inout [Turn]) {
        if let system = obj["system"] {
            appendContent(system, role: "system", mode: .full, mediaDir: nil, into: &out)
        }
        if let instructions = obj["instructions"] as? String, !instructions.isEmpty {
            out.append(Turn(role: "system", text: instructions, name: "instructions"))
        }
        if let tools = obj["tools"] as? [Any], !tools.isEmpty {
            out.append(Turn(role: "tools", text: stringifyJSON(tools)))
        }
    }

    private static func appendMessage(_ m: [String: Any], mode: ParseMode, mediaDir: URL?, into out: inout [Turn]) {
        let role = (m["role"] as? String) ?? ""
        if role == "tool" {
            out.append(Turn(
                role: "tool",
                text: stringifyLeaf(m["content"]),
                name: (m["tool_call_id"] as? String) ?? (m["name"] as? String) ?? ""))
            return
        }
        if let r = m["reasoning"] as? String, !r.isEmpty {
            out.append(Turn(role: "thinking", text: r))
        }
        if let r = m["reasoning_content"] as? String, !r.isEmpty {
            out.append(Turn(role: "thinking", text: r))
        }
        appendContent(m["content"], role: role.isEmpty ? "user" : role, mode: mode, mediaDir: mediaDir, into: &out)
        if let calls = m["tool_calls"] as? [[String: Any]] {
            for c in calls {
                let parsed = toolCallFields(c)
                out.append(Turn(role: "tool", text: parsed.arguments, name: parsed.name))
            }
        }
    }

    private static func appendInput(_ item: Any, mode: ParseMode, mediaDir: URL?, into out: inout [Turn]) {
        guard let d = item as? [String: Any] else { return }
        let type = (d["type"] as? String) ?? ""
        if type == "function_call" {
            out.append(Turn(
                role: "tool",
                text: stringifyJSON(d["arguments"]),
                name: (d["name"] as? String) ?? ""))
            return
        }
        if type == "function_call_output" {
            out.append(Turn(
                role: "tool",
                text: stringifyLeaf(d["output"]),
                name: (d["call_id"] as? String) ?? (d["id"] as? String) ?? ""))
            return
        }
        let role = (d["role"] as? String) ?? ""
        if !type.isEmpty, d["content"] == nil, d["text"] == nil {
            let text = stringifyJSON(d)
            if !text.isEmpty {
                out.append(Turn(role: role.isEmpty ? type : role, text: text))
            }
            return
        }
        appendContent(d["content"] ?? d["text"], role: role.isEmpty ? "user" : role, mode: mode, mediaDir: mediaDir, into: &out)
    }

    /// Emit each content block in document order. Grouping text then tools
    /// used to scramble Anthropic assistant turns (text / tool_use / text).
    private static func appendContent(_ any: Any?, role: String, mode: ParseMode, mediaDir: URL?, into out: inout [Turn]) {
        if any == nil || any is NSNull { return }
        if let s = any as? String {
            emitText(s, role: role, mode: mode, into: &out)
            return
        }
        guard let parts = any as? [[String: Any]] else {
            if mode == .full {
                let text = stringifyJSON(any)
                if !text.isEmpty { out.append(Turn(role: role, text: text)) }
            }
            return
        }
        for p in parts {
            emitPart(p, role: role, mode: mode, mediaDir: mediaDir, into: &out)
        }
    }

    private static func emitPart(_ p: [String: Any], role: String, mode: ParseMode, mediaDir: URL?, into out: inout [Turn]) {
        let type = (p["type"] as? String) ?? ""
        switch type {
        case "thinking", "reasoning", "redacted_thinking":
            let t = (p["thinking"] as? String) ?? (p["text"] as? String)
                ?? (mode == .full ? stringifyJSON(p) : "")
            if !t.isEmpty { out.append(Turn(role: "thinking", text: t)) }
        case "tool_use":
            out.append(Turn(
                role: "tool",
                text: stringifyJSON(p["input"]),
                name: (p["name"] as? String) ?? ""))
        case "tool_result", "function_call_output":
            if let parts = (p["content"] ?? p["output"]) as? [[String: Any]] {
                for part in parts {
                    emitPart(part, role: "tool", mode: mode, mediaDir: mediaDir, into: &out)
                }
            } else {
                out.append(Turn(
                    role: "tool",
                    text: stringifyLeaf(p["content"] ?? p["output"]),
                    name: (p["tool_use_id"] as? String)
                        ?? (p["call_id"] as? String)
                        ?? (p["id"] as? String)
                        ?? ""))
            }
        case "image", "image_url", "input_image":
            if let img = CaptureMedia.image(from: p, mediaDir: mediaDir) {
                out.append(Turn(role: role, text: "", name: "image", images: [img]))
            } else {
                out.append(Turn(role: role, text: "[image]", name: "image"))
            }
        case "document", "file":
            if let img = CaptureMedia.image(from: p, mediaDir: mediaDir) {
                out.append(Turn(role: role, text: "", name: type, images: [img]))
            } else {
                out.append(Turn(
                    role: role,
                    text: mode == .full ? stringifyJSON(p) : "[document]",
                    name: type))
            }
        case "text", "input_text", "output_text", "":
            if let t = p["text"] as? String {
                emitText(t, role: role, mode: mode, into: &out)
            } else if mode == .full {
                out.append(Turn(role: "block", text: stringifyJSON(p), name: type.isEmpty ? "part" : type))
            }
        default:
            if let t = p["text"] as? String {
                emitText(t, role: role, mode: mode, into: &out)
            } else if mode == .full {
                out.append(Turn(role: "block", text: stringifyJSON(p), name: type))
            }
        }
    }

    private static func emitText(_ raw: String, role: String, mode: ParseMode, into out: inout [Turn]) {
        let text = mode == .full ? raw : stripScaffolding(raw)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if mode == .conversation, role == "user", isNoiseUser(trimmed) { return }
        out.append(Turn(role: role, text: mode == .full ? raw : trimmed))
    }

    /// Chat Completions nest name/arguments under `function`; Anthropic / our
    /// assembler keep them at the top level.
    private static func toolCallFields(_ c: [String: Any]) -> (id: String, name: String, arguments: String) {
        let fn = c["function"] as? [String: Any]
        return (
            id: (c["id"] as? String) ?? "",
            name: (fn?["name"] as? String) ?? (c["name"] as? String) ?? "",
            arguments: stringifyJSON(fn?["arguments"] ?? c["arguments"])
        )
    }

    private static func collectTools(
        from obj: [String: Any]?,
        upsert: (String, String, String) -> Void,
        setOutput: (String, String) -> Void
    ) {
        guard let obj else { return }
        if let messages = obj["messages"] as? [[String: Any]] {
            for m in messages {
                collectContentTools(m["content"], upsert: upsert, setOutput: setOutput)
                if let calls = m["tool_calls"] as? [[String: Any]] {
                    for c in calls {
                        let parsed = toolCallFields(c)
                        upsert(parsed.id, parsed.name, parsed.arguments)
                    }
                }
                if (m["role"] as? String) == "tool" {
                    setOutput(
                        (m["tool_call_id"] as? String) ?? "",
                        stringifyLeaf(m["content"]))
                }
            }
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
                    let parsed = toolCallFields(c)
                    upsert(parsed.id, parsed.name, parsed.arguments)
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
        if any == nil || any is NSNull { return "" }
        if let s = any as? String { return s }
        if let parts = any as? [[String: Any]] {
            let texts = parts.compactMap { p -> String? in
                if let t = p["text"] as? String { return t }
                if let t = p["thinking"] as? String { return t }
                return nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
            return stringifyJSON(any)
        }
        return stringifyJSON(any)
    }

    private static func compactConversation(_ out: inout [Turn]) {
        for i in out.indices {
            out[i].text = clipRole(out[i].text, role: out[i].role)
        }
    }

    private static func clipRole(_ text: String, role: String) -> String {
        let cap: Int
        switch role {
        case "tool", "function": cap = 480
        case "system", "developer", "tools": cap = 4_000
        case "thinking": cap = 8_000
        default: cap = 20_000
        }
        if text.count <= cap { return text }
        return String(text.prefix(cap)) + "\n… 已省略 \(text.count - cap) 字"
    }

    private static func stringifyJSON(_ any: Any?) -> String {
        guard let any else { return "" }
        if let s = any as? String { return s }
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}
