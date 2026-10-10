import Foundation

struct VpnDomainRule: Codable, Identifiable, Equatable {
    enum Route: String, Codable, CaseIterable {
        case direct, proxy
        var title: String { self == .direct ? "直连" : "代理" }
    }
    var id = UUID()
    var domain: String
    var includesSubdomains: Bool
    var route: Route

    func matches(_ host: String) -> Bool {
        host == domain || (includesSubdomains && host.hasSuffix("." + domain))
    }
}

enum VpnDomainRules {
    enum RuleError: LocalizedError {
        case unsupportedRules
        var errorDescription: String? { "订阅的 rules 格式不支持添加域名规则，请使用 YAML 列表格式。" }
    }
    static var file: URL { FilePaths.vpnDir.appendingPathComponent("domain-rules.json") }

    static func normalize(_ input: String) -> String? {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.allSatisfy({ Int($0) != nil }) else { return nil }
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return host
    }

    static func load(from url: URL = file) -> [VpnDomainRule] {
        guard let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([VpnDomainRule].self, from: data) else { return [] }
        return rules.filter { normalize($0.domain) == $0.domain }
    }

    static func save(_ rules: [VpnDomainRule], to url: URL = file) throws {
        try PrivateFileWriter.write(JSONEncoder().encode(rules), to: url)
    }

    /// Specific hosts win over broader suffixes. User pins precede automatic pins.
    static func ordered(_ rules: [VpnDomainRule]) -> [VpnDomainRule] {
        rules.sorted {
            if $0.domain.count != $1.domain.count { return $0.domain.count > $1.domain.count }
            if $0.includesSubdomains != $1.includesSubdomains { return !$0.includesSubdomains }
            return $0.domain < $1.domain
        }
    }

    static func providerBypass(_ hosts: [String], rules: [VpnDomainRule]) -> [String] {
        let ordered = ordered(rules)
        return hosts.filter { host in ordered.first(where: { $0.matches(host) })?.route != .proxy }
    }

    static func inject(into yaml: String, rules: [VpnDomainRule], proxyTarget: String) throws -> String {
        guard !rules.isEmpty else { return yaml }
        var lines = yaml.components(separatedBy: "\n")
        let key = lines.firstIndex { $0.hasPrefix("rules:") }
        var index = key.map { $0 + 1 } ?? lines.count
        var indent = "  "
        if let key {
            let value = lines[key].dropFirst("rules:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("[") {
                // Expand quoted flow-sequence scalars to regular rule items.
                let raw = value.components(separatedBy: " #").first ?? value
                if let data = raw.data(using: .utf8),
                   let items = try? JSONDecoder().decode([String].self, from: data) {
                    lines[key] = "rules:"
                    lines.insert(contentsOf: items.map { indent + "- " + quoted($0) }, at: index)
                } else {
                    // A YAML flow list can use single quotes as well.
                    let pattern = #"'((?:[^']|'')*)'"#
                    let regex = try! NSRegularExpression(pattern: pattern)
                    let items = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
                        .compactMap { Range($0.range(at: 1), in: raw).map { String(raw[$0]).replacingOccurrences(of: "''", with: "'") } }
                    var remainder = raw
                    for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).reversed() {
                        if let range = Range(match.range, in: remainder) { remainder.removeSubrange(range) }
                    }
                    guard remainder.allSatisfy({ "[], \t".contains($0) }), raw.hasSuffix("]"),
                          raw == "[]" || !items.isEmpty else { throw RuleError.unsupportedRules }
                    lines[key] = "rules:"
                    lines.insert(contentsOf: items.map { indent + "- " + quoted($0) }, at: index)
                }
            } else if !value.isEmpty && !value.hasPrefix("#") && value != "null" && value != "~" {
                throw RuleError.unsupportedRules
            }
            lines[key] = "rules:"
            for line in lines[index...] {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                if trimmed.hasPrefix("-") { indent = String(line.prefix { $0 == " " }) }
                break
            }
        } else {
            lines.append("rules:")
            index = lines.count
        }
        let pins = ordered(rules).map { rule in
            let kind = rule.includesSubdomains ? "DOMAIN-SUFFIX" : "DOMAIN"
            let target = rule.route == .direct ? "DIRECT" : proxyTarget
            return indent + "- " + quoted("\(kind),\(rule.domain),\(target)")
        }
        lines.insert(contentsOf: pins, at: index)
        return lines.joined(separator: "\n")
    }

    private static func quoted(_ value: String) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }
}
