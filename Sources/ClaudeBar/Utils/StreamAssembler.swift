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

/// Token usage as one upstream call reported it.
///
/// Fed from the same events the capture assembler consumes, so the access-log
/// console can show token counts whether or not traffic recording is on — with
/// recording off there is no capture tap at all, and the console is the only
/// surface left.
///
/// The buckets are **disjoint** — fresh input, cache read, cache write, output
/// — because that is the only shape anything downstream can bill: `ModelUsage`
/// stores them disjointly, `ModelPricing` multiplies each by its own rate and
/// adds, and `ModelUsage.totalTokens` is their sum. The upstreams do not agree
/// on that shape, so the disagreement is resolved here, at the one layer that
/// knows which protocol the numbers arrived on:
///
///   * **Anthropic** reports cache reads and writes as their own fields, and
///     its `input_tokens` excludes both. Taken at face value.
///   * **Chat / Responses** report the cache hit *inside* the prompt count.
///     DeepSeek documents it outright — `prompt_tokens` equals
///     `prompt_cache_hit_tokens + prompt_cache_miss_tokens` — and OpenAI's
///     `input_tokens_details.cached_tokens` is likewise a subset of
///     `input_tokens`. Storing both numbers raw bills the cached part twice
///     (once at the miss rate, once at the hit rate) and double counts it in
///     `total`.
///
/// The subtraction happens on every apply, from the raw prompt count kept
/// aside — not once against `input` — so a stream that repeats its usage block,
/// or reports the cached count in a different event than the total, settles on
/// the same answer instead of subtracting twice.
struct TokenTotals: Equatable {
    var input: Int?
    var output: Int?
    var cacheRead: Int?
    var cacheWrite: Int?

    /// The upstream's own prompt count, and whether that number already
    /// contains `cacheRead`. Private: they are the inputs `input` is derived
    /// from, not buckets in their own right.
    private var promptTotal: Int?
    private var promptIncludesCacheRead = false

