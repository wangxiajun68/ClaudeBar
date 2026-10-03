import Foundation

struct MigrationLocations: Sendable {
    let claude: URL
    let codex: URL
    let cursorCLI: URL
    let records: URL
    var cursorDesktop: URL? = nil

    func nativeURL(client: MigrationClient, sessionID: String, cwd: String, now: Date = Date()) throws -> URL {
        guard UUID(uuidString: sessionID) != nil else { throw MigrationFailure.invalidHistory }
        switch client {
        case .claude:
            // Claude's JavaScript path encoding replaces each non-ASCII UTF-16 unit.
            let slug = try MigrationPath.canonical(cwd).utf16.map { byte -> String in
                ((48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte))
                    ? String(UnicodeScalar(UInt8(byte))) : "-"
            }.joined()
            guard slug.count <= 200 else {
                throw MigrationFailure.unsupported("Claude Code 的工作目录编码过长，首版暂不向这个目录迁移。")
            }
            return claude.appendingPathComponent("projects").appendingPathComponent(slug)
                .appendingPathComponent(sessionID + ".jsonl")
        case .codex:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy/MM/dd"
            let folder = codex.appendingPathComponent("sessions/" + formatter.string(from: now))
            formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            return folder.appendingPathComponent("rollout-" + formatter.string(from: now) + "-" + sessionID + ".jsonl")
        case .cursorCLI:
            return cursorCLI.appendingPathComponent("chats")
                .appendingPathComponent(try MigrationCursorHistory.workspaceHash(cwd))
                .appendingPathComponent(sessionID).appendingPathComponent("store.db")
        case .cursorDesktop:
            guard let cursorDesktop else { throw MigrationFailure.missing }
            return cursorDesktop
        }
    }

    func containsNative(_ path: URL, client: MigrationClient) -> Bool {
        let root: URL
        switch client {
        case .claude: root = claude.appendingPathComponent("projects")
        case .codex: root = codex.appendingPathComponent("sessions")
        case .cursorCLI: root = cursorCLI.appendingPathComponent("chats")
        case .cursorDesktop:
            guard let cursorDesktop, let candidate = try? MigrationPath.canonical(path.path),
                  let expected = try? MigrationPath.canonical(cursorDesktop.path) else { return false }
            return candidate == expected
        }
        guard let resolved = try? MigrationPath.canonical(path.path),
              let prefix = try? MigrationPath.canonical(root.path) else { return false }
        return resolved.hasPrefix(prefix + "/")
    }
}

struct MigrationRoute: Sendable {
    let model: String
    let providerKey: String
    let configurationFingerprint: String?
    let executablePath: String
    var bridgeProviderID: UUID? = nil
}

/// Transaction over new files only: stage privately, install without replacing,
/// publish a manifest last. A failure rolls back our target, never the source.
enum MigrationStorage {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    static func records(at root: URL) throws -> [MigrationRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var records: [MigrationRecord] = []
        for file in files where file.pathExtension == "json" {
            let data = try readBounded(file)
            guard let record = try? JSONDecoder().decode(MigrationRecord.self, from: data),
                  record.formatVersion == 1, file.deletingPathExtension().lastPathComponent == record.id.uuidString,
                  UUID(uuidString: record.targetSessionID) != nil else { throw MigrationFailure.invalidHistory }
            records.append(record)
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    static func readBounded(_ file: URL, maxBytes: Int = MigrationHistory.maxFileBytes) throws -> Data {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) } catch { throw MigrationFailure.missing }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else {
            throw MigrationFailure.sizeLimit("源文件超过 \(maxBytes / (1024 * 1024)) MiB 读取上限，请在来源客户端整理交接上下文后迁移。")
        }
        return data
    }

