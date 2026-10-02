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

# The analysis table the summary's "常见服务走了直连" line reads.
watchlist = source[source.index('enum VpnWatchlist {'):].rstrip() + '\n'

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
assert 'ObservedObject private var log = VpnDomainLog.shared' in section, \
    'the section is the observer the page delegates to'
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

# --- the harness ------------------------------------------------------------
swift = r'''
import Foundation

MODELS_AND_FEED

enum DomainStat { STAT_FUNC }

WATCHLIST

FILTER_HARNESS

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

    static func main() {
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

        // Capacity, order, eviction, wraparound, and reuse after clear.
        var ring = VpnDomainRing(capacity: 10_000)
        let batch = (1...25_000).map { id -> VpnDomainEntry in
            var row = entries[0]
            row.id = UInt64(id)
            return row
        }
        ring.append(contentsOf: Array(batch.prefix(9_000)))
        precondition(ring.count == 9_000 && ring.snapshot().first?.id == 1)
        ring.append(contentsOf: Array(batch.dropFirst(9_000)))
        let retained = ring.snapshot()
        precondition(ring.count == 10_000 && retained.first?.id == 15_001
                     && retained.last?.id == 25_000)
        precondition(zip(retained, retained.dropFirst()).allSatisfy { $1.id == $0.id + 1 })
        ring.clear()
        precondition(ring.count == 0 && ring.snapshot().isEmpty)
        ring.append(contentsOf: Array(batch.prefix(3)))
        precondition(ring.snapshot().map(\.id) == [1, 2, 3])
        print("vpn domain log OK · query + 10,000-row ring")
    }
}
'''

swift = (swift
         .replace('MODELS_AND_FEED', feed)
         .replace('STAT_FUNC', stat)
         .replace('WATCHLIST', watchlist)
         .replace('FILTER_HARNESS', filter_harness))

with tempfile.TemporaryDirectory() as tmp:
    temporary = Path(tmp)
    source_file = temporary / 'Regression.swift'
    source_file.write_text(swift)
    binary = temporary / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(source_file), '-o', str(binary)],
                   check=True)
    subprocess.run([str(binary)], check=True)
