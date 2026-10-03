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

    static func desktop(_ path: URL, source: MigrationSource, includeCompletedTools: Bool = false,
                        includeImages: Bool = false) throws -> MigrationPreview {
        let db = try readOnly(path)
        defer { sqlite3_close(db) }
        let data = try value(db, sql: "SELECT value FROM cursorDiskKV WHERE key = ?", key: "composerData:" + source.sessionID)
        let header = try object(value(db, sql: "SELECT value FROM composerHeaders WHERE composerId = ?", key: source.sessionID))
        guard let workspace = header["workspaceIdentifier"] as? [String: Any],
              let uri = workspace["uri"] as? [String: Any], let cwd = uri["fsPath"] as? String,
              try MigrationPath.canonical(cwd) == MigrationPath.canonical(source.cwd),
              let workspaceID = workspace["id"] as? String else {
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
        var completedTools = 0
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
            if let attachments = bubble["attachedFiles"] as? [Any], !attachments.isEmpty {
                throw MigrationFailure.unsupported("这段 Cursor 会话包含附件，暂不迁移。")
            }
            if let context = bubble["context"] as? [String: Any] {
                for key in ["selectedDocuments", "selectedVideos"] {
                    if let attachments = context[key] as? [Any], !attachments.isEmpty {
                        throw MigrationFailure.unsupported("这段 Cursor 会话包含附件，暂不迁移。")
                    }
                }
            }
            let images = try bubbleImages(bubble, database: path, workspaceID: workspaceID, includeImages: includeImages)
            if let text = bubble["text"] as? String, !text.isEmpty {
                messages.append(.init(role: type == 1 ? .user : .assistant, text: text, images: type == 1 ? images : []))
                if type != 1, !images.isEmpty {
                    throw MigrationFailure.unsupported("助手消息里的图片暂不迁移。")
                }
            } else if !images.isEmpty {
                guard type == 1 else { throw MigrationFailure.unsupported("助手消息里的图片暂不迁移。") }
                messages.append(.init(role: .user, text: "", images: images))
            }
            if let tool = try cursorTool(bubble["toolFormerData"], includeCompletedTools: includeCompletedTools, omissions: &omissions) {
                messages.append(tool)
                completedTools += 1
            }
        }
        if completedTools > 0 { omissions.append("已完成工具的输入与结果作为历史资料携带，不会重新执行。") }
        if messages.contains(where: { $0.carriedImageCount > 0 }) {
            omissions.append("已携带用户图片，写入目标会话的对应图片字段。")
        }
        return try MigrationHistory.preview(source: source, messages: messages, snapshot: snapshot,
                                            omissions: omissions, completedToolCount: completedTools)
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

    /// Production state lives in `User/globalStorage`. Tests keep images beside the database.
    static func imageDirectory(database: URL, workspaceID: String) -> URL {
        let parent = database.deletingLastPathComponent()
        let user = parent.lastPathComponent == "globalStorage" ? parent.deletingLastPathComponent() : parent
        return user.appendingPathComponent("workspaceStorage").appendingPathComponent(workspaceID)
            .appendingPathComponent("images")
    }

    static func storedImage(database: URL, workspaceID: String, image: MigrationImage, loadedAt: Int64) throws
        -> (bubble: [String: Any], selected: [String: Any]) {
        guard image.dataURL.hasPrefix("data:") else {
            throw MigrationFailure.unsupported("Cursor 只接受已验证的本地图片，暂不写入图片地址。")
        }
        let source = try MigrationHistory.imageSource(image)
        guard source["type"] as? String == "base64", let encoded = source["data"] as? String,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else {
            throw MigrationFailure.unsupported("这张图片的格式尚未验证，暂不迁移。")
        }
        let size = try pixelSize(bytes, mediaType: image.mediaType)
        let ext: String
        switch image.mediaType {
        case "image/png": ext = "png"
        case "image/jpeg": ext = "jpg"
        case "image/webp": ext = "webp"
        case "image/gif": ext = "gif"
        default: throw MigrationFailure.unsupported("这张图片的格式尚未验证，暂不迁移。")
        }
        let directory = imageDirectory(database: database, workspaceID: workspaceID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let uuid = UUID().uuidString.lowercased()
        let file = directory.appendingPathComponent(uuid + "." + ext)
        try PrivateFileWriter.write(bytes, to: file)
        let dimension: [String: Any] = ["width": size.0, "height": size.1]
        return (["uuid": uuid, "dimension": dimension],
                ["uuid": uuid, "path": file.path, "dimension": dimension, "loadedAt": NSNumber(value: loadedAt)])
    }

    private static func bubbleImages(_ bubble: [String: Any], database: URL, workspaceID: String,
                                     includeImages: Bool) throws -> [MigrationImage] {
        let listed = bubble["images"] as? [[String: Any]] ?? []
        let selected = (bubble["context"] as? [String: Any])?["selectedImages"] as? [[String: Any]] ?? []
        guard !listed.isEmpty || !selected.isEmpty else { return [] }
        guard includeImages else { throw MigrationFailure.unsupported("这段 Cursor 会话包含附件，暂不迁移。") }
        let sources = selected.isEmpty ? listed : selected
        guard sources.count <= 32, listed.isEmpty || selected.isEmpty || listed.count == selected.count else {
            throw MigrationFailure.unsupported("这张 Cursor 图片的格式尚未验证，暂不迁移。")
        }
        let root = try MigrationPath.canonical(imageDirectory(database: database, workspaceID: workspaceID).path)
        var images: [MigrationImage] = []
        for item in sources {
            guard let path = item["path"] as? String else {
                throw MigrationFailure.unsupported("这张 Cursor 图片的格式尚未验证，暂不迁移。")
            }
            let file = try MigrationPath.canonical(path)
            guard file == root || file.hasPrefix(root + "/") else {
                throw MigrationFailure.unsupported("这张 Cursor 图片不在已验证的图片目录里，暂不迁移。")
            }
            let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
            let media: String
            switch ext {
            case "png": media = "image/png"
            case "jpg", "jpeg": media = "image/jpeg"
            case "webp": media = "image/webp"
            case "gif": media = "image/gif"
            default: throw MigrationFailure.unsupported("这张 Cursor 图片的格式尚未验证，暂不迁移。")
            }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
            guard bytes.count <= ConversationMedia.maxBytes, !bytes.isEmpty else { throw MigrationFailure.tooLarge }
            images.append(try MigrationHistory.parseImageBlock([
                "image_url": "data:" + media + ";base64," + bytes.base64EncodedString()
            ]))
        }
        return images
    }

    private static func cursorTool(_ raw: Any?, includeCompletedTools: Bool,
                                   omissions: inout [String]) throws -> MigrationMessage? {
        guard let data = raw as? [String: Any] else { return nil }
        guard includeCompletedTools else {
            omissions.append("历史工具调用未重放；请在来源查看完整工具结果。")
            return nil
        }
        let status = data["status"] as? String ?? ""
        if status == "loading" { throw MigrationFailure.busy }
        guard ["completed", "error"].contains(status), let name = data["name"] as? String,
              let code = data["tool"] as? Int, (0..<256).contains(code) else {
            omissions.append("历史工具调用未重放；请在来源查看完整工具结果。")
            return nil
        }
        guard let result = data["result"] as? String ?? data["error"] as? String else {
            omissions.append("历史工具调用未重放；请在来源查看完整工具结果。")
            return nil
        }
        let rawArgs = data["rawArgs"] as? String ?? ""
        let input: Any
        if (rawArgs.hasPrefix("{") || rawArgs.hasPrefix("[")),
           let parsed = try? JSONSerialization.jsonObject(with: Data(rawArgs.utf8)) {
            input = parsed
        } else {
            input = rawArgs
        }
        return try MigrationHistory.toolContext(name: name, input: input, output: result, kind: "cursor",
                                                cursorTool: code, cursorStatus: status)
    }

    private static func pixelSize(_ data: Data, mediaType: String) throws -> (Int, Int) {
        let bytes = [UInt8](data)
        func pair(_ width: Int, _ height: Int) throws -> (Int, Int) {
            guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
                throw MigrationFailure.unsupported("这张图片的格式尚未验证，暂不迁移。")
            }
            return (width, height)
        }
        switch mediaType {
        case "image/png":
            guard bytes.count >= 24, bytes[0] == 0x89, bytes[1] == 0x50 else { break }
            let width = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
            let height = Int(bytes[20]) << 24 | Int(bytes[21]) << 16 | Int(bytes[22]) << 8 | Int(bytes[23])
            return try pair(width, height)
        case "image/gif":
            guard bytes.count >= 10, bytes[0] == 0x47, bytes[1] == 0x49 else { break }
            return try pair(Int(bytes[6]) | Int(bytes[7]) << 8, Int(bytes[8]) | Int(bytes[9]) << 8)
        case "image/jpeg":
            guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { break }
            var index = 2
            while index + 8 < bytes.count, bytes[index] == 0xFF {
                let marker = bytes[index + 1]
                if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                    let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                    let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                    return try pair(width, height)
                }
                let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
                guard length >= 2 else { break }
                index += 2 + length
            }
        case "image/webp":
            guard bytes.count >= 30, bytes[0] == 0x52, bytes[8] == 0x57, bytes[12] == 0x56,
                  bytes[15] == 0x58 else { break }
            let width = Int(bytes[24]) | Int(bytes[25]) << 8 | Int(bytes[26]) << 16
            let height = Int(bytes[27]) | Int(bytes[28]) << 8 | Int(bytes[29]) << 16
            return try pair(width + 1, height + 1)
        default: break
        }
        throw MigrationFailure.unsupported("这张图片的格式尚未验证，暂不迁移。")
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
        guard messages.allSatisfy({ $0.carriedImageCount == 0 }) else {
            throw MigrationFailure.unsupported("Cursor 尚不能写入图片。请改迁到 Claude Code 或 Codex，或取消包含图片。")
        }
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
