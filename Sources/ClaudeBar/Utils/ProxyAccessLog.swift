import Foundation
import Combine
import CoreFoundation

/// Origin of a proxied request. Independent of capture enums so the access
/// log can run when traffic recording is off.
enum ProxyLogSource: String {
    case claude, codex, other
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .other: return "第三方"
        }
    }
}

enum ProxyLogKind: String {
    case anthropic
    case openaiChat = "chat"
    case openaiResponses = "responses"
    case health
    case models
    case other

    var label: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openaiChat: return "Chat"
        case .openaiResponses: return "Responses"
        case .health: return "Health"
        case .models: return "Models"
        case .other: return "Other"
        }
    }
}

/// One access-log line. Metadata only — never request or response bodies.
struct ProxyLogEntry: Identifiable, Equatable {
    var id: UInt64
    var startedAt: Date
    var endedAt: Date?
    var method: String
    var path: String
    var source: ProxyLogSource
    var kind: ProxyLogKind
    var provider: String
    var model: String
    var stream: Bool
    var bytesIn: Int
    var status: Int
    var error: String?
    /// Reported by the upstream, present only when it said so. `nil` is "the
    /// upstream never reported usage" — an interrupted stream, a gateway that
    /// omits the field — and reads as `—`, never as a real zero.
    var promptTokens: Int?
    var completionTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?

    var isPending: Bool { endedAt == nil }

    var durationMs: Int {
        let end = endedAt ?? Date()
        return max(0, Int(end.timeIntervalSince(startedAt) * 1000))
    }

    /// `⌊input + output + cache read + cache write⌋`, all four summed — the
    /// same fold as `TokenTotals.total` in `StreamAssembler`, and as
    /// `ModelUsage.totalTokens`, which is what the Usage page's per-model
    /// rollup is built from. `nil` when the upstream reported nothing.
    ///
    /// Summed with `addingReportingOverflow`: a line loaded from disk carries
    /// whatever number was in the file, and `NSNumber.intValue` clamps an
    /// oversized one to `Int.max` rather than rejecting it, so four of those
    /// would trap on the main actor while the page renders. Saturating is the
    /// only outcome that keeps a corrupt file from crashing the app.
    var totalTokens: Int? {
        guard promptTokens != nil || completionTokens != nil
                || cacheReadTokens != nil || cacheWriteTokens != nil else { return nil }
        var sum = 0
        for value in [promptTokens, completionTokens, cacheReadTokens, cacheWriteTokens] {
            guard let value else { continue }
            let (next, overflow) = sum.addingReportingOverflow(value)
            sum = overflow ? Int.max : next
        }
        return sum
    }

    /// Single-line console form, used by the log view and copy-all: the
    /// metadata line plus the token column.
    var consoleLine: String { consoleBody + tokenField }

    /// Everything but the token column — the log view renders the two
    /// separately so the counts stay in their own right-hand column instead of
    /// wrapping off a long path.
    var consoleBody: String {
        let time = ProxyAccessLog.clock.string(from: startedAt)
        let src = source.label.padding(toLength: 6, withPad: " ", startingAt: 0)
        let kindPad = kind.label.padding(toLength: 10, withPad: " ", startingAt: 0)
        let st: String
        if isPending {
            st = "  …"
        } else if status == 0 {
            st = "  —"
        } else {
            st = String(format: "%3d", status)
        }
        let dur = isPending ? "     …" : ProxyAccessLog.formatDuration(durationMs)
        let size = ProxyAccessLog.formatBytes(bytesIn)
        let modelBit = model.isEmpty ? "—" : model
        let streamBit = stream ? " sse" : ""
        let err = (error?.isEmpty == false) ? "  \(error!)" : ""
        return "\(time)  \(method.padding(toLength: 4, withPad: " ", startingAt: 0))  \(path)  \(src) \(kindPad)  \(modelBit)\(streamBit)  \(st)  \(dur)  \(size)\(err)"
    }

