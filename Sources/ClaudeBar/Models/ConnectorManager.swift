import Foundation
import Combine
import Darwin

enum ConnectorPlatform: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, cursor
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
}

enum ConnectorKind: String, CaseIterable, Identifiable, Sendable {
    case skill, mcp, plugin
    var id: String { rawValue }
    var title: String {
        switch self {
        case .skill: return "Skills"
        case .mcp: return "MCP"
        case .plugin: return "插件"
        }
    }
    var symbol: String {
        switch self {
        case .skill: return "doc.text"
        case .mcp: return "network"
        case .plugin: return "puzzlepiece.extension"
        }
    }
}

struct MCPConnection: Sendable {
    let command: String
    let arguments: [String]
    let environment: [String: String]
    var url: URL? = nil
    var headers: [String: String] = [:]
}

enum ConnectorMethod: Sendable {
    case skillMove(original: URL)
    case codexSetting(section: String)
    case claudePlugin(identifier: String)
    case cursorMCP(identifier: String, directory: URL)
    case native

    var isCursorMCP: Bool {
        if case .cursorMCP = self { return true }
        return false
    }
}

struct ConnectorRecord: Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let kind: ConnectorKind
    let platforms: [ConnectorPlatform]
    let scope: String
    let source: URL
    let enabled: Bool?
    let method: ConnectorMethod
    var sharedOwner: String? = nil
    var mcpConnection: MCPConnection? = nil
    var detailDirectory: URL? = nil

    /// Plugin install folder, when this record points at a directory rather than a config file.
    var installDirectory: URL? {
        if let directory = detailDirectory { return directory }
        guard kind == .plugin else { return nil }
        let name = source.lastPathComponent
        if name.hasSuffix(".json") || name.hasSuffix(".toml") || name.hasSuffix(".md") { return nil }
        return source
    }
    var canToggle: Bool { enabled != nil && !isNative }
    /// Removal is only offered where the write target is a skill directory,
    /// one Codex table, a Claude plugin CLI, or an MCP config file.
    var canRemove: Bool {
        switch method {
        case .skillMove, .codexSetting, .claudePlugin, .cursorMCP: return true
        case .native:
            let file = source.lastPathComponent
            return file == "mcp.json" || file == ".mcp.json"
        }
    }
    private var isNative: Bool {
        if case .native = method { return true }
        return false
    }
}

/// Names found inside a plugin install. Read from the directory only.
struct PluginBundleContents: Sendable {
    struct Item: Identifiable, Sendable {
        var id: String { kind + ":" + name }
        let kind: String
        let name: String
    }
    let items: [Item]

    static func read(directory: URL) -> PluginBundleContents {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return PluginBundleContents(items: []) }
        var items: [Item] = []
        func walkSkills(_ root: URL, depth: Int) {
            guard depth < 3, items.count < 40,
                  let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for child in children where items.count < 40 {
                let skill = child.appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: skill.path) {
                    items.append(Item(kind: "Skill", name: child.lastPathComponent))
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    walkSkills(child, depth: depth + 1)
                }
            }
        }
        walkSkills(directory.appendingPathComponent("skills"), depth: 0)
        if let servers = mcpNames(directory.appendingPathComponent(".mcp.json")) {
            for name in servers where items.count < 40 {
                items.append(Item(kind: "MCP", name: name))
            }
        }
        let mcpFolder = directory.appendingPathComponent("mcp")
        if let files = try? fm.contentsOfDirectory(at: mcpFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for file in files.prefix(12) where items.count < 40 {
                items.append(Item(kind: "MCP", name: file.deletingPathExtension().lastPathComponent))
            }
        }
        let commands = directory.appendingPathComponent("commands")
        if let files = try? fm.contentsOfDirectory(at: commands, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for file in files.prefix(12) where items.count < 40 {
                items.append(Item(kind: "命令", name: file.deletingPathExtension().lastPathComponent))
            }
        }
        return PluginBundleContents(items: items)
    }

    private static func mcpNames(_ file: URL) -> [String]? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let servers = (object["mcpServers"] as? [String: Any]) ?? object
        return servers.keys.sorted()
    }
}

struct LocalCLIRecord: Identifiable, Sendable {
    let name: String
    let category: String
    let summary: String
    let source: URL
    var id: String { name }
}