    static func prepare(_ preview: MigrationPreview, target: MigrationTarget, route: MigrationRoute,
                        locations: MigrationLocations) throws -> MigrationRecord {
        guard !preview.source.isBusy else { throw MigrationFailure.busy }
        guard !preview.source.isSubagent else { throw MigrationFailure.unsupported("首版不迁移子代理会话。") }
        if preview.imageCount > 0, target.client == .cursorCLI {
            throw MigrationFailure.unsupported("Cursor CLI 尚不能写入图片。请改迁到 Claude Code、Codex 或 Cursor 桌面，或取消包含图片。")
        }
        let desktopProfile: MigrationCursorDesktop.Profile?
        if target == .cursorDesktop {
            guard let database = locations.cursorDesktop else { throw MigrationFailure.missing }
            let profile = try MigrationCursorDesktop.profile(database, cwd: preview.source.cwd)
            guard profile.modelName == route.model,
                  try profile.fingerprint() == route.configurationFingerprint else { throw MigrationFailure.changed }
            desktopProfile = profile
        } else { desktopProfile = nil }
        let old = try records(at: locations.records)
        if let reused = old.first(where: {
            $0.source.id == preview.source.id && $0.sourceFingerprint == preview.fingerprint && $0.target == target
                && $0.model == route.model && $0.providerKey == route.providerKey
                && $0.configurationFingerprint == route.configurationFingerprint && $0.executablePath == route.executablePath
                && $0.bridgeProviderID == route.bridgeProviderID
        }), locations.containsNative(URL(fileURLWithPath: reused.nativePath), client: reused.target.client),
           try exists(reused) {
            return reused
        }
        try Task.checkCancellation()
        let id = UUID(), targetID = UUID().uuidString.lowercased(), now = Date()
        let targetPath = try locations.nativeURL(client: target.client, sessionID: targetID,
                                                 cwd: preview.source.cwd, now: now)
        guard locations.containsNative(targetPath, client: target.client) else { throw MigrationFailure.storage }
        let parent = old.first { $0.target.client == preview.source.client && $0.targetSessionID == preview.source.sessionID }
        let record = MigrationRecord(id: id, logicalConversationID: parent?.logicalConversationID ?? id,
            createdAt: now, source: preview.source, sourceFingerprint: preview.fingerprint,
            target: target, targetSessionID: targetID, nativePath: targetPath.path,
            messageCount: preview.messages.count, omissions: preview.omissions, model: route.model,
            providerKey: route.providerKey, configurationFingerprint: route.configurationFingerprint,
            executablePath: route.executablePath, bridgeProviderID: route.bridgeProviderID)
        let manifest = locations.records.appendingPathComponent(id.uuidString + ".json")
        if let profile = desktopProfile {
            try directory(locations.records)
            do {
                try MigrationCursorDesktop.insert(preview.messages, record: record, profile: profile, database: targetPath) {
                    try PrivateFileWriter.write(JSONEncoder().encode(record), to: manifest)
                }
            } catch {
                try? FileManager.default.removeItem(at: manifest)
                throw error
            }
            return record
        }
        let staging = locations.records.appendingPathComponent(".staging-" + id.uuidString)
        try directory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(targetPath.lastPathComponent)
        switch target.client {
        case .claude:
            try PrivateFileWriter.write(MigrationHistory.claudeData(preview.messages, sessionID: targetID,
                                         cwd: preview.source.cwd), to: staged)
        case .codex:
            try PrivateFileWriter.write(MigrationHistory.codexData(preview.messages, sessionID: targetID,
                cwd: preview.source.cwd, providerKey: route.providerKey), to: staged)
        case .cursorCLI:
            try MigrationCursorHistory.writeCLI(preview.messages, sessionID: targetID, cwd: preview.source.cwd, to: staged)
        case .cursorDesktop: throw MigrationFailure.invalidHistory // Handled transactionally above.
        }
        try Task.checkCancellation()
        try directory(targetPath.deletingLastPathComponent())
        // Reject replacement, including a race with another creator.
        try FileManager.default.moveItem(at: staged, to: targetPath)
        do {
            try Task.checkCancellation()
            try directory(locations.records)
            try PrivateFileWriter.write(JSONEncoder().encode(record),
                                        to: locations.records.appendingPathComponent(id.uuidString + ".json"))
        } catch {
            try? FileManager.default.removeItem(at: targetPath)
            throw error
        }
        return record
    }

    static func exists(_ record: MigrationRecord) throws -> Bool {
        guard FileManager.default.fileExists(atPath: record.nativePath) else { return false }
        if record.target == .cursorDesktop {
            return try MigrationCursorDesktop.contains(URL(fileURLWithPath: record.nativePath), sessionID: record.targetSessionID)
        }
        return true
    }
}

enum MigrationCommand {
    /// Fixed-version local chat selection; verified against Cursor 3.23.12.
    static func desktopURL(for record: MigrationRecord) throws -> URL {
        guard record.target == .cursorDesktop, UUID(uuidString: record.targetSessionID) != nil,
              record.formatVersion == 1 else { throw MigrationFailure.invalidHistory }
        var components = URLComponents()
        components.scheme = "cursor"; components.host = "anysphere.cursor-deeplink"
        components.path = "/background-agent"
        components.queryItems = [.init(name: "bcId", value: record.targetSessionID)]
        guard let url = components.url else { throw MigrationFailure.invalidHistory }
        return url
    }

    static func arguments(for record: MigrationRecord, bridge: MigrationBridgeLaunch? = nil) throws -> [String] {
        guard UUID(uuidString: record.targetSessionID) != nil, record.formatVersion == 1 else {
            throw MigrationFailure.invalidHistory
        }
        switch record.target {
        case .claude: return ["--resume", record.targetSessionID]
        case .claudeCodexModel:
            guard let bridge, record.bridgeProviderID != nil else { throw MigrationFailure.changed }
            let settings = try bridge.settings(record: record)
            return ["--model", record.model, "--settings", settings, "--resume", record.targetSessionID]
        case .cursorCLI: return ["--workspace", record.source.cwd, "--mode", "ask", "--model", "auto", "--resume", record.targetSessionID]
        case .cursorDesktop: throw MigrationFailure.unsupported("Cursor 桌面通过项目窗口打开。")
        case .codexCurrent:
            return ["-c", "model_provider=" + toml(record.providerKey)] +
                (record.model.isEmpty ? [] : ["-m", record.model]) + ["resume", record.targetSessionID]
        case .codexOfficial:
            let provider = "claudebar_migration_official"
            return ["-c", "model_provider=" + toml(provider),
                    "-c", "model_providers." + provider + ".name=\"Official OpenAI\"",
                    "-c", "model_providers." + provider + ".requires_openai_auth=true",
                    "-c", "model_providers." + provider + ".supports_websockets=false",
                    "-c", "model_providers." + provider + ".wire_api=\"responses\"",
                    "-m", record.model, "resume", record.targetSessionID]
        }
    }

    static func toml(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"" + escaped + "\""
    }

    static func shell(for record: MigrationRecord, locations: MigrationLocations, bridge: MigrationBridgeLaunch? = nil) throws -> String {
        var environment: [String] = []
        switch record.target.client {
        case .claude: environment = ["CLAUDE_CONFIG_DIR=" + locations.claude.path]
        case .codex: environment = ["CODEX_HOME=" + locations.codex.path]
        case .cursorCLI: environment = ["CURSOR_CONFIG_DIR=" + locations.cursorCLI.path]
        case .cursorDesktop: throw MigrationFailure.invalidHistory
        }
        return (["env"] + environment.map(ShellQuote.single) + [ShellQuote.single(record.executablePath)]
                + (try arguments(for: record, bridge: bridge)).map(ShellQuote.single)).joined(separator: " ")
    }
}
