import Foundation
import SQLite3

/// Cursor 3.23.12 only. New identities and allowlisted metadata; never clone
/// another composer's prompts, context, encryption keys or checkpoint state.
enum MigrationCursorDesktop {
    struct Profile {
        let workspace: [String: Any]
        let model: [String: Any]
        var modelName: String { model["modelName"] as? String ?? "" }
        func fingerprint() throws -> String {
            MigrationHistory.fingerprint(try MigrationHistory.json(["workspace": workspace, "model": model]))
        }
    }

    static func schema(_ db: OpaquePointer) throws {
        for (table, required) in [
            ("composerHeaders", Set(["composerId", "workspaceId", "createdAt", "lastUpdatedAt", "isArchived",
                "isSubagent", "recency", "checkpointAt", "value", "subagentTypeName"])),
            ("cursorDiskKV", Set(["key", "value"]))
        ] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(" + table + ")", -1, &statement, nil) == SQLITE_OK else {
                throw MigrationFailure.invalidHistory
            }
            defer { sqlite3_finalize(statement) }
            var columns: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
            }
            guard columns == required else { throw MigrationFailure.unsupported("Cursor 桌面数据库结构尚未验证。") }
        }
    }

    static func profile(_ path: URL, cwd: String) throws -> Profile {
        let db = try MigrationCursorHistory.readOnly(path)
        defer { sqlite3_close(db) }
        try schema(db)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT composerId, value FROM composerHeaders WHERE isSubagent = 0 ORDER BY lastUpdatedAt DESC LIMIT 2000",
                                -1, &statement, nil) == SQLITE_OK else { throw MigrationFailure.invalidHistory }
        defer { sqlite3_finalize(statement) }
        let canonical = try MigrationPath.canonical(cwd)
        while sqlite3_step(statement) == SQLITE_ROW {
            try Task.checkCancellation()
            guard let bytes = sqlite3_column_blob(statement, 1),
                  sqlite3_column_bytes(statement, 1) <= MigrationHistory.maxFileBytes else { throw MigrationFailure.tooLarge }
            let header = try MigrationCursorHistory.object(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))))
            guard let workspace = header["workspaceIdentifier"] as? [String: Any],
                  let uri = workspace["uri"] as? [String: Any], let directory = uri["fsPath"] as? String,
                  (try? MigrationPath.canonical(directory)) == canonical,
                  let workspaceID = workspace["id"] as? String, !workspaceID.isEmpty,
                  workspaceID.utf8.count <= 128, workspaceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  let sidBytes = sqlite3_column_text(statement, 0) else { continue }
            let sid = String(cString: sidBytes)
            guard UUID(uuidString: sid) != nil else { continue }
            let composer = try MigrationCursorHistory.object(MigrationCursorHistory.value(db,
                sql: "SELECT value FROM cursorDiskKV WHERE key = ?", key: "composerData:" + sid))
            guard composer["_v"] as? Int == 18, let selected = composer["modelConfig"] as? [String: Any],
                  let name = selected["modelName"] as? String, validModel(name) else { continue }
            var model: [String: Any] = ["modelName": name, "maxMode": selected["maxMode"] as? Bool ?? false]
            if let choices = selected["selectedModels"] as? [[String: Any]], choices.count <= 16 {
                model["selectedModels"] = choices.compactMap { choice -> [String: Any]? in
                    guard let id = choice["modelId"] as? String, validModel(id) else { return nil }
                    let parameters = (choice["parameters"] as? [[String: Any]] ?? []).compactMap { parameter -> [String: String]? in
                        guard let id = parameter["id"] as? String, ["context", "reasoning_effort", "fast"].contains(id),
                              let value = parameter["value"] as? String, value.utf8.count <= 80,
                              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
                        return ["id": id, "value": value]
                    }
                    return ["modelId": id, "parameters": parameters]
                }
            }
            // Keep the registered URI paired with its native workspace ID.
            // A symlink/alias can identify the same directory under another ID.
            let url = URL(fileURLWithPath: directory, isDirectory: false)
            return Profile(workspace: ["id": workspaceID, "uri": ["$mid": 1, "fsPath": directory,
                "external": url.absoluteString, "path": url.path, "scheme": "file"]], model: model)
        }
        throw MigrationFailure.unsupported("请先在 Cursor 打开此项目并创建一条聊天，让 Cursor 登记项目和模型，再重试迁移。")
    }

    private static func validModel(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 160 && name.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/").contains($0)
        }
    }

    static func contains(_ path: URL, sessionID: String) throws -> Bool {
        let db = try MigrationCursorHistory.readOnly(path)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM composerHeaders h JOIN cursorDiskKV k ON k.key = 'composerData:' || h.composerId WHERE h.composerId = ? AND h.isSubagent = 0",
                                -1, &statement, nil) == SQLITE_OK else { throw MigrationFailure.invalidHistory }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, SQLITE_TRANSIENT)
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw MigrationFailure.storage }
        return status == SQLITE_ROW
    }

    /// Manifest publication happens while the DB transaction is still private.
    /// A throw rolls back all inserted rows. A crash before COMMIT can leave a
    /// missing-target record; opening checks its identity and never fabricates it.
    static func insert(_ messages: [MigrationMessage], record: MigrationRecord, profile: Profile,
                       database path: URL, publish: () throws -> Void) throws {
        guard record.target == .cursorDesktop, UUID(uuidString: record.targetSessionID) != nil else {
            throw MigrationFailure.invalidHistory
        }
        let encoded = try MigrationCursorHistory.payload(messages, cwd: record.source.cwd, mode: 1)
        guard encoded.root.count * (messages.count + 1) + encoded.blobs.values.reduce(0, { $0 + $1.count })
                + messages.reduce(0, { $0 + $1.text.utf8.count }) < MigrationHistory.maxFileBytes else {
            throw MigrationFailure.tooLarge
        }
        let state = "~" + encoded.root.base64EncodedString(), stamp = ISO8601DateFormatter().string(from: record.createdAt)
        let now = Int64(record.createdAt.timeIntervalSince1970 * 1000), sid = record.targetSessionID
        var headers: [[String: Any]] = [], rows: [(String, Data)] = []
        let workspaceID = profile.workspace["id"] as? String ?? ""
        func appendBubble(_ message: MigrationMessage, pictures: [MigrationImage]) throws {
            let id = UUID().uuidString.lowercased()
            let nativeTool = message.tool?.cursorTool != nil
            let text = nativeTool ? "" : message.text
            let type = message.role == .user ? 1 : 2
            var bubble: [String: Any] = ["_v": 3, "bubbleId": id, "type": type, "text": text,
                "createdAt": stamp, "conversationState": state, "richText": NSNull(), "isAgentic": false,
                "unifiedMode": 2, "capabilities": [], "capabilityContexts": []]
            for key in ["images", "suggestedCodeBlocks", "toolResults", "allThinkingBlocks", "attachedCodeChunks",
                        "attachedFileCodeChunksMetadataOnly", "attachedFolders", "contextPieces", "codebaseContextChunks",
                        "docsReferences", "webReferences", "externalLinks", "pastChats", "cursorRules", "cursorCommands",
                        "workspaceUris", "todos", "supportedTools", "mcpDescriptors", "relevantFiles"] { bubble[key] = [Any]() }
            if type == 1 { bubble["agentMode"] = 1; bubble["modelInfo"] = ["modelName": profile.modelName]; bubble["context"] = emptyContext() }
            else { bubble["capabilityType"] = 30 }
            if nativeTool, let tool = message.tool, let code = tool.cursorTool, let status = tool.cursorStatus {
                let input = try MigrationHistory.jsonValue(tool.inputJSON)
                let rawArgs: String
                if let text = input as? String { rawArgs = text }
                else { rawArgs = String(decoding: try MigrationHistory.json(input), as: UTF8.self) }
                let output = try MigrationHistory.jsonValue(tool.outputJSON)
                let result: String
                if let text = output as? String { result = text }
                else { result = String(decoding: try MigrationHistory.json(output), as: UTF8.self) }
                bubble["toolFormerData"] = ["tool": code, "toolIndex": 0,
                    "modelCallId": UUID().uuidString.lowercased(),
                    "toolCallId": "toolu_migration_" + UUID().uuidString.lowercased(),
                    "status": status, "name": tool.name, "rawArgs": rawArgs, "params": rawArgs,
                    "result": result, "additionalData": [String: Any]()]
            }
            if !pictures.isEmpty {
                guard type == 1 else { throw MigrationFailure.unsupported("助手消息里的图片暂不迁移。") }
                var refs: [[String: Any]] = [], selected: [[String: Any]] = []
                for image in pictures {
                    let stored = try MigrationCursorHistory.storedImage(database: path, workspaceID: workspaceID,
                                                                        image: image, loadedAt: now)
                    refs.append(stored.bubble); selected.append(stored.selected)
                }
                bubble["images"] = refs
                var context = emptyContext()
                context["selectedImages"] = selected
                bubble["context"] = context
            }
            let preview = text.isEmpty ? (message.tool?.name ?? "") : text
            headers.append(["bubbleId": id, "type": type, "createdAt": stamp,
                            "grouping": ["isRenderable": true, "hasText": !preview.isEmpty,
                                         "textPreview": String(preview.prefix(160))]])
            rows.append(("bubbleId:" + sid + ":" + id, try MigrationHistory.json(bubble)))
        }
        for message in messages {
            try appendBubble(message, pictures: message.role == .user ? message.images : [])
            if let images = message.tool?.images, !images.isEmpty {
                try appendBubble(.init(role: .user, text: "", images: images), pictures: images)
            }
        }
        var composer: [String: Any] = ["_v": 18, "composerId": sid, "name": record.desktopTitle,
            "subtitle": "来自 " + record.source.client.label, "workspaceIdentifier": profile.workspace,
            "modelConfig": profile.model, "fullConversationHeadersOnly": headers, "conversationMap": [:],
            "conversationState": state, "isNAL": true, "status": "completed", "createdAt": now,
            "lastUpdatedAt": now, "conversationCheckpointLastUpdatedAt": now, "lastReadAtMs": now,
            "text": "", "richText": "", "context": emptyContext(), "contextUsagePercent": 0,
            "codeBlockData": [:], "originalFileStates": [:], "usageData": [:],
            "hasLoaded": true, "isAgentic": true, "unifiedMode": "agent", "forceMode": "edit",
            "capabilities": [["type": 15, "data": ["bubbleDataMap": "{}"]]] + [19, 33, 32, 23, 16, 24].map { ["type": $0, "data": [:]] },
            "filesChangedCount": 0, "totalLinesAdded": 0, "totalLinesRemoved": 0, "addedFiles": 0, "removedFiles": 0]
        for key in ["queueItems", "generatingBubbleIds", "subComposerIds", "subagentComposerIds", "todos",
                    "capabilityContexts", "newlyCreatedFiles", "newlyCreatedFolders", "trackedGitRepos"] { composer[key] = [Any]() }
        for key in ["isDraft", "isProject", "isSpec", "isBestOfNParent", "isBestOfNSubcomposer", "isContinuationInProgress",
                    "isCreatingWorktree", "isApplyingWorktree", "isUndoingWorktree", "hasBlockingPendingActions", "hasPendingPlan", "applied"] { composer[key] = false }
        rows.append(("composerData:" + sid, try MigrationHistory.json(composer)))
        guard rows.reduce(0, { $0 + $1.1.count }) + encoded.blobs.values.reduce(0, { $0 + $1.count })
                <= MigrationHistory.maxFileBytes else { throw MigrationFailure.tooLarge }
        let header: [String: Any] = ["composerId": sid, "name": record.desktopTitle, "subtitle": "来自 " + record.source.client.label,
            "type": "head", "workspaceIdentifier": profile.workspace, "createdAt": now, "lastUpdatedAt": now,
            "conversationCheckpointLastUpdatedAt": now, "unifiedMode": "agent", "forceMode": "edit",
            "isDraft": false, "isProject": false, "isSpec": false, "isWorktree": false,
            "hasBlockingPendingActions": false, "contextUsagePercent": 0, "numSubComposers": 0,
            "agentLocation": ["type": "local", "environment": profile.workspace, "status": "active"],
            "agentLocationHistory": [], "trackedGitRepos": [], "referencedPlans": [],
            "filesChangedCount": 0, "totalLinesAdded": 0, "totalLinesRemoved": 0]
        var db: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { sqlite3_close(db); throw MigrationFailure.storage }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        try schema(db)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw MigrationFailure.storage }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        for (key, data) in rows { try insertKV(db, key: key, data: data, text: true) }
        for (id, data) in encoded.blobs {
            let key = "agentKv:blob:" + id
            if let existing = try existingKV(db, key: key) {
                guard existing == data else { throw MigrationFailure.invalidHistory }
            } else { try insertKV(db, key: key, data: data, text: false) }
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR ABORT INTO composerHeaders(composerId, workspaceId, createdAt, lastUpdatedAt, isArchived, isSubagent, recency, checkpointAt, value, subagentTypeName) VALUES (?, ?, ?, ?, 0, 0, ?, ?, ?, '')",
                                -1, &statement, nil) == SQLITE_OK else { throw MigrationFailure.storage }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sid, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, profile.workspace["id"] as? String ?? "", -1, SQLITE_TRANSIENT)
        for index: Int32 in [3, 4, 5, 6] { sqlite3_bind_int64(statement, index, now) }
        let headerJSON = String(decoding: try MigrationHistory.json(header), as: UTF8.self)
        sqlite3_bind_text(statement, 7, headerJSON, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MigrationFailure.storage }
        try Task.checkCancellation()
        try publish()
        try Task.checkCancellation()
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw MigrationFailure.storage }
    }

    private static func existingKV(_ db: OpaquePointer, key: String) throws -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM cursorDiskKV WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { throw MigrationFailure.storage }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw MigrationFailure.storage }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count <= MigrationHistory.maxFileBytes else { throw MigrationFailure.tooLarge }
        return Data(bytes: bytes, count: count)
    }

    private static func insertKV(_ db: OpaquePointer, key: String, data: Data, text: Bool) throws {
        var statement: OpaquePointer?
        // Native cursorDiskKV declares UNIQUE ON CONFLICT REPLACE. Override it
        // explicitly: a collision must abort, never replace another chat.
        guard sqlite3_prepare_v2(db, "INSERT OR ABORT INTO cursorDiskKV(key, value) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else { throw MigrationFailure.storage }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        if text { sqlite3_bind_text(statement, 2, String(decoding: data, as: UTF8.self), -1, SQLITE_TRANSIENT) }
        else { _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) } }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MigrationFailure.storage }
    }

    private static func emptyContext() -> [String: Any] {
        var result: [String: Any] = [:], mentions: [String: Any] = [:]
        for key in ["composers", "selectedCommits", "selectedPullRequests", "selectedImages", "selectedDocuments", "selectedVideos",
                    "folderSelections", "fileSelections", "selections", "terminalFiles", "terminalSelections", "selectedDocs", "externalLinks",
                    "cursorRules", "cursorCommands", "gitPRDiffSelections", "subagentSelections", "browserSelections"] {
            result[key] = [Any](); mentions[key] = [String: Any]()
        }
        result["extraContext"] = [Any]()
        for key in ["gitDiff", "gitDiffFromBranchToMain", "diffHistory", "uiElementSelections", "consoleLogs", "ideEditorsState"] { mentions[key] = [Any]() }
        result["mentions"] = mentions
        return result
    }
}