/// Reads local connector metadata only. No network call, server launch, or
/// content from SKILL.md beyond its frontmatter is needed for the inventory.
@MainActor final class ConnectorManager: ObservableObject {
    @Published private(set) var records: [ConnectorRecord] = []
    @Published private(set) var pluginContents: [String: PluginBundleContents] = [:]
    @Published private(set) var localCLIs: [LocalCLIRecord] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    private var scanGeneration = 0

    func refresh(projectPath: String?, scanCLIs: Bool = true) async {
        scanGeneration += 1
        let generation = scanGeneration
        isLoading = true
        let path = projectPath
        let retainedCLIs = localCLIs
        let result = await Task.detached(priority: .utility) {
            let scanned = ConnectorInventory.scan(projectPath: path)
            return (scanned,
                    ConnectorInventory.bundledContents(of: scanned),
                    scanCLIs ? LocalCLIInventory.scan() : retainedCLIs)
        }.value
        guard generation == scanGeneration else { return }
        records = result.0
        pluginContents = result.1
        localCLIs = result.2
        isLoading = false
    }

    func setEnabled(_ enabled: Bool, for record: ConnectorRecord, projectPath: String?) async {
        do {
            try await ConnectorMutationGate.shared.setEnabled(enabled, record: record)
            errorMessage = nil
            if case .cursorMCP = record.method {
                noticeMessage = "已向 Cursor 发送\(enabled ? "启用" : "停用")命令；最终状态请在 Customize 中确认。"
            } else {
                noticeMessage = nil
            }
            await refresh(projectPath: projectPath, scanCLIs: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ record: ConnectorRecord, projectPath: String?) async {
        do {
            try await ConnectorMutationGate.shared.remove(record)
            errorMessage = nil
            noticeMessage = "已移除 \(record.name)"
            await refresh(projectPath: projectPath, scanCLIs: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private actor ConnectorMutationGate {
    static let shared = ConnectorMutationGate()
    func setEnabled(_ enabled: Bool, record: ConnectorRecord) throws {
        try ConnectorInventory.setEnabled(enabled, record: record)
    }
    func remove(_ record: ConnectorRecord) throws {
        try ConnectorInventory.remove(record)
    }
}

private enum ConnectorInventory {
    private static var fm: FileManager { .default }
    private static var home: URL { fm.homeDirectoryForCurrentUser }
    private static var vault: URL { home.appendingPathComponent("Library/Application Support/ClaudeBar/DisabledSkills", isDirectory: true) }
    private static var registry: URL { vault.appendingPathComponent("registry.json") }

    private struct ParkedSkill: Codable {
        let original: String
        let stored: String
    }

    /// Read each plugin folder once per refresh, off the main thread, so the
    /// grid never walks the disk while scrolling.
    static func bundledContents(of records: [ConnectorRecord]) -> [String: PluginBundleContents] {
        var result: [String: PluginBundleContents] = [:]
        result.reserveCapacity(records.count)
        for record in records where record.kind == .plugin {
            guard let directory = record.installDirectory else { continue }
            let contents = PluginBundleContents.read(directory: directory)
            if !contents.items.isEmpty { result[record.id] = contents }
        }
        return result
    }

    static func scan(projectPath: String?) -> [ConnectorRecord] {
        var result: [ConnectorRecord] = []
        let project = projectPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let roots: [(URL, [ConnectorPlatform], String)] = [
            (home.appendingPathComponent(".claude/skills"), [.claude, .cursor], "个人"),
            (home.appendingPathComponent(".agents/skills"), [.codex, .cursor], "个人 · 共享"),
            (home.appendingPathComponent(".codex/skills"), [.codex, .cursor], "个人"),
            (home.appendingPathComponent(".cursor/skills"), [.cursor], "个人"),
        ] + (project.map { p in [
            (p.appendingPathComponent(".claude/skills"), [.claude, .cursor], "项目"),
            (p.appendingPathComponent(".agents/skills"), [.codex, .cursor], "项目 · 共享"),
            (p.appendingPathComponent(".codex/skills"), [.codex, .cursor], "项目"),
            (p.appendingPathComponent(".cursor/skills"), [.cursor], "项目"),
        ] } ?? [])
        for (root, platforms, scope) in roots {
            scanSkills(in: root, platforms: platforms, scope: scope, depth: 0, into: &result)
        }
        for parked in (try? parkedSkills()) ?? [] {
            let original = URL(fileURLWithPath: parked.original)
            guard let match = roots.first(where: { original.path.hasPrefix($0.0.path + "/") }),
                  fm.fileExists(atPath: parked.stored) else { continue }
            let stored = URL(fileURLWithPath: parked.stored)
            result.append(skillRecord(at: original, contentsAt: stored,
                                      platforms: match.1, scope: match.2, enabled: false))
        }

        scanCodexConfig(home.appendingPathComponent(".codex/config.toml"), scope: "个人", into: &result)
        if let project { scanCodexConfig(project.appendingPathComponent(".codex/config.toml"), scope: "项目", into: &result) }
        scanCodexCachedPlugins(into: &result)
        scanJSONMCP(home.appendingPathComponent(".cursor/mcp.json"), platform: .cursor, scope: "个人", into: &result)
        if let project { scanJSONMCP(project.appendingPathComponent(".cursor/mcp.json"), platform: .cursor, scope: "项目", into: &result) }
        scanClaudeMCP(project: project, into: &result)
        scanClaudePlugins(project: project, into: &result)
        scanCursorLocalPlugins(into: &result)
        return result.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.scope < $1.scope
        }
    }

    private static func scanSkills(in root: URL, platforms: [ConnectorPlatform], scope: String,
                                   depth: Int, into records: inout [ConnectorRecord]) {
        guard depth < 4, let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if fm.fileExists(atPath: child.appendingPathComponent("SKILL.md").path) {
                records.append(skillRecord(at: child, contentsAt: child, platforms: platforms, scope: scope, enabled: true))
            } else {
                scanSkills(in: child, platforms: platforms, scope: scope, depth: depth + 1, into: &records)
            }
        }
    }

    private static func skillRecord(at original: URL, contentsAt location: URL,
                                    platforms: [ConnectorPlatform], scope: String, enabled: Bool) -> ConnectorRecord {
        let metadata = skillMetadata(location.appendingPathComponent("SKILL.md"))
        return ConnectorRecord(id: "skill:" + original.path, name: metadata.0 ?? original.lastPathComponent,
                               summary: metadata.1 ?? original.path, kind: .skill,
                               platforms: platforms, scope: scope, source: location,
                               enabled: enabled, method: .skillMove(original: original),
                               sharedOwner: metadata.2)
    }

    private static func skillMetadata(_ file: URL) -> (String?, String?, String?) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return (nil, nil, nil) }
        defer { try? handle.close() }
        let text = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        guard text.hasPrefix("---") else { return (nil, nil, nil) }
        let lines = Array(text.components(separatedBy: .newlines).dropFirst()
            .prefix { $0.trimmingCharacters(in: .whitespaces) != "---" })
        func field(_ key: String) -> String? {
            lines.first(where: { $0.hasPrefix(key + ":") })?
                .dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return (field("name"), field("description"), requiredCLI(in: lines))
    }

    private static func requiredCLI(in lines: [String]) -> String? {
        var inMetadata = false
        var inRequires = false
        for (index, line) in lines.enumerated() {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if indent == 0 {
                inMetadata = trimmed == "metadata:"
                inRequires = false
                continue
            }
            if inMetadata && indent == 2 {
                inRequires = trimmed == "requires:"
                continue
            }
            guard inMetadata && inRequires && indent >= 4 && trimmed.hasPrefix("bins:") else { continue }
            let value = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("["), value.hasSuffix("]") {
                let bins = value.dropFirst().dropLast().split(separator: ",")
                for bin in bins {
                    let name = bin.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if let owner = LocalCLIInventory.owner(for: name) { return owner }
                }
            } else if value.isEmpty {
                for next in lines.dropFirst(index + 1) {
                    guard next.prefix(while: { $0 == " " }).count > indent else { break }
                    let item = next.trimmingCharacters(in: .whitespaces)
                    if item.hasPrefix("- "),
                       let owner = LocalCLIInventory.owner(for: String(item.dropFirst(2))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) {
                        return owner
                    }
                }
            }
        }
        return nil
    }

    private static func scanCodexConfig(_ file: URL, scope: String, into records: inout [ConnectorRecord]) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let doc = CodexConfigWriter.parse(text)
        for section in doc.sections {
            let kind: ConnectorKind
            let prefix: String
            if section.name.hasPrefix("mcp_servers.") {
                kind = .mcp; prefix = "mcp_servers."
            } else if section.name.hasPrefix("plugins.") {
                kind = .plugin; prefix = "plugins."
            } else { continue }
            let entry = String(section.name.dropFirst(prefix.count))
            // Child tables such as `.env` and `.tools.search` are not items.
            guard let name = topLevelTOMLName(entry),
                  kind == .plugin || section.lines.contains(where: { $0.range(of: #"^\s*(command|url)\s*="# , options: .regularExpression) != nil }) else { continue }
            let enabledLine = section.lines.first { $0.range(of: #"^\s*enabled\s*="# , options: .regularExpression) != nil }
            let enabled = enabledLine?.range(of: #"=\s*false\b"#, options: .regularExpression) == nil
            let command = section.lines.first { $0.range(of: #"^\s*command\s*="# , options: .regularExpression) != nil }
                .flatMap(tomlCommand)
            let remoteURL = section.lines.first { $0.range(of: #"^\s*url\s*="# , options: .regularExpression) != nil }
                .flatMap(tomlCommand).flatMap(URL.init(string:))
            let arguments = tomlStringArray("args", in: section.lines)
            let environment = doc.sections.first(where: { $0.name == section.name + ".env" })
                .map { tomlEnvironment($0.lines) } ?? [:]
            let headers = doc.sections.first(where: { $0.name == section.name + ".http_headers" })
                .map { tomlEnvironment($0.lines) } ?? [:]
            records.append(ConnectorRecord(id: "codex:\(file.path):\(section.name)", name: name,
                summary: file.path, kind: kind, platforms: [.codex], scope: scope,
                source: file, enabled: enabled, method: .codexSetting(section: section.name),
                sharedOwner: kind == .mcp ? command.flatMap(LocalCLIInventory.owner(for:)) : nil,
                mcpConnection: kind == .mcp && (command != nil || remoteURL != nil)
                    ? MCPConnection(command: command ?? "", arguments: arguments,
                                    environment: environment, url: remoteURL, headers: headers)
                    : nil,
                detailDirectory: kind == .plugin ? codexPluginDirectory(name) : nil))
        }
    }

    private static func codexPluginDirectory(_ identifier: String) -> URL? {
        guard let separator = identifier.lastIndex(of: "@") else { return nil }
        let plugin = String(identifier[..<separator])
        let marketplace = String(identifier[identifier.index(after: separator)...])
        let root = home.appendingPathComponent(".codex/plugins/cache")
            .appendingPathComponent(marketplace).appendingPathComponent(plugin)
        let versions = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return versions.first(where: {
            fm.fileExists(atPath: $0.appendingPathComponent("plugin.json").path) ||
            fm.fileExists(atPath: $0.appendingPathComponent(".codex-plugin/plugin.json").path)
        })
    }

    private static func tomlCommand(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
        return String(value.dropFirst().prefix { $0 != quote })
    }

    private static func tomlStringArray(_ key: String, in lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.range(of: "^\\s*\(key)\\s*=", options: .regularExpression) != nil }),
              let equals = lines[start].firstIndex(of: "=") else { return [] }
        var value = String(lines[start][lines[start].index(after: equals)...])
        if !value.contains("]") {
            for line in lines.dropFirst(start + 1) {
                value += line
                if line.contains("]") { break }
            }
        }
        guard let left = value.firstIndex(of: "["), let right = value.lastIndex(of: "]"), left < right else { return [] }
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in value[value.index(after: left)..<right] {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote == "\"" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil; items.append(current); current = "" }
                else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            }
        }
        return items
    }

    private static func tomlEnvironment(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty, let value = tomlCommand(line) else { continue }
            result[key] = value
        }
        return result
    }

    private static func topLevelTOMLName(_ entry: String) -> String? {
        guard !entry.isEmpty else { return nil }
        if entry.hasPrefix("\"") || entry.hasPrefix("'") {
            guard let quote = entry.first, entry.last == quote, entry.count > 2,
                  !entry.dropFirst().dropLast().contains(quote) else { return nil }
            return String(entry.dropFirst().dropLast())
        }
        return entry.contains(".") ? nil : entry
    }

    private static func scanJSONMCP(_ file: URL, platform: ConnectorPlatform, scope: String,
                                    into records: inout [ConnectorRecord]) {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return }
        for name in servers.keys.sorted() {
            let entry = servers[name] as? [String: Any]
            let method: ConnectorMethod = platform == .cursor
                ? .cursorMCP(identifier: name, directory: scope == "个人" ? home : file.deletingLastPathComponent().deletingLastPathComponent())
                : .native
            records.append(ConnectorRecord(id: "\(platform.rawValue):\(file.path):\(name)", name: name,
                summary: file.path, kind: .mcp, platforms: [platform], scope: scope,
                source: file, enabled: nil, method: method,
                sharedOwner: (entry?["command"] as? String).flatMap(LocalCLIInventory.owner(for:)),
                mcpConnection: mcpConnection(entry)))
        }
    }

    private static func scanClaudeMCP(project: URL?, into records: inout [ConnectorRecord]) {
        let config = home.appendingPathComponent(".claude.json")
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: config),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        }
        let userServers = object["mcpServers"] as? [String: Any] ?? [:]
        for name in userServers.keys.sorted() {
            let entry = userServers[name] as? [String: Any]
            records.append(ConnectorRecord(id: "claude:user:\(name)", name: name,
                summary: "Claude Code · 用户配置（状态随项目变化）", kind: .mcp,
                platforms: [.claude], scope: "个人", source: config, enabled: nil, method: .native,
                sharedOwner: (entry?["command"] as? String).flatMap(LocalCLIInventory.owner(for:)),
                mcpConnection: mcpConnection(entry)))
        }
        guard let project else { return }
        let path = project.standardizedFileURL.path
        let projects = object["projects"] as? [String: Any] ?? [:]
        let projectConfig = projects[path] as? [String: Any] ?? [:]
        let projectServers = projectConfig["mcpServers"] as? [String: Any] ?? [:]
        for name in projectServers.keys.sorted() {
            let entry = projectServers[name] as? [String: Any]
            records.append(ConnectorRecord(id: "claude:project:\(path):\(name)", name: name,
                summary: "Claude Code · 当前项目", kind: .mcp, platforms: [.claude],
                scope: "项目", source: config, enabled: nil, method: .native,
                sharedOwner: (entry?["command"] as? String).flatMap(LocalCLIInventory.owner(for:)),
                mcpConnection: mcpConnection(entry)))
        }
        scanJSONMCP(project.appendingPathComponent(".mcp.json"), platform: .claude, scope: "项目 · 共享", into: &records)
    }

    private static func mcpConnection(_ entry: [String: Any]?) -> MCPConnection? {
        let command = entry?["command"] as? String ?? ""
        let remoteURL = (entry?["url"] as? String).flatMap(URL.init(string:))
        guard !command.isEmpty || remoteURL != nil else { return nil }
        return MCPConnection(command: command,
                             arguments: entry?["args"] as? [String] ?? [],
                             environment: entry?["env"] as? [String: String] ?? [:],
                             url: remoteURL,
                             headers: entry?["headers"] as? [String: String] ?? [:])
    }

    private static func scanClaudePlugins(project: URL?, into records: inout [ConnectorRecord]) {
        let installed = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        let settings = home.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: installed),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return }
        let settingData = (try? Data(contentsOf: settings)) ?? Data()
        let settingRoot = (try? JSONSerialization.jsonObject(with: settingData)) as? [String: Any] ?? [:]
        let flags = settingRoot["enabledPlugins"] as? [String: Bool] ?? [:]
        for name in plugins.keys.sorted() {
            let installs = plugins[name] as? [[String: Any]] ?? []
            let userInstall = installs.contains { ($0["scope"] as? String) == "user" }
            let projectInstall = project != nil && installs.contains {
                ($0["scope"] as? String) != "user" &&
                ($0["projectPath"] as? String) == project?.standardizedFileURL.path
            }
            guard userInstall || projectInstall else { continue }
            let chosenInstall = installs.first(where: { ($0["scope"] as? String) == "user" })
                ?? installs.first(where: { ($0["projectPath"] as? String) == project?.standardizedFileURL.path })
            let detailDirectory = (chosenInstall?["installPath"] as? String).map { URL(fileURLWithPath: $0) }
            records.append(ConnectorRecord(id: "claude:plugin:\(name)", name: name,
                summary: "Claude Code 插件 · 更改后在会话中执行 /reload-plugins", kind: .plugin,
                platforms: [.claude], scope: userInstall ? "个人" : "项目", source: settings,
                enabled: userInstall ? (flags[name] ?? true) : nil,
                method: userInstall ? .claudePlugin(identifier: name) : .native,
                detailDirectory: detailDirectory))
        }
    }

    private static func scanCursorLocalPlugins(into records: inout [ConnectorRecord]) {
        let root = home.appendingPathComponent(".cursor/plugins/local")
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let hasManifest = fm.fileExists(atPath: dir.appendingPathComponent("plugin.json").path) ||
                fm.fileExists(atPath: dir.appendingPathComponent(".cursor-plugin/plugin.json").path)
            guard hasManifest else { continue }
            records.append(ConnectorRecord(id: "cursor:plugin:\(dir.path)", name: dir.lastPathComponent,
                summary: "Cursor 本地插件 · 在 Customize 中管理", kind: .plugin,
                platforms: [.cursor], scope: "个人 · 本地", source: dir,
                enabled: nil, method: .native))
        }
        let cache = home.appendingPathComponent(".cursor/plugins/cache")
        guard let marketplaces = try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for marketplace in marketplaces {
            guard let plugins = try? fm.contentsOfDirectory(at: marketplace, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for plugin in plugins {
                guard let versions = try? fm.contentsOfDirectory(at: plugin, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]),
                      let version = versions.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("plugin.json").path) ||
                          fm.fileExists(atPath: $0.appendingPathComponent(".cursor-plugin/plugin.json").path) }) else { continue }
                records.append(ConnectorRecord(id: "cursor:cache:\(plugin.path)", name: plugin.lastPathComponent,
                    summary: "Cursor 插件缓存 · 安装和启用状态请在 Customize 中确认", kind: .plugin,
                    platforms: [.cursor], scope: "本机缓存", source: version,
                    enabled: nil, method: .native))
            }
        }
    }

    private static func scanCodexCachedPlugins(into records: inout [ConnectorRecord]) {
        let cache = home.appendingPathComponent(".codex/plugins/cache")
        guard let marketplaces = try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        let configured = Set(records.filter { $0.kind == .plugin && $0.platforms == [.codex] }.map(\.name))
        for marketplace in marketplaces {
            guard let plugins = try? fm.contentsOfDirectory(at: marketplace, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for plugin in plugins {
                let name = "\(plugin.lastPathComponent)@\(marketplace.lastPathComponent)"
                guard !configured.contains(name),
                      let versions = try? fm.contentsOfDirectory(at: plugin, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]),
                      let version = versions.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("plugin.json").path) ||
                          fm.fileExists(atPath: $0.appendingPathComponent(".codex-plugin/plugin.json").path) }) else { continue }
                records.append(ConnectorRecord(id: "codex:cache:\(plugin.path)", name: name,
                    summary: "Codex 插件缓存 · 安装和启用状态请在 Codex 中确认", kind: .plugin,
                    platforms: [.codex], scope: "本机缓存", source: version,
                    enabled: nil, method: .native))
            }
        }
    }

    static func remove(_ record: ConnectorRecord) throws {
        switch record.method {
        case .skillMove(let original): try removeSkill(original: original)
        case .codexSetting(let section): try removeTOMLSections(file: record.source, rootedAt: section)
        case .claudePlugin(let identifier): try runClaude(["plugin", "uninstall", identifier])
        case .cursorMCP(let identifier, _): try removeJSONServer(file: record.source, name: identifier)
        case .native:
            guard record.canRemove else { throw ConnectorError.nativeOnly }
            try removeJSONServer(file: record.source, name: record.name)
        }
    }

    static func setEnabled(_ enabled: Bool, record: ConnectorRecord) throws {
        switch record.method {
        case .skillMove(let original): try setSkillEnabled(enabled, original: original)
        case .codexSetting(let section): try setTOMLEnabled(enabled, file: record.source, sectionName: section)
        case .claudePlugin(let identifier): try setClaudePluginEnabled(enabled, identifier: identifier)
        case .cursorMCP(let identifier, let directory): try setCursorMCPEnabled(enabled, identifier: identifier, directory: directory)
        case .native: throw ConnectorError.nativeOnly
        }
    }

    private static func parkedSkills() throws -> [ParkedSkill] {
        guard fm.fileExists(atPath: registry.path) else { return [] }
        return try JSONDecoder().decode([ParkedSkill].self, from: Data(contentsOf: registry))
    }

    private static func saveParkedSkills(_ entries: [ParkedSkill]) throws {
        try ensureVault()
        let data = try JSONEncoder().encode(entries)
        try secureReplace(data, at: registry)
    }

    private static func ensureVault() throws {
        try fm.createDirectory(at: vault, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vault.path)
    }

    private static func setSkillEnabled(_ enabled: Bool, original: URL) throws {
        var entries = try parkedSkills()
        if enabled {
            guard let index = entries.firstIndex(where: { $0.original == original.path }) else { throw ConnectorError.changed }
            let stored = URL(fileURLWithPath: entries[index].stored)
            guard stored.path.hasPrefix(vault.path + "/"), !fm.fileExists(atPath: original.path),
                  fm.fileExists(atPath: stored.path) else { throw ConnectorError.changed }
            try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: stored, to: original)
            entries.remove(at: index)
            do { try saveParkedSkills(entries) }
            catch { try? fm.moveItem(at: original, to: stored); throw error }
        } else {
            guard !entries.contains(where: { $0.original == original.path }),
                  fm.fileExists(atPath: original.path),
                  (try? original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw ConnectorError.changed }
            try ensureVault()
            let stored = vault.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.moveItem(at: original, to: stored)
            entries.append(ParkedSkill(original: original.path, stored: stored.path))
            do { try saveParkedSkills(entries) }
            catch { try? fm.moveItem(at: stored, to: original); throw error }
        }
    }

    /// Change only the one `enabled` line in one TOML table. All other bytes,
    /// including comments, credentials, and neighboring tables, stay intact.
    private static func setTOMLEnabled(_ enabled: Bool, file: URL, sectionName: String) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        let header = "[\(sectionName)]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else { throw ConnectorError.changed }
        let end = lines[(start + 1)...].firstIndex(where: {
            let s = $0.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix("[") && s.hasSuffix("]")
        }) ?? lines.count
        if let line = (start + 1..<end).first(where: { lines[$0].range(of: #"^\s*enabled\s*="# , options: .regularExpression) != nil }) {
            var existing = lines[line]
            guard let equals = existing.firstIndex(of: "="),
                  let value = existing[existing.index(after: equals)...].range(of: #"^\s*(true|false)\b"#, options: .regularExpression) else {
                throw ConnectorError.changed
            }
            existing.replaceSubrange(value, with: " \(enabled)")
            lines[line] = existing
        } else {
            lines.insert("enabled = \(enabled)", at: start + 1)
        }
        let replacement = lines.joined(separator: "\n")
        guard (try? String(contentsOf: file, encoding: .utf8)) == text else { throw ConnectorError.changed }
        try secureReplace(Data(replacement.utf8), at: file)
    }

    private static func secureReplace(_ data: Data, at file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".claudebar-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw ConnectorError.changed }
        defer { try? fm.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if let mode = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        }
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw ConnectorError.changed }
    }

    private static func removeSkill(original: URL) throws {
        var entries = try parkedSkills()
        if let index = entries.firstIndex(where: { $0.original == original.path }) {
            let stored = URL(fileURLWithPath: entries[index].stored)
            guard stored.path.hasPrefix(vault.path + "/") else { throw ConnectorError.changed }
            if fm.fileExists(atPath: stored.path) {
                try fm.trashItem(at: stored, resultingItemURL: nil)
            }
            entries.remove(at: index)
            try saveParkedSkills(entries)
            return
        }
        guard fm.fileExists(atPath: original.path),
              (try? original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw ConnectorError.changed
        }
        try fm.trashItem(at: original, resultingItemURL: nil)
    }

    /// Drop one table and its child tables (`name.env`, `name.tools`) and leave
    /// every other byte of the file alone.
    private static func removeTOMLSections(file: URL, rootedAt sectionName: String) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var dropping = false
        var removed = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 {
                let header = String(trimmed.dropFirst().dropLast())
                dropping = header == sectionName || header.hasPrefix(sectionName + ".")
                if dropping { removed = true; continue }
            }
            if !dropping { kept.append(line) }
        }
        guard removed else { throw ConnectorError.changed }
        while kept.last?.isEmpty == true, kept.count > 1 { kept.removeLast() }
        let replacement = kept.joined(separator: "\n")
        guard (try? String(contentsOf: file, encoding: .utf8)) == text else { throw ConnectorError.changed }
        try secureReplace(Data(replacement.utf8), at: file)
    }

    private static func removeJSONServer(file: URL, name: String) throws {
        let original = try Data(contentsOf: file)
        guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              var servers = object["mcpServers"] as? [String: Any],
              servers.removeValue(forKey: name) != nil else { throw ConnectorError.changed }
        object["mcpServers"] = servers
        let replacement = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard (try? Data(contentsOf: file)) == original else { throw ConnectorError.changed }
        try secureReplace(replacement, at: file)
    }

    private static func setClaudePluginEnabled(_ enabled: Bool, identifier: String) throws {
        try runClaude(["plugin", enabled ? "enable" : "disable", identifier])
    }

    private static func runClaude(_ arguments: [String]) throws {
        let executable = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home.appendingPathComponent(".local/bin/claude").path]
            .first(where: { fm.isExecutableFile(atPath: $0) })
        guard let executable else { throw ConnectorError.missingClaudeCLI }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = home
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runCLI(process)
    }

    private static func setCursorMCPEnabled(_ enabled: Bool, identifier: String, directory: URL) throws {
        let executable = [home.appendingPathComponent(".local/bin/agent").path,
                          "/opt/homebrew/bin/agent", "/usr/local/bin/agent"]
            .first(where: { fm.isExecutableFile(atPath: $0) })
        guard let executable else { throw ConnectorError.missingCursorCLI }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        process.arguments = ["mcp", enabled ? "enable" : "disable", identifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runCLI(process)
    }

    private static func runCLI(_ process: Process) throws {
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 15) == .timedOut {
            if process.isRunning { process.terminate() }
            throw ConnectorError.cliFailed
        }
        guard process.terminationStatus == 0 else { throw ConnectorError.cliFailed }
    }

    private enum ConnectorError: LocalizedError {
        case changed, nativeOnly, missingClaudeCLI, missingCursorCLI, cliFailed
        var errorDescription: String? {
            switch self {
            case .changed: return "连接器文件已变化或目标位置被占用。请刷新后再试。"
            case .nativeOnly: return "此连接器需要在原生客户端中管理。"
            case .missingClaudeCLI: return "未找到 Claude Code 命令行程序；请在 Claude Code 的 /plugin 中管理。"
            case .missingCursorCLI: return "未找到 Cursor Agent CLI；请在 Cursor 的 Customize 中管理 MCP。"
            case .cliFailed: return "客户端未接受这次更改；请在其原生管理界面中检查状态。"
            }
        }
    }
}