    /// Copy-all form of the token column. The on-screen column is
    /// `LogTokenColumn`, which keeps each bucket in a fixed-width slot;
    /// this string is the same buckets, in the same order, without the
    /// parentheses the old line used.
    ///
    /// `入` is fresh input: `TokenTotals` has already folded the cache hit
    /// out of the upstream's prompt count, so `入 + 缓存` is the prompt the
    /// model actually saw. `""` when the call is over and the upstream never
    /// reported usage — that absence is not a row of zeros.
    var tokenField: String {
        if let totalTokens {
            let f: (Int) -> String = UsageStats.formatTokens
            var parts = [
                f(totalTokens),
                "入 \(f(promptTokens ?? 0))",
                "出 \(f(completionTokens ?? 0))",
                "缓存 \(f(cacheReadTokens ?? 0))",
            ]
            if let written = cacheWriteTokens {
                parts.append("写入 \(f(written))")
            }
            return "  " + parts.joined(separator: "  ")
        }
        return isPending ? "  …" : ""
    }
}

/// In-memory ring + JSONL sidecar for proxy access logs.
/// The proxy calls `begin` / `ProxyLogTap.finish`; the UI observes `entries`.
/// Mutable request state is lock-guarded, disk formatting is ioQueue-only,
/// and published state belongs to the main actor.
final class ProxyAccessLog: ObservableObject, @unchecked Sendable {
    static let shared = ProxyAccessLog()

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Hour and minute only, for the traffic list rows. `Date.formatted` builds
    /// a fresh `Date.FormatStyle` and re-parses the pattern through ICU on every
    /// call — for up to `listLimit` rows, on every capture publish (0.1 s while
    /// anything is streaming).
    static let clockShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    @MainActor @Published private(set) var entries: [ProxyLogEntry] = []

    private let lock = NSLock()
    private var rows: [ProxyLogEntry] = []
    /// Streaming usage, keyed by row id — see `updateTokens`.
    private var pendingTokens: [UInt64: TokenTotals] = [:]
    private var nextID: UInt64 = 1
    private var loaded = false
    private let loadQueue = DispatchQueue(label: "com.claudebar.proxy-access-log.load", qos: .utility)
    private let limit = 500
    private let iso = ISO8601DateFormatter()
    /// Lock-guarded single-flight publication; a continuous burst still gets
    /// a snapshot every 100 ms. The serial worker takes the lock off-main.
    private var publishScheduled = false
    private let publishQueue = DispatchQueue(label: "com.claudebar.proxy-access-log.publish", qos: .utility)

    /// Every write to `proxyLogFile` runs here. One writer means the JSONL
    /// append and the whole-file compaction can never interleave on the same
    /// path, and it keeps the cooperative pool from blocking on disk I/O.
    private let ioQueue = DispatchQueue(label: "com.claudebar.proxy-access-log.io", qos: .utility)
    /// `ioQueue`-only state, deliberately not lock-guarded.
    ///
    /// This used to be read and replaced from whichever cooperative thread
    /// finished a request first. Two overlapping calls both did
    /// `compactWork = work`, and the released-then-swapped strong reference
    /// was deallocated twice — the crash landed in
    /// `ProxyAccessLog.scheduleCompact` → `swift_deallocClassInstance` →
    /// `objc_destructInstance`, faulting on a garbage isa. Confining the item
    /// to one serial queue removes the shared reference entirely.
    private var compactWork: DispatchWorkItem?

    private init() {}

    /// UI construction never opens the sidecar. A first request uses the same
    /// serial loader before assigning its id; history cannot overwrite traffic.
    func loadListIfNeeded() {
        loadQueue.async { [weak self] in self?.loadHistory() }
    }

    /// The proxy's first request suspends while the Dispatch loader reads;
    /// subsequent requests take only the short state check.
    func prepareForRequests() async {
        guard needsHistoryLoad() else { return }
        await withCheckedContinuation { continuation in
            loadQueue.async {
                self.loadHistory()
                continuation.resume()
            }
        }
    }

