#!/usr/bin/env python3
"""The VPN 流量日志 parser must classify a connection the way the core meant it.

The page's whole value is the 已代理 / 直连 / 拒绝 split and the outbound+rule it
prints beside each domain. Both are read out of one mihomo log line whose shape
differs depending on whether the dial *succeeded*:

  level=info    msg="[TCP] 127.0.0.1:49701 --> api2.cursor.sh:443 match Match using 🐟 漏网之鱼[1 官网 tcp.bet]"
  level=warning msg="[TCP] dial 🎯 Direct (match GeoSite/CN) 127.0.0.1:49287 --> host:443 error: dns resolve failed: …"

Getting the rule/outbound pair wrong, or bucketing a `Direct` line as proxied,
produces a page that confidently tells the user the wrong thing about which
traffic leaves through a node — and nothing in review shows it, because every
individual string still looks plausible. So (as with the proxy's token buckets)
this suite feeds the *production* parser the exact lines the real core emits and
fixtures every classification the UI can show.

`VpnDomainFeed` is also the app's line *buffer*, and the real `core.log` on this
machine contains a line split across two pipe reads (a bare `官网 tcp.bet]"`).
The chunk-boundary cases below are the reason it buffers bytes rather than
decoding each read on its own.

No app launch, no network.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Utils/VpnDomainLog.swift').read_text()

# --- slice the production source ---------------------------------------------
# Models + the feed: everything before the @MainActor store.
feed = source[source.index('/// How mihomo routed one connection.'):
              source.index('/// Ring of recent mihomo connections')]

# The per-domain fold lives inside the store; wrap it as the same free-standing
# static function so the assertions drive the real implementation.
stat_start = source.index('nonisolated static func stat(')
stat_end = source.index('// MARK: - Flush', stat_start)
stat = source[stat_start:stat_end].replace('nonisolated ', '', 1)

# The exact `updateConnections` → accumulator → published-state integration,
# minus the parts a fixture cannot touch (the private feed/ring and the two
# @Published stores live on the same real @MainActor class the UI observes).
apply = source[source.index('    /// The pure half of `updateConnections`'):
              source.index('    func clear()')]
apply = apply.replace('''    nonisolated static func preparedConnections(_ snapshot: [[String: Any]]) -> [VpnDomainConnection] {''',
                      '''    nonisolated static func prepared(_ snapshot: [[String: Any]]) -> [VpnDomainConnection] {
        ConnectionsFixture.lift(from: snapshot)
    }

    nonisolated static func lift(from snapshot: [[String: Any]]) -> [VpnDomainConnection] {
        ConnectionsFixture.preparedConnections(snapshot)
    }

    nonisolated static func preparedConnections(_ snapshot: [[String: Any]]) -> [VpnDomainConnection] {''')
apply = apply.replace('''    func applyConnections(_ next: [VpnDomainConnection]) {
        trafficAccumulator.sample(next)''',
                      '''    func applyConnections(_ next: [VpnDomainConnection]) {
        published = []
        trafficAccumulator.sample(next)''')
apply = apply.replace('if totals != proxiedTraffic { proxiedTraffic = totals }',
                      'if totals != proxiedTraffic { published.append("totals"); proxiedTraffic = totals }')
apply = apply.replace('if byHost != trafficByHost { trafficByHost = byHost }',
                      'if byHost != trafficByHost { published.append("byHost"); trafficByHost = byHost }')
apply = apply.replace('connections = next',
                      '{ published.append("connections"); connections = next }()')
assert 'published.append("totals")' in apply and 'published.append("byHost")' in apply, \
    'the equality-guard rewrite must have matched the production text'

# The publish-cadence policy: the two ceilings and the pure chooser. Sliced
# from production so the regression executes them, not a restatement; the
# task/state fields between them are skipped (they need the real main actor).
min_src = source[source.index('private static let minInterval'):source.index('    private var lastFlush')]
pub_start = source.index('static func publishInterval')
pub_end = source.index('    private init()', pub_start)
cadence = (min_src + '\n' + source[pub_start:pub_end]).replace('private static let', 'static let')

# The analysis table the summary's "常见服务走了直连" line reads.
watchlist = source[source.index('enum VpnWatchlist {'):].rstrip() + '\n'

# `preparedConnections` reads its counters through the production coercion.
json_coerce = (root / 'Sources/ClaudeBar/Utils/JSONCoerce.swift').read_text()

# --- wire-up assertions ------------------------------------------------------
manager = (root / 'Sources/ClaudeBar/Utils/VpnManager.swift').read_text()
spawn = manager[manager.index('private func spawnProcess'):]
spawn = spawn[:spawn.index('private func readPipe')]
assert 'VpnDomainLog.shared.ingest(data)' in spawn, \
    'spawnProcess must hand the core pipe bytes to the domain log'
assert 'VpnDomainLog.shared.resetCarry()' in manager, \
    'a core restart must drop the carry buffer from the dead pipe'

view = (root / 'Sources/ClaudeBar/Views/Pages/VPNView.swift').read_text()
assert 'VpnDomainLogSection(isVisible:' in view and 'private func trafficGroup' in view, \
    'VPNView must mount the 流量日志 section'
assert 'ObservedObject private var domainLog' not in view and \
    'VpnDomainLog.shared' not in view, \
    ('VPNView must not observe the domain log: a connection line would '
     're-evaluate the header, subscription cards and node mosaic')

section = (root / 'Sources/ClaudeBar/Views/Pages/VpnDomainLogSection.swift').read_text()
assert '@ObservedObject private var log' not in section and '.onReceive(log.$revision)' in section and '.onReceive(log.$connectionRevision)' in section, \
    'the section must subscribe to active revisions without observing every store field'
assert 'role: .destructive' in section and 'confirmClear' in section, \
    '清空 must confirm: it discards the aggregate the user is reading'

# Exercise production query computation independently of SwiftUI scheduling.
filter_enum = section[section.index('    enum RouteFilter:'):
                      section.index('    var body:')]
query_source = (root / 'Sources/ClaudeBar/Utils/VpnDomainQuery.swift').read_text()
query_source = query_source.replace('import Foundation', '').replace('VpnDomainLog.stat', 'DomainStat.stat')
filter_harness = r"""
QUERY_SOURCE
final class FilterHarness {
    var entries: [VpnDomainEntry]
    var query = ""
    var routeFilter: RouteFilter = .all
    var failedOnly = false
    var visibleRows: [VpnDomainEntry] = []
    var visibleStats: [VpnDomainLogStat] = []
    var tallyProxied = 0
    var counts: [VpnDomainRoute: Int] = [:]
    init(_ entries: [VpnDomainEntry]) { self.entries = entries }
    FILTER_ENUM
    func recompute() {
        let result = VpnDomainQuery.run(entries: entries, query: query,
                                       route: routeFilter.route, failedOnly: failedOnly, summary: true)
        visibleRows = result.rows
        visibleStats = result.stats
        counts = result.counts
        tallyProxied = result.rows.filter { $0.route == .proxied }.count
    }
}
""".replace('FILTER_ENUM', filter_enum).replace('QUERY_SOURCE', query_source)

# Execute the actual asynchronous UI cache/action functions with an in-memory store.
cache = section[section.index('    private struct RequestKey:'):section.index('    private func copyVisible()')]
cache = cache.replace('private ', '')
mode_enum = section[section.index('    enum Mode:'):section.index('    enum RouteFilter:')]
async_harness = r"""
@MainActor final class CacheFixture {
    final class Store {
        var entries: [VpnDomainEntry] = []
        var connections: [VpnDomainConnection] = []
        var revision = 0
        var connectionRevision = 0
        var proxiedTraffic = VpnDomainTraffic()
        var trafficByHost: [String: VpnDomainTraffic] = [:]
    }
    let log = Store()
    var isVisible = true
    var proxiedTraffic = VpnDomainTraffic()
    var historyRevision = 0
    var connectionRevision = 0
    var mode: Mode = .detail
    var routeFilter: RouteFilter = .all
    var query = ""
    var failedOnly = false
    var followTail = true
    var pendingRows = 0
    var lastSeenID: UInt64?
    var copied = false
    var page = 0
    var visibleRows: [VpnDomainEntry] = []
    var visibleStats: [VpnDomainLogStat] = []
    var visibleConnections: [VpnDomainConnection] = []
    var visibleLeaks: [(service: String, hosts: [String])] = []
    var routeCounts: [VpnDomainRoute: Int] = [:]
    var matchedCount = 0
    var tallyProxied = 0
    var tallyDirect = 0
    var tallyReject = 0
    var visibleCount: Int {
        switch mode {
        case .detail: return visibleRows.count
        case .summary: return visibleStats.count
        case .connections: return visibleConnections.count
        }
    }
    MODE_ENUM
    FILTER_ENUM
    CACHE
}
""".replace('MODE_ENUM', mode_enum).replace('FILTER_ENUM', filter_enum).replace('CACHE', cache)

# --- the harness ------------------------------------------------------------
swift = r'''
import Foundation

MODELS_AND_FEED

JSON_COERCE

VPN_FORMAT

enum DomainStat { STAT_FUNC }

/// The production `updateConnections` integration, sliced from the real store:
/// the accumulator, the two publish guards and the revision bump, against
/// plain fixture state. `published` records each write so the assertions can
/// see whether an unchanged snapshot republished.
@MainActor final class ConnectionsFixture {
    var published: [String] = []
    var connections: [VpnDomainConnection] = []
    var connectionRevision = 0
    var proxiedTraffic = VpnDomainTraffic()
    var trafficByHost: [String: VpnDomainTraffic] = [:]
    private var trafficAccumulator = VpnDomainTrafficAccumulator()

    APPLY
}

/// The production publish ceilings and their chooser, sliced whole.
enum PublishCadence {
CADENCE
}

WATCHLIST

FILTER_HARNESS
ASYNC_HARNESS

@main struct Regression {
    static func feedAll(_ lines: [String]) -> [VpnDomainEntry] {
        let feed = VpnDomainFeed()
        var out: [VpnDomainEntry] = []
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if feed.ingest(data) { out += feed.drain() }
        return out
    }

    static func parse(_ line: String) -> VpnDomainEntry? {
        feedAll([line]).first
    }

    @MainActor static func main() async {
        // 1. Proxied: the shape that dominates a real log (11141 of 13141 lines
        //    in a 2.2 MB sample).
        guard let proxied = parse("time=\"2026-09-29T11:41:02.432485000+08:00\" level=info "
            + "msg=\"[TCP] 127.0.0.1:49701 --> api2.cursor.sh:443 match Match "
            + "using 🐟 漏网之鱼[1 官网 tcp.bet]\"") else {
            preconditionFailure("a proxied connection line must parse")
        }
        precondition(proxied.route == .proxied, "Match via a node group is 已代理")
        precondition(proxied.host == "api2.cursor.sh", "host: \(proxied.host)")
        precondition(proxied.port == 443, "port: \(proxied.port)")
        precondition(proxied.rule == "Match", "rule: \(proxied.rule)")
        precondition(proxied.outbound == "🐟 漏网之鱼[1 官网 tcp.bet]",
                     "outbound: \(proxied.outbound)")
        precondition(proxied.timeText == "11:41:02", "clock: \(proxied.timeText)")
        precondition(!proxied.failed)

        // 2. Direct through a proxy group: `[DIRECT]` on the bracket is the
        //    final outbound, which is what makes this classifiable without
        //    asking /proxies.
        guard let direct = parse("time=\"2026-09-29T11:41:02.432485000+08:00\" level=info "
            + "msg=\"[TCP] 127.0.0.1:49959 --> ipcdn.apple.com:443 "
            + "match DomainSuffix(apple.com) using 🎯 Direct[DIRECT]\"") else {
            preconditionFailure("a direct connection line must parse")
        }
        precondition(direct.route == .direct, "a [DIRECT] bracket is 直连")
        precondition(direct.rule == "DomainSuffix(apple.com)", "rule: \(direct.rule)")
        precondition(direct.outbound == "🎯 Direct[DIRECT]", "outbound: \(direct.outbound)")
        precondition(direct.host == "ipcdn.apple.com")

        // 3. A rule that resolved straight to DIRECT, no group around it.
        if let bare = parse("time=\"2026-09-29T11:41:03.000000000+08:00\" level=info "
            + "msg=\"[TCP] 127.0.0.1:50001 --> 120.92.33.171:80 match GeoIP(cn) using DIRECT\"") {
            precondition(bare.route == .direct, "a bare DIRECT outbound is 直连")
            precondition(bare.host == "120.92.33.171", "host: \(bare.host)")
            precondition(bare.port == 80, "port: \(bare.port)")
            precondition(bare.rule == "GeoIP(cn)", "rule: \(bare.rule)")
        } else {
            preconditionFailure("a bare-DIRECT line must parse")
        }

        // 4. The dial-failure shape (level=warning): outbound before the
        //    parens, rule inside them, error at the end.
        guard let failed = parse("time=\"2026-09-29T11:41:04.000000000+08:00\" level=warning "
            + "msg=\"[TCP] dial 🎯 Direct (match GeoSite/CN) 127.0.0.1:49287 --> "
            + "wetype.weixin.qq.com:443 error: dns resolve failed: all DNS requests failed\"") else {
            preconditionFailure("a dial-failure line must parse")
        }
        precondition(failed.route == .direct, "the intended outbound is Direct")
        precondition(failed.rule == "GeoSite/CN", "rule: \(failed.rule)")
        precondition(failed.outbound == "🎯 Direct", "outbound: \(failed.outbound)")
        precondition(failed.failed, "error: on the line means failed")
        precondition(failed.host == "wetype.weixin.qq.com")

        // 5. The private rule spellings real airport profiles emit. The domain
        //    must survive; the rule text is what keeps it out of the outbound.
        if let slash = parse("time=\"2026-09-29T11:41:05.000000000+08:00\" level=info "
            + "msg=\"[TCP] 127.0.0.1:50486 --> api.telegram.org:443 "
            + "match DomainSuffix/telegram.org) using 🐟 漏网之鱼[1 官网 tcp.bet]\"") {
            precondition(slash.host == "api.telegram.org", "host: \(slash.host)")
            precondition(slash.rule.contains("DomainSuffix/telegram.org"),
                         "rule: \(slash.rule)")
        } else {
            preconditionFailure("a slash-spelled rule must not swallow the host")
        }

        // 6. Reject.
        if let reject = parse("time=\"2026-09-29T11:41:06.000000000+08:00\" level=info "
            + "msg=\"[TCP] 127.0.0.1:51000 --> ads.example.com:443 "
            + "match DomainSuffix(ads.example.com) using REJECT[REJECT]\"") {
            precondition(reject.route == .reject, "REJECT[REJECT] is 拒绝")
        } else {
            preconditionFailure("a reject line must parse")
        }

        // 7. Rejections — the lines the parser must NOT turn into rows.
        //    Our own diagnostics land in the same file (`extractFatal` reads
        //    exactly this line), so the `time=`+`level=` guard is load-bearing.
        let notConnections = [
            "level=error msg=\"listen tcp 127.0.0.1:9097: bind: address already in use\"",
            "level=fatal msg=\"Parse config error: rules[0] error\"",
            "time=\"2026-09-29T11:41:02.432485000+08:00\" level=info "
                + "msg=\"Start initial compatible provider 🐟 漏网之鱼\"",
            "time=\"2026-09-29T11:41:02.432485000+08:00\" level=info "
                + "msg=\"Load MMDB file: /Users/x/geoip.metadb\"",
            "time=\"2026-09-29T11:41:02.432485000+08:00\" level=info "
                + "msg=\"[TCP] connection closed\"",
            "官网 tcp.bet]\"",
            "",
        ]
        for line in notConnections {
            precondition(parse(line) == nil, "must not parse: \(line)")
        }

        // 8. sliceClock: nanoseconds, plain seconds, and garbage.
        precondition(VpnDomainFeed.sliceClock("2026-09-29T11:41:02.432485000+08:00") == "11:41:02")
        precondition(VpnDomainFeed.sliceClock("2026-09-29T00:00:00Z") == "00:00:00")
        precondition(VpnDomainFeed.sliceClock("nonsense") == nil)
        precondition(VpnDomainFeed.sliceClock("2026-09-29T11:41Z") == nil)

        // 9. Chunk boundaries. A pipe read can end anywhere — including inside
        //    a line and inside the emoji in an outbound name (the real log has a
        //    mangled fragment from exactly this).
        let feed = VpnDomainFeed()
        let text = "time=\"2026-09-29T11:41:02.432485000+08:00\" level=info "
            + "msg=\"[TCP] 127.0.0.1:49701 --> api2.cursor.sh:443 match Match "
            + "using 🐟 漏网之鱼[1 官网 tcp.bet]\"\n"
        let bytes = Data(text.utf8)
        let emoji = [UInt8](text.utf8).firstIndex(of: 0xF0)!   // first byte of 🐟
        var split = feed.ingest(bytes.prefix(emoji + 1))
        var got = feed.drain()
        precondition(got.isEmpty, "a half-line is not a row yet (notified=\(split))")
        split = feed.ingest(bytes.dropFirst(emoji + 1))
        got += feed.drain()
        precondition(split, "the completing chunk must notify")
        precondition(got.count == 1, "one line, one row: \(got.count)")
        precondition(got[0].outbound == "🐟 漏网之鱼[1 官网 tcp.bet]",
                     "the emoji survived the split: \(got[0].outbound)")

        let empty = VpnDomainFeed()
        precondition(!empty.ingest(Data()), "an empty read notifies nobody")

        // 10. Per-domain fold: hits, route split, most-hit first, and "last"
        //     taken from the most recent arrival (never the max string).
        let entries = feedAll([
            "time=\"2026-09-29T11:41:00.000000000+08:00\" level=info "
                + "msg=\"[TCP] 127.0.0.1:1 --> api2.cursor.sh:443 match Match using 🐟 漏网之鱼[node]\"",
            "time=\"2026-09-29T11:41:01.000000000+08:00\" level=info "
                + "msg=\"[TCP] 127.0.0.1:2 --> api2.cursor.sh:443 match Match using 🐟 漏网之鱼[node]\"",
            "time=\"2026-09-29T11:41:02.000000000+08:00\" level=warning "
                + "msg=\"[TCP] dial 🎯 Direct (match GeoSite/CN) 127.0.0.1:3 --> api2.cursor.sh:443 error: dns resolve failed\"",
            "time=\"2026-09-29T11:41:03.000000000+08:00\" level=info "
                + "msg=\"[TCP] 127.0.0.1:4 --> www.apple.com:443 match DomainSuffix(apple.com) using 🎯 Direct[DIRECT]\"",
        ])
        precondition(entries.count == 4, "four rows: \(entries.count)")
        let stats = DomainStat.stat(entries: entries)
        precondition(stats.count == 2, "two domains: \(stats.count)")
        precondition(stats[0].host == "api2.cursor.sh", "most-hit first: \(stats[0].host)")
        precondition(stats[0].hits == 3 && stats[0].proxied == 2 && stats[0].direct == 1,
                     "route split: \(stats[0])")
        precondition(stats[0].failed == 1, "failures counted: \(stats[0].failed)")
        precondition(stats[0].lastTimeText == "11:41:02",
                     "last seen is the newest arrival: \(stats[0].lastTimeText)")
        precondition(stats[1].host == "www.apple.com" && stats[1].direct == 1)

        // 10b. "Last" is the last *arrival*, not the lexicographic max of the
        //      clock strings. Every clock above ascends with its arrival, so a
        //      `max(by: timeText)` implementation would pass section 10 — the
        //      discriminating pair is one whose string order and arrival order
        //      disagree, exactly the midnight case the `sliceClock` comment
        //      names ("a run spanning midnight cannot make yesterday's lines
        //      sort after today's"). Rows are appended 23:59:59 then 00:00:01
        //      for the same host; the fold must report the later arrival.
        let midnight = feedAll([
            "time=\"2026-09-30T23:59:59.000000000+08:00\" level=info "
                + "msg=\"[TCP] 127.0.0.1:5 --> span.example.com:443 match Match using 🐟 漏网之鱼[node]\"",
            "time=\"2026-10-01T00:00:01.000000000+08:00\" level=info "
                + "msg=\"[TCP] 127.0.0.1:6 --> span.example.com:443 match Match using 🐟 漏网之鱼[node]\"",
        ])
        let midnightStat = DomainStat.stat(entries: midnight).first { $0.host == "span.example.com" }
        precondition(midnightStat?.lastTimeText == "00:00:01",
                     "last seen must be the newest arrival across midnight, not the max clock string: "
                     + "\(midnightStat?.lastTimeText ?? "nil")")

        // 11. The one piece of analysis: a watchlist service sent 直连.
        precondition(VpnWatchlist.matches(host: "api2.cursor.sh") == ["Cursor"])
        precondition(VpnWatchlist.matches(host: "chatgpt.com") == ["OpenAI"])
        precondition(VpnWatchlist.matches(host: "api.anthropic.com") == ["Anthropic"])
        precondition(VpnWatchlist.matches(host: "example.com").isEmpty,
                     "an unknown domain is not a leak")
        precondition(VpnWatchlist.matches(host: "mycursor.com").isEmpty,
                     "suffix matching must not catch a lookalike")

        // 11b. The publish cadence is a pure function of visibility: full rate
        //      while any surface is on screen, the sleep rate when the app is
        //      background-only (the same 10 s /connections drops to in that
        //      state). A regression that dropped this to a constant would make
        //      a hidden menu-bar app rebuild the 2,000-row snapshot every
        //      second forever; one that inverted it would starve the page.
        precondition(PublishCadence.publishInterval(visible: true) == PublishCadence.minInterval
                     && PublishCadence.minInterval == 1,
                     "visible publishes ride the 1 s ceiling")
        precondition(PublishCadence.publishInterval(visible: false) == PublishCadence.hiddenInterval
                     && PublishCadence.hiddenInterval == 10,
                     "background-only publishes ride the 10 s sleep cadence")
        precondition(PublishCadence.hiddenInterval > PublishCadence.minInterval,
                     "the sleep cadence must be the slower one")

        let filters = FilterHarness(entries)
        filters.recompute()
        precondition(filters.visibleRows.count == 4)
        filters.routeFilter = .direct
        filters.recompute()
        precondition(filters.visibleRows.count == 2 && filters.tallyProxied == 0,
                     "route selection must update without a new log revision")
        precondition(filters.visibleStats.allSatisfy { $0.proxied == 0 })
        filters.query = "  APPLE\n"
        filters.recompute()
        precondition(filters.visibleRows.count == 1 && filters.visibleRows[0].host == "www.apple.com",
                     "search must update while the log is idle, ignoring whitespace and case")
        filters.query = "no-such-host"
        filters.recompute()
        precondition(filters.visibleRows.isEmpty && filters.visibleStats.isEmpty)
        filters.query = ""
        filters.routeFilter = .all
        filters.recompute()
        precondition(filters.visibleRows.count == 4, "clearing filters restores all rows")
        precondition(filters.counts[.proxied] == 2 && filters.counts[.direct] == 2)
        filters.routeFilter = .direct
        filters.recompute()
        precondition(filters.counts[.proxied] == 2,
                     "route counts must retain the unselected route's search results")
        let detail = VpnDomainQuery.run(entries: entries, query: "", route: nil,
                                        failedOnly: false, summary: false)
        precondition(detail.stats.isEmpty && detail.rows.count == 4,
                     "detail view must not build per-domain summaries")
        var failureFixture = entries[0]
        failureFixture.failed = true
        let failures = VpnDomainQuery.run(entries: entries + [failureFixture], query: "", route: nil,
                                          failedOnly: true, summary: false)
        precondition(failures.rows.allSatisfy { $0.failed })
        let portSearch = VpnDomainQuery.run(entries: [failureFixture], query: String(failureFixture.port),
                                           route: nil, failedOnly: false, summary: false)
        precondition(portSearch.rows.count == 1, "search also matches target ports")

        // Bounded rendering covers every matching record without duplicates.
        for count in [0, 1, 199, 200, 201, 2_000] {
            for newest in [true, false] {
                let pages = max(1, (count + VpnDomainQuery.pageSize - 1) / VpnDomainQuery.pageSize)
                let ranges = (0..<pages).map { VpnDomainQuery.pageRange(count: count, page: $0, newestFirst: newest) }
                precondition(ranges.allSatisfy { $0.count <= 200 })
                precondition(ranges.flatMap { Array($0) }.sorted() == Array(0..<count))
                precondition(VpnDomainQuery.pageRange(count: count, page: Int.max, newestFirst: newest) == ranges.last!)
                precondition(VpnDomainQuery.pageRange(count: count, page: -1, newestFirst: newest) == ranges.first!)
            }
        }
        let connections = [
            VpnDomainConnection(id: "1", endpoint: "example.com:443", process: "Browser", route: .proxied,
                                rule: "Match", outbound: "Node A", upload: 1, download: 2),
            VpnDomainConnection(id: "2", endpoint: "example.com:80", process: "Terminal", route: .direct,
                                rule: "Domain", outbound: "DIRECT", upload: 3, download: 4)
        ]
        let connectionResult = VpnDomainQuery.connections(connections, query: "  EXAMPLE ", route: .direct)
        precondition(connectionResult.rows.map(\.id) == ["2"] && connectionResult.matched == 2)
        precondition(connectionResult.counts[.proxied] == 1 && connectionResult.counts[.direct] == 1)
        precondition(VpnDomainQuery.connections(connections, query: "browser", route: nil).rows.map(\.id) == ["1"])
        precondition(VpnDomainQuery.connections(connections, query: "node a", route: nil).rows.count == 1)
        precondition(VpnDomainQuery.connections(connections, query: "no-such-host", route: nil).rows.isEmpty)

        var traffic = VpnDomainTrafficAccumulator()
        traffic.sample(connections)
        precondition(traffic.totals.upload == 1 && traffic.totals.download == 2,
                     "direct connections must not count as VPN traffic")
        traffic.sample(connections + connections)
        precondition(traffic.totals.total == 3, "repeated IDs and snapshots must not double count")
        let increased = VpnDomainConnection(id: "1", endpoint: "example.com:443", process: "Browser",
            route: .proxied, rule: "Match", outbound: "Node A", upload: 10, download: 20)
        traffic.sample([increased])
        traffic.sample(connections)
        traffic.sample([increased])
        precondition(traffic.totals.total == 30, "regressing counters must not recount bytes")
        precondition(traffic.byHost["example.com"]?.total == 30)
        traffic.clear()
        traffic.sample([increased])
        precondition(traffic.totals.total == 0, "clear retains live counter baselines")
        let afterClear = VpnDomainConnection(id: "1", endpoint: "example.com:443", process: "Browser",
            route: .proxied, rule: "Match", outbound: "Node A", upload: 12, download: 23)
        traffic.sample([afterClear])
        precondition(traffic.totals.upload == 2 && traffic.totals.download == 3,
                     "after clear, count only new bytes on the existing connection")
        traffic.clear()
        traffic.sample([])
        precondition(traffic.totals.total == 0)
        traffic.sample([increased])
        traffic.sample([])
        precondition(traffic.totals.total == 30, "closed sampled connections retain their traffic")
        traffic.retainHosts([])
        precondition(traffic.byHost.isEmpty && traffic.totals.total == 30)
        var extreme = VpnDomainTraffic(upload: .max, download: .max)
        extreme.add(upload: 1, download: 1)
        precondition(extreme.total == .max, "totals saturate without overflowing")

        // 11c. /connections JSON → rows → accumulator → published state, the
        //      exact integration finding 480 called untested: `preparedConnections`
        //      is the only mapping of the core's own payload, and it must hand
        //      `updateConnections` a route that agrees with the log parser.
        let snapshot: [[String: Any]] = [
            ["id": "1", "chains": ["🐟 漏网之鱼[Node A]"],
             "metadata": ["host": "api2.cursor.sh", "destinationPort": 443, "process": "Claude"],
             "upload": 1, "download": 2],
            ["id": "2", "chains": ["REJECT[REJECT]"],
             "metadata": ["destinationIP": "9.9.9.9", "destinationPort": 53, "processPath": "/usr/bin/dig"]],
            ["id": "3", "chains": ["DIRECT"],
             "metadata": ["host": "apple.com", "destinationPort": 443, "process": "curl"]],
            // The bare `🎯 Direct` spelling the feed's own comment admits: the
            // live tab must show 直连, exactly as the log side does.
            ["id": "4", "chains": ["🎯 Direct"],
             "metadata": ["host": "www.apple.com", "destinationPort": 443]],
            ["id": "5", "chains": ["Proxy Group", "Node B"],
             "metadata": ["host": "x.example.com", "destinationPort": 443]],
            ["id": "6", "chains": [],
             "metadata": ["host": "dropped.example.com"]],
        ]
        let prepared = ConnectionsFixture.prepared(snapshot)
        precondition(prepared.map(\.id) == ["1", "2", "3", "4", "5"],
                     "routes come from chains, not from the absent rule field: \(prepared.map(\.id))")
        precondition(prepared[0].route == .proxied && prepared[0].endpoint == "api2.cursor.sh:443")
        precondition(prepared[1].route == .reject && prepared[1].endpoint == "9.9.9.9:53")
        precondition(prepared[1].process == "dig", "a sourceless process falls back to the path's basename")
        precondition(prepared[2].route == .direct, "a bare DIRECT chain is 直连")
        precondition(prepared[3].route == .direct, "🎯 Direct must read 直连 on the live tab too")
        precondition(prepared[4].route == .proxied, "the entry (first) chain decides, not the leaf")
        precondition(prepared[4].outbound == "Proxy Group → Node B", "chains render outermost first")
        precondition(ConnectionsFixture.prepared([]).isEmpty)
        for row in prepared {
            precondition(!row.endpoint.isEmpty, "a connection without a host still resolves a target")
        }

        // The same fixture through the store's real update path: unchanged
        // snapshots must not republish the two accumulator readings.
        let fixture = ConnectionsFixture()
        fixture.applyConnections(prepared)
        precondition(fixture.published == ["totals", "byHost", "connections"], "first sample publishes all: \(fixture.published)")
        precondition(fixture.connectionRevision == 1)
        precondition(fixture.proxiedTraffic.total == 3 && fixture.trafficByHost["api2.cursor.sh"]?.total == 3)
        fixture.applyConnections(prepared)
        precondition(fixture.published.isEmpty,
                     "an idle core's identical snapshot must not republish (finding 479): \(fixture.published)")
        precondition(fixture.connectionRevision == 1, "bytes on an open connection are not a row change")
        var moved = prepared
        moved[0] = VpnDomainConnection(id: "1", endpoint: "api2.cursor.sh:443", process: "Claude",
            route: .proxied, rule: "", outbound: "🐟 漏网之鱼[Node A]", upload: 10, download: 20)
        fixture.applyConnections(moved)
        precondition(fixture.published == ["totals", "byHost", "connections"],
                     "a byte change is also a row change (counters are part of the row): \(fixture.published)")
        precondition(fixture.connectionRevision == 2)
        precondition(fixture.proxiedTraffic.total == 30 && fixture.trafficByHost["api2.cursor.sh"]?.total == 30)
        var settled = moved
        fixture.applyConnections(settled)
        precondition(fixture.published.isEmpty,
                     "the same rows with the same counters must not republish: \(fixture.published)")
        settled[0] = VpnDomainConnection(id: "1", endpoint: "api2.cursor.sh:443", process: "Claude",
            route: .proxied, rule: "", outbound: "🐟 漏网之鱼[Node A]", upload: 12, download: 25)
        fixture.applyConnections(settled)
        precondition(fixture.published == ["totals", "byHost", "connections"],
                     "a counter move republishes both readings: \(fixture.published)")
        precondition(fixture.proxiedTraffic.total == 37)
        fixture.applyConnections([])
        precondition(fixture.published == ["connections"],
                     "closing connections must not republish unchanged totals: \(fixture.published)")
        precondition(fixture.connectionRevision == 4)
        precondition(fixture.proxiedTraffic.total == 37, "closed connections retain their traffic")

        // Capacity, order, eviction, wraparound, and reuse after clear.
        var ring = VpnDomainRing(capacity: 2_000)
        let batch = (1...25_000).map { id -> VpnDomainEntry in
            var row = entries[0]
            row.id = UInt64(id)
            return row
        }
        ring.append(contentsOf: Array(batch.prefix(9_000)))
        precondition(ring.count == 2_000 && ring.snapshot().first?.id == 7_001)
        ring.append(contentsOf: Array(batch.dropFirst(9_000)))
        let retained = ring.snapshot()
        precondition(ring.count == 2_000 && retained.first?.id == 23_001
                     && retained.last?.id == 25_000)
        precondition(zip(retained, retained.dropFirst()).allSatisfy { $1.id == $0.id + 1 })
        ring.clear()
        precondition(ring.count == 0 && ring.snapshot().isEmpty)
        ring.append(contentsOf: Array(batch.prefix(3)))
        precondition(ring.snapshot().map(\.id) == [1, 2, 3])
        let cache = CacheFixture()
        cache.log.entries = Array(batch.prefix(2_000))
        await cache.recompute()
        precondition(cache.visibleRows.first?.id == 1 && cache.visibleRows.last?.id == 2_000)
        cache.followTail = false
        cache.page = 3
        cache.log.entries = Array(batch[1_000..<3_000])
        await cache.recompute()
        precondition(cache.visibleRows.first?.id == 1 && cache.visibleRows.last?.id == 2_000,
                     "pause must freeze rows even when the ring evicts them")
        precondition(cache.pendingRows == 1_000 && cache.page == 3)
        await cache.recompute()
        precondition(cache.pendingRows == 1_000, "same revision must not double count pending rows")

        // The shape finding 38 called untested: the ring **at capacity**, count
        // fixed at 2,000, ids rolling forward, the user paused. Each run counts
        // only ids above `lastSeenID` and then advances it to the snapshot's
        // newest id — a partition of the id range, so a repeated run over one
        // snapshot adds zero and every rolling flush adds exactly its arrivals.
        // (In production each flush also bumps `revision`, which restarts the
        // task; driving `recompute()` directly at a fixed key is the stricter
        // same-revision form of the same shape.)
        cache.log.entries = Array(batch[1_001..<3_001])            // one arrival, count still 2,000
        await cache.recompute()
        precondition(cache.pendingRows == 1_001, "a full ring rolling forward counts exactly the arrivals")
        await cache.recompute()
        precondition(cache.pendingRows == 1_001, "no double count after the ring rolled")
        for step in 2...50 {
            cache.log.entries = Array(batch[(1_000 + step)..<(3_000 + step)])
            await cache.recompute()
        }
        precondition(cache.pendingRows == 1_050 && cache.page == 3,
                     "fifty rolling flushes count fifty arrivals, page stays put")
        cache.followTail = true
        await cache.recompute()
        precondition(cache.visibleRows.first?.id == 1_051 && cache.visibleRows.last?.id == 3_050,
                     "resuming follow replaces the frozen snapshot with the ring as it stands now")
        cache.followTail = false
        cache.query = "no-such-host"
        cache.resetFollow()
        await cache.recompute()
        precondition(cache.visibleRows.isEmpty && cache.page == 0 && cache.pendingRows == 0)
        cache.query = ""
        cache.resetFollow()
        await cache.recompute()
        cache.followTail = false
        cache.log.entries = []
        await cache.recompute()
        precondition(cache.visibleRows.isEmpty, "clear must also discard a paused snapshot")
        cache.mode = .summary
        cache.log.entries = entries
        cache.log.trafficByHost = ["api2.cursor.sh": VpnDomainTraffic(upload: 100, download: 200)]
        await cache.recompute()
        precondition(cache.visibleStats.first?.traffic?.total == 300,
                     "summary attaches only sampled VPN traffic to the matching host")
        precondition(cache.visibleStats.last?.traffic == nil,
                     "unsampled hosts must not invent a zero reading")
        let beforeTraffic = cache.requestKey
        cache.connectionRevision += 1
        precondition(cache.requestKey != beforeTraffic, "live bytes refresh the summary without new log entries")
        cache.mode = .connections
        cache.log.connections = connections
        await cache.recompute()
        precondition(cache.visibleConnections.count == 2)
        cache.isVisible = false
        cache.log.connections = []
        await cache.recompute()
        precondition(cache.visibleConnections.count == 2, "hidden workspaces must skip queries")
        cache.isVisible = true
        await cache.recompute()
        precondition(cache.visibleConnections.isEmpty)
        cache.mode = .detail
        cache.log.entries = []
        await cache.recompute()
        cache.query = "cursor"
        cache.log.entries = Array(batch.prefix(2_000))
        let stale = Task { await cache.recompute() }
        await Task.yield()
        cache.query = "no-such-host"
        await stale.value
        precondition(cache.visibleRows.isEmpty, "obsolete searches must not publish")

        // Optimized synthetic CPU measurement, separate from UI frame timing.
        for size in [10_000, 2_000] {
            let input = Array(batch.suffix(size))
            let start = Date()
            var checksum = 0
            for _ in 0..<100 {
                checksum += VpnDomainQuery.run(entries: input, query: "example", route: nil,
                                               failedOnly: false, summary: false).matched
            }
            print(String(format: "VPN query %d rows × 100: %.2f ms (checksum %d)",
                         size, Date().timeIntervalSince(start) * 1000, checksum))
        }
        print("vpn domain log OK · query + connections + 200-row pages + 2,000-row ring")
    }
}
'''

swift = (swift
         .replace('MODELS_AND_FEED', feed)
         .replace('JSON_COERCE', json_coerce)
         .replace('VPN_FORMAT', manager[manager.index('enum VpnFormat {'):manager.index('/// The core\'s log ring.')])
         .replace('STAT_FUNC', stat)
         .replace('APPLY', apply)
         .replace('CADENCE', cadence)
         .replace('WATCHLIST', watchlist)
         .replace('FILTER_HARNESS', filter_harness)
         .replace('ASYNC_HARNESS', async_harness))

with tempfile.TemporaryDirectory() as tmp:
    temporary = Path(tmp)
    source_file = temporary / 'Regression.swift'
    source_file.write_text(swift)
    binary = temporary / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source_file), '-o', str(binary)],
                   check=True)
    subprocess.run([str(binary)], check=True)
