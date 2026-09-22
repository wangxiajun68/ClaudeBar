import Foundation
import Combine
import SQLite3

/// One captured proxy request. Summaries stay in memory for the list;
/// payloads live in SQLite and are loaded on demand.
struct CaptureSummary: Identifiable, Equatable {
    var id: Int64
    var startedAt: Date
    var endedAt: Date?
    var firstTokenAt: Date?
    var kind: CaptureKind
    var source: CaptureSource
    var providerName: String
    var model: String
    var path: String
    var isStream: Bool
    var state: CaptureState
    var httpStatus: Int
    var promptTokens: Int?
    var completionTokens: Int?
    var cacheReadTokens: Int?
    var error: String?
    var preview: String
}

struct CaptureDetail: Equatable {
    var summary: CaptureSummary
    var requestJSON: String
    var rewrittenJSON: String
    var responseJSON: String
    var rawSSE: String
    var requestHeadersJSON: String
    var turns: [CaptureTranscript.Turn]
    var toolCalls: [CaptureTranscript.ToolCall]
    var requestTruncated: Bool = false
    var payloadsLoaded: Bool = true
}

enum CaptureKind: String {
    case anthropic
    case openaiChat = "openai-chat"
    case openaiResponses = "openai-responses"

    var label: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openaiChat: return "Chat"
        case .openaiResponses: return "Responses"
        }
    }
}

enum CaptureSource: String {
    case claude, codex, other

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .other: return "代理"
        }
    }

    var shortLabel: String {
        switch self {
        case .claude: return "CC"
        case .codex: return "Codex"
        case .other: return "代理"
        }
    }

    /// Classify by User-Agent only. Unrecognized clients are third-party — never
    /// inferred from the proxy route (OpenAI vs Anthropic path).
    static func infer(headers: [String: String], route: CaptureSource = .other) -> CaptureSource {
        if isClaudeClient(headers: headers) { return .claude }
        if isCodexClient(headers: headers) { return .codex }
        return .other
    }

    static func isClaudeClient(headers: [String: String]) -> Bool {
        let ua = (headers["user-agent"] ?? "").lowercased()
        return ua.contains("claude-cli") || ua.contains("claude-code") || ua.contains("claude-user")
    }

    static func isCodexClient(headers: [String: String]) -> Bool {
        let ua = (headers["user-agent"] ?? "").lowercased()
        return ua.contains("codex")
    }

    /// Any client that is not Claude Code or Codex (Cursor, curl, custom SDKs, …).
    static func isThirdPartyClient(headers: [String: String]) -> Bool {
        !isClaudeClient(headers: headers) && !isCodexClient(headers: headers)
    }
}

enum CaptureState: String {
    case pending, streaming, done, error, aborted
}

extension CaptureSummary {
    /// Still in flight — no terminal state yet. Drives the interrupt button.
    var isLive: Bool { state == .pending || state == .streaming }
}

struct CaptureLive: Equatable {
    var content = ""
    var reasoning = ""
    var tools: [CaptureAssembler.Tool] = []
}

final class CaptureCatalog: ObservableObject {
    @Published var records: [CaptureSummary] = []
    @Published var livePreview: [Int64: String] = [:]
}

final class CaptureStreams: ObservableObject {
    @Published var live: [Int64: CaptureLive] = [:]
}

/// Sidecar recorder for the local proxy. SQLite writes happen off-main.
/// List UI observes `catalog`; the selected inspector observes `streams`.
final class ProxyCaptureStore {
    static let shared = ProxyCaptureStore()

    let catalog = CaptureCatalog()
    let streams = CaptureStreams()

    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?
    private var openFailed = false
    private var pendingLive: [Int64: CaptureLive] = [:]
    private var flushWork: DispatchWorkItem?
    private let listLimit = 120
    private let payloadCap = 16 * 1024 * 1024
    private let isoFormatter = ISO8601DateFormatter()
    private lazy var jsonStore = CaptureJSONStore(listLimit: listLimit, iso: isoFormatter)
    private var useDatabase: Bool { DiskPersistence.useDatabase }

