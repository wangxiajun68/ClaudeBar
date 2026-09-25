import Foundation
import Combine

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

    var isPending: Bool { endedAt == nil }

    var durationMs: Int {
        let end = endedAt ?? Date()
        return max(0, Int(end.timeIntervalSince(startedAt) * 1000))
    }

    /// `⌊input + output + cache⌋`, all three summed, so the number matches the
    /// Usage page's `ModelUsage.totalTokens` for the same call. `nil` when the
    /// upstream reported nothing.
    var totalTokens: Int? {
        guard promptTokens != nil || completionTokens != nil || cacheReadTokens != nil else { return nil }
        return (promptTokens ?? 0) + (completionTokens ?? 0) + (cacheReadTokens ?? 0)
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

    /// The token column for this line, as text: `Σ 8.9万 (in …/out …/cache …)`,
    /// or a bare `Σ …` while the call is still streaming and no usage event
    /// has arrived. `""` — no column at all — when the call is over and the
    /// upstream never reported usage. That is what the `—` of a checkless row
    /// means; it is not a store of zeros.
    var tokenField: String {
        if let totalTokens {
            // Typed, because `UsageStats.formatTokens` is overloaded (the
            // style-explicit variant) and a bare reference is ambiguous.
            let f: (Int) -> String = UsageStats.formatTokens
            return "  Σ \(f(totalTokens)) (in \(f(promptTokens ?? 0)) / out \(f(completionTokens ?? 0)) / cache \(f(cacheReadTokens ?? 0)))"
        }
        return isPending ? "  Σ …" : ""
    }
}

/// In-memory ring + JSONL sidecar for proxy access logs.
/// The proxy calls `begin` / `ProxyLogTap.finish`; the UI observes `entries`.
final class ProxyAccessLog: ObservableObject {
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

    @Published private(set) var entries: [ProxyLogEntry] = []

    private let lock = NSLock()
    private var rows: [ProxyLogEntry] = []
    /// Streaming usage, keyed by row id — see `updateTokens`.
    private var pendingTokens: [UInt64: TokenTotals] = [:]
    private var nextID: UInt64 = 1
    private let limit = 500
    private let iso = ISO8601DateFormatter()

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

    private init() {
        lock.lock()
        let loaded = loadLocked()
        rows = loaded
        lock.unlock()
        entries = loaded
    }

    // MARK: - Proxy API (any thread)

    func begin(method: String, path: String, source: ProxyLogSource, kind: ProxyLogKind,
               provider: String, model: String, stream: Bool, bytesIn: Int) -> ProxyLogTap {
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
            cacheReadTokens: nil)
        rows.append(entry)
        var dropped = 0
        if rows.count > limit {
            dropped = rows.count - limit
            rows.removeFirst(dropped)
        }
        lock.unlock()
        publishAppended(entry, droppedFirst: dropped)
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
        }
        row.endedAt = Date()
        row.status = status
        row.error = error.flatMap { Self.clip($0, 240) }.flatMap { $0.isEmpty ? nil : $0 }
        rows[idx] = row
        lock.unlock()
        publishUpdated(row)
        scheduleWrite(row)
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
        lock.unlock()
        publish()
        ioQueue.async { try? FileManager.default.removeItem(at: FilePaths.proxyLogFile) }
    }

    // MARK: - Internals

    private func publish() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.rows
            self.lock.unlock()
            self.entries = snapshot
        }
    }

    /// Incremental variants. `publish()` copied the whole 500-row array under
    /// the lock and reassigned it on every single request — two full copies
    /// per forwarded call, plus a 500-element array diff for SwiftUI. Appending
    /// or patching one row is all the UI actually needs.
    private func publishAppended(_ row: ProxyLogEntry, droppedFirst: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if droppedFirst > 0, self.entries.count >= droppedFirst {
                self.entries.removeFirst(droppedFirst)
            }
            self.entries.append(row)
        }
    }

    private func publishUpdated(_ row: ProxyLogEntry) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let i = self.entries.firstIndex(where: { $0.id == row.id }) {
                self.entries[i] = row
            }
        }
    }

    private func loadLocked() -> [ProxyLogEntry] {
        guard let data = try? Data(contentsOf: FilePaths.proxyLogFile),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var rows: [ProxyLogEntry] = []
        rows.reserveCapacity(limit)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let row = decode(String(line)) else { continue }
            rows.append(row)
        }
        if rows.count > limit {
            rows = Array(rows.suffix(limit))
        }
        nextID = (rows.map(\.id).max() ?? 0) + 1
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
        let blob = snapshot.compactMap { encode($0) }.reduce(into: Data(), { $0.append($1) })
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
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        var line = data
        line.append(10)
        return line
    }

    private func decode(_ line: String) -> ProxyLogEntry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let id = (obj["id"] as? NSNumber)?.uint64Value ?? 0
        guard id > 0,
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
            // lines for requests whose upstream never reported it.
            promptTokens: (obj["promptTokens"] as? NSNumber)?.intValue,
            completionTokens: (obj["completionTokens"] as? NSNumber)?.intValue,
            cacheReadTokens: (obj["cacheReadTokens"] as? NSNumber)?.intValue)
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
