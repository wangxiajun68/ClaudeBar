import Foundation
import CryptoKit
import CoreFoundation
import Darwin

/// POSIX realpath agrees with Node/Python client workspace keys. Foundation's
/// resolvingSymlinksInPath can rewrite /private/var to /var, and resolves an
/// existing directory differently from its not-yet-created child.
enum MigrationPath {
    static func canonical(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw MigrationFailure.invalidHistory }
        var ancestor = path, suffix: [String] = []
        for _ in 0..<1024 {
            if let pointer = realpath(ancestor, nil) {
                defer { free(pointer) }
                let root = String(cString: pointer)
                return suffix.isEmpty ? root
                    : (root == "/" ? "" : root) + "/" + suffix.reversed().joined(separator: "/")
            }
            guard errno == ENOENT || errno == ENOTDIR else { throw MigrationFailure.storage }
            let parent = (ancestor as NSString).deletingLastPathComponent
            guard parent != ancestor else { throw MigrationFailure.storage }
            suffix.append((ancestor as NSString).lastPathComponent)
            ancestor = parent
        }
        throw MigrationFailure.invalidHistory
    }
}

/// Pure adapters: accept an explicit snapshot, never look up credentials or
/// launch a process. Unknown/partial history is rejected rather than truncated.
enum MigrationHistory {
    static let maxFileBytes = 16 * 1024 * 1024
    static let maxTextBytes = 400_000
    static let maxMessages = 8_000

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func rows(_ data: Data) throws -> [[String: Any]] {
        guard data.count <= maxFileBytes else { throw MigrationFailure.tooLarge }
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else {
            throw MigrationFailure.invalidHistory
        }
        return try text.split(separator: "\n", omittingEmptySubsequences: true).map {
            guard let row = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
                throw MigrationFailure.invalidHistory
            }
            return row
        }
    }

    static func text(_ content: Any?) -> String {
        if let value = content as? String { return value }
        return (content as? [[String: Any]] ?? []).compactMap { block -> String? in
            guard ["text", "input_text", "output_text"].contains((block["type"] as? String ?? "").lowercased()) else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func preview(source: MigrationSource, messages: [MigrationMessage],
                        snapshot: Data, omissions: [String] = []) throws -> MigrationPreview {
        guard messages.last?.role == .assistant, messages.contains(where: { $0.role == .user }),
              messages.contains(where: { $0.role == .assistant }) else { throw MigrationFailure.invalidHistory }
        guard messages.count <= maxMessages,
              messages.reduce(0, { $0 + $1.text.utf8.count }) <= maxTextBytes else { throw MigrationFailure.tooLarge }
        return .init(source: source, messages: messages, fingerprint: fingerprint(snapshot),
                     omissions: Array(Set(omissions)).sorted())
    }

    static func validateIdentity(_ meta: [String: Any], source: MigrationSource) throws {
        guard let id = meta["id"] as? String ?? meta["session_id"] as? String,
              id.lowercased() == source.sessionID.lowercased(),
              let cwd = meta["cwd"] as? String,
              try MigrationPath.canonical(cwd) == MigrationPath.canonical(source.cwd) else {
            throw MigrationFailure.invalidHistory
        }
    }

    static func codex(_ data: Data, source: MigrationSource) throws -> MigrationPreview {
        let records = try rows(data)
        guard let first = records.first, first["type"] as? String == "session_meta",
              let meta = first["payload"] as? [String: Any] else { throw MigrationFailure.invalidHistory }
        try validateIdentity(meta, source: source)
        guard meta["parent_thread_id"] == nil, meta["history_base"] == nil,
              meta["thread_source"] as? String != "subagent", meta["subagent_history_start_ordinal"] == nil else {
            throw MigrationFailure.unsupported("首版不迁移子代理或引用其他历史的会话。")
        }
        if let mode = meta["history_mode"] as? String, !["paginated", "legacy"].contains(mode) {
            throw MigrationFailure.invalidHistory
        }
        let paginated = meta["history_mode"] as? String == "paginated"
        if paginated {
            for (index, row) in records.enumerated() {
                guard let ordinal = row["ordinal"] as? NSNumber,
                      CFGetTypeID(ordinal) != CFBooleanGetTypeID(),
                      ordinal.intValue == index, ordinal.doubleValue == Double(index) else {
                    throw MigrationFailure.invalidHistory
                }
            }
        }
        guard records.dropFirst().allSatisfy({ $0["type"] as? String != "session_meta" }) else {
            throw MigrationFailure.invalidHistory
        }
        var canonical: [MigrationMessage] = [], projected: [MigrationMessage] = []
        var omissions: [String] = [], openTurn = false
        for row in records.dropFirst() {
            let payload = row["payload"] as? [String: Any] ?? [:]
            let type = row["type"] as? String ?? ""
            if ["compacted", "history_base", "history_page", "history_reference"].contains(type)
                || payload["history_base"] != nil {
                throw MigrationFailure.unsupported("这段历史已压缩或引用外部分页，首版暂不能完整迁移。")
            }
            if type == "event_msg" {
                switch payload["type"] as? String {
                case "context_compacted":
                    throw MigrationFailure.unsupported("这段历史已压缩，首版暂不能完整迁移。")
                case "task_started", "turn_started": openTurn = true
                case "task_complete", "turn_complete", "turn_aborted": openTurn = false
                case "item_completed":
                    guard let item = payload["item"] as? [String: Any] else { throw MigrationFailure.invalidHistory }
                    let kind = item["type"] as? String ?? ""
                    if ["UserMessage", "AgentMessage"].contains(kind) {
                        let body = text(item["content"])
                        try checkTextOnly(item["content"], omissions: &omissions)
                        if !body.isEmpty { canonical.append(.init(role: kind == "UserMessage" ? .user : .assistant, text: body)) }
                    } else if ["CommandExecution", "FileChange", "McpToolCall", "DynamicToolCall", "WebSearch"].contains(kind) {
                        omissions.append("历史工具调用未重放；请在来源查看完整工具结果。")
                    }
                default: break
                }
            } else if type == "response_item" {
                switch payload["type"] as? String {
                case "message":
                    let role = payload["role"] as? String ?? ""
                    let body = text(payload["content"])
                    if ["user", "assistant"].contains(role), !isEnvironment(body) {
                        try checkTextOnly(payload["content"], omissions: &omissions)
                        if !body.isEmpty { projected.append(.init(role: role == "user" ? .user : .assistant, text: body)) }
                    }
                case "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output":
                    omissions.append("历史工具调用未重放；请在来源查看完整工具结果。")
                default: break // Private reasoning and provider IDs never cross the boundary.
                }
            }
        }
        guard !openTurn else { throw MigrationFailure.busy }
        if paginated && canonical.isEmpty { throw MigrationFailure.invalidHistory }
        return try preview(source: source, messages: paginated ? canonical : projected,
                           snapshot: data, omissions: omissions)
    }

    static func claude(_ data: Data, source: MigrationSource) throws -> MigrationPreview {
        let records = try rows(data)
        if records.contains(where: { $0["type"] as? String == "system"
            && $0["subtype"] as? String == "compact_boundary" }) {
            throw MigrationFailure.unsupported("这段 Claude Code 历史已压缩，首版暂不能完整迁移。")
        }
        // Resolve the latest main branch by parent UUID; do not concatenate siblings.
        guard let identity = records.first(where: { $0["type"] as? String == "user" }),
              identity["sessionId"] as? String == source.sessionID,
              let cwd = identity["cwd"] as? String,
              try MigrationPath.canonical(cwd) == MigrationPath.canonical(source.cwd) else {
            throw MigrationFailure.invalidHistory
        }
        let main = records.filter { ["user", "assistant"].contains($0["type"] as? String ?? "")
            && $0["isSidechain"] as? Bool != true }
        var byID: [String: [String: Any]] = [:]
        for row in records {
            if let id = row["uuid"] as? String {
                guard byID[id] == nil else { throw MigrationFailure.invalidHistory }
                byID[id] = row
            }
        }
        guard var current = main.last else { throw MigrationFailure.invalidHistory }
        var chain: [[String: Any]] = [], visited: Set<String> = []
        while true {
            guard let id = current["uuid"] as? String, visited.insert(id).inserted else {
                throw MigrationFailure.invalidHistory
            }
            if let sid = current["sessionId"] as? String, sid.lowercased() != source.sessionID.lowercased() {
                throw MigrationFailure.invalidHistory
            }
            chain.append(current)
            guard let parent = current["parentUuid"] as? String else { break }
            guard let next = byID[parent] else { throw MigrationFailure.invalidHistory }
            current = next
        }
        var messages: [MigrationMessage] = [], omissions: [String] = []
        var pending: Set<String> = []
        for row in chain.reversed() {
            guard ["user", "assistant"].contains(row["type"] as? String ?? ""),
                  let message = row["message"] as? [String: Any],
                  let role = MigrationMessage.Role(rawValue: message["role"] as? String ?? "") else { continue }
            let content = message["content"]
            for block in content as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "tool_use":
                    if let id = block["id"] as? String { pending.insert(id) }
                    omissions.append("历史工具调用未重放；请在来源查看完整工具结果。")
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { pending.remove(id) }
                default: break
                }
            }
            try checkTextOnly(content, omissions: &omissions)
            let body = text(content)
            if !body.isEmpty { messages.append(.init(role: role, text: body)) }
        }
        guard pending.isEmpty else { throw MigrationFailure.busy }
        return try preview(source: source, messages: messages, snapshot: data, omissions: omissions)
    }

    static func checkTextOnly(_ content: Any?, omissions: inout [String]) throws {
        for block in content as? [[String: Any]] ?? [] {
            let type = (block["type"] as? String ?? "").lowercased()
            if ["image", "input_image", "audio", "input_audio", "document", "file"].contains(type) {
                throw MigrationFailure.unsupported("这段会话包含附件，首版不迁移图片、音频或文档。")
            }
            if ["tool_use", "tool_result"].contains(type) {
                omissions.append("历史工具调用未重放；请在来源查看完整工具结果。")
            }
        }
    }

    static func isEnvironment(_ value: String) -> Bool {
        let body = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["<environment_context>", "<user_instructions>", "<INSTRUCTIONS>", "<permissions instructions>"]
            .contains { body.hasPrefix($0) }
    }

    static func claudeData(_ messages: [MigrationMessage], sessionID: String, cwd: String,
                           now: Date = Date()) throws -> Data {
        var parent: String?
        var output = Data()
        for message in messages {
            let id = UUID().uuidString.lowercased()
            var body: [String: Any] = ["role": message.role.rawValue, "content": message.text]
            if message.role == .assistant {
                body = ["role": "assistant", "type": "message", "id": "msg_migration_" + id,
                        "model": "imported-text", "content": [["type": "text", "text": message.text]],
                        "stop_reason": "end_turn", "stop_sequence": NSNull(),
                        "usage": ["input_tokens": 0, "output_tokens": 0]]
            }
            let row: [String: Any] = ["type": message.role.rawValue, "uuid": id,
                "parentUuid": parent as Any? ?? NSNull(), "isSidechain": false,
                "sessionId": sessionID, "cwd": cwd, "version": "2.1.288", "userType": "external",
                "timestamp": ISO8601DateFormatter().string(from: now), "message": body]
            output.append(try json(row)); output.append(0x0a)
            parent = id
        }
        return output
    }

    static func codexData(_ messages: [MigrationMessage], sessionID: String, cwd: String,
                          providerKey: String, now: Date = Date()) throws -> Data {
        let stamp = ISO8601DateFormatter().string(from: now)
        var output = Data()
        func append(_ type: String, _ payload: [String: Any]) throws {
            output.append(try json(["timestamp": stamp, "type": type, "payload": payload])); output.append(0x0a)
        }
        try append("session_meta", ["id": sessionID, "timestamp": stamp, "cwd": cwd,
            "originator": "claudebar_migration", "source": "cli", "cli_version": "0.159.0",
            "model_provider": providerKey, "history_mode": "legacy"])
        for message in messages {
            var body: [String: Any] = ["type": "message", "role": message.role.rawValue,
                "content": [["type": message.role == .user ? "input_text" : "output_text", "text": message.text]]]
            if message.role == .assistant { body["phase"] = "final_answer" }
            try append("response_item", body)
            var event: [String: Any] = ["type": message.role == .user ? "user_message" : "agent_message",
                                      "message": message.text]
            if message.role == .user { event["images"] = [] as [String] }
            else { event["phase"] = "final_answer" }
            try append("event_msg", event)
        }
        return output
    }
}
