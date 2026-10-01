import Foundation

/// Native per-client overrides. Unsupported TOML representations are rejected
/// rather than appending a duplicate key and breaking the client's config.
enum ConnectorSkillPolicy {
    enum PolicyError: LocalizedError {
        case unsupported
        var errorDescription: String? { "Skill 配置使用了暂不支持的格式；请在客户端管理后刷新。" }
    }

    private struct Entry {
        let start: Int
        let end: Int
        let path: String
        let enabledLine: Int?
        let enabled: Bool
    }

    private static func entries(_ text: String) throws -> [Entry] {
        let lines = text.components(separatedBy: "\n")
        // Inline arrays, quoted/dotted variants and multiline strings require a
        // full TOML parser. Refuse them without changing any bytes.
        guard !text.contains("\"\"\""), !text.contains("'''"),
              !lines.contains(where: {
                  $0.range(of: #"^\s*(skills\s*[.=]|config\s*=|\[\s*[\"']skills)"#, options: .regularExpression) != nil
              }) else { throw PolicyError.unsupported }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^\[\[?\s*["']?skills\b"#, options: .regularExpression) != nil,
               !trimmed.hasPrefix("[[skills.config]]"), !trimmed.hasPrefix("[skills]") {
                throw PolicyError.unsupported
            }
        }
        var result: [Entry] = []
        for start in lines.indices where lines[start].trimmingCharacters(in: .whitespaces).hasPrefix("[[skills.config]]") {
            let end = lines.indices.dropFirst(start + 1).first {
                lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("[")
            } ?? lines.count
            let paths = (start + 1..<end).filter { lines[$0].range(of: #"^\s*path\s*="# , options: .regularExpression) != nil }
            let flags = (start + 1..<end).filter { lines[$0].range(of: #"^\s*enabled\s*="# , options: .regularExpression) != nil }
            guard paths.count == 1, flags.count <= 1,
                  let path = stringValue(lines[paths[0]]) else { throw PolicyError.unsupported }
            if let flag = flags.first,
               lines[flag].range(of: #"^\s*enabled\s*=\s*(true|false)\s*(#.*)?$"#, options: .regularExpression) == nil {
                throw PolicyError.unsupported
            }
            result.append(Entry(start: start, end: end, path: path, enabledLine: flags.first,
                                enabled: flags.first.map { lines[$0].range(of: #"^\s*enabled\s*=\s*false\b"#, options: .regularExpression) == nil } ?? true))
        }
        return result
    }

    private static func stringValue(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.first == "'", let end = value.dropFirst().firstIndex(of: "'") {
            return String(value[value.index(after: value.startIndex)..<end])
        }
        // JSON's escaping is a safe subset of TOML basic strings.
        guard value.first == "\"" else { return nil }
        var escaped = false
        for index in value.indices.dropFirst() {
            let char = value[index]
            if char == "\"", !escaped {
                return (try? JSONSerialization.jsonObject(with: Data(value[...index].utf8), options: [.fragmentsAllowed])) as? String
            }
            if char == "\\", !escaped { escaped = true } else { escaped = false }
        }
        return nil
    }

    private static func matches(_ path: String, original: URL) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let folder = url.lastPathComponent == "SKILL.md" ? url.deletingLastPathComponent() : url
        return folder.path == original.standardizedFileURL.path ||
            folder.resolvingSymlinksInPath().path == original.resolvingSymlinksInPath().path
    }

    static func codexEnabled(_ text: String, original: URL) throws -> Bool {
        let found = try entries(text).filter { matches($0.path, original: original) }
        return !found.contains { !$0.enabled }
    }

    static func codexUpdating(_ text: String, original: URL, enabled: Bool) throws -> String {
        let found = try entries(text).filter { matches($0.path, original: original) }
        var lines = text.components(separatedBy: "\n")
        if found.isEmpty {
            let pathData = try JSONSerialization.data(withJSONObject: original.appendingPathComponent("SKILL.md").path, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            let path = String(decoding: pathData, as: UTF8.self)
            return text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n")
                + "\n[[skills.config]]\npath = \(path)\nenabled = \(enabled)\n"
        }
        // Update every duplicate match so an older false entry cannot win.
        for entry in found.reversed() {
            if let index = entry.enabledLine {
                let range = lines[index].range(of: #"\b(true|false)\b"#, options: .regularExpression)!
                lines[index].replaceSubrange(range, with: String(enabled))
            } else { lines.insert("enabled = \(enabled)", at: entry.start + 1) }
        }
        return lines.joined(separator: "\n")
    }

    static func claudeEnabled(_ data: Data, name: String) throws -> Bool {
        let object = try claudeObject(data)
        guard let overrides = object["skillOverrides"] else { return true }
        guard let values = overrides as? [String: String] else { throw PolicyError.unsupported }
        return values[name] != "off"
    }

    static func claudeUpdating(_ data: Data, name: String, enabled: Bool) throws -> Data {
        var object = try claudeObject(data)
        if let values = object["skillOverrides"], !(values is [String: String]) { throw PolicyError.unsupported }
        var values = object["skillOverrides"] as? [String: String] ?? [:]
        values[name] = enabled ? "on" : "off"
        object["skillOverrides"] = values
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func claudeObject(_ data: Data) throws -> [String: Any] {
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PolicyError.unsupported }
        return object
    }
}
