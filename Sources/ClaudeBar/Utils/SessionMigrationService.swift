import Foundation

/// Actor owns file work; every external read, materialization and runtime probe
/// is gated before touching real client data. No environment bypass in dev.
actor SessionMigrationService {
    static let shared = SessionMigrationService()

    static var locations: MigrationLocations {
        .init(claude: FilePaths.claudeDir, codex: FilePaths.codexDir,
              cursorCLI: FilePaths.cursorCLIConfigDir, records: FilePaths.sessionMigrationsDir,
              cursorDesktop: FilePaths.cursorStateDB)
    }

    func records() throws -> [MigrationRecord] { try MigrationStorage.records(at: Self.locations.records) }

    func preview(_ source: MigrationSource, includeCompletedTools: Bool = false,
                 includeImages: Bool = false) async throws -> MigrationPreview {
        guard BuildChannel.allowsSystemIntegration else { throw MigrationFailure.restricted }
        try Task.checkCancellation()
        guard UUID(uuidString: source.sessionID) != nil, !source.cwd.isEmpty,
              source.cwd.hasPrefix("/"),
              !source.cwd.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw MigrationFailure.invalidHistory
        }
        guard !source.isBusy else { throw MigrationFailure.busy }
        guard !source.isSubagent else { throw MigrationFailure.unsupported("首版不迁移子代理会话。") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw MigrationFailure.unsupported("工作目录不存在，无法在原项目继续。") }
        let locations = Self.locations
        switch source.client {
        case .claude:
            if SessionMonitor.fetchActive().contains(where: {
                $0.sessionId == source.sessionID && ($0.isBusy || $0.isWaiting || $0.toolPending)
            }) { throw MigrationFailure.busy }
            let root = locations.claude.appendingPathComponent("projects")
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let paths = files.map { $0.appendingPathComponent(source.sessionID + ".jsonl") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard paths.count == 1, locations.containsNative(paths[0], client: .claude) else { throw MigrationFailure.missing }
            return try MigrationHistory.claude(MigrationStorage.readBounded(paths[0], maxBytes: MigrationHistory.maxSourceFileBytes), source: source,
                                               includeCompletedTools: includeCompletedTools, includeImages: includeImages)
        case .codex:
            let root = locations.codex.appendingPathComponent("sessions")
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { throw MigrationFailure.missing }
            var found: URL?, count = 0
            for case let file as URL in enumerator {
                count += 1
                guard count <= 60_000 else { throw MigrationFailure.tooLarge }
                if file.lastPathComponent.hasSuffix(source.sessionID + ".jsonl") {
                    guard found == nil, locations.containsNative(file, client: .codex) else { throw MigrationFailure.invalidHistory }
                    found = file
                }
                try Task.checkCancellation()
            }
            guard let found else { throw MigrationFailure.missing }
            return try MigrationHistory.codex(MigrationStorage.readBounded(found, maxBytes: MigrationHistory.maxSourceFileBytes), source: source,
                                              includeCompletedTools: includeCompletedTools, includeImages: includeImages)
        case .cursorDesktop:
            _ = try cursorApplication()
            return try MigrationCursorHistory.desktop(FilePaths.cursorStateDB, source: source,
                                                      includeCompletedTools: includeCompletedTools,
                                                      includeImages: includeImages)
        case .cursorCLI:
            let path = try locations.nativeURL(client: .cursorCLI, sessionID: source.sessionID, cwd: source.cwd)
            guard locations.containsNative(path, client: .cursorCLI) else { throw MigrationFailure.invalidHistory }
            return try await MigrationCursorHistory.cli(path, source: source)
        }
    }

    func prepare(source: MigrationSource, target: MigrationTarget, fingerprint: String,
                 officialModel: String, includeCompletedTools: Bool = false, includeImages: Bool = false,
                 bridgeProviderID: UUID? = nil, bridgeModel: String = "") async throws -> MigrationRecord {
        guard BuildChannel.allowsSystemIntegration else { throw MigrationFailure.restricted }
        let latest = try await preview(source, includeCompletedTools: includeCompletedTools, includeImages: includeImages)
        guard latest.fingerprint == fingerprint else { throw MigrationFailure.changed }
        let executable = try runtime(target.client)
        let configuration: URL?
        var routeFingerprint: String?
        let model: String, provider: String
        switch target {
        case .claude:
            configuration = FilePaths.settingsFile
            model = "当前 Claude Code 配置"; provider = ""
        case .claudeCodexModel:
            guard let bridgeProviderID else { throw MigrationFailure.unsupported("请选择自定义供应商与模型。") }
            let endpoint = try MigrationBridgeConfiguration.endpoint(MigrationStorage.readBounded(FilePaths.codexProvidersFile),
                providerID: bridgeProviderID, model: bridgeModel, localProxyPort: LocalProxyAddress.port)
            configuration = nil
            routeFingerprint = try MigrationBridgeConfiguration.fingerprint(endpoint)
            model = endpoint.model; provider = "migration:" + bridgeProviderID.uuidString.lowercased()
        case .cursorCLI:
            configuration = nil; model = "Auto"; provider = ""
        case .cursorDesktop:
            configuration = nil
            let profile = try MigrationCursorDesktop.profile(FilePaths.cursorStateDB, cwd: source.cwd)
            model = profile.modelName
            routeFingerprint = try profile.fingerprint()
            provider = ""
        case .codexCurrent:
            configuration = FilePaths.codexConfigFile
            guard let selected = CodexConfigWriter.readSelection() else {
                throw MigrationFailure.unsupported("未找到当前 Codex 配置，请先配置或选择官方登录。")
            }
            model = selected.model; provider = selected.providerKey
        case .codexOfficial:
            try requireOfficialLogin()
            configuration = nil
            model = officialModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, model.utf8.count <= 160,
                  model.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
                throw MigrationFailure.unsupported("请填写官方账号可用的模型名称。")
            }
            provider = "claudebar_migration_official"
        }
        let configHash = try configuration.map { try configurationHash($0) }
        let route = MigrationRoute(model: model, providerKey: provider,
            configurationFingerprint: routeFingerprint ?? configHash, executablePath: executable.path,
            bridgeProviderID: target == .claudeCodexModel ? bridgeProviderID : nil)
        // Version probing can take time; source must still be a complete unchanged snapshot.
        let checked = try await preview(source, includeCompletedTools: includeCompletedTools, includeImages: includeImages)
        guard checked.fingerprint == latest.fingerprint else { throw MigrationFailure.changed }
        return try MigrationStorage.prepare(checked, target: target, route: route, locations: Self.locations)
    }

    func command(for record: MigrationRecord, bridge: MigrationBridgeLaunch? = nil) throws -> String {
        guard BuildChannel.allowsSystemIntegration else { throw MigrationFailure.restricted }
        guard Self.locations.containsNative(URL(fileURLWithPath: record.nativePath), client: record.target.client),
              try MigrationStorage.exists(record),
              FileManager.default.fileExists(atPath: record.source.cwd) else { throw MigrationFailure.missing }
        if record.target == .codexOfficial { try requireOfficialLogin() }
        let executable = try runtime(record.target.client)
        guard executable.path == record.executablePath else { throw MigrationFailure.changed }
        if record.target == .cursorDesktop {
            // Validate native identity and cwd, including crash-before-commit records.
            _ = try MigrationCursorHistory.desktop(URL(fileURLWithPath: record.nativePath), source: record.targetSource)
            return ""
        }
        if record.target == .claudeCodexModel { _ = try bridgeEndpoint(for: record) }
        else if let expected = record.configurationFingerprint {
            let configuration = record.target == .claude ? FilePaths.settingsFile : FilePaths.codexConfigFile
            guard try configurationHash(configuration) == expected else {
                throw MigrationFailure.changed
            }
        }
        return try MigrationCommand.shell(for: record, locations: Self.locations, bridge: bridge)
    }

    func bridgeEndpoint(for record: MigrationRecord) throws -> MigrationBridgeEndpoint {
        guard BuildChannel.allowsSystemIntegration else { throw MigrationFailure.restricted }
        guard record.target == .claudeCodexModel, let id = record.bridgeProviderID,
              Self.locations.containsNative(URL(fileURLWithPath: record.nativePath), client: .claude),
              try MigrationStorage.exists(record) else { throw MigrationFailure.changed }
        let endpoint = try MigrationBridgeConfiguration.endpoint(MigrationStorage.readBounded(FilePaths.codexProvidersFile),
            providerID: id, model: record.model, localProxyPort: LocalProxyAddress.port)
        guard try MigrationBridgeConfiguration.fingerprint(endpoint) == record.configurationFingerprint else { throw MigrationFailure.changed }
        return endpoint
    }

    private func requireOfficialLogin() throws {
        guard BuildChannel.allowsSystemIntegration else { throw MigrationFailure.restricted }
        guard let data = try? MigrationStorage.readBounded(FilePaths.codexAuthFile),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              CodexConfigWriter.hasOfficialLogin(auth) else {
            throw MigrationFailure.unsupported("未找到 ChatGPT 官方登录，请先在 Codex 中登录后再迁移。")
        }
    }

    private func configurationHash(_ path: URL) throws -> String {
        // A native official CC login can legitimately have no settings file.
        let metadata = path == FilePaths.codexConfigFile ? FilePaths.codexProvidersFile : FilePaths.presetsFile
        var snapshot = Data()
        for file in [path, metadata] {
            let data = FileManager.default.fileExists(atPath: file.path)
                ? try MigrationStorage.readBounded(file) : Data()
            snapshot.append(Data(String(data.count).utf8)); snapshot.append(0)
            snapshot.append(data)
        }
        return MigrationHistory.fingerprint(snapshot)
    }

    private func runtime(_ client: MigrationClient) throws -> URL {
        guard BuildChannel.allowsSystemIntegration else { throw MigrationFailure.restricted }
        let name: String, expected: String
        switch client {
        case .claude: name = "claude"; expected = "2.1.288 (Claude Code)"
        case .codex: name = "codex"; expected = "codex-cli 0.159.0-alpha.12.1"
        case .cursorCLI: name = "agent"; expected = "2026.06.19-20-24-33-653a7fb"
        case .cursorDesktop:
            let executable = try cursorApplication().appendingPathComponent("Contents/MacOS/Cursor")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw MigrationFailure.unavailable(client.label) }
            return executable
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [home + "/.local/bin/" + name, "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + name }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MigrationFailure.unavailable(client.label)
        }
        let executable = URL(fileURLWithPath: path)
        let version = try version(executable)
        guard version == expected else {
            throw MigrationFailure.unsupported(client.label + " 版本尚未验证（" + version + "），首版不会写入其会话。")
        }
        return executable
    }

    private func cursorApplication() throws -> URL {
        guard BuildChannel.allowsSystemIntegration else { throw MigrationFailure.restricted }
        let application = URL(fileURLWithPath: "/Applications/Cursor.app")
        guard let data = try? Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleShortVersionString"] as? String == "3.23.12" else {
            throw MigrationFailure.unsupported("Cursor 桌面版本尚未验证，当前支持 3.23.12。")
        }
        return application
    }

    private func version(_ executable: URL) throws -> String {
        guard BuildChannel.allowsSystemIntegration else { throw MigrationFailure.restricted }
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = ["--version"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw MigrationFailure.unavailable(executable.lastPathComponent) }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning {
            if Task.isCancelled || Date() > deadline {
                process.terminate()
                throw MigrationFailure.unsupported("客户端版本检查未完成，请稍后重试。")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, data.count < 4096,
              let value = String(data: data, encoding: .utf8) else { throw MigrationFailure.invalidHistory }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
