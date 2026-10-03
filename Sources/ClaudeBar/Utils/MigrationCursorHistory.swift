import Foundation
import CryptoKit
import SQLite3

enum MigrationCursorHistory {
    struct Field { let number: Int; let bytes: Data?; let integer: UInt64? }

    static func varint(_ input: UInt64) -> Data {
        var value = input, output = Data()
        while value > 127 { output.append(UInt8(value & 127) | 128); value >>= 7 }
        output.append(UInt8(value)); return output
    }

    static func field(_ number: Int, _ bytes: Data) -> Data {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    /// Bounded wire decoder. A corrupt length/varint cannot escape the snapshot.
    static func fields(_ data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var offset = 0, output: [Field] = []
        func read() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw MigrationFailure.invalidHistory }
                let byte = bytes[offset]; offset += 1
                if shift == 63 && byte > 1 { throw MigrationFailure.invalidHistory }
                result |= UInt64(byte & 127) << shift
                if byte < 128 { return result }
            }
            throw MigrationFailure.invalidHistory
        }
        while offset < bytes.count {
            let tag = try read()
            guard tag >> 3 > 0 else { throw MigrationFailure.invalidHistory }
            if tag & 7 == 0 { output.append(.init(number: Int(tag >> 3), bytes: nil, integer: try read())); continue }
            let count: Int
            switch tag & 7 {
            case 2:
                let length = try read()
                guard length <= UInt64(bytes.count - offset) else { throw MigrationFailure.invalidHistory }
                count = Int(length)
            case 1: count = 8
            case 5: count = 4
            default: throw MigrationFailure.invalidHistory
            }
            guard count <= bytes.count - offset else { throw MigrationFailure.invalidHistory }
            output.append(.init(number: Int(tag >> 3), bytes: Data(bytes[offset..<offset + count]), integer: nil))
            offset += count
        }
        return output
    }

    static func workspaceHash(_ cwd: String) throws -> String {
        Insecure.MD5.hash(data: Data(try MigrationPath.canonical(cwd).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func readOnly(_ path: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = db else { sqlite3_close(db); throw MigrationFailure.missing }
        sqlite3_busy_timeout(opened, 2000)
        guard sqlite3_exec(opened, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(opened); throw MigrationFailure.storage
        }
        return opened
    }

    static func value(_ db: OpaquePointer, sql: String, key: String) throws -> Data {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw MigrationFailure.invalidHistory }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else {
            throw MigrationFailure.invalidHistory
        }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard count <= MigrationHistory.maxFileBytes else { throw MigrationFailure.tooLarge }
        return Data(bytes: bytes, count: count)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MigrationFailure.invalidHistory
        }
        return object
    }

    static func desktop(_ path: URL, source: MigrationSource) throws -> MigrationPreview {
        let db = try readOnly(path)
        defer { sqlite3_close(db) }
        let data = try value(db, sql: "SELECT value FROM cursorDiskKV WHERE key = ?", key: "composerData:" + source.sessionID)
        let header = try object(value(db, sql: "SELECT value FROM composerHeaders WHERE composerId = ?", key: source.sessionID))
        guard let workspace = header["workspaceIdentifier"] as? [String: Any],
              let uri = workspace["uri"] as? [String: Any], let cwd = uri["fsPath"] as? String,
              try MigrationPath.canonical(cwd) == MigrationPath.canonical(source.cwd) else {
            throw MigrationFailure.invalidHistory
        }
        let composer = try object(data)
        guard composer["composerId"] as? String == source.sessionID else { throw MigrationFailure.invalidHistory }
        guard composer["status"] as? String != "generating",
              composer["hasPendingPlan"] as? Bool != true,
              composer["hasBlockingPendingActions"] as? Bool != true else { throw MigrationFailure.busy }
        guard let headers = composer["fullConversationHeadersOnly"] as? [[String: Any]],
              headers.count <= MigrationHistory.maxMessages else { throw MigrationFailure.invalidHistory }
        var messages: [MigrationMessage] = [], snapshot = data, seen: Set<String> = []
        var omissions = ["Cursor 的文件上下文和非正文工具细节不迁移。"]
        for header in headers {
            guard let id = header["bubbleId"] as? String, UUID(uuidString: id) != nil,
                  seen.insert(id).inserted else { throw MigrationFailure.invalidHistory }
            let data = try value(db, sql: "SELECT value FROM cursorDiskKV WHERE key = ?",
                                 key: "bubbleId:" + source.sessionID + ":" + id)
            guard snapshot.count + data.count <= MigrationHistory.maxFileBytes else { throw MigrationFailure.tooLarge }
            snapshot.append(data)
            let bubble = try object(data)
            let type = bubble["type"] as? Int
            guard type == 1 || type == 2 else {
                omissions.append("Cursor 的非正文记录未迁移。"); continue
            }
            for key in ["attachedFiles", "images"] {
                if let attachments = bubble[key] as? [Any], !attachments.isEmpty {
                    throw MigrationFailure.unsupported("这段 Cursor 会话包含附件，暂不迁移。")
                }
            }
            if let context = bubble["context"] as? [String: Any] {
                for key in ["selectedImages", "selectedDocuments", "selectedVideos"] {
                    if let attachments = context[key] as? [Any], !attachments.isEmpty {
                        throw MigrationFailure.unsupported("这段 Cursor 会话包含附件，暂不迁移。")
                    }
                }
            }
            if let text = bubble["text"] as? String, !text.isEmpty {
                messages.append(.init(role: type == 1 ? .user : .assistant, text: text))
            }
            if bubble["toolFormerData"] != nil { omissions.append("历史工具调用未重放；请在来源查看完整工具结果。") }
        }
        return try MigrationHistory.preview(source: source, messages: messages, snapshot: snapshot, omissions: omissions)
    }

    static func cli(_ path: URL, source: MigrationSource) throws -> MigrationPreview {
        // The native CLI can return its answer before all referenced blobs
        // finish landing. Each retry gets a fresh read transaction.
        for attempt in 0..<6 {
            try Task.checkCancellation()
            do { return try cliSnapshot(path, source: source) }
            catch MigrationFailure.pendingPersistence {
                guard attempt < 5 else { throw MigrationFailure.pendingPersistence }
                Thread.sleep(forTimeInterval: 0.1 * pow(2, Double(attempt)))
            }
        }
        throw MigrationFailure.pendingPersistence
    }

    private static func cliSnapshot(_ path: URL, source: MigrationSource) throws -> MigrationPreview {
        let db = try readOnly(path)
        defer { sqlite3_close(db) }
        let metaData = try value(db, sql: "SELECT value FROM meta WHERE key = ?", key: "0")
        guard let hex = String(data: metaData, encoding: .utf8),
              let decoded = decodeHex(hex) else { throw MigrationFailure.invalidHistory }
        let meta = try object(decoded)
        guard meta["agentId"] as? String == source.sessionID,
              let rootID = meta["latestRootBlobId"] as? String else { throw MigrationFailure.invalidHistory }
        func blob(_ id: String) throws -> Data {
            let data: Data
            do { data = try value(db, sql: "SELECT data FROM blobs WHERE id = ?", key: id) }
            catch MigrationFailure.invalidHistory { throw MigrationFailure.pendingPersistence }
            guard MigrationHistory.fingerprint(data) == id else { throw MigrationFailure.invalidHistory }
            return data
        }
        let root = try blob(rootID), references = try fields(root)
        guard let workspace = references.first(where: { $0.number == 9 })?.bytes,
              let uri = String(data: workspace, encoding: .utf8),
              let workspaceURL = URL(string: uri), workspaceURL.isFileURL,
              try MigrationPath.canonical(workspaceURL.path) == MigrationPath.canonical(source.cwd) else {
            throw MigrationFailure.invalidHistory
        }
        var messages: [MigrationMessage] = [], snapshot = root, omissions: [String] = []
        for field in references where field.number == 1 {
            guard let hash = field.bytes, hash.count == 32 else { throw MigrationFailure.invalidHistory }
            let id = hash.map { String(format: "%02x", $0) }.joined()
            let data = try blob(id), message = try object(data)
            guard snapshot.count + data.count <= MigrationHistory.maxFileBytes else { throw MigrationFailure.tooLarge }
            snapshot.append(data)
            guard let role = MigrationMessage.Role(rawValue: message["role"] as? String ?? "") else { continue }
            try MigrationHistory.checkTextOnly(message["content"], omissions: &omissions)
            var body = MigrationHistory.text(message["content"])
            if role == .user, let start = body.range(of: "<user_query>"),
               let end = body.range(of: "</user_query>", range: start.upperBound..<body.endIndex) {
                body = String(body[start.upperBound..<end.lowerBound])
            } else if role == .user, body.hasPrefix("<user_info>") { continue }
            if role == .user {
                body = body.replacingOccurrences(of: #"<system_reminder>[\s\S]*?</system_reminder>"#,
                                                 with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !body.isEmpty { messages.append(.init(role: role, text: body)) }
        }
        guard messages.last?.role == .assistant else { throw MigrationFailure.pendingPersistence }
        return try MigrationHistory.preview(source: source, messages: messages, snapshot: snapshot, omissions: omissions)
    }

    static func decodeHex(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var output = Data()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(bytes: bytes[index..<index + 2], encoding: .utf8) ?? "", radix: 16) else { return nil }
            output.append(byte)
        }
        return output
    }

    static func payload(_ messages: [MigrationMessage], cwd: String, mode: UInt64) throws
        -> (root: Data, rootID: String, blobs: [String: Data]) {
        var blobs: [String: Data] = [:]
        func store(_ data: Data) -> Data {
            let id = MigrationHistory.fingerprint(data)
            blobs[id] = data
            return decodeHex(id)!
        }
        var messageHashes: [Data] = []
        for message in messages {
            messageHashes.append(store(try MigrationHistory.json(["role": message.role.rawValue,
                "content": [["type": "text", "text": message.text]]])))
        }
        var turnHashes: [Data] = [], pending: String?, answers: [String] = []
        func flush() {
            guard let pending else { return }
            let user = store(field(1, Data(pending.utf8)) + field(2, Data(UUID().uuidString.utf8)))
            var turn = field(1, user)
            for answer in answers { turn += field(2, store(field(1, field(1, Data(answer.utf8))))) }
            turn += field(3, Data(UUID().uuidString.utf8))
            turnHashes.append(store(field(1, turn)))
        }
        for message in messages {
            if message.role == .user { flush(); pending = message.text; answers = [] }
            else if pending != nil { answers.append(message.text) }
        }
        flush()
        var root = Data()
        for hash in messageHashes { root += field(1, hash) }
        for hash in turnHashes { root += field(8, hash) }
        root += field(9, Data(URL(fileURLWithPath: try MigrationPath.canonical(cwd), isDirectory: false).absoluteString.utf8))
        root += varint(10 << 3) + varint(mode)
        let rootHash = store(root).map { String(format: "%02x", $0) }.joined()
        return (root, rootHash, blobs)
    }

    static func writeCLI(_ messages: [MigrationMessage], sessionID: String, cwd: String, to path: URL) throws {
        guard !FileManager.default.fileExists(atPath: path.path) else { throw MigrationFailure.storage }
        let encoded = try payload(messages, cwd: cwd, mode: 2) // Ask mode.
        var db: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE, nil) == SQLITE_OK,
              let db else { sqlite3_close(db); throw MigrationFailure.storage }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA user_version=1; CREATE TABLE blobs(id TEXT PRIMARY KEY,data BLOB); CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT); BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw MigrationFailure.storage
        }
        func insert(_ sql: String, key: String, data: Data, text: Bool = false) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw MigrationFailure.storage }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            if text {
                sqlite3_bind_text(stmt, 2, String(decoding: data, as: UTF8.self), -1, SQLITE_TRANSIENT)
            } else {
                _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw MigrationFailure.storage }
        }
        for (key, data) in encoded.blobs { try insert("INSERT INTO blobs VALUES (?, ?)", key: key, data: data) }
        let meta = try MigrationHistory.json(["agentId": sessionID, "latestRootBlobId": encoded.rootID,
            "name": "ClaudeBar · 迁移会话", "mode": "search", "isRunEverything": false,
            "createdAt": Int(Date().timeIntervalSince1970 * 1000)])
        let hex = meta.map { String(format: "%02x", $0) }.joined()
        try insert("INSERT INTO meta VALUES (?, ?)", key: "0", data: Data(hex.utf8), text: true)
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw MigrationFailure.storage }
        PrivateFileWriter.harden(path)
    }
}
