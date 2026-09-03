import Foundation
import Combine

/// Origin of a proxied request. Independent of capture enums so the access
/// log can run when traffic recording is off.
enum ProxyLogSource: String {
    case claude, codex
    var label: String { self == .claude ? "Claude" : "Codex" }
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

    var isPending: Bool { endedAt == nil }

    var durationMs: Int {
        let end = endedAt ?? Date()
        return max(0, Int(end.timeIntervalSince(startedAt) * 1000))
    }

    /// Single-line console form, used by the log view and copy-all.
    var consoleLine: String {
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

    @Published private(set) var entries: [ProxyLogEntry] = []

    private let lock = NSLock()
    private var rows: [ProxyLogEntry] = []
    private var nextID: UInt64 = 1
    private let limit = 500
    private let iso = ISO8601DateFormatter()
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
            error: nil)
        rows.append(entry)
        if rows.count > limit {
            rows.removeFirst(rows.count - limit)
        }
        lock.unlock()
        publish()
        return ProxyLogTap(id: id, store: self)
    }

    func finish(id: UInt64, status: Int, error: String?) {
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
        row.endedAt = Date()
        row.status = status
        row.error = error.flatMap { Self.clip($0, 240) }.flatMap { $0.isEmpty ? nil : $0 }
        rows[idx] = row
        lock.unlock()
        publish()
        appendJSONL(row)
        scheduleCompact()
    }

    func clear() {
        lock.lock()
        rows = []
        lock.unlock()
        publish()
        try? FileManager.default.removeItem(at: FilePaths.proxyLogFile)
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

    private func scheduleCompact() {
        compactWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.compactIfNeeded() }
        compactWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
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
            }())
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
    private var finished = false

    init(id: UInt64, store: ProxyAccessLog) {
        self.id = id
        self.store = store
    }

    func finish(status: Int, error: String? = nil) {
        guard !finished else { return }
        finished = true
        store?.finish(id: id, status: status, error: error)
    }
}