    private static let dbURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("proxy-capture.db")
    }()

    private init() {
        lock.lock()
        let rows = loadCurrentBackendLocked()
        lock.unlock()
        publishList(rows)
    }

    /// Close SQLite (if open) and reload from the backend selected in Settings.
    func reloadPersistence() {
        lock.lock()
        closeDatabaseLocked()
        let rows = loadCurrentBackendLocked()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.catalog.records = rows
            self.catalog.livePreview = [:]
            self.streams.live = [:]
        }
    }

    // MARK: - Proxy API (any thread)

    /// Start a capture. Returns nil if the active backend cannot persist.
    ///
    /// `preview` and `encodeHeaders` parse the request body to find the last
    /// user utterance and to pretty-print headers. Both are pure functions of
    /// `requestJSON` / `requestHeaders`, so they run *before* taking the lock
    /// — holding the recursive lock across two full JSON parses of a
    /// multi-MB body (a screenshot request peaks at 40–100 MB) stalled every
    /// other capture thread for the duration.
    func begin(kind: CaptureKind, source: CaptureSource, provider: String,
               model: String, path: String, stream: Bool,
               requestJSON: String?, rewrittenJSON: String?,
               requestHeaders: [String: String]? = nil) -> CaptureTap? {
        let preview = Self.preview(from: requestJSON)
        let headersJSON = Self.encodeHeaders(requestHeaders)
        lock.lock()
        defer { lock.unlock() }
        let summary: CaptureSummary
        if useDatabase {
            guard let created = beginSQL(kind: kind, source: source, provider: provider,
                                         model: model, path: path, stream: stream,
                                         requestJSON: requestJSON, rewrittenJSON: rewrittenJSON,
                                         requestHeadersJSON: headersJSON,
                                         preview: preview) else { return nil }
            summary = created
        } else {
            summary = jsonStore.begin(kind: kind, source: source, provider: provider,
                                      model: model, path: path, stream: stream,
                                      requestJSON: requestJSON, rewrittenJSON: rewrittenJSON,
                                      requestHeadersJSON: headersJSON,
                                      preview: preview)
        }
        let id = summary.id
        // Registered before the tap escapes, so an interrupt tap that lands
        // while the proxy is still connecting upstream is not lost.
        let inflight = ProxyInflight.shared.open(captureID: id)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.catalog.records.insert(summary, at: 0)
            if self.catalog.records.count > self.listLimit {
                self.catalog.records.removeLast(self.catalog.records.count - self.listLimit)
            }
            if stream { self.streams.live[id] = CaptureLive() }
        }
        return CaptureTap(id: id, kind: kind, source: source, modelName: model,
                          store: self, inflight: inflight)
    }

    func markStreaming(_ id: Int64) {
        update(id, fields: ["state": .text(CaptureState.streaming.rawValue)])
        patch(id) { $0.state = .streaming }
    }

    func markFirstToken(_ id: Int64) {
        let t = Date()
        update(id, fields: ["first_token_at": .text(iso(t))])
        patch(id) { $0.firstTokenAt = t }
    }

    func pushLive(_ id: Int64, assembler: CaptureAssembler) {
        lock.lock()
        pendingLive[id] = CaptureLive(content: assembler.content,
                                      reasoning: assembler.reasoning,
                                      tools: assembler.tools)
        lock.unlock()
        scheduleFlush()
    }

    func finish(_ id: Int64, source: CaptureSource, model: String,
                state: CaptureState, status: Int, error: String?,
                assembler: CaptureAssembler, rawSSE: String?) {
        let ended = Date()
        if useDatabase {
            update(id, fields: [
                "state": .text(state.rawValue),
                "http_status": .int(Int64(status)),
                "ended_at": .text(iso(ended)),
                "prompt_tokens": assembler.promptTokens.map { .int(Int64($0)) } ?? .null,
                "completion_tokens": assembler.completionTokens.map { .int(Int64($0)) } ?? .null,
                "cache_read_tokens": assembler.cacheReadTokens.map { .int(Int64($0)) } ?? .null,
                "error": error.map { .text($0) } ?? .null,
                "model": assembler.model.isEmpty ? .null : .text(assembler.model),
            ])
            exec("""
                UPDATE payloads SET response_json = ?, raw_sse = ? WHERE capture_id = ?
                """, args: [
                .text(Self.truncate(assembler.toResponseJSON(), cap: payloadCap)),
                .text(Self.truncate(rawSSE, cap: payloadCap)),
                .int(id),
            ])
        } else {
            lock.lock()
            jsonStore.patch(id) {
                $0.state = state
                $0.httpStatus = status
                $0.endedAt = ended
                $0.promptTokens = assembler.promptTokens
                $0.completionTokens = assembler.completionTokens
                $0.cacheReadTokens = assembler.cacheReadTokens
                $0.error = error
                if !assembler.model.isEmpty { $0.model = assembler.model }
            }
            jsonStore.mergePayload(id,
                response: Self.truncate(assembler.toResponseJSON(), cap: payloadCap),
                sse: Self.truncate(rawSSE, cap: payloadCap))
            lock.unlock()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let live = CaptureLive(content: assembler.content,
                                   reasoning: assembler.reasoning,
                                   tools: assembler.tools)
            self.streams.live[id] = live
            self.catalog.livePreview[id] = Self.clip(live.content.isEmpty ? live.reasoning : live.content)
            self.patchMain(id) {
                $0.state = state
                $0.httpStatus = status
                $0.endedAt = ended
                $0.promptTokens = assembler.promptTokens
                $0.completionTokens = assembler.completionTokens
                $0.cacheReadTokens = assembler.cacheReadTokens
                $0.error = error
                if !assembler.model.isEmpty { $0.model = assembler.model }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                // A row that was pruned out of the 120-entry window while the
                // call was in flight is gone from `records`, so `?? .streaming`
                // was needed here: `nil != .streaming` is true and the buffers
                // were dropped for a capture whose detail view is still open.
                guard let row = self.catalog.records.first(where: { $0.id == id }) else { return }
                if row.state != .streaming {
                    self.streams.live.removeValue(forKey: id)
                    self.catalog.livePreview.removeValue(forKey: id)
                }
            }
        }
        // Cap the two live maps. They are keyed by capture id and the row
        // window is 120, but a burst of `begin`s that never reach `finish`
        // (interrupted streams, a client that vanishes) would otherwise leave
        // entries with no owner: nothing else ever removes them.
        evictStaleLiveBuffers(keeping: id)
        // Durable third-party token rollup. Capture rows are capped at 120 and
        // carry no period breakdown, so the usage ring reads this instead.
        if source == .other {
            ProxyUsageStore.shared.record(
                model: assembler.model.isEmpty ? model : assembler.model,
                at: ended,
                input: assembler.promptTokens ?? 0,
                output: assembler.completionTokens ?? 0,
                cacheRead: assembler.cacheReadTokens ?? 0)
        }
    }

    func detail(id: Int64, includeRaw: Bool = false,
                includePayloads: Bool = true, includeTools: Bool = true) -> CaptureDetail? {
        lock.lock()
        defer { lock.unlock() }
        if !useDatabase {
            guard let summary = jsonStore.summary(id: id) else { return nil }
            let payload = jsonStore.readPayload(id)
            return makeDetail(id: id, summary: summary, request: payload.request,
                              rewritten: payload.rewritten, response: payload.response,
                              sse: includeRaw ? payload.sse : "",
                              requestHeadersJSON: payload.headers,
                              includePayloads: includePayloads, includeTools: includeTools)
        }
        guard let db = connection() else { return nil }
        let sql = includeRaw
            ? """
            SELECT c.id, c.started_at, c.ended_at, c.first_token_at, c.kind, c.source,
                   c.provider_name, c.model, c.path, c.is_stream, c.state, c.http_status,
                   c.prompt_tokens, c.completion_tokens, c.cache_read_tokens, c.error, c.preview,
                   p.request_json, p.rewritten_json, p.response_json, p.raw_sse,
                   COALESCE(p.request_headers, '')
            FROM captures c LEFT JOIN payloads p ON p.capture_id = c.id WHERE c.id = ?
            """
            : """
            SELECT c.id, c.started_at, c.ended_at, c.first_token_at, c.kind, c.source,
                   c.provider_name, c.model, c.path, c.is_stream, c.state, c.http_status,
                   c.prompt_tokens, c.completion_tokens, c.cache_read_tokens, c.error, c.preview,
                   p.request_json, p.rewritten_json, p.response_json, '',
                   COALESCE(p.request_headers, '')
            FROM captures c LEFT JOIN payloads p ON p.capture_id = c.id WHERE c.id = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW, let summary = rowToSummary(stmt) else { return nil }
        let request = text(stmt, 17)
        return makeDetail(id: id, summary: summary, request: request,
                          rewritten: text(stmt, 18), response: text(stmt, 19),
                          sse: includeRaw ? text(stmt, 20) : "",
                          requestHeadersJSON: text(stmt, 21),
                          includePayloads: includePayloads, includeTools: includeTools)
    }

    private func makeDetail(id: Int64, summary: CaptureSummary,
                            request: String, rewritten: String, response: String, sse: String,
                            requestHeadersJSON: String,
                            includePayloads: Bool, includeTools: Bool) -> CaptureDetail {
        let dir = CaptureMedia.mediaDir(captureID: id)
        var turns = CaptureTranscript.turns(from: request, mediaDir: dir)
        if !response.isEmpty {
            turns += CaptureTranscript.replyTurns(
                responseJSON: response, live: nil, streaming: false, mode: .conversation)
        }
        return CaptureDetail(
            summary: summary,
            requestJSON: includePayloads ? request : "",
            rewrittenJSON: includePayloads ? rewritten : "",
            responseJSON: includePayloads ? response : "",
            rawSSE: includePayloads ? sse : "",
            requestHeadersJSON: includePayloads ? requestHeadersJSON : "",
            turns: turns,
            toolCalls: includeTools ? CaptureTranscript.toolCalls(request: request, response: response) : [],
            requestTruncated: request.contains("[truncated]"),
            payloadsLoaded: includePayloads)
    }

    func delete(_ id: Int64) {
        if useDatabase {
            exec("DELETE FROM captures WHERE id = ?", args: [.int(id)])
        } else {
            lock.lock(); jsonStore.delete(id); lock.unlock()
        }
        DispatchQueue.main.async { [weak self] in
            self?.catalog.records.removeAll { $0.id == id }
            self?.catalog.livePreview.removeValue(forKey: id)
            self?.streams.live.removeValue(forKey: id)
        }
        try? FileManager.default.removeItem(at: CaptureMedia.mediaDir(captureID: id))
    }

    func clearAll() {
        if useDatabase {
            exec("DELETE FROM captures", args: [])
        } else {
            lock.lock(); jsonStore.clearAll(); lock.unlock()
        }
        DispatchQueue.main.async { [weak self] in
            self?.catalog.records = []
            self?.catalog.livePreview = [:]
            self?.streams.live = [:]
        }
    }

    // MARK: - SQLite

    private func connection() -> OpaquePointer? {
        guard useDatabase else { return nil }
        if let db { return db }
        if openFailed { return nil }
        guard sqlite3_open_v2(Self.dbURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            openFailed = true
            return nil
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-2000; PRAGMA foreign_keys=ON", nil, nil, nil)
        // The app is the only writer, but a backup agent or a `sqlite3` shell
        // holding a lock made every capture write fail instantly with
        // SQLITE_BUSY and vanish without a message. Match CursorDB's 2s.
        sqlite3_busy_timeout(db, 2000)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS captures (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                first_token_at TEXT,
                kind TEXT NOT NULL,
                source TEXT NOT NULL,
                provider_name TEXT,
                model TEXT,
                path TEXT NOT NULL,
                is_stream INTEGER NOT NULL DEFAULT 1,
                state TEXT NOT NULL DEFAULT 'pending',
                http_status INTEGER,
                prompt_tokens INTEGER,
                completion_tokens INTEGER,
                cache_read_tokens INTEGER,
                error TEXT,
                preview TEXT
            );
            CREATE TABLE IF NOT EXISTS payloads (
                capture_id INTEGER PRIMARY KEY,
                request_json TEXT,
                rewritten_json TEXT,
                response_json TEXT,
                raw_sse TEXT,
                FOREIGN KEY (capture_id) REFERENCES captures(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS captures_started ON captures(started_at DESC);
            """, nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE payloads ADD COLUMN request_headers TEXT DEFAULT ''", nil, nil, nil)
        return db
    }

    private func recoverOrphans() {
        exec("""
            UPDATE captures SET state = 'aborted', error = 'interrupted',
                ended_at = COALESCE(ended_at, started_at)
            WHERE state IN ('pending', 'streaming')
            """, args: [])
    }

    private func loadCurrentBackendLocked() -> [CaptureSummary] {
        if useDatabase {
            _ = connection()
            recoverOrphans()
            pruneLocked()
            return loadListUnlocked()
        }
        jsonStore.load()
        jsonStore.recoverOrphans()
        return jsonStore.summaries
    }

    private func closeDatabaseLocked() {
        guard let handle = db else { return }
        sqlite3_exec(handle, "PRAGMA wal_checkpoint(PASSIVE)", nil, nil, nil)
        sqlite3_close(handle)
        db = nil
        openFailed = false
    }

    private func publishList(_ rows: [CaptureSummary]) {
        if Thread.isMainThread {
            catalog.records = rows
        } else {
            DispatchQueue.main.async { [weak self] in self?.catalog.records = rows }
        }
    }

    private func beginSQL(kind: CaptureKind, source: CaptureSource, provider: String,
                          model: String, path: String, stream: Bool,
                          requestJSON: String?, rewrittenJSON: String?,
                          requestHeadersJSON: String,
                          preview: String) -> CaptureSummary? {
        guard let db = connection() else { return nil }
        let now = iso(Date())
        let sql = """
            INSERT INTO captures (started_at, kind, source, provider_name, model, path,
                is_stream, state, preview)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        bind(stmt, 1, now)
        bind(stmt, 2, kind.rawValue)
        bind(stmt, 3, source.rawValue)
        bind(stmt, 4, provider)
        bind(stmt, 5, model)
        bind(stmt, 6, path)
        sqlite3_bind_int(stmt, 7, stream ? 1 : 0)
        bind(stmt, 8, preview)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            return nil
        }
        sqlite3_finalize(stmt)
        let id = sqlite3_last_insert_rowid(db)
        let req = Self.truncate(CaptureMedia.compact(requestJSON, captureID: id), cap: payloadCap)
        let rew = Self.truncate(CaptureMedia.compact(rewrittenJSON, captureID: id), cap: payloadCap)
        exec("INSERT INTO payloads (capture_id, request_json, rewritten_json, request_headers) VALUES (?, ?, ?, ?)",
             args: [.int(id), .text(req), .text(rew), .text(requestHeadersJSON)])
        pruneLocked()
        return CaptureSummary(
            id: id, startedAt: Date(), endedAt: nil, firstTokenAt: nil,
            kind: kind, source: source, providerName: provider, model: model,
            path: path, isStream: stream, state: .pending, httpStatus: 0,
            promptTokens: nil, completionTokens: nil, cacheReadTokens: nil,
            error: nil, preview: preview)
    }

    private func loadListUnlocked() -> [CaptureSummary] {
        guard let db = connection() else { return [] }
        var stmt: OpaquePointer?
        let sql = """
            SELECT id, started_at, ended_at, first_token_at, kind, source, provider_name, model, path,
                   is_stream, state, http_status, prompt_tokens, completion_tokens, cache_read_tokens,
                   error, preview
            FROM captures ORDER BY id DESC LIMIT \(listLimit)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [CaptureSummary] = []
        rows.reserveCapacity(64)
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = rowToSummary(stmt) { rows.append(s) }
        }
        return rows
    }

    private func pruneLocked() {
        // Payloads are deleted explicitly rather than by the `ON DELETE
        // CASCADE` on the table. `PRAGMA foreign_keys` is per-connection and
        // is not guaranteed to be on for every handle that reaches this store
        // (verified: with the pragma off the capture row disappears and its
        // multi-hundred-KB payload row stays forever, in a table the UI no
        // longer shows). Doing it here makes the invariant independent of a
        // connection-level setting, and the DELETE is cheap because
        // `capture_id` is the payloads primary key.
        exec("""
            DELETE FROM payloads WHERE capture_id NOT IN (
                SELECT id FROM captures ORDER BY id DESC LIMIT \(listLimit)
            )
            """, args: [])
        exec("""
            DELETE FROM captures WHERE id NOT IN (
                SELECT id FROM captures ORDER BY id DESC LIMIT \(listLimit)
            )
            """, args: [])
        // The media directories (base64-decoded screenshots, a few hundred KB
        // each) are keyed by capture id and are only removed by `delete(_:)`.
        // The JSON backend removes them in its own prune; this one used to
        // leave every one of them on disk forever. Daemon turns spend most of
        // their time under a retention window this kills.
        if Date().timeIntervalSince(lastMediaSweep) > 300 {
            lastMediaSweep = Date()
            sweepOrphanMedia()
        }
        // `pruneLocked` frees pages but nothing ever returns them to the
        // filesystem: `proxy-capture.db` measured 84 MB with 20,581 pages on
        // the freelist and two live rows. auto_vacuum cannot be enabled on an
        // existing database, so reclaim opportunistically — VACUUM is a
        // full-file rewrite, so only run it when a real amount is reclaimable.
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA freelist_count", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 0) > Self.vacuumThresholdPages {
                sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                execRaw("VACUUM")
            }
        }
        if let db { sqlite3_exec(db, "PRAGMA wal_checkpoint(PASSIVE)", nil, nil, nil) }
    }

    /// Pages that must be reclaimable before a `VACUUM` full-file rewrite is
    /// worth its cost (4096-byte pages → ~32 MB).
    private static let vacuumThresholdPages: Int64 = 8_192

    private var lastMediaSweep = Date.distantPast

    /// Remove `logs/captures/<id>/` for ids that no longer have a capture row.
    ///
    /// A capture that *streams its media* (the ids in `capturePayloadsDir` are
    /// created by `CaptureMedia` while the request is being written) hits this
    /// store as `begin` → media dir created → row pruned by a later `begin`.
    /// Directories are capped by age as well, so a crash between the two
    /// cannot leave an unreferenced tree behind indefinitely.
    private func sweepOrphanMedia() {
        let fm = FileManager.default
        let root = FilePaths.capturePayloadsDir
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        let live = Set(currentLiveIDs())
        let cutoff = Date().addingTimeInterval(-86_400)
        for dir in entries where dir.hasDirectoryPath {
            let name = dir.lastPathComponent
            let id = Int64(name) ?? -1
            var keep = live.contains(id)
            if !keep,
               let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime > cutoff {
                // Recently written but not (yet) in the list — a capture that
                // started between the query and the sweep. Keep it.
                keep = true
            }
            if !keep { try? fm.removeItem(at: dir) }
        }
    }

    private func currentLiveIDs() -> [Int64] {
        if useDatabase, let db, let rows = loadListIDs(db) { return rows }
        return jsonStore.summaries.map(\.id)
    }

    private func loadListIDs(_ db: OpaquePointer) -> [Int64]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM captures", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        return ids
    }

    private func execRaw(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private enum Bind {
        case text(String), int(Int64), null
    }

    private func update(_ id: Int64, fields: [String: Bind]) {
        if !useDatabase {
            lock.lock()
            jsonStore.patch(id) { row in
                for (k, v) in fields {
                    switch (k, v) {
                    case ("state", .text(let s)):
                        if let st = CaptureState(rawValue: s) { row.state = st }
                    case ("first_token_at", .text(let s)):
                        row.firstTokenAt = parseISO(s)
                    case ("ended_at", .text(let s)):
                        row.endedAt = parseISO(s)
                    case ("http_status", .int(let n)):
                        row.httpStatus = Int(n)
                    case ("prompt_tokens", .int(let n)):
                        row.promptTokens = Int(n)
                    case ("prompt_tokens", .null):
                        row.promptTokens = nil
                    case ("completion_tokens", .int(let n)):
                        row.completionTokens = Int(n)
                    case ("completion_tokens", .null):
                        row.completionTokens = nil
                    case ("cache_read_tokens", .int(let n)):
                        row.cacheReadTokens = Int(n)
                    case ("cache_read_tokens", .null):
                        row.cacheReadTokens = nil
                    case ("error", .text(let s)):
                        row.error = s
                    case ("error", .null):
                        row.error = nil
                    case ("model", .text(let s)):
                        row.model = s
                    default:
                        break
                    }
                }
            }
            lock.unlock()
            return
        }
        var sets: [String] = []
        var args: [Bind] = []
        for (k, v) in fields {
            sets.append("\(k) = ?")
            args.append(v)
        }
        args.append(.int(id))
        exec("UPDATE captures SET \(sets.joined(separator: ", ")) WHERE id = ?", args: args)
    }

    private func exec(_ sql: String, args: [Bind]) {
        lock.lock(); defer { lock.unlock() }
        guard useDatabase, let db = connection() else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            switch arg {
            case .text(let s): bind(stmt, Int32(i + 1), s)
            case .int(let n): sqlite3_bind_int64(stmt, Int32(i + 1), n)
            case .null: sqlite3_bind_null(stmt, Int32(i + 1))
            }
        }
        sqlite3_step(stmt)
    }

    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ text: String) {
        sqlite3_bind_text(stmt, idx, text, -1, SQLITE_TRANSIENT)
    }

    private func rowToSummary(_ stmt: OpaquePointer?) -> CaptureSummary? {
        guard let stmt else { return nil }
        guard let kind = CaptureKind(rawValue: text(stmt, 4)),
              let state = CaptureState(rawValue: text(stmt, 10)) else { return nil }
        let source = CaptureSource(rawValue: text(stmt, 5)) ?? .other
        let err = text(stmt, 15)
        return CaptureSummary(
            id: sqlite3_column_int64(stmt, 0),
            startedAt: parseISO(text(stmt, 1)) ?? Date(),
            endedAt: parseISO(text(stmt, 2)),
            firstTokenAt: parseISO(text(stmt, 3)),
            kind: kind, source: source,
            providerName: text(stmt, 6),
            model: text(stmt, 7),
            path: text(stmt, 8),
            isStream: sqlite3_column_int(stmt, 9) != 0,
            state: state,
            httpStatus: Int(sqlite3_column_int(stmt, 11)),
            promptTokens: optInt(stmt, 12),
            completionTokens: optInt(stmt, 13),
            cacheReadTokens: optInt(stmt, 14),
            error: err.isEmpty ? nil : err,
            preview: text(stmt, 16))
    }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: ptr)
    }

    private func optInt(_ stmt: OpaquePointer?, _ i: Int32) -> Int? {
        if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int(stmt, i))
    }

    private func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private func parseISO(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        return isoFormatter.date(from: s)
    }

    private func scheduleFlush() {
        lock.lock()
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushLive() }
        flushWork = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func flushLive() {
        lock.lock()
        let snapshot = pendingLive
        pendingLive = [:]
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (id, buf) in snapshot {
                self.streams.live[id] = buf
                self.catalog.livePreview[id] = Self.clip(buf.content.isEmpty ? buf.reasoning : buf.content)
            }
        }
    }

    private func patch(_ id: Int64, _ mutate: @escaping (inout CaptureSummary) -> Void) {
        DispatchQueue.main.async { [weak self] in self?.patchMain(id, mutate) }
    }

    /// Keep `streams.live` / `catalog.livePreview` bounded to the ids the list
    /// still shows, plus the one that just finished.
    ///
    /// Both maps are only otherwise removed by `delete`, `clearAll`,
    /// `reloadPersistence`, and the delayed check in `finish` — so a capture
    /// that is pruned (or never finishes) leaves a `CaptureLive` buffer behind
    /// for the life of the process.
    private func evictStaleLiveBuffers(keeping id: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let live = Set(self.catalog.records.map(\.id)).union([id])
            self.streams.live = self.streams.live.filter { live.contains($0.key) }
            self.catalog.livePreview = self.catalog.livePreview.filter { live.contains($0.key) }
        }
    }

    private func patchMain(_ id: Int64, _ mutate: (inout CaptureSummary) -> Void) {
        guard let idx = catalog.records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&catalog.records[idx])
    }

    static func truncate(_ text: String?, cap: Int) -> String {
        guard let text, !text.isEmpty else { return "" }
        if text.utf8.count <= cap { return text }
        return String(decoding: Data(text.utf8.prefix(cap)), as: UTF8.self) + "\n… [truncated]"
    }

    /// Last real user utterance, not Claude Code / Codex scaffolding.
    static func preview(from requestJSON: String?) -> String {
        CaptureTranscript.preview(from: requestJSON)
    }

    /// Headers for the capture inspector, with credentials removed.
    ///
    /// This ran through the whole inbound header map, so a third-party client
    /// that authenticated *to the proxy* had its own credential — and anything
    /// else it sent, cookies included — serialized into `payloads.request_
    /// request_headers`. The proxy no longer forwards client credentials
    /// upstream, and the inspector has no use for them, so they never reach
    /// disk. The proxy's own token is redacted too: it is the credential the
    /// app hands out in the curl example.
    private static let redactedHeaderKeys: Set<String> = [
        "authorization", "x-api-key", "proxy-authorization", "cookie", "set-cookie",
    ]

    static func encodeHeaders(_ headers: [String: String]?) -> String {
        guard let headers, !headers.isEmpty else { return "" }
        var obj: [String: String] = [:]
        for (k, v) in headers {
            obj[k] = redactedHeaderKeys.contains(k.lowercased()) ? "…" : v
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func clip(_ s: String) -> String {
        CaptureTranscript.clip(s, cap: 120)
    }
}

/// Held by the proxy for the lifetime of one upstream call.
final class CaptureTap {
    let id: Int64
    let kind: CaptureKind
    /// Origin of the request — the durable third-party rollup is written from
    /// here, where the value is known without a lookup.
    let source: CaptureSource
    /// Model name from the request body (the upstream may report a different
    /// one, which the assembler prefers when it has it).
    let modelName: String
    private weak var store: ProxyCaptureStore?
    /// Lifetime token for the interrupt button; retired in `finish`.
    private let inflight: ProxyInflight.Handle?
    var assembler = CaptureAssembler()
    private var raw: [Data] = []
    private var rawBytes = 0
    private let rawCap = 16 * 1024 * 1024
    private var firstToken = false
    private var startedStreaming = false

    init(id: Int64, kind: CaptureKind, source: CaptureSource, modelName: String,
         store: ProxyCaptureStore, inflight: ProxyInflight.Handle? = nil) {
        self.id = id
        self.kind = kind
        self.source = source
        self.modelName = modelName
        self.store = store
        self.inflight = inflight
    }

    /// Hand the proxy the client-side teardown: close the loopback connection
    /// with no terminal frame, so Claude Code / Codex see the turn cut instead
    /// of a finished response.
    func attachClientAbort(_ abort: @escaping () -> Void) {
        inflight?.attachAbort(abort)
    }

    /// Hand the proxy the upstream-side teardown, once the request exists.
    func attachUpstreamAbort(_ cancel: @escaping () -> Void) {
        inflight?.attachUpstream(cancel)
    }

    /// True when the user has already interrupted this call — the proxy checks
    /// before opening an upstream request that would be thrown away.
    var isInterrupted: Bool { inflight?.isCancelled ?? false }

    func noteStreaming() {
        guard !startedStreaming else { return }
        startedStreaming = true
        store?.markStreaming(id)
    }

    func applyChat(_ json: [String: Any]) {
        noteStreaming()
        let before = assembler.content.count + assembler.reasoning.count
        assembler.applyChat(json)
        tokenIfNeeded(before: before)
        store?.pushLive(id, assembler: assembler)
    }

    func applyResponses(_ json: [String: Any]) {
        noteStreaming()
        let before = assembler.content.count + assembler.reasoning.count
        assembler.applyResponses(json)
        tokenIfNeeded(before: before)
        store?.pushLive(id, assembler: assembler)
    }

    func applyAnthropic(event: String, json: [String: Any]) {
        noteStreaming()
        let before = assembler.content.count + assembler.reasoning.count
        assembler.applyAnthropic(event: event, json: json)
        tokenIfNeeded(before: before)
        store?.pushLive(id, assembler: assembler)
    }

    func appendRaw(_ data: Data) {
        guard rawBytes < rawCap else { return }
        let room = rawCap - rawBytes
        let slice = data.prefix(room)
        raw.append(Data(slice))
        rawBytes += slice.count
    }

    func finish(state: CaptureState, status: Int, error: String?) {
        // The call is over (finished or torn down); retire the interrupt handle
        // so a stale tap cannot reach a dead connection.
        if let inflight { ProxyInflight.shared.close(inflight) }
        // Lossy: this is upstream SSE bytes, which the gateway may split
        // mid-codepoint. A strict decode dropped the entire raw body.
        let sse = raw.isEmpty ? nil : String(decoding: raw.reduce(into: Data(), { $0.append($1) }), as: UTF8.self)
        store?.finish(id, source: source, model: modelName,
                      state: state, status: status, error: error,
                      assembler: assembler, rawSSE: sse)
    }

    func ingestAnthropicMessage(_ json: [String: Any]) {
        applyAnthropic(event: "message_start", json: ["type": "message_start", "message": json])
        for block in json["content"] as? [[String: Any]] ?? [] {
            switch (block["type"] as? String) ?? "" {
            case "text":
                if let t = block["text"] as? String { assembler.content += t }
            case "thinking", "reasoning":
                if let t = (block["thinking"] as? String) ?? (block["text"] as? String) {
                    assembler.reasoning += t
                }
            case "tool_use":
                let args: String
                if let input = block["input"],
                   let data = try? JSONSerialization.data(withJSONObject: input),
                   let s = String(data: data, encoding: .utf8) {
                    args = s
                } else {
                    args = ""
                }
                assembler.tools.append(.init(
                    id: (block["id"] as? String) ?? "",
                    name: (block["name"] as? String) ?? "",
                    arguments: args))
            default:
                break
            }
        }
    }

    private func tokenIfNeeded(before: Int) {
        let after = assembler.content.count + assembler.reasoning.count
        if !firstToken, after > before {
            firstToken = true
            store?.markFirstToken(id)
        }
    }
}
