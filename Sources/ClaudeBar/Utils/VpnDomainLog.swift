import Foundation
import Combine

/// How mihomo routed one connection.
///
/// Three buckets, because the interesting question on the VPN page is exactly
/// this split: a domain that *should* go through a node but is in `direct` is
/// the one thing this log can tell the user that the node mosaic cannot.
enum VpnDomainRoute: String, CaseIterable, Identifiable {
    case proxied, direct, reject
    var id: String { rawValue }

    var label: String {
        switch self {
        case .proxied: return "已代理"
        case .direct: return "直连"
        case .reject: return "拒绝"
        }
    }
}

/// One mihomo connection line, reduced to the fields the VPN page shows.
///
/// The core logs bytes for a *closed* connection only, in a separate
/// `[TCP] ... closed` line this app does not read, so there is deliberately no
/// byte field here rather than inventing a number.
struct VpnDomainEntry: Identifiable, Equatable {
    var id: UInt64
    /// `HH:mm:ss`, sliced positionally out of the core's ISO timestamp.
    var timeText: String
    /// Hostname, or the literal address when the core logged an IP target.
    var host: String
    /// 0 when the target carried no port (never in practice; kept so a
    /// hand-written line cannot fabricate `:0` in the UI).
    var port: Int
    var route: VpnDomainRoute
    /// Outbound the connection exited through (`🐟 漏网之鱼[1 官网 tcp.bet]`,
    /// `🎯 Direct[DIRECT]`, …).
    var outbound: String
    /// The rule that matched (`Match`, `DomainSuffix(cn)`, `GeoSite/CN`).
    var rule: String
    /// The core logged this dial as failed (`error:` on the line).
    var failed: Bool

    var endpoint: String { port > 0 ? "\(host):\(port)" : host }

    /// Console form used by 复制.
    var consoleLine: String {
        var line = "\(timeText)  \(endpoint)"
        line += "  \(route.label)"
        if !rule.isEmpty { line += "  \(rule)" }
        if !outbound.isEmpty { line += "  → \(outbound)" }
        if failed { line += "  失败" }
        return line
    }
}

/// A sampled live connection. Counters belong to this connection ID only;
/// they must not be assigned to older log lines that share the same hostname.
struct VpnDomainConnection: Identifiable, Equatable {
    let id: String
    let endpoint: String
    let process: String
    let route: VpnDomainRoute
    let rule: String
    let outbound: String
    let upload: Int64
    let download: Int64
    var host: String { VpnDomainFeed.splitHostPort(endpoint).host }
}

/// Bytes observed on proxied connections since launch or the last clear.
struct VpnDomainTraffic: Equatable {
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 { VpnFormat.saturatingAdd(upload, download) }

    mutating func add(upload: Int64, download: Int64) {
        self.upload = VpnFormat.saturatingAdd(self.upload, upload)
        self.download = VpnFormat.saturatingAdd(self.download, download)
    }
}

/// Keep only live IDs for deduplication; closed connections leave their bytes
/// in the totals. Snapshots cannot capture traffic after the last live sample.
struct VpnDomainTrafficAccumulator {
    private var previous: [String: VpnDomainConnection] = [:]
    private(set) var totals = VpnDomainTraffic()
    private(set) var byHost: [String: VpnDomainTraffic] = [:]

    mutating func sample(_ connections: [VpnDomainConnection]) {
        var next: [String: VpnDomainConnection] = [:]
        for connection in connections {
            guard next[connection.id] == nil else { continue }
            let old = previous[connection.id]
            next[connection.id] = VpnDomainConnection(
                id: connection.id, endpoint: connection.endpoint, process: connection.process,
                route: connection.route, rule: connection.rule, outbound: connection.outbound,
                upload: max(connection.upload, old?.upload ?? 0),
                download: max(connection.download, old?.download ?? 0))
            guard connection.route == .proxied else { continue }
            let upload = max(0, connection.upload)
            let download = max(0, connection.download)
            let deltaUp = max(0, upload - max(0, old?.upload ?? 0))
            let deltaDown = max(0, download - max(0, old?.download ?? 0))
            totals.add(upload: deltaUp, download: deltaDown)
            byHost[connection.host, default: VpnDomainTraffic()].add(upload: deltaUp, download: deltaDown)
        }
        previous = next
    }