    /// Usage is identical when the buckets are — the raw prompt count is
    /// bookkeeping, not part of the report.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.input == rhs.input && lhs.output == rhs.output
            && lhs.cacheRead == rhs.cacheRead && lhs.cacheWrite == rhs.cacheWrite
    }

    var isEmpty: Bool {
        input == nil && output == nil && cacheRead == nil && cacheWrite == nil
    }

    /// `nil` when the upstream never reported usage — an interrupted stream, a
    /// gateway that omits the field. Distinct from a real zero.
    var total: Int? {
        isEmpty ? nil : (input ?? 0) + (output ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0)
    }

    mutating func applyChat(_ event: [String: Any]) {
        guard let usage = event["usage"] as? [String: Any] else { return }
        output = intValue(usage["completion_tokens"]) ?? output
        // `prompt_tokens_details.cached_tokens` is the OpenAI-compatible
        // spelling; DeepSeek also reports the same number at the top level as
        // `prompt_cache_hit_tokens`. Either may be the only one present.
        let details = usage["prompt_tokens_details"] as? [String: Any]
        if let hit = positive(details?["cached_tokens"], usage["prompt_cache_hit_tokens"]) {
            cacheRead = hit
        }
        if let written = positive(details?["cache_write_tokens"], usage["cache_write_tokens"]) {
            cacheWrite = written
        }
        // A Chat prompt count always *includes* the hit — DeepSeek documents
        // `prompt_tokens == prompt_cache_hit_tokens + prompt_cache_miss_tokens`.
        setPrompt(total: intValue(usage["prompt_tokens"]), includesCacheRead: true)
    }

    /// `response.usage` on streamed events; the top level on a non-streaming
    /// response body, which `CodexProxyTransform.normalizeUsage` leaves there.
    mutating func applyResponses(_ event: [String: Any]) {
        let usage = ((event["response"] as? [String: Any])?["usage"] as? [String: Any])
            ?? (event["usage"] as? [String: Any])
        guard let usage else { return }
        output = intValue(usage["output_tokens"]) ?? intValue(usage["completion_tokens"]) ?? output
        let prompt = intValue(usage["input_tokens"]) ?? intValue(usage["prompt_tokens"])
        let inputDetails = usage["input_tokens_details"] as? [String: Any]
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        // A hit under one of the OpenAI-compatible names is a *subset* of the
        // prompt count. Both detail blocks are consulted: `normalizeUsage`
        // fills `input_tokens_details` from `prompt_tokens_details` only when
        // the former is absent, so an upstream that sent both leaves the
        // interesting number in the second.
        let subsetHit = positive(inputDetails?["cached_tokens"],
                                 promptDetails?["cached_tokens"],
                                 usage["prompt_cache_hit_tokens"])
        // Anthropic's spelling is a *sibling* of `input_tokens`, not a subset:
        // a relay echoing the upstream's usage verbatim hands us a prompt count
        // that already excludes it. Folding that count would under-report the
        // whole cache read, so this wins only when no subset-shaped hit is
        // present (otherwise the two agree and the subset is the safe read).
        let siblingRead = positive(usage["cache_read_input_tokens"])
        if let subsetHit {
            cacheRead = subsetHit
            if let written = positive(inputDetails?["cache_write_tokens"],
                                      promptDetails?["cache_write_tokens"]) {
                cacheWrite = written
            }
            setPrompt(total: prompt, includesCacheRead: true)
        } else if let siblingRead {
            cacheRead = siblingRead
            if let written = positive(usage["cache_creation_input_tokens"]) { cacheWrite = written }
            setPrompt(total: prompt, includesCacheRead: false)
        } else {
            setPrompt(total: prompt, includesCacheRead: true)
        }
    }

    mutating func applyAnthropic(event: String, json: [String: Any]) {
        switch event {
        case "message_start":
            applyAnthropicUsage((json["message"] as? [String: Any])?["usage"] as? [String: Any])
        case "message_delta":
            applyAnthropicUsage(json["usage"] as? [String: Any])
        default:
            break
        }
    }

    /// A whole non-streaming Messages response — usage sits at its top level.
    mutating func applyAnthropicMessage(_ message: [String: Any]) {
        applyAnthropicUsage(message["usage"] as? [String: Any])
    }

    private mutating func applyAnthropicUsage(_ usage: [String: Any]?) {
        guard let usage else { return }
        output = intValue(usage["output_tokens"]) ?? output
        cacheRead = intValue(usage["cache_read_input_tokens"]) ?? cacheRead
        cacheWrite = intValue(usage["cache_creation_input_tokens"]) ?? cacheWrite
        // Anthropic's `input_tokens` is fresh input on its own — the cache
        // fields sit beside it, not inside it. Nothing is folded out.
        setPrompt(total: intValue(usage["input_tokens"]), includesCacheRead: false)
    }

    /// Record the upstream's prompt count and derive the fresh-input bucket.
    ///
    /// Chat/Responses report a prompt total that already contains the cache hit
    /// (see the type's comment), so the hit is subtracted here — recomputed
    /// from the raw total each time rather than decremented from `input`, so
    /// repeated usage blocks converge instead of double-subtracting. Callers
    /// pass `total: nil` when this event did not carry one: the remembered
    /// total is then re-derived against the cache hit, which may have arrived
    /// in a different event.
    private mutating func setPrompt(total: Int?, includesCacheRead: Bool) {
        if let total {
            promptTotal = total
            promptIncludesCacheRead = includesCacheRead
        }
        guard let total = promptTotal else { return }
        let hit = promptIncludesCacheRead ? (cacheRead ?? 0) : 0
        input = max(0, total - hit)
    }

    private func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        return nil
    }

    /// First of several spellings that carries a count. Zero counts as absent
    /// on purpose: `CodexProxyTransform.normalizeUsage` synthesizes
    /// `cached_tokens: 0` for an upstream that never reported a detail block,
    /// and a real zero and a synthesized one are indistinguishable — treating
    /// zero as "not reported" keeps that placeholder from masking an
    /// Anthropic-shaped hit sitting beside it.
    private func positive(_ candidates: Any?...) -> Int? {
        for candidate in candidates {
            if let value = intValue(candidate), value > 0 { return value }
        }
        return nil
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
    var tokens = TokenTotals()
    var tools: [Tool] = []

    var promptTokens: Int? { tokens.input }
    var completionTokens: Int? { tokens.output }
    var cacheReadTokens: Int? { tokens.cacheRead }
    var cacheWriteTokens: Int? { tokens.cacheWrite }

    struct Tool: Equatable {
        var id: String
        var name: String
        var arguments: String
    }

    var snapshot: [Tool] { tools }

    mutating func applyChat(_ parsed: [String: Any]) {
        if let m = parsed["model"] as? String, !m.isEmpty { model = m }
        if let i = parsed["id"] as? String, !i.isEmpty { id = i }
        tokens.applyChat(parsed)

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
        }
        tokens.applyResponses(parsed)
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
            // Usage for this event was already folded in above, from
            // `response.usage`.
        }
    }

    mutating func applyAnthropic(event: String, json: [String: Any]) {
        let type = event.isEmpty ? ((json["type"] as? String) ?? "") : event
        switch type {
        case "message_start":
            if let msg = json["message"] as? [String: Any] {
                id = (msg["id"] as? String) ?? id
                model = (msg["model"] as? String) ?? model
            }
            tokens.applyAnthropic(event: type, json: json)
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
            tokens.applyAnthropic(event: type, json: json)
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
                "cache_write_tokens": cacheWriteTokens as Any,
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
}
