import Foundation

/// Pure filtering shared by the UI and regression tests. Executed off-main;
/// route counts cover the search set, before applying the route filter.
struct VpnDomainQuery {
    struct Result {
        let rows: [VpnDomainEntry]
        let stats: [VpnDomainLogStat]
        let counts: [VpnDomainRoute: Int]
        let matched: Int
    }

    static func run(entries: [VpnDomainEntry], query: String,
                    route: VpnDomainRoute?, failedOnly: Bool,
                    summary: Bool) -> Result {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var counts: [VpnDomainRoute: Int] = [:]
        var rows: [VpnDomainEntry] = []
        var matched = 0
        for entry in entries {
            if Task.isCancelled { break }
            if failedOnly && !entry.failed { continue }
            if !q.isEmpty && !entry.endpoint.localizedCaseInsensitiveContains(q)
                && !entry.outbound.localizedCaseInsensitiveContains(q)
                && !entry.rule.localizedCaseInsensitiveContains(q) { continue }
            matched += 1
            counts[entry.route, default: 0] += 1
            if route == nil || entry.route == route { rows.append(entry) }
        }
        return Result(rows: rows, stats: summary ? VpnDomainLog.stat(entries: rows) : [],
                      counts: counts, matched: matched)
    }
}