    mutating func retainHosts(_ hosts: Set<String>) {
        let liveHosts = Set(previous.values.map(\.host))
        byHost = byHost.filter { hosts.contains($0.key) || liveHosts.contains($0.key) }
    }

    mutating func clear() {
        totals = VpnDomainTraffic()
        byHost.removeAll(keepingCapacity: true)
        // Retain live baselines so clearing does not recount existing bytes.
    }
}

/// Per-domain rollup. Built from the ring by `VpnDomainLog.stat`.
struct VpnDomainLogStat: Identifiable, Equatable {
    var id: String { host }
    var host: String
    var hits: Int
    var proxied: Int
    var direct: Int
    var reject: Int
    var failed: Int
    /// Time text of the domain's most recent connection.
    var lastTimeText: String
    var lastOutbound: String
    var lastRoute: VpnDomainRoute
    var traffic: VpnDomainTraffic?
}

/// Off-main half of the domain log: line buffering + parsing.
///
/// `VpnManager`'s `readabilityHandler` hands the raw core bytes to this object
/// **on the pipe's own thread** — two of those (stdout and stderr) — so
/// everything mutable here is lock-guarded, and parsing happens off the main
/// actor because `core.log` takes 10+ lines a second while the user is
/// browsing.
///
/// Bytes, not `String`: a chunk boundary can land inside a line *and* inside a
/// multi-byte character (the emoji in an outbound name). The real log on this
/// machine carries a mangled fragment — a bare `官网 tcp.bet]"` line — from
/// exactly that. Buffering raw bytes and cutting only at `\n` keeps every
/// decoded line whole, since a newline can never sit inside a UTF-8 sequence.
final class VpnDomainFeed: @unchecked Sendable {
    private let lock = NSLock()
    /// Bytes after the last newline — the incomplete tail of the last chunk.
    private var buffer = Data()
    /// Parsed lines not yet handed to the main actor.
    private var staging: [VpnDomainEntry] = []
    /// True while the main actor already has a flush scheduled for `staging`.
    /// `ingest` returns `false` then, so a burst costs one task rather than one
    /// per pipe read.
    private var notified = false
    private var nextID: UInt64 = 1

    /// The carried-byte count at which a stuck chunk without any newline is
    /// flushed anyway. A core that somehow logged a single line bigger than
    /// this would otherwise lose it entirely; nothing real comes close (longest
    /// observed connection line is ~200 bytes).
    private static let maxCarry = 64 * 1024