/// A bounded local inventory: direct path checks only, never launches a CLI.
/// These tools are shared by the machine and stay separate from client Skills,
/// MCP servers, and plugins.
private enum LocalCLIInventory {
    private static let candidates: [(name: String, category: String, summary: String)] = [
        ("lark-cli", "服务集成", "飞书命令行工具"),
        ("tencent-docs-cli", "服务集成", "腾讯文档命令行工具"),
        ("tencent-docs", "服务集成", "腾讯文档命令行工具"),
        ("txdocs", "服务集成", "腾讯文档命令行工具"),
        ("qqdocs", "服务集成", "腾讯文档命令行工具"),
        ("wecom-cli", "服务集成", "企业微信命令行工具"),
        ("dingtalk-cli", "服务集成", "钉钉命令行工具"),
        ("notion-cli", "服务集成", "Notion 命令行工具"),
        ("gdrive", "服务集成", "Google Drive 命令行工具"),
        ("google-drive-cli", "服务集成", "Google Drive 命令行工具"),
        ("slack-cli", "服务集成", "Slack 命令行工具"),
        ("linear-cli", "服务集成", "Linear 命令行工具"),
        ("obsidian", "服务集成", "Obsidian 命令行入口"),
        ("gh", "服务集成", "GitHub 命令行工具"),
        ("mcporter", "MCP 工具", "MCP 服务连接与调用"),
        ("mcp", "MCP 工具", "MCP 命令行工具"),
        ("happy-mcp", "MCP 工具", "MCP 命令行工具"),
        ("openclaw", "Agent 工具", "OpenClaw 命令行入口"),
        ("oc-skills", "Agent 工具", "OpenClaw Skill 管理"),
        ("skillhub", "Agent 工具", "Skill 管理工具"),
    ]

    static func owner(for command: String) -> String? {
        let name = URL(fileURLWithPath: command.trimmingCharacters(in: .whitespacesAndNewlines))
            .lastPathComponent
        return candidates.first(where: { $0.name == name })?.name
    }

    static func scan() -> [LocalCLIRecord] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let knownRoots = [
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".bun/bin"),
            home.appendingPathComponent(".cargo/bin"),
            home.appendingPathComponent(".lmstudio/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/opt/miniconda3/bin"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources"),
        ]
        let pathRoots = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        var seen = Set<String>()
        let roots = (knownRoots + pathRoots).filter { seen.insert($0.standardizedFileURL.path).inserted }
        return candidates.compactMap { candidate in
            guard let source = roots.lazy
                .map({ $0.appendingPathComponent(candidate.name) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
            return LocalCLIRecord(name: candidate.name, category: candidate.category,
                                  summary: candidate.summary, source: source)
        }
    }
}
