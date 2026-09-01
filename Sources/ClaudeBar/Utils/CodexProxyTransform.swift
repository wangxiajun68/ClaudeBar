import CryptoKit
import Foundation

/// Pure protocol transforms for the Codex local routing proxy (fix for
/// openai/codex#23186). No I/O — every function takes/returns
/// JSONSerialization-native types and the caller owns the parsed body.
///
/// Request side: Codex's proprietary tool shapes (`type:"namespace"` MCP
/// wrappers, `additional_tools` input items, `custom`/`web_search`/`tool_search`
/// tools) are rewritten into plain function tools; replayed namespaced /
/// custom / bridged calls in history are flattened the same way.
/// Response side: flat function names are split back into `{namespace, name}`
/// (Responses-native upstreams) or a full Responses SSE stream is synthesized
/// from Chat deltas (Chat upstreams).
enum CodexProxyTransform {

    // MARK: - Tool registry

    /// flatName → (namespace, originalName). Rebuilt from the request body on
    /// every request (tools[] + additional_tools), so there is no cross-request
    /// session state to synchronize.
    struct ToolRegistry: @unchecked Sendable {
        private(set) var map: [String: (ns: String, name: String)] = [:]
        private(set) var customNames: Set<String> = []

        mutating func register(flat: String, ns: String, name: String) {
            if map[flat] == nil { map[flat] = (ns, name) }
        }

        mutating func registerCustom(_ name: String) {
            customNames.insert(name)
        }

        mutating func merge(_ other: ToolRegistry) {
            for (k, v) in other.map where map[k] == nil { map[k] = v }
            customNames.formUnion(other.customNames)
        }

        /// nil = not a known flat MCP name → passthrough.
        func split(_ flat: String) -> (ns: String, name: String)? {
            map[flat]
        }

        /// cc-switch `flatten_namespace_tool_name`: `{namespace}__{name}`,
        /// truncated to 64 chars with a sha256 suffix when over the Chat
        /// tool-name limit. Namespace already ending in `__` produces a
        /// double underscore (e.g. `mcp__files____read`) — Codex restores
        /// via `{namespace, name}` so the exact flat spelling only has to
        /// be consistent between flatten and restore.
        static func flatten(ns: String, child: String) -> String {
            let full = "\(ns)__\(child)"
            if full.utf8.count <= chatToolNameMaxLen { return full }
            let hash = SHA256.hash(data: Data(full.utf8))
                .prefix(4)
                .map { String(format: "%02x", $0) }
                .joined()
            let suffix = "__\(hash)"
            let budget = chatToolNameMaxLen - suffix.utf8.count
            var prefix = ""
            for ch in full {
                let next = String(ch)
                if prefix.utf8.count + next.utf8.count > budget { break }
                prefix += next
            }
            return prefix + suffix
        }

        /// Kept as a synonym so existing call sites read as "qualify".
        static func qualify(ns: String, child: String) -> String { flatten(ns: ns, child: child) }
    }

    private static let chatToolNameMaxLen = 64

    // MARK: - Request: Codex → upstream (Responses dialect)

    /// Hosts whose `/v1/responses` is a thin OpenAI-shaped wrapper over Chat
    /// Completions. They accept a first-turn `input[]` of `message` items, then
    /// 400 on turn 2 when Codex replays `function_call` / `function_call_output`
    /// (`untagged enum ResponseInput`). cc-switch's Chat path and Codex++'s
    /// `protocol_proxy` convert that history to Chat `tool_calls` + `role:tool`
    /// instead of forwarding it as Responses.
    ///
    /// Official OpenAI and xAI implement the real Responses item enum and must
    /// stay on the native path (xAI has its own sanitizer in cc-switch).
    static func shouldBridgeToChat(baseURL: String, wireAPI: String, model: String) -> Bool {
        if wireAPI == "chat" { return true }
        let host = baseURL.lowercased()
        if host.contains("api.openai.com") || host.contains("api.x.ai") { return false }
        let chatHosts = [
            "aibox", "richaibox", "bigmodel.cn", "deepseek.com", "moonshot",
            "kimi.com", "siliconflow", "volces.com", "dashscope", "minimax",
            "anthropic.com",
        ]
        if chatHosts.contains(where: { host.contains($0) }) { return true }
        let m = model.lowercased()
        if m.contains("glm") || m.hasPrefix("deepseek") || m.hasPrefix("kimi")
            || m.hasPrefix("qwen") || m.hasPrefix("doubao") || m.contains("moonshot") {
            return true
        }
        return false
    }

    /// Upstream 400 whose serde path is `input: … untagged enum ResponseInput`.
    /// That is the Responses-lite failure on replayed tool history; retrying
    /// via Chat Completions is what Codex++ does for third-party models.
    static func isResponseInputReject(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text.contains("ResponseInput")
            || text.contains("json_parse_error")
            || text.contains("did not match any variant")
    }

    /// Rewrite a `/v1/responses` body for a Responses-native upstream.
    ///
    /// cc-switch's native path only flattens `namespace` tools and namespaced
    /// `function_call` items — it does **not** mutate valid ResponseInput
    /// variants in place. Mutating `custom_tool_call` / `web_search_call` into
    /// `function_call` while leaving leftover fields makes serde's untagged
    /// `ResponseInput` fail (`input: data did not match any variant`).
    static func rewriteRequestBody(_ body: [String: Any], wireAPI: String,
                                   registry: inout ToolRegistry) -> [String: Any] {
        var out = body
        flattenResponsesTools(&out, registry: &registry)
        sanitizeResponsesInput(&out, registry: &registry)
        if let choice = out["tool_choice"] as? [String: Any],
           choice["type"] as? String == "namespace" {
            out["tool_choice"] = "auto"
        }
        return out
    }