    /// Same shape as `ProxyAccessLog.clock`, same reason: a bare `HH:mm:ss`
    /// still resolves through the user's calendar, and in a Thai locale that
    /// renders the year in Buddhist numerals.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Stage every complete line in `data`. Returns true when the caller should
    /// schedule a main-actor flush.
    func ingest(_ data: Data) -> Bool {
        lock.lock()
        buffer.append(data)
        let cut: Data.Index?
        if let nl = buffer.lastIndex(of: 0x0A) {
            cut = buffer.index(after: nl)
        } else if buffer.count > Self.maxCarry {
            cut = buffer.endIndex
        } else {
            cut = nil
        }
        guard let cut else {
            lock.unlock()
            return false
        }
        let complete = buffer[buffer.startIndex..<cut]
        buffer.removeFirst(cut - buffer.startIndex)
        // Decoding a slice that ends at a newline is safe: the trailing
        // multi-byte fragment, if any, stayed in `buffer`.
        let text = String(decoding: complete, as: UTF8.self)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(raw)
            // A trailing `\r` would otherwise end up inside the rule text.
            if line.hasSuffix("\r") { line.removeLast() }
            guard var entry = Self.parse(line: line, fallbackClock: self.nowClock()) else { continue }
            entry.id = nextID
            nextID += 1
            staging.append(entry)
        }
        let shouldNotify = !staging.isEmpty && !notified
        if shouldNotify { notified = true }
        lock.unlock()
        return shouldNotify
    }

    /// Take everything staged. Re-arms the notification so the next chunk after
    /// this flush schedules its own.
    func drain() -> [VpnDomainEntry] {
        lock.lock()
        defer { lock.unlock() }
        notified = false
        guard !staging.isEmpty else { return [] }
        let out = staging
        staging = []
        return out
    }

    /// Drop buffered bytes and staged lines (用户点「清空」).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
        staging = []
        notified = false
    }

    /// Drop only the half-line carried over from a pipe that has closed.
    ///
    /// A core restart (port / TUN / subscription change) tears down the pipes
    /// mid-stream, so the bytes after the last newline belong to a process that
    /// is gone and can never be completed. Parsed lines and the ring survive —
    /// see `VpnDomainLog.resetCarry`.
    func resetCarry() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }

    private func nowClock() -> String {
        // Called only for a line whose timestamp did not slice; every real core
        // line carries one, so this is the unreachable-in-practice path.
        Self.clockFormatter.string(from: Date())
    }

    // MARK: - Line grammar

    /// One core log line → one entry, or nil when the line is not a connection.
    ///
    /// Two guards, both load-bearing:
    ///
    /// * `time="` **and** `level=info` / `level=warning`. ClaudeBar's own
    ///   diagnostics land in the same file (`listen tcp … bind: address already
    ///   in use` is written at error level with no timestamp), and
    ///   `VpnManager.extractFatal` treats that line as the fatal condition. A
    ///   parser keyed on `[TCP]` alone would swallow it on the next core.
    /// * a ` --> ` arrow. Two real shapes, differing in where the outbound and
    ///   the rule sit:
    ///
    ///   ```
    ///   level=info    msg="[TCP] 127.0.0.1:49701 --> api2.cursor.sh:443 match Match using 🐟 漏网之鱼[…]"
    ///   level=warning msg="[TCP] dial 🎯 Direct (match GeoSite/CN) 127.0.0.1:49287 --> host:443 error: dns resolve failed: …"
    ///   ```
    ///
    ///   So: host is always after the arrow, the rule is either between
    ///   ` match ` and ` using ` or inside the parentheses of the `dial` form,
    ///   and the outbound is whichever side of that pair is left over.
    ///
    /// A line whose outbound cannot be read is dropped rather than bucketed:
    /// calling it 直连 would falsely claim a leak, calling it 已代理 would
    /// falsely claim protection. Nothing in the observed grammar does this.
    nonisolated static func parse(line: String, fallbackClock: @autoclosure () -> String) -> VpnDomainEntry? {
        guard line.contains("time=\""),
              line.contains("level=info") || line.contains("level=warning"),
              let msg = line.range(of: "msg=\""),
              let tagStart = line[msg.upperBound...].firstIndex(of: "["),
              let tagEnd = line[tagStart...].firstIndex(of: "]"),
              let arrow = line.range(of: " --> ", range: tagEnd..<line.endIndex)
        else { return nil }

        // The proto tag carries the line's identity; UDP is accepted even
        // though this core never logs it, so a future log-level change does not
        // silently start dropping half the traffic.
        let proto = line[line.index(after: tagStart)..<tagEnd]
        guard proto == "TCP" || proto == "UDP" else { return nil }

        let stamp: String
        if let open = line.range(of: "time=\""),
           let close = line[open.upperBound...].firstIndex(of: "\"") {
            stamp = sliceClock(String(line[open.upperBound..<close])) ?? fallbackClock()
        } else {
            stamp = fallbackClock()
        }

        // ` --> host:port`, the target token ending at the first space — or at
        // `dial`, in the form that has no arrow (never observed, rejected).
        let target = line[arrow.upperBound...]
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let (host, port) = splitHostPort(target)
        guard isPlausibleHost(host) else { return nil }

        // Everything after the tag minus the failure tail is where the rule and
        // the outbound live. The closing quote of `msg="…"` has to go first —
        // the outbound is the last thing on the line, so leaving it in would
        // put a `"` at the end of every node name and every direct-outbound
        // comparison.
        var routing = line[tagEnd...]
        if routing.hasSuffix("\"") { routing = routing.dropLast() }
        if let err = routing.range(of: " error:") { routing = routing[..<err.lowerBound] }
        let failed = line.contains(" error:")

        var outbound = ""
        var rule = ""
        if let using = routing.range(of: " using ") {
            outbound = String(routing[using.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let m = routing.range(of: " match ", options: .caseInsensitive,
                                     range: routing.startIndex..<using.lowerBound) {
                rule = String(routing[m.upperBound..<using.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
        } else if let open = routing.firstIndex(of: "("),
                  let close = routing.lastIndex(of: ")"), open < close,
                  let dial = routing.range(of: "dial ", options: .caseInsensitive) {
            // The parens carry the rule *with* the keyword the `using` form puts
            // outside them — `(match GeoSite/CN)`, `(match Match/)` — so strip it
            // here or every dial-failure row would read "match …".
            rule = Self.strippingMatchKeyword(
                String(routing[routing.index(after: open)..<close]))
            outbound = String(routing[dial.upperBound..<open])
                .trimmingCharacters(in: .whitespaces)
        } else if let m = routing.range(of: " match ", options: .caseInsensitive) {
            // No `using` and no parens: take the rule, leave the outbound empty
            // — the guard below drops the line rather than guessing an exit.
            rule = String(routing[m.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        guard !outbound.isEmpty else { return nil }

        // id stays 0 here; `ingest` assigns one under its lock so the counter is
        // touched on exactly one thread.
        return VpnDomainEntry(id: 0, timeText: stamp, host: host, port: port,
                              route: route(outbound: outbound), outbound: outbound,
                              rule: rule, failed: failed)
    }

    private nonisolated static func strippingMatchKeyword(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 6,
              trimmed.prefix(6).lowercased() == "match "
        else { return trimmed }
        return String(trimmed.dropFirst(6))
    }

    /// `…T11:41:02.432485000+08:00` → `11:41:02`, without a `DateFormatter`.
    ///
    /// Positional on purpose: the core emits RFC3339 with nanoseconds, which
    /// `ISO8601DateFormatter` only parses with `.withFractionalSeconds` set,
    /// and doing that per line would allocate a formatter's worth of work
    /// 10+ times a second for a string slice. The date half is unused anyway —
    /// ordering comes from arrival, so a run spanning midnight cannot make
    /// yesterday's lines sort after today's.
    nonisolated static func sliceClock(_ iso: String) -> String? {
        guard let t = iso.firstIndex(of: "T") else { return nil }
        let rest = iso[iso.index(after: t)...]
        guard rest.count >= 8 else { return nil }
        let candidate = String(rest.prefix(8))
        let parts = candidate.split(separator: ":")
        guard parts.count == 3,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return candidate
    }

    /// `host:port`, `[v6]:port`, or a bare host. IPv6 is bracketed by the core.
    nonisolated static func splitHostPort(_ token: String) -> (host: String, port: Int) {
        if token.hasPrefix("["),
           let close = token.firstIndex(of: "]") {
            let host = String(token[token.index(after: token.startIndex)..<close])
            let tail = token[token.index(after: close)...]
            if tail.hasPrefix(":"), let port = Int(tail.dropFirst()) { return (host, port) }
            return (host, 0)
        }
        if let colon = token.lastIndex(of: ":"), colon != token.startIndex {
            let host = String(token[..<colon])
            if let port = Int(token[token.index(after: colon)...]) { return (host, port) }
        }
        return (token, 0)
    }

    /// A host is something a human could read. Keeps a mangled line (the real
    /// log has one split across a chunk boundary, decoding to `tcp.bet]"`) from
    /// producing a row.
    nonisolated static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        return host.allSatisfy { c in
            c.isLetter || c.isNumber || c == "." || c == "-" || c == "_" || c == ":" || c == "%"
        }
    }

    /// `[DIRECT]` / `DIRECT` ⇒ 直连; `[REJECT]` / `REJECT` ⇒ 拒绝; anything else is
    /// a proxy node or group.
    ///
    /// The core names the destination two ways, and they carry the answer in
    /// different places:
    ///
    /// * A **bracket** — `🐟 漏网之鱼[1 官网 tcp.bet]`, `🎯 Direct[DIRECT]` — is a
    ///   proxy group's own name followed by the adapter it finally landed on.
    ///   The bracket wins, because the group's name can be anything.
    /// * A **bare adapter** — `DIRECT`, or `🎯 Direct` as this profile spells the
    ///   built-in one — has no bracket, so the last whitespace-separated word is
    ///   the adapter name and the emoji before it is decoration.
    ///
    /// A node whose *name* merely ends in "REJECT" is a `.proxied` connection,
    /// which is why the bare form is only consulted when there is no bracket.
    nonisolated static func route(outbound: String) -> VpnDomainRoute {
        let upper = outbound.uppercased()
        if let bracket = upper.lastIndex(of: "["),
           upper.hasSuffix("]") {
            let inner = upper[upper.index(after: bracket)..<upper.dropLast().endIndex]
            return adapter(inner)
        }
        guard let last = upper.split(separator: " ").last else { return .proxied }
        return adapter(last)
    }

    private nonisolated static func adapter(_ name: Substring) -> VpnDomainRoute {
        switch name {
        case "REJECT", "REJECT-DROP": return .reject
        case "DIRECT": return .direct
        default: return .proxied
        }
    }
}

/// Fixed-capacity FIFO. Appending at capacity replaces one slot rather than
/// moving all retained entries; IDs and chronological order survive wraparound.
struct VpnDomainRing {
    private var slots: [VpnDomainEntry?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        slots = Array(repeating: nil, count: capacity)
    }

    mutating func append(contentsOf batch: [VpnDomainEntry]) {
        for entry in batch {
            if count < slots.count {
                slots[(head + count) % slots.count] = entry
                count += 1
            } else {
                slots[head] = entry
                head = (head + 1) % slots.count
            }
        }
    }

    func snapshot() -> [VpnDomainEntry] {
        (0..<count).compactMap { slots[(head + $0) % slots.count] }
    }

    mutating func clear() {
        slots = Array(repeating: nil, count: slots.count)
        head = 0
        count = 0
    }
}

/// Ring of recent mihomo connections, keyed by destination domain.
///
/// Separate from `VpnManager` for the same reason `VpnLiveRates` and
/// `VpnLogStore` are: a connection line must not invalidate the VPN page's
/// 1100-line body (header, subscription cards, node mosaic). `VPNView` never
/// observes this object — only `VpnDomainLogSection` does.
///
/// **In memory only.** This is a live diagnostic, not an audit trail:
/// `core.log` is still on disk for anything that needs to outlive the session,
/// and persisting every visited domain would add retention, privacy and
/// rotation concerns to a reading the user asked to *look at*.
@MainActor
final class VpnDomainLog: ObservableObject {
    static let shared = VpnDomainLog()

    /// Recent diagnostic history; the UI displays bounded pages of this ring.
    static let limit = 2_000
    private var ring = VpnDomainRing(capacity: VpnDomainLog.limit)

    @Published private(set) var connections: [VpnDomainConnection] = []
    @Published private(set) var connectionRevision = 0
    @Published private(set) var proxiedTraffic = VpnDomainTraffic()
    private(set) var trafficByHost: [String: VpnDomainTraffic] = [:]
    private var trafficAccumulator = VpnDomainTrafficAccumulator()
    @Published private(set) var entries: [VpnDomainEntry] = []
    /// Rows parsed this session, including ones the ring has since evicted.
    /// Session total; per-domain summaries deliberately cover retained rows only.
    @Published private(set) var received = 0
    /// Bumped on every publish. The section's cache reads it instead of
    /// invalidating retained-row query results.
    @Published private(set) var revision = 0

    private let feed = VpnDomainFeed()
    /// Publish ceiling — same shape as `VpnLiveRates.minInterval`. A burst of
    /// connections (a page load opens dozens) should cost one view update, not
    /// dozens.
    private static let minInterval: TimeInterval = 1
    /// The background-only ceiling. A flush is not cheap: it rebuilds the
    /// 2,000-row snapshot and a 2,000-element `Set` of hosts on the main
    /// actor, and nothing reads either while every surface is hidden —
    /// /connections already drops to its 10 s sleep cadence in the same
    /// state. The ring still receives every line; only the publish slows.
    private static let hiddenInterval: TimeInterval = 10
    private var lastFlush = Date.distantPast
    private var flushTask: Task<Void, Never>?
    /// The interval a pending `flushTask` promised to wait out, so a later
    /// schedule call can tell whether the armed wait is still good enough.
    private var armedInterval: TimeInterval?
    private var wakeObservation: AnyCancellable?

    /// The cadence a flush may run at, as a pure function so the regression
    /// can execute it: full rate while anything is on screen, the sleep rate
    /// when the app is background-only.
    static func publishInterval(visible: Bool) -> TimeInterval {
        visible ? minInterval : hiddenInterval
    }

    private init() {
        // Coming back from background-only must publish immediately rather
        // than wait out a hidden-rate deadline: the section's first frame
        // after `isVisible` flips reads `revision`, and a staged batch that
        // sat through the sleep interval would read as a log that stopped.
        // Same subscription shape as `FanMonitor.syncPolling` — the closure
        // is delivered on the main queue and inherits main-actor isolation.
        wakeObservation = UIWakePolicy.observe { [weak self] in self?.scheduleFlush() }
    }

    /// Called from the core's pipe thread. Parsing and line buffering stay off
    /// the main actor; only a scheduled flush hops over.
    nonisolated func ingest(_ data: Data) {
        guard feed.ingest(data) else { return }
        Task { @MainActor [weak self] in self?.scheduleFlush() }
    }

    func updateConnections(_ snapshot: [[String: Any]]) {
        // The mapping itself is pure (string reads, `JSONCoerce`, one sort), so
        // it can run off the main actor: `/connections` is 0.1–2 MB of JSON and
        // this runs every 2 s while any window is visible. Callers on the main
        // actor pass `prepared` instead of `snapshot`.
        let next = Self.preparedConnections(snapshot)
        applyConnections(next)
    }

    /// The pure half of `updateConnections` — sees an already-decoded JSON
    /// array and produces the rows, with no main-actor state touched.
    nonisolated static func preparedConnections(_ snapshot: [[String: Any]]) -> [VpnDomainConnection] {
        snapshot.compactMap { item -> VpnDomainConnection? in
            guard let id = item["id"] as? String,
                  let metadata = item["metadata"] as? [String: Any] else { return nil }
            let host = metadata["host"] as? String ?? ""
            let destination = host.isEmpty ? (metadata["destinationIP"] as? String ?? "未知目标") : host
            let port = metadata["destinationPort"].map { String(describing: $0) } ?? ""
            let chains = item["chains"] as? [String] ?? []
            guard !chains.isEmpty else { return nil }
            let outbound = chains.joined(separator: " → ")
            let route: VpnDomainRoute = chains.contains(where: { $0.uppercased().hasPrefix("REJECT") })
                ? .reject : (chains.contains(where: { $0.uppercased() == "DIRECT" }) ? .direct : .proxied)
            let name = metadata["process"] as? String ?? ""
            let path = metadata["processPath"] as? String ?? ""
            let process = name.isEmpty ? (path.isEmpty ? "进程未知" : URL(fileURLWithPath: path).lastPathComponent) : name
            return VpnDomainConnection(
                id: id, endpoint: port.isEmpty ? destination : "\(destination):\(port)",
                process: process, route: route,
                rule: item["rule"] as? String ?? "", outbound: outbound,
                upload: max(0, JSONCoerce.int64Val(item["upload"])),
                download: max(0, JSONCoerce.int64Val(item["download"])))
        }.sorted { $0.id < $1.id }
    }

    func applyConnections(_ next: [VpnDomainConnection]) {
        trafficAccumulator.sample(next)
        proxiedTraffic = trafficAccumulator.totals
        trafficByHost = trafficAccumulator.byHost
        if connections != next {
            connections = next
            connectionRevision &+= 1
        }
    }

    func clear() {
        flushTask?.cancel()
        flushTask = nil
        armedInterval = nil
        feed.reset()
        ring.clear()
        entries = []
        received = 0
        trafficAccumulator.clear()
        proxiedTraffic = trafficAccumulator.totals
        trafficByHost = trafficAccumulator.byHost
        revision &+= 1
    }

    /// The core was relaunched. Drop the half-line its dead pipe left behind;
    /// keep everything already parsed.
    ///
    /// Deliberately **not** a full reset, although a restart already discards
    /// the buffers on the manager's side: changing the port, toggling TUN or
    /// switching subscription all restart the core, and wiping the table on
    /// each of those would erase the thing the user is reading the page for.
    /// The time column is what separates a pre-restart row from a post-restart
    /// one, so no "cleared at …" marker is needed either.
    func resetCarry() { feed.resetCarry() }

    /// Per-domain rollup, most-hit first. Pure and static so the regression
    /// suite can drive it without a main actor.
    nonisolated static func stat(entries: [VpnDomainEntry]) -> [VpnDomainLogStat] {
        var order: [String] = []
        var byHost: [String: VpnDomainLogStat] = [:]
        byHost.reserveCapacity(min(entries.count, 256))
        for entry in entries {
            if Task.isCancelled { break }
            if var stat = byHost[entry.host] {
                stat.hits += 1
                switch entry.route {
                case .proxied: stat.proxied += 1
                case .direct: stat.direct += 1
                case .reject: stat.reject += 1
                }
                if entry.failed { stat.failed += 1 }
                // Arrival order is chronological, so the last write wins.
                stat.lastTimeText = entry.timeText
                stat.lastOutbound = entry.outbound
                stat.lastRoute = entry.route
                byHost[entry.host] = stat
            } else {
                order.append(entry.host)
                byHost[entry.host] = VpnDomainLogStat(
                    host: entry.host, hits: 1,
                    proxied: entry.route == .proxied ? 1 : 0,
                    direct: entry.route == .direct ? 1 : 0,
                    reject: entry.route == .reject ? 1 : 0,
                    failed: entry.failed ? 1 : 0,
                    lastTimeText: entry.timeText,
                    lastOutbound: entry.outbound,
                    lastRoute: entry.route)
            }
        }
        return order.compactMap { byHost[$0] }
            .sorted { lhs, rhs in
                if lhs.hits != rhs.hits { return lhs.hits > rhs.hits }
                return lhs.host < rhs.host
            }
    }

    // MARK: - Flush

    private func scheduleFlush() {
        let interval = Self.publishInterval(visible: UIWakePolicy.hasVisibleWindow)
        let wait = interval - Date().timeIntervalSince(lastFlush)
        if wait <= 0 {
            flush()
            return
        }
        // A pending task was armed against the cadence in force when it was
        // scheduled. If that cadence is still at least as short as the
        // current one, the pending publish is due no later than the new
        // interval allows — publishing early is always fine, so keep it.
        // Only a longer armed wait (armed while hidden, now visible) is
        // re-taken, so the section's first frame after a wake does not wait
        // out a sleep-interval deadline.
        if flushTask != nil, let armed = armedInterval, armed <= interval { return }
        flushTask?.cancel()
        armedInterval = interval
        let ns = UInt64(wait * 1_000_000_000)
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    private func flush() {
        flushTask = nil
        armedInterval = nil
        lastFlush = Date()
        let batch = feed.drain()
        guard !batch.isEmpty else { return }
        ring.append(contentsOf: batch)
        entries = ring.snapshot()
        trafficAccumulator.retainHosts(Set(entries.map(\.host)))
        trafficByHost = trafficAccumulator.byHost
        received += batch.count
        revision &+= 1
    }
}

/// Services this app already knows about, for the one piece of *analysis* the
/// summary offers: a domain on this list that the core sent out **direct** is
/// traffic the user probably expects to be proxied.
///
/// Deliberately small and suffix-matched — it is a hint, not a blocklist, and a
/// false positive (flagging every `googleapis.com` call as a missed Gemini
/// request) is worse than not showing the line at all.
enum VpnWatchlist {
    static let services: [(name: String, domains: [String])] = [
        ("Anthropic", ["anthropic.com", "claude.ai"]),
        ("OpenAI", ["openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com"]),
        ("Gemini", ["gemini.google.com", "generativelanguage.googleapis.com"]),
        ("xAI", ["x.ai", "grok.com"]),
        ("Cursor", ["cursor.com", "cursor.sh"]),
        ("GitHub", ["github.com", "githubusercontent.com"]),
    ]

    /// Names of the watchlist services this host belongs to.
    static func matches(host: String) -> [String] {
        let h = host.lowercased()
        return services.filter { _, domains in
            domains.contains { h == $0 || h.hasSuffix("." + $0) }
        }.map(\.name)
    }
}
