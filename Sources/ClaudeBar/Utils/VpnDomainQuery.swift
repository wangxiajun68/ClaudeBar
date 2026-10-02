import Foundation

/// Pure filtering shared by the UI and regression tests. Executed off-main;
/// route counts cover the search set, before applying the route filter.
struct VpnDomainQuery {
    static let pageSize = 200

    /// Detail pages count backwards from the newest record; other modes forwards.
    static func pageRange(count: Int, page: Int, newestFirst: Bool) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let page = min(max(0, page), (count - 1) / pageSize)
        if newestFirst {
            let end = count - page * pageSize
            return max(0, end - pageSize)..<end
        }
        let start = page * pageSize
        return start..<min(count, start + pageSize)
    }

    struct ConnectionResult {
        let rows: [VpnDomainConnection]
        let counts: [VpnDomainRoute: Int]
        let matched: Int
    }

    static func connections(_ connections: [VpnDomainConnection], query: String,
                            route: VpnDomainRoute?) -> ConnectionResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [VpnDomainConnection] = []
        var counts: [VpnDomainRoute: Int] = [:]
        var matched = 0
        for connection in connections {
            if Task.isCancelled { break }
            if !q.isEmpty && !connection.endpoint.localizedCaseInsensitiveContains(q)
                && !connection.process.localizedCaseInsensitiveContains(q)
                && !connection.outbound.localizedCaseInsensitiveContains(q)
                && !connection.rule.localizedCaseInsensitiveContains(q) { continue }
            matched += 1
            counts[connection.route, default: 0] += 1
            if route == nil || connection.route == route { rows.append(connection) }
        }
        return ConnectionResult(rows: rows, counts: counts, matched: matched)
    }

    /// The one piece of actual analysis: a service this app knows about (an LLM
    /// or a client vendor) that the core sent out **direct**. Everything else on
    /// this page reports what happened; this line reports something the user
    /// probably did not intend.
    static func directLeaks(_ stats: [VpnDomainLogStat]) -> [(service: String, hosts: [String])] {
        var byService: [String: [String]] = [:]
        var order: [String] = []
        for stat in stats where stat.direct > 0 && stat.proxied == 0 {
            for service in VpnWatchlist.matches(host: stat.host) {
                if byService[service] == nil { order.append(service) }
                byService[service, default: []].append(stat.host)
            }
        }
        return order.map { ($0, byService[$0] ?? []) }
    }

    struct Result {
        let rows: [VpnDomainEntry]
        let stats: [VpnDomainLogStat]
        let leaks: [(service: String, hosts: [String])]
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
        let stats = summary && !Task.isCancelled ? VpnDomainLog.stat(entries: rows) : []
        return Result(rows: rows, stats: stats, leaks: summary ? directLeaks(stats) : [],
                      counts: counts, matched: matched)
    }
}