    private func needsHistoryLoad() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !loaded
    }

    private func loadHistory() {
        guard needsHistoryLoad() else { return }
        let history = readRecentEntries()
        lock.lock()
        // A clear during the read marks the history consumed. Never resurrect
        // its old rows, even if new traffic has already arrived afterwards.
        if !loaded {
            rows = history
            nextID = (history.map(\.id).max() ?? 0) + 1
            loaded = true
            schedulePublishLocked()
        }
        lock.unlock()
    }

    // MARK: - Proxy API (any thread)

    func begin(method: String, path: String, source: ProxyLogSource, kind: ProxyLogKind,
               provider: String, model: String, stream: Bool, bytesIn: Int) -> ProxyLogTap {
        if needsHistoryLoad() { loadQueue.sync { loadHistory() } }
        lock.lock()
        let id = nextID
        nextID += 1
        let entry = ProxyLogEntry(
            id: id,
            startedAt: Date(),
            endedAt: nil,
            method: method,
            path: Self.clipPath(path),
            source: source,
            kind: kind,
            provider: Self.clip(provider, 80),
            model: Self.clip(model, 80),
            stream: stream,
            bytesIn: max(0, bytesIn),
            status: 0,
            error: nil,
            promptTokens: nil,
            completionTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil)
        rows.append(entry)
        if rows.count > limit {
            let dropped = rows.count - limit
            rows.removeFirst(dropped)
            // A row evicted here can never be sealed — `finish` bails on a
            // missing id — so its pending usage would sit in the dictionary
            // for the life of the process. Ids are monotonic, so anything
            // below the new first id is gone for good.
            if let first = rows.first {
                pendingTokens = pendingTokens.filter { $0.key >= first.id }
            }
        }
        schedulePublishLocked()
        lock.unlock()
        return ProxyLogTap(id: id, store: self)
    }

    /// Seal one line. `tokens` is the upstream's own usage report.
    ///
    /// Counts already handed in by `note` are used when `finish` carries none
    /// — the sealed status does not always come from the arm that merged the
    /// usage event, and dropping them there would silently blank the field.
    func finish(id: UInt64, status: Int, error: String?, tokens: TokenTotals? = nil) {
        lock.lock()
        guard let idx = rows.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        var row = rows[idx]
        if row.endedAt != nil {
            lock.unlock()
            return
        }
        let stored = pendingTokens.removeValue(forKey: id)
        let merged = (tokens?.isEmpty == false ? tokens : nil) ?? stored
        if let merged {
            row.promptTokens = merged.input
            row.completionTokens = merged.output
            row.cacheReadTokens = merged.cacheRead
            row.cacheWriteTokens = merged.cacheWrite
        }
        row.endedAt = Date()
        row.status = status
        row.error = error.flatMap { Self.clip($0, 240) }.flatMap { $0.isEmpty ? nil : $0 }
        rows[idx] = row
        schedulePublishLocked()
        // Enqueue while holding the ordering lock so clear cannot get ahead
        // of this write and then have an older finished row reappear on disk.
        scheduleWrite(row)
        lock.unlock()
    }

    /// Counts that arrived while the row was still streaming, held back until
    /// `finish` writes the line once. Usage clusters at the end of a stream,
    /// so this is both cheaper and what keeps the row from republishing itself
    /// on every chunk.
    func updateTokens(id: UInt64, tokens: TokenTotals) {
        guard !tokens.isEmpty else { return }
        lock.lock()
        guard let idx = rows.firstIndex(where: { $0.id == id }), rows[idx].endedAt == nil else {
            lock.unlock()
            return
        }
        pendingTokens[id] = tokens
        lock.unlock()
    }

    func clear() {
        lock.lock()
        rows = []
        pendingTokens = [:]
        loaded = true
        schedulePublishLocked()
        ioQueue.async { try? FileManager.default.removeItem(at: FilePaths.proxyLogFile) }
        lock.unlock()
    }

    // MARK: - Internals

    private func schedulePublishLocked() {
        guard !publishScheduled else { return }
        publishScheduled = true
        publishQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.rows
            self.publishScheduled = false
            self.lock.unlock()
            // All snapshots are dispatched by one serial worker, preserving
            // order across concurrent begin/finish/clear calls without making
            // the interaction thread wait on the proxy's lock.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.entries != snapshot else { return }
                self.entries = snapshot
            }
        }
    }

    private func readRecentEntries() -> [ProxyLogEntry] {
        guard let handle = try? FileHandle(forReadingFrom: FilePaths.proxyLogFile) else { return [] }
        defer { try? handle.close() }
        let formatter = ISO8601DateFormatter()
        var rows: [ProxyLogEntry] = []
        rows.reserveCapacity(limit)
        func appendLines(_ data: Data.SubSequence) {
            // Records are cut at raw 0x0A above, so split on "\n" only. The
            // previous `whereSeparator: \.isNewline` also cut on U+2028,
            // U+2029 and U+0085, and `JSONSerialization` writes those scalars
            // unescaped inside a JSON string — a path or error containing one
            // split a single record into fragments that no longer decoded, and
            // the row silently disappeared from the history list.
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let row = decode(String(line), using: formatter) else { continue }
                rows.append(row)
                if rows.count == limit { break }
            }
        }
        do {
            var position = try handle.seekToEnd()
            var pending = Data()
            while position > 0 && rows.count < limit {
                let count = Int(min(position, 64 * 1024))
                position -= UInt64(count)
                try handle.seek(toOffset: position)
                var chunk = Data()
                while chunk.count < count {
                    guard let part = try handle.read(upToCount: count - chunk.count), !part.isEmpty else { return [] }
                    chunk.append(part)
                }
                chunk.append(pending)
                var end = chunk.endIndex
                while let separator = chunk[..<end].lastIndex(of: 0x0A) {
                    appendLines(chunk[(separator + 1)..<end])
                    end = separator
                    if rows.count == limit { break }
                }
                if rows.count == limit { break }
                if position == 0 { appendLines(chunk[..<end]); break }
                pending = Data(chunk[..<end])
            }
        } catch {
            return []
        }
        rows.reverse()
        return rows
    }

    // MARK: - Disk I/O (ioQueue only)

    /// One finished row → append + a debounced compaction check, both queued
    /// on the single writer. Hop off the caller's thread so a request's
    /// completion never waits on `open`/`write`/`close`.
    private func scheduleWrite(_ row: ProxyLogEntry) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.appendJSONL(row)
            self.scheduleCompact()
        }
    }

    private func appendJSONL(_ row: ProxyLogEntry) {
        guard let data = encode(row) else { return }
        let url = FilePaths.proxyLogFile
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Debounce: each finished call pushes the rewrite out another 2s, so a
    /// burst of traffic compacts once at the end instead of per request.
    private func scheduleCompact() {
        compactWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.compactIfNeeded() }
        compactWork = work
        ioQueue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func compactIfNeeded() {
        lock.lock()
        let snapshot = rows
        lock.unlock()
        guard snapshot.count >= limit else { return }
        // Only sealed rows. `rows` holds requests still streaming, and writing
        // one now puts a `"end":""` copy on disk that `finish` then appends
        // again under the same id — the loader would list the call twice, once
        // pending forever. A pending row is also the one most likely to change
        // a millisecond later, so skipping it is what the next compaction (or
        // its own `scheduleWrite`) will pick up.
        let blob = snapshot.compactMap { $0.endedAt == nil ? nil : encode($0) }
            .reduce(into: Data(), { $0.append($1) })
        try? blob.write(to: FilePaths.proxyLogFile, options: .atomic)
    }

    private func encode(_ row: ProxyLogEntry) -> Data? {
        let obj: [String: Any] = [
            "id": row.id,
            "at": iso.string(from: row.startedAt),
            "end": row.endedAt.map { iso.string(from: $0) } ?? "",
            "method": row.method,
            "path": row.path,
            "source": row.source.rawValue,
            "kind": row.kind.rawValue,
            "provider": row.provider,
            "model": row.model,
            "stream": row.stream,
            "bytesIn": row.bytesIn,
            "status": row.status,
            "error": row.error ?? "",
            "promptTokens": row.promptTokens as Any? ?? NSNull(),
            "completionTokens": row.completionTokens as Any? ?? NSNull(),
            "cacheReadTokens": row.cacheReadTokens as Any? ?? NSNull(),
            "cacheWriteTokens": row.cacheWriteTokens as Any? ?? NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        var line = data
        line.append(10)
        return line
    }

    private func decode(_ line: String, using iso: ISO8601DateFormatter) -> ProxyLogEntry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let id = (obj["id"] as? NSNumber)?.uint64Value ?? 0
        // The ceiling keeps `begin`'s `nextID += 1` away from UInt64 overflow:
        // a truncated or hand-edited sidecar can hold any value that fits, and
        // `NSNumber.uint64Value` converts a larger one without complaining.
        guard id > 0, id < 1 << 62,
              let atRaw = obj["at"] as? String,
              let at = iso.date(from: atRaw),
              let method = obj["method"] as? String,
              let path = obj["path"] as? String,
              let sourceRaw = obj["source"] as? String,
              let source = ProxyLogSource(rawValue: sourceRaw),
              let kindRaw = obj["kind"] as? String,
              let kind = ProxyLogKind(rawValue: kindRaw) else { return nil }
        let endRaw = obj["end"] as? String ?? ""
        return ProxyLogEntry(
            id: id,
            startedAt: at,
            endedAt: endRaw.isEmpty ? nil : iso.date(from: endRaw),
            method: method,
            path: path,
            source: source,
            kind: kind,
            provider: obj["provider"] as? String ?? "",
            model: obj["model"] as? String ?? "",
            stream: obj["stream"] as? Bool ?? false,
            bytesIn: (obj["bytesIn"] as? NSNumber)?.intValue ?? 0,
            status: (obj["status"] as? NSNumber)?.intValue ?? 0,
            error: {
                let s = obj["error"] as? String ?? ""
                return s.isEmpty ? nil : s
            }(),
            // Absent on every line written before usage was recorded, and on
            // lines for requests whose upstream never reported it. Present but
            // implausible counts read as absent (see `tokenCount`).
            promptTokens: (obj["promptTokens"] as? NSNumber).flatMap(Self.tokenCount),
            completionTokens: (obj["completionTokens"] as? NSNumber).flatMap(Self.tokenCount),
            cacheReadTokens: (obj["cacheReadTokens"] as? NSNumber).flatMap(Self.tokenCount),
            cacheWriteTokens: (obj["cacheWriteTokens"] as? NSNumber).flatMap(Self.tokenCount))
    }

    /// One token bucket from disk, rejected when it is not a plausible count.
    ///
    /// `NSNumber.intValue` clamps anything oversized to `Int.max` and rounds a
    /// fractional value, so a corrupted or hand-edited line would otherwise
    /// hand the UI a number no request can produce — four of those trap the
    /// `totalTokens` sum under `-O`. The ceiling is a plausibility bound, well
    /// above any single request's counts and well below `Int.max`, so a real
    /// line is never rejected while a hostile one is dropped to "unreported".
    static func tokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < 1e15 else { return nil }
        return Int(double)
    }

    static func clip(_ s: String, _ cap: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if flat.count <= cap { return flat }
        return String(flat.prefix(cap - 1)) + "…"
    }

    static func clipPath(_ path: String) -> String {
        clip(path.split(separator: "?").first.map(String.init) ?? path, 160)
    }

    static func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return String(format: "%4dms", ms) }
        return String(format: "%5.2fs", Double(ms) / 1000)
    }

    static func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return String(format: "%.1fKB", Double(n) / 1024) }
        return String(format: "%.1fMB", Double(n) / (1024 * 1024))
    }
}

/// Held by the proxy for the lifetime of one forwarded call. `finish` is
/// idempotent so nested defer / catch paths cannot double-write.
final class ProxyLogTap {
    let id: UInt64
    private weak var store: ProxyAccessLog?
    /// `finish` is reached from nested defer/catch arms on the connection's
    /// task and can also be raced by a teardown path, so the once-only flag is
    /// lock-guarded rather than a bare `Bool`.
    private let lock = NSLock()
    private var finished = false
    private let records: Bool

    init(id: UInt64, store: ProxyAccessLog?, records: Bool = true) {
        self.id = id
        self.store = store
        self.records = records
    }

    /// Fold the upstream's usage into this line. Safe to call for every event
    /// and with `nil`; the counts are held until `finish` writes the row.
    func note(tokens: TokenTotals?) {
        guard records, let tokens, !tokens.isEmpty else { return }
        store?.updateTokens(id: id, tokens: tokens)
    }

    func finish(status: Int, error: String? = nil, tokens: TokenTotals? = nil) {
        lock.lock()
        guard records, !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        store?.finish(id: id, status: status, error: error, tokens: tokens)
    }

    /// Returned when third-party traffic recording is disabled.
    static let noop = ProxyLogTap(id: 0, store: nil, records: false)
}