    /// tools[]: lift namespace children to clean function tools; convert
    /// freeform `custom` (apply_patch) to function; drop hosted tools that
    /// strict gateways reject (`web_search`, `image_generation`, …).
    private static func flattenResponsesTools(_ body: inout [String: Any],
                                              registry: inout ToolRegistry) {
        var flatTools: [[String: Any]] = []
        var seen = Set<String>()
        func appendClean(_ t: [String: Any]) {
            guard let name = t["name"] as? String, !name.isEmpty, !seen.contains(name) else { return }
            seen.insert(name)
            flatTools.append(t)
        }
        for tool in body["tools"] as? [[String: Any]] ?? [] {
            switch tool["type"] as? String {
            case "namespace":
                let ns = (tool["name"] as? String) ?? ""
                let children = (tool["tools"] as? [[String: Any]])
                    ?? (tool["children"] as? [[String: Any]])
                    ?? []
                for child in children {
                    guard let childName = child["name"] as? String, !childName.isEmpty else { continue }
                    let flat = ToolRegistry.flatten(ns: ns, child: childName)
                    registry.register(flat: flat, ns: ns, name: childName)
                    appendClean(cleanFunctionTool(child, name: flat))
                }
            case "function":
                if let name = tool["name"] as? String {
                    appendClean(cleanFunctionTool(tool, name: name))
                }
            case "custom":
                guard let name = tool["name"] as? String else { break }
                registry.registerCustom(name)
                appendClean(customToolAsFunction(tool, name: name))
            case "tool_search":
                appendClean(cleanFunctionTool([
                    "name": "tool_search",
                    "description": "Search and load Codex tools, plugins, connectors, and MCP namespaces for the current task.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": ["type": "string"],
                            "limit": ["type": "integer"],
                        ],
                        "required": ["query"],
                    ],
                ], name: "tool_search"))
            default:
                break
            }
        }
        body["tools"] = flatTools
    }

    private static func cleanFunctionTool(_ tool: [String: Any], name: String) -> [String: Any] {
        var out: [String: Any] = [
            "type": "function",
            "name": name,
            "parameters": tool["parameters"] ?? ["type": "object", "properties": [:]],
        ]
        if let desc = tool["description"] as? String { out["description"] = desc }
        if let strict = tool["strict"] { out["strict"] = strict }
        return out
    }

    private static func customToolAsFunction(_ tool: [String: Any], name: String) -> [String: Any] {
        var desc = (tool["description"] as? String) ?? ""
        if let format = tool["format"] as? [String: Any],
           let grammar = format["definition"] as? String {
            desc += "\n\nGrammar:\n\(grammar)"
        }
        return [
            "type": "function",
            "name": name,
            "description": desc,
            "strict": false,
            "parameters": [
                "type": "object",
                "properties": ["input": ["type": "string", "description": desc]],
                "required": ["input"],
            ],
        ]
    }

    // MARK: - Tool-output image hoist

    /// Chat Completions (and most Responses-lite Relays) treat `role:tool` /
    /// `function_call_output.output` as a string. Codex `view_image` returns
    /// `{type:input_image, image_url: data:…}` in that slot; JSON-stringifying
    /// it sends megabytes of base64 as text tokens and the model never sees
    /// pixels. Industry fix (LiteLLM hoist, OpenAI Chat 400 on tool images):
    /// keep a short placeholder in the tool output and attach the image to
    /// the following `role:user` message, where vision actually works.
    private static let toolImagePlaceholder =
        "[Tool returned an image — see the following user message]"

    private static let dataImageRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\n\r]+"#)
    }()

    private struct ExtractedImage {
        var url: String
        var detail: String?
    }

    /// After a run of consecutive `function_call_output` items: stringify
    /// their output (lite-safe) and, if any contained images, append one
    /// user message carrying every extracted `input_image`. Preserves
    /// tool-call adjacency — the user image turn comes *after* the whole
    /// tool-output run, never between two outputs of the same turn.
    private static func hoistImagesOutOfToolOutputs(_ input: [Any]) -> [Any] {
        var out: [Any] = []
        var pending: [ExtractedImage] = []
        func flush() {
            guard !pending.isEmpty else { return }
            out.append(canonicalMessage([
                "role": "user",
                "content": pending.map { responsesImagePart($0) },
            ]))
            pending.removeAll(keepingCapacity: true)
        }
        for item in input {
            guard var d = item as? [String: Any],
                  d["type"] as? String == "function_call_output" else {
                flush()
                out.append(item)
                continue
            }
            let split = splitToolOutput(d["output"])
            d["output"] = split.text
            out.append(d)
            pending.append(contentsOf: split.images)
        }
        flush()
        return out
    }

    private static func splitToolOutput(_ raw: Any?) -> (text: String, images: [ExtractedImage]) {
        var images: [ExtractedImage] = []
        var texts: [String] = []

        func walk(_ value: Any) {
            if let parts = value as? [[String: Any]] {
                for part in parts { walkPart(part) }
                return
            }
            if let arr = value as? [Any] {
                for el in arr { walk(el) }
                return
            }
            if let dict = value as? [String: Any] {
                walkPart(dict)
                return
            }
            if let s = value as? String {
                walkString(s)
            }
        }

        func walkPart(_ part: [String: Any]) {
            if let img = extractImage(from: part) {
                images.append(img)
                return
            }
            if let t = (part["text"] as? String)
                ?? (part["input_text"] as? String)
                ?? (part["output_text"] as? String) {
                walkString(t)
                return
            }
            for v in part.values { walk(v) }
        }

        func walkString(_ s: String) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") || trimmed.hasPrefix("{"),
               let data = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                let imgBefore = images.count
                let textBefore = texts.count
                walk(parsed)
                if images.count == imgBefore && texts.count == textBefore, !trimmed.isEmpty {
                    texts.append(trimmed)
                }
                return
            }
            let nsRange = NSRange(s.startIndex..<s.endIndex, in: s)
            let matches = dataImageRegex.matches(in: s, options: [], range: nsRange)
            if matches.isEmpty {
                if !s.isEmpty { texts.append(s) }
                return
            }
            for m in matches {
                guard let r = Range(m.range, in: s) else { continue }
                let url = String(s[r])
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\r", with: "")
                images.append(ExtractedImage(url: url, detail: nil))
            }
            var leftover = s
            for m in matches.reversed() {
                guard let r = Range(m.range, in: leftover) else { continue }
                leftover.removeSubrange(r)
            }
            let rest = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty && rest != "[]" && rest != "{}" {
                texts.append(rest)
            }
        }

        if let raw { walk(raw) }
        var text = texts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !images.isEmpty {
            if text.isEmpty {
                text = toolImagePlaceholder
            } else if !text.contains(toolImagePlaceholder) {
                text += "\n" + toolImagePlaceholder
            }
        }
        return (text, images)
    }

    private static func extractImage(from part: [String: Any]) -> ExtractedImage? {
        let type = part["type"] as? String
        let typed = type == "input_image" || type == "image_url" || type == "image"
        let url: String?
        if typed {
            url = imageURL(in: part) ?? (part["file_id"] as? String)
        } else if let u = imageURL(in: part), u.hasPrefix("data:image") {
            url = u
        } else {
            return nil
        }
        guard let url, !url.isEmpty else { return nil }
        let detail = (part["detail"] as? String)
            ?? (part["image_url"] as? [String: Any]).flatMap { $0["detail"] as? String }
        return ExtractedImage(url: url, detail: detail)
    }

    private static func imageURL(in part: [String: Any]) -> String? {
        if let s = part["image_url"] as? String { return s }
        if let obj = part["image_url"] as? [String: Any], let s = obj["url"] as? String { return s }
        if let src = part["source"] as? [String: Any] {
            if let data = src["data"] as? String,
               let media = src["media_type"] as? String, media.hasPrefix("image/") {
                return "data:\(media);base64,\(data)"
            }
            if let u = src["url"] as? String { return u }
        }
        return nil
    }

    private static func responsesImagePart(_ img: ExtractedImage) -> [String: Any] {
        var part: [String: Any] = ["type": "input_image", "image_url": img.url]
        if let detail = img.detail { part["detail"] = detail }
        return part
    }

    private static func chatImagePart(_ img: ExtractedImage) -> [String: Any] {
        var url: [String: Any] = ["url": img.url]
        if let detail = img.detail { url["detail"] = detail }
        return ["type": "image_url", "image_url": url]
    }

    /// Chat content: a plain string when there are no images (strict Relays
    /// reject array content on text-only turns); a part list when vision
    /// parts are present.
    private static func chatMessageContent(_ item: [String: Any]) -> Any {
        if let s = item["content"] as? String { return s }
        guard let arr = item["content"] as? [[String: Any]] else {
            if let content = item["content"] { return jsonString(content) }
            return ""
        }
        var parts: [[String: Any]] = []
        var textBuf: [String] = []
        func flushText() {
            let t = textBuf.joined(separator: "\n")
            textBuf.removeAll(keepingCapacity: true)
            if !t.isEmpty { parts.append(["type": "text", "text": t]) }
        }
        for part in arr {
            if let img = extractImage(from: part) {
                flushText()
                parts.append(chatImagePart(img))
            } else if let t = (part["text"] as? String)
                        ?? (part["input_text"] as? String)
                        ?? (part["refusal"] as? String) {
                textBuf.append(t)
            }
        }
        if parts.isEmpty { return textBuf.joined(separator: "\n") }
        flushText()
        return parts
    }

    /// Rebuild `input[]` as the intersection of shapes every strict
    /// Responses deserializer accepts:
    ///   message            {type, id, role, content: [input_text|output_text|input_image]}
    ///   function_call      {type, call_id, name, arguments}
    ///   function_call_output {type, call_id, output: string}
    ///   (+ a following user message when the output contained images)
    ///
    /// Nested unknown content-part tags (`text`, `refusal`, screenshot, …)
    /// fail a closed `ResponseContentPart` enum; serde then collapses the
    /// error to `input: … untagged enum ResponseInput` — which is the 400
    /// Aibox returns. Hosted items (reasoning, web_search_call, mcp_*, …)
    /// are dropped rather than forwarded.
    private static func sanitizeResponsesInput(_ body: inout [String: Any],
                                               registry: inout ToolRegistry) {
        guard var input = body["input"] as? [Any] else { return }
        var lifted: [[String: Any]] = []
        var pending: [[String: Any]] = []
        input = input.compactMap { item -> Any? in
            guard let d = item as? [String: Any] else {
                // Bare string easy-input: wrap as a user message.
                if let s = item as? String {
                    return canonicalMessage(["role": "user", "content": s])
                }
                return nil
            }
            switch d["type"] as? String {
            case "additional_tools":
                if let tools = d["tools"] as? [[String: Any]] { lifted.append(contentsOf: tools) }
                return nil
            case "function_call":
                return cleanFunctionCall(d, registry: &registry)
            case "custom_tool_call":
                return cleanFunctionCall(flattenCustomToolCall(d, registry: &registry),
                                         registry: &registry)
            case "custom_tool_call_output", "function_call_output":
                return cleanFunctionCallOutput(d)
            case "tool_search_call":
                return cleanFunctionCall(bridgedCall(d, name: "tool_search"), registry: &registry)
            case "tool_search_output":
                return cleanFunctionCallOutput(bridgedOutput(d, pendingSurfaced: &pending))
            case "message":
                return canonicalMessage(d)
            default:
                if d["role"] != nil, d["content"] != nil {
                    return canonicalMessage(d)
                }
                return nil
            }
        }
        for t in lifted { appendLiftedTool(t, into: &body, registry: &registry) }
        for t in pending { appendLiftedTool(t, into: &body, registry: &registry) }
        body["input"] = hoistImagesOutOfToolOutputs(input)
    }

    /// Always `{type: message, id, role, content: [parts]}`. Content is never
    /// a raw string (openai-protocol's Message variant requires a Vec of
    /// parts; a string 400s the whole untagged ResponseInput).
    private static func canonicalMessage(_ d: [String: Any]) -> [String: Any] {
        let role = (d["role"] as? String) ?? "user"
        // Always `input_text`: many Relays' input content-part enum has no
        // `output_text` variant, and Codex's replayed assistant `output_text`
        // is what 400s `ResponseInput`.
        let textType = "input_text"
        var parts: [[String: Any]] = []

        func appendText(_ raw: String) {
            guard !raw.isEmpty || parts.isEmpty else { return }
            var part: [String: Any] = ["type": textType, "text": raw]
            parts.append(part)
        }

        if let s = d["content"] as? String {
            appendText(s)
        } else if let arr = d["content"] as? [[String: Any]] {
            var buf = ""
            for part in arr {
                let t = part["type"] as? String
                if t == "input_image" || t == "image_url" {
                    if !buf.isEmpty { appendText(buf); buf = "" }
                    if let url = (part["image_url"] as? String)
                        ?? (part["image_url"] as? [String: Any]).flatMap({ $0["url"] as? String })
                        ?? (part["file_id"] as? String) {
                        var img: [String: Any] = ["type": "input_image", "image_url": url]
                        if let detail = part["detail"] as? String { img["detail"] = detail }
                        parts.append(img)
                    }
                    continue
                }
                if let text = (part["text"] as? String)
                    ?? (part["input_text"] as? String)
                    ?? (part["refusal"] as? String) {
                    if !buf.isEmpty { buf += "\n" }
                    buf += text
                }
            }
            if !buf.isEmpty || parts.isEmpty { appendText(buf) }
        } else if let content = d["content"] {
            appendText(jsonString(content))
        } else {
            appendText("")
        }

        var out: [String: Any] = [
            "type": "message",
            "id": (d["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            "role": role,
            "content": parts,
        ]
        return out
    }

    private static func cleanFunctionCall(_ d: [String: Any], registry: inout ToolRegistry) -> [String: Any] {
        var name = (d["name"] as? String) ?? ""
        if let ns = d["namespace"] as? String, !ns.isEmpty, !name.isEmpty {
            let orig = name
            name = ToolRegistry.flatten(ns: ns, child: orig)
            registry.register(flat: name, ns: ns, name: orig)
        }
        let arguments: String
        if let s = d["arguments"] as? String {
            arguments = s
        } else if let args = d["arguments"], !(args is NSNull) {
            arguments = jsonString(args)
        } else {
            arguments = "{}"
        }
        var out: [String: Any] = [
            "type": "function_call",
            "name": name,
            "arguments": arguments,
            "call_id": (d["call_id"] as? String)
                ?? (d["id"] as? String)
                ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
        ]
        // Real Responses deserializers (OpenAI / xAI) require `id` on replayed
        // function_call items; stripping it is what Responses-lite gateways
        // never see because we bridge those to Chat instead.
        if let id = d["id"] as? String, !id.isEmpty { out["id"] = id }
        if let status = d["status"] as? String, !status.isEmpty { out["status"] = status }
        return out
    }

    private static func cleanFunctionCallOutput(_ d: [String: Any]) -> [String: Any] {
        // Leave structured image output intact; `hoistImagesOutOfToolOutputs`
        // turns it into a string placeholder + following user message.
        let output: Any
        if let obj = d["output"], !(obj is NSNull) {
            output = obj
        } else {
            output = ""
        }
        var out: [String: Any] = [
            "type": "function_call_output",
            "call_id": (d["call_id"] as? String)
                ?? (d["id"] as? String)
                ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            "output": output,
        ]
        if let id = d["id"] as? String, !id.isEmpty { out["id"] = id }
        if let status = d["status"] as? String, !status.isEmpty { out["status"] = status }
        return out
    }

    /// Shared tool/input normalization (used by both dialects — the Chat
    /// converter calls this first, then maps messages).
    static func rewriteToolsAndInput(_ body: inout [String: Any], registry: inout ToolRegistry) {
        var pendingSurfaced: [[String: Any]] = []
        rewriteToolsAndInput(&body, registry: &registry, pendingSurfaced: &pendingSurfaced)
    }

    private static func rewriteToolsAndInput(_ body: inout [String: Any],
                                             registry: inout ToolRegistry,
                                             pendingSurfaced: inout [[String: Any]]) {
        // --- tools[] ---
        var flatTools: [[String: Any]] = []
        var seen = Set<String>()
        func appendTool(_ t: [String: Any]) {
            guard let name = t["name"] as? String else { return }
            guard !seen.contains(name) else { return }
            seen.insert(name)
            flatTools.append(t)
        }

        for tool in body["tools"] as? [[String: Any]] ?? [] {
            switch tool["type"] as? String {
            case "namespace":
                let ns = (tool["name"] as? String) ?? ""
                let children = (tool["tools"] as? [[String: Any]])
                    ?? (tool["children"] as? [[String: Any]])
                    ?? []
                for child in children {
                    guard let childName = child["name"] as? String, !childName.isEmpty else { continue }
                    var f = child
                    f["type"] = "function"
                    f["name"] = ToolRegistry.flatten(ns: ns, child: childName)
                    f.removeValue(forKey: "defer_loading")
                    f.removeValue(forKey: "output_schema")
                    if f["parameters"] == nil { f["parameters"] = ["type": "object", "properties": [:]] }
                    registry.register(flat: f["name"] as! String, ns: ns, name: childName)
                    appendTool(f)
                }
            case "function":
                appendTool(tool)
            case "custom":
                // Freeform tool (apply_patch) → function with a single string arg.
                guard let name = tool["name"] as? String else { break }
                registry.registerCustom(name)
                var desc = (tool["description"] as? String) ?? ""
                if let format = tool["format"] as? [String: Any],
                   let grammar = format["definition"] as? String {
                    desc += "\n\nGrammar:\n\(grammar)"
                }
                appendTool([
                    "type": "function",
                    "name": name,
                    "description": desc,
                    "strict": false,
                    "parameters": [
                        "type": "object",
                        "properties": ["input": ["type": "string", "description": desc]],
                        "required": ["input"],
                    ],
                ])
            case "tool_search":
                // cc-switch keeps tool_search as a callable function so the
                // model can still load deferred MCP namespaces.
                appendTool([
                    "type": "function",
                    "name": "tool_search",
                    "description": "Search and load Codex tools, plugins, connectors, and MCP namespaces for the current task.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": ["type": "string", "description": "Search query for tools or connectors to load."],
                            "limit": ["type": "integer", "description": "Maximum number of tool groups to return."],
                        ],
                        "required": ["query"],
                    ],
                ])
            default:
                break // web_search / web_search_preview / image_generation / …: dropped
            }
        }
        body["tools"] = flatTools

        if let choice = body["tool_choice"] as? [String: Any],
           choice["type"] as? String == "namespace" {
            body["tool_choice"] = "auto"
        }

        // --- input[] ---
        if var input = body["input"] as? [Any] {
            var lifted: [[String: Any]] = []
            input = input.compactMap { item -> Any? in
                guard var d = item as? [String: Any] else { return item }
                switch d["type"] as? String {
                case "additional_tools":
                    if let tools = d["tools"] as? [[String: Any]] {
                        lifted.append(contentsOf: tools)
                    }
                    return nil
                case "function_call":
                    flattenFunctionCall(&d, registry: &registry)
                    ensureReplayIDs(&d)
                    return d
                case "custom_tool_call":
                    var c = flattenCustomToolCall(d, registry: &registry)
                    ensureReplayIDs(&c)
                    return c
                case "custom_tool_call_output":
                    var o = d
                    o["type"] = "function_call_output"
                    ensureReplayIDs(&o)
                    return o
                case "tool_search_call":
                    var t = bridgedCall(d, name: "tool_search")
                    ensureReplayIDs(&t)
                    return t
                case "web_search_call":
                    var w = bridgedCall(d, name: "web_search")
                    ensureReplayIDs(&w)
                    return w
                case "tool_search_output":
                    return bridgedOutput(d, pendingSurfaced: &pendingSurfaced)
                case "function_call_output":
                    ensureReplayIDs(&d)
                    return d
                default:
                    return d // message / reasoning / …: passthrough
                }
            }
            for t in lifted {
                appendLiftedTool(t, into: &body, registry: &registry)
            }
            // Tools surfaced mid-session via tool_search_output join the
            // top-level list too (codex-ollama-proxy's flattenDiscoveredTools).
            for t in pendingSurfaced {
                appendLiftedTool(t, into: &body, registry: &registry)
            }
            body["input"] = hoistImagesOutOfToolOutputs(input)
        }
    }

    /// Normalize + merge one lifted (additional_tools) tool into body.tools.
    /// Later definitions win over stale top-level ones of the same name.
    private static func appendLiftedTool(_ tool: [String: Any], into body: inout [String: Any],
                                         registry: inout ToolRegistry) {
        var unused: [[String: Any]] = []
        var wrapper: [String: Any] = ["tools": [tool]]
        rewriteToolsAndInput(&wrapper, registry: &registry, pendingSurfaced: &unused)
        guard let normalized = (wrapper["tools"] as? [[String: Any]])?.first,
              let name = normalized["name"] as? String else { return }

        var tools = (body["tools"] as? [[String: Any]]) ?? []
        if let idx = tools.firstIndex(where: { ($0["name"] as? String) == name }) {
            tools[idx] = normalized
        } else {
            tools.append(normalized)
        }
        body["tools"] = tools
    }

    /// Replay: `function_call{namespace, name}` → `function_call{name: flat}`.
    private static func flattenFunctionCall(_ d: inout [String: Any], registry: inout ToolRegistry) {
        guard let ns = d["namespace"] as? String, let name = d["name"] as? String else { return }
        let flat = ToolRegistry.flatten(ns: ns, child: name)
        registry.register(flat: flat, ns: ns, name: name)
        d["name"] = flat
        d.removeValue(forKey: "namespace")
        // arguments must be a string on the wire
        if let args = d["arguments"], !(args is String) {
            d["arguments"] = jsonString(args)
        }
    }

    /// Relay stations' Responses deserializers require `id`+`status` on
    /// replayed call items (OpenAI's own history always carries them; Codex
    /// sends them too, but hand-built/converted items may lack them).
    private static func ensureReplayIDs(_ d: inout [String: Any]) {
        let type = d["type"] as? String ?? ""
        if d["id"] == nil {
            d["id"] = type.contains("output") ? "fco_" + UUID().uuidString.prefix(8)
                                              : "fc_" + UUID().uuidString.prefix(8)
        }
        if type == "function_call" && d["status"] == nil {
            d["status"] = "completed"
        }
    }

    /// Replay: `custom_tool_call{call_id, name, input}` → `function_call`.
    private static func flattenCustomToolCall(_ d: [String: Any], registry: inout ToolRegistry) -> [String: Any] {
        if let name = d["name"] as? String { registry.registerCustom(name) }
        let raw = (d["input"] as? String) ?? ""
        var out = d
        out["type"] = "function_call"
        out["arguments"] = jsonString(["input": raw])
        out.removeValue(forKey: "input")
        return out
    }

    /// Replay: `tool_search_call`/`web_search_call` → `function_call`.
    private static func bridgedCall(_ d: [String: Any], name: String) -> [String: Any] {
        var out = d
        out["type"] = "function_call"
        out["name"] = name
        if let args = d["arguments"], !(args is String) {
            out["arguments"] = jsonString(args)
        } else if d["arguments"] == nil {
            out["arguments"] = "{}"
        }
        out.removeValue(forKey: "execution")
        return out
    }

    /// `tool_search_output` → `function_call_output` carrying the surfaced
    /// tool declarations (so the model learns the flat names). Surfaced
    /// tools are also registered/added to the top-level tools list.
    private static func bridgedOutput(_ d: [String: Any],
                                      pendingSurfaced: inout [[String: Any]]) -> [String: Any] {
        var out = d
        out["type"] = "function_call_output"
        if let tools = d["tools"] as? [[String: Any]] {
            var text = jsonString(tools)
            text += "\n\nInvoke each tool by its exact name as listed."
            out["output"] = text
            pendingSurfaced.append(contentsOf: tools)
        }
        out.removeValue(forKey: "tools")
        return out
    }

    // MARK: - Request: Responses → Chat Completions

    static func responsesToChatRequest(_ body: [String: Any], registry: inout ToolRegistry) -> [String: Any] {
        var out = body
        rewriteToolsAndInput(&out, registry: &registry)

        var messages: [[String: Any]] = []
        // instructions → leading system message
        if let instructions = out["instructions"] as? String, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }

        // Buffer consecutive function_call items into one assistant tool_calls
        // message, flushed before the first matching function_call_output.
        var pendingCalls: [[String: Any]] = []
        var pendingToolImages: [ExtractedImage] = []
        func flushCalls() {
            guard !pendingCalls.isEmpty else { return }
            messages.append(["role": "assistant", "content": "", "tool_calls": pendingCalls])
            pendingCalls = []
        }
        func flushToolImages() {
            guard !pendingToolImages.isEmpty else { return }
            messages.append([
                "role": "user",
                "content": pendingToolImages.map { chatImagePart($0) },
            ])
            pendingToolImages.removeAll(keepingCapacity: true)
        }

        func toolCallsEntry(_ call: [String: Any]) -> [String: Any] {
            [
                "id": (call["call_id"] as? String) ?? (call["id"] as? String) ?? UUID().uuidString,
                "type": "function",
                "function": [
                    "name": call["name"] ?? "",
                    "arguments": call["arguments"] ?? "{}",
                ],
            ]
        }

        for raw in out["input"] as? [Any] ?? [] {
            guard let item = raw as? [String: Any] else { continue }
            switch item["type"] as? String {
            case "message":
                flushCalls()
                flushToolImages()
                // cc-switch `responses_role_to_chat_role`: developer is a
                // Codex/OpenAI system alias; mapping it to user duplicates
                // the instructions as a human turn.
                let role: String
                switch item["role"] as? String {
                case "assistant": role = "assistant"
                case "system", "developer": role = "system"
                case "tool": role = "tool"
                default: role = "user"
                }
                messages.append(["role": role, "content": chatMessageContent(item)])
            case "reasoning":
                continue // summaries are not replayable for most Chat backends
            case "function_call":
                flushToolImages()
                pendingCalls.append(toolCallsEntry(item))
            case "function_call_output":
                // Assistant tool_calls flush happens lazily here so all
                // consecutive calls share one message.
                flushCalls()
                let callID = (item["call_id"] as? String) ?? ""
                let split = splitToolOutput(item["output"])
                messages.append(["role": "tool", "tool_call_id": callID, "content": split.text])
                pendingToolImages.append(contentsOf: split.images)
            default:
                continue
            }
        }
        flushCalls()
        flushToolImages()

        // tools → Chat shape
        var chatTools: [[String: Any]] = []
        for t in out["tools"] as? [[String: Any]] ?? [] {
            guard let name = t["name"] as? String else { continue }
            chatTools.append([
                "type": "function",
                "function": [
                    "name": name,
                    "description": t["description"] ?? "",
                    "parameters": t["parameters"] ?? ["type": "object", "properties": [:]],
                ],
            ])
        }

        var chat: [String: Any] = [
            "model": out["model"] ?? "",
            "messages": messages,
            "stream": (out["stream"] as? Bool) ?? true,
        ]
        if !chatTools.isEmpty { chat["tools"] = chatTools }
        if let choice = out["tool_choice"] as? String {
            chat["tool_choice"] = choice
        } else if let choice = out["tool_choice"] as? [String: Any],
                  choice["type"] as? String != "namespace" {
            chat["tool_choice"] = choice
        }
        if let effort = (out["reasoning"] as? [String: Any])?["effort"] as? String {
            chat["reasoning_effort"] = effort
        }
        return chat
    }

    // MARK: - Response: Responses-native upstream, per-event rewrite

    /// Rewrite one SSE event JSON: split resolvable flat function_call names
    /// back to {namespace, name}; normalize usage. Walks the whole payload
    /// (cc-switch `restore_value`) so nested `output` / `item` / arrays all
    /// get restored.
    static func rewriteResponsesEvent(_ json: [String: Any], registry: ToolRegistry) -> [String: Any] {
        var out = json
        restoreNamespaces(&out, registry: registry)
        if var resp = out["response"] as? [String: Any] {
            normalizeUsage(&resp)
            out["response"] = resp
        } else {
            normalizeUsage(&out)
        }
        return out
    }

    static func restoreNamespaces(_ value: inout [String: Any], registry: ToolRegistry) {
        if value["type"] as? String == "function_call",
           let name = value["name"] as? String,
           let (ns, orig) = registry.split(name) {
            value["name"] = orig
            value["namespace"] = ns
        }
        for key in Array(value.keys) {
            if var child = value[key] as? [String: Any] {
                restoreNamespaces(&child, registry: registry)
                value[key] = child
            } else if let arr = value[key] as? [Any] {
                var out: [Any] = []
                out.reserveCapacity(arr.count)
                for item in arr {
                    if var d = item as? [String: Any] {
                        restoreNamespaces(&d, registry: registry)
                        out.append(d)
                    } else {
                        out.append(item)
                    }
                }
                value[key] = out
            }
        }
    }

    /// prompt_tokens↔input_tokens, completion_tokens↔output_tokens; fill
    /// details with 0; if usage is present but lacks the core counts, delete it
    /// (Codex requires the three core numbers when usage is present).
    static func normalizeUsage(_ response: inout [String: Any]) {
        guard var usage = response["usage"] as? [String: Any] else { return }
        if let input = usage["prompt_tokens"] { usage["input_tokens"] = input }
        if let output = usage["completion_tokens"] { usage["output_tokens"] = output }
        if usage["input_tokens"] == nil || usage["output_tokens"] == nil {
            response.removeValue(forKey: "usage")
            return
        }
        if usage["total_tokens"] == nil {
            let i = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
            let o = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            usage["total_tokens"] = i + o
        }
        if usage["input_tokens_details"] == nil { usage["input_tokens_details"] = ["cached_tokens": 0] }
        if usage["output_tokens_details"] == nil { usage["output_tokens_details"] = ["reasoning_tokens": 0] }
        response["usage"] = usage
    }

    // MARK: - Response: Chat upstream → synthesized Responses SSE

    struct ChatStreamState {
        var sequenceNumber = 0
        var created = false
        var responseID = "resp_" + UUID().uuidString
        var textItemID = "msg_" + UUID().uuidString
        var textStarted = false
        var textBuffer = ""
        // chat tool_call index → item state
        var calls: [Int: (itemID: String, callID: String, name: String, buffer: String, added: Bool)] = [:]
        var finishedCalls: [[String: Any]] = []
        var usage: [String: Any]? = nil
        var registry = ToolRegistry()

        mutating func next() -> Int { sequenceNumber += 1; return sequenceNumber }
    }

    /// Convert one Chat `data:` delta into zero or more Responses SSE events.
    /// `state` accumulates across deltas of the same stream.
    static func chatDeltaToResponsesEvents(_ chatDelta: [String: Any], state: inout ChatStreamState) -> [[String: Any]] {
        var events: [[String: Any]] = []

        if !state.created {
            state.created = true
            events.append(responseEvent("response.created", state: &state, extra: [
                "response": baseResponse(state, status: "in_progress"),
            ]))
        }

        let delta = chatDelta["choices"] as? [[String: Any]] ?? []
        let first = (delta.first?["delta"] as? [String: Any]) ?? delta.first ?? [:]

        // Text deltas.
        if let content = first["content"] as? String, !content.isEmpty {
            if !state.textStarted {
                state.textStarted = true
                events.append(responseEvent("response.output_item.added", state: &state, extra: [
                    "output_index": 0,
                    "item": messageItem(state.textItemID, inProgress: true),
                ]))
                events.append(responseEvent("response.content_part.added", state: &state, extra: [
                    "item_id": state.textItemID, "output_index": 0, "content_index": 0,
                    "part": ["type": "output_text", "text": "", "annotations": []],
                ]))
            }
            state.textBuffer += content
            events.append(responseEvent("response.output_text.delta", state: &state, extra: [
                "item_id": state.textItemID, "output_index": 0, "content_index": 0,
                "delta": content,
            ]))
        }

        // Tool-call deltas, buffered by Chat index.
        for tc in first["tool_calls"] as? [[String: Any]] ?? [] {
            let idx = (tc["index"] as? NSNumber)?.intValue ?? 0
            let fn = tc["function"] as? [String: Any] ?? [:]
            var entry = state.calls[idx] ?? (itemID: "fc_" + UUID().uuidString,
                                             callID: (tc["id"] as? String) ?? "call_" + UUID().uuidString,
                                             name: "", buffer: "", added: false)
            if let id = tc["id"] as? String, !id.isEmpty { entry.callID = id }
            if let n = fn["name"] as? String, !n.isEmpty { entry.name += n }
            if let args = fn["arguments"] as? String { entry.buffer += args }
            if !entry.added, !entry.name.isEmpty {
                entry.added = true
                events.append(responseEvent("response.output_item.added", state: &state, extra: [
                    "output_index": state.finishedCalls.count + state.calls.count,
                    "item": functionCallItem(entry, inProgress: true, registry: state.registry),
                ]))
            }
            if !argsDeltaSource(fn, entry: entry).isEmpty {
                events.append(responseEvent("response.function_call_arguments.delta", state: &state, extra: [
                    "item_id": entry.itemID,
                    "output_index": state.finishedCalls.count + state.calls.count,
                    "delta": argsDeltaSource(fn, entry: entry),
                ]))
            }
            state.calls[idx] = entry
        }

        // Usage on the final chunk.
        if let usage = chatDelta["usage"] as? [String: Any] {
            var resp = baseResponse(state, status: "completed")
            var u: [String: Any] = usage
            if let i = u["prompt_tokens"] { u["input_tokens"] = i }
            if let o = u["completion_tokens"] { u["output_tokens"] = o }
            let input = (u["input_tokens"] as? NSNumber)?.intValue ?? 0
            let output = (u["output_tokens"] as? NSNumber)?.intValue ?? 0
            u["total_tokens"] = (u["total_tokens"] as? NSNumber)?.intValue ?? input + output
            u["input_tokens_details"] = ["cached_tokens": 0]
            u["output_tokens_details"] = ["reasoning_tokens": 0]
            resp["usage"] = u
            events.append(contentsOf: completedEvents(state: &state, response: resp))
        }

        return events
    }

    /// Chat tool-call arguments for this delta: the slice Chat sent (we treat
    /// each chunk's arguments as incremental — the standard behavior).
    private static func argsDeltaSource(_ fn: [String: Any], entry: (itemID: String, callID: String, name: String, buffer: String, added: Bool)) -> String {
        (fn["arguments"] as? String) ?? ""
    }

    /// Emit the terminal sequence: close open items + response.completed.
    static func completedEvents(state: inout ChatStreamState, response: [String: Any]) -> [[String: Any]] {
        var events: [[String: Any]] = []
        if state.textStarted {
            events.append(responseEvent("response.output_text.done", state: &state, extra: [
                "item_id": state.textItemID, "output_index": 0, "content_index": 0,
                "text": state.textBuffer,
            ]))
            events.append(responseEvent("response.content_part.done", state: &state, extra: [
                "item_id": state.textItemID, "output_index": 0, "content_index": 0,
                "part": ["type": "output_text", "text": state.textBuffer, "annotations": []],
            ]))
            events.append(responseEvent("response.output_item.done", state: &state, extra: [
                "output_index": 0,
                "item": messageItem(state.textItemID, inProgress: false, text: state.textBuffer),
            ]))
        }
        var output: [[String: Any]] = []
        var index = 0
        for (_, entry) in state.calls.sorted(by: { $0.key < $1.key }) {
            if entry.added {
                events.append(responseEvent("response.function_call_arguments.done", state: &state, extra: [
                    "item_id": entry.itemID, "output_index": index,
                    "arguments": entry.buffer,
                ]))
                var item = functionCallItem(entry, inProgress: false, registry: state.registry)
                item["arguments"] = entry.buffer
                events.append(responseEvent("response.output_item.done", state: &state, extra: [
                    "output_index": index, "item": item,
                ]))
                output.append(item)
            }
            index += 1
        }
        if state.textStarted {
            output.insert(messageItem(state.textItemID, inProgress: false, text: state.textBuffer), at: 0)
        }
        var final = response
        final["output"] = output
        events.append(responseEvent("response.completed", state: &state, extra: ["response": final]))
        return events
    }

    /// Restore an apply_patch-style function call into a custom_tool_call.
    /// Returns nil when the name isn't a custom tool (passthrough as function_call).
    static func chatToolCallToCustomTool(_ name: String, argsJSON: String) -> [String: Any]? {
        var raw = customInputFromChatArgs(argsJSON)
        if name == "apply_patch" { raw = normalizeApplyPatch(raw) }
        return customToolCall(name: name, input: raw)
    }

    private static func customInputFromChatArgs(_ argsJSON: String) -> String {
        if let data = argsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (obj["input"] as? String)
                ?? (obj["patch"] as? String)
                ?? (obj.values.compactMap { $0 as? String }.first ?? argsJSON)
        }
        return argsJSON
    }

    static func customToolCall(name: String, input: String) -> [String: Any] {
        [
            "type": "custom_tool_call",
            "id": "ctc_" + UUID().uuidString,
            "call_id": "call_" + UUID().uuidString,
            "name": name,
            "input": input,
            "status": "completed",
        ]
    }

    /// Canonical apply_patch dialect: normalize casing/spacing markers.
    static func normalizeApplyPatch(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "(?im)^\\s*\\*\\*\\*\\s*begin\\s+patch\\s*$",
                                   with: "*** Begin Patch", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?im)^\\s*\\*\\*\\*\\s*end\\s+patch\\s*$",
                                   with: "*** End Patch", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?im)^\\s*\\*\\*\\*\\s*add\\s+file\\s*:\\s*",
                                   with: "*** Add File: ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?im)^\\s*\\*\\*\\*\\s*update\\s+file\\s*:\\s*",
                                   with: "*** Update File: ", options: .regularExpression)
        return s
    }

    // MARK: - Synthetic terminals

    static func synthesizeCompletedZeroUsage() -> Data {
        let resp: [String: Any] = [
            "id": "resp_" + UUID().uuidString,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": "completed",
            "model": "",
            "output": [],
            "usage": ["input_tokens": 0, "output_tokens": 0, "total_tokens": 0],
        ]
        let event: [String: Any] = ["type": "response.completed", "sequence_number": 0, "response": resp]
        return sse(event) + sseRaw("[DONE]")
    }

    /// Post-stream lifecycle patch for incomplete Responses upstreams.
    /// Relay stations frequently skip `response.created` (and always the
    /// terminal) — Codex requires both or reports "stream disconnected
    /// before completion". Returns SSE bytes to append (possibly empty).
    static func synthesizeLifecycle(sawCreated: Bool, sawTerminal: Bool, lastSequence: Int) -> Data {
        var out = Data()
        var seq = lastSequence
        func emit(_ event: [String: Any]) -> Data {
            var e = event
            seq += 1
            e["sequence_number"] = seq
            return sse(e)
        }
        if !sawTerminal {
            // response.failed can't be used (Codex surfaces an error); emit a
            // completed with zero usage — the actual content already streamed.
            let resp: [String: Any] = [
                "id": "resp_" + UUID().uuidString,
                "object": "response",
                "created_at": Int(Date().timeIntervalSince1970),
                "status": "completed",
                "model": "",
                "output": [],
                "usage": ["input_tokens": 0, "output_tokens": 0, "total_tokens": 0],
            ]
            out += emit(["type": "response.completed", "response": resp])
            out += sseRaw("[DONE]")
        }
        return out
    }

    static func synthesizeFailed(message: String) -> Data {
        let resp: [String: Any] = [
            "id": "resp_" + UUID().uuidString,
            "object": "response",
            "status": "failed",
            "error": ["code": "upstream_error", "message": message],
        ]
        let event: [String: Any] = ["type": "response.failed", "sequence_number": 0, "response": resp]
        return sse(event)
    }

    // MARK: - SSE framing helpers

    static func sse(_ json: [String: Any]) -> Data {
        sseRaw(jsonString(json))
    }

    /// Every event MUST end with \n\n — a single \n corrupts Codex's framing.
    static func sseRaw(_ payload: String) -> Data {
        Data("data: \(payload)\n\n".utf8)
    }

    // MARK: - Event builders (Chat → Responses synthesis)

    private static func responseEvent(_ type: String, state: inout ChatStreamState, extra: [String: Any]) -> [String: Any] {
        var e: [String: Any] = ["type": type, "sequence_number": state.next()]
        for (k, v) in extra { e[k] = v }
        return e
    }

    private static func baseResponse(_ state: ChatStreamState, status: String) -> [String: Any] {
        [
            "id": state.responseID,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": status,
            "model": "",
            "output": [],
        ]
    }

    private static func messageItem(_ id: String, inProgress: Bool, text: String = "") -> [String: Any] {
        [
            "id": id,
            "type": "message",
            "status": inProgress ? "in_progress" : "completed",
            "role": "assistant",
            "content": [["type": "output_text", "text": text, "annotations": []]],
        ]
    }

    private static func functionCallItem(_ entry: (itemID: String, callID: String, name: String, buffer: String, added: Bool),
                                         inProgress: Bool,
                                         registry: ToolRegistry) -> [String: Any] {
        if registry.customNames.contains(entry.name) {
            let input: String
            if inProgress {
                input = ""
            } else if let custom = chatToolCallToCustomTool(entry.name, argsJSON: entry.buffer) {
                return mergedCustom(custom, entry: entry, inProgress: false)
            } else {
                input = entry.buffer
            }
            return [
                "id": entry.itemID,
                "type": "custom_tool_call",
                "status": inProgress ? "in_progress" : "completed",
                "call_id": entry.callID,
                "name": entry.name,
                "input": input,
            ]
        }
        var item: [String: Any] = [
            "id": entry.itemID,
            "type": "function_call",
            "status": inProgress ? "in_progress" : "completed",
            "call_id": entry.callID,
            "name": entry.name,
            "arguments": inProgress ? "" : entry.buffer,
        ]
        if let (ns, orig) = registry.split(entry.name) {
            item["name"] = orig
            item["namespace"] = ns
        }
        return item
    }

    private static func mergedCustom(_ custom: [String: Any],
                                     entry: (itemID: String, callID: String, name: String, buffer: String, added: Bool),
                                     inProgress: Bool) -> [String: Any] {
        var out = custom
        out["id"] = entry.itemID
        out["call_id"] = entry.callID
        out["status"] = inProgress ? "in_progress" : "completed"
        return out
    }

    // MARK: - JSON helpers

    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
