import Foundation

/// File-backed capture log used when SQLite is turned off.
/// Summaries live in `logs/captures.jsonl`; payloads in `logs/captures/<id>.json`.
final class CaptureJSONStore {
    struct Payload: Codable {
        var request: String
        var rewritten: String
        var response: String
        var sse: String
    }

    private struct IndexRow: Codable {
        var id: Int64
        var startedAt: String
        var endedAt: String?
        var firstTokenAt: String?
        var kind: String
        var source: String
        var providerName: String
        var model: String
        var path: String
        var isStream: Bool
        var state: String
        var httpStatus: Int
        var promptTokens: Int?
        var completionTokens: Int?
        var cacheReadTokens: Int?
        var error: String?
        var preview: String
    }

    private(set) var summaries: [CaptureSummary] = []
    private var nextId: Int64 = 1
    private let listLimit: Int
    private let iso: ISO8601DateFormatter

    init(listLimit: Int, iso: ISO8601DateFormatter) {
        self.listLimit = listLimit
        self.iso = iso
    }

    func load() {
        summaries = []
        nextId = 1
        if let data = try? Data(contentsOf: FilePaths.captureIndexFile),
           let text = String(data: data, encoding: .utf8) {
            let dec = JSONDecoder()
            for line in text.split(whereSeparator: \.isNewline) {
                guard let row = try? dec.decode(IndexRow.self, from: Data(line.utf8)),
                      let summary = summary(from: row) else { continue }
                summaries.append(summary)
            }
        }
        summaries.sort { $0.id > $1.id }
        if summaries.count > listLimit {
            let drop = Array(summaries.dropFirst(listLimit))
            summaries = Array(summaries.prefix(listLimit))
            for s in drop { deletePayload(s.id) }
            persistIndex()
        }
        if let raw = try? String(contentsOf: FilePaths.captureSeqFile, encoding: .utf8),
           let n = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
            nextId = n
        }
        if let maxId = summaries.map(\.id).max() {
            nextId = max(nextId, maxId + 1)
        }
    }

    func recoverOrphans() {
        var dirty = false
        for i in summaries.indices where summaries[i].state == .pending || summaries[i].state == .streaming {
            summaries[i].state = .aborted
            summaries[i].error = summaries[i].error ?? "interrupted"
            summaries[i].endedAt = summaries[i].endedAt ?? summaries[i].startedAt
            dirty = true
        }
        if dirty { persistIndex() }
    }

    func begin(kind: CaptureKind, source: CaptureSource, provider: String,
               model: String, path: String, stream: Bool,
               requestJSON: String?, rewrittenJSON: String?,
               preview: String) -> CaptureSummary {
        let id = nextId
        nextId += 1
        persistSeq()
        let summary = CaptureSummary(
            id: id, startedAt: Date(), endedAt: nil, firstTokenAt: nil,
            kind: kind, source: source, providerName: provider, model: model,
            path: path, isStream: stream, state: .pending, httpStatus: 0,
            promptTokens: nil, completionTokens: nil, cacheReadTokens: nil,
            error: nil, preview: preview)
        summaries.insert(summary, at: 0)
        let req = CaptureMedia.compact(requestJSON, captureID: id)
        let rew = CaptureMedia.compact(rewrittenJSON, captureID: id)
        writePayload(id, Payload(request: req, rewritten: rew,
                                 response: "", sse: ""))
        prune()
        persistIndex()
        return summary
    }

    func patch(_ id: Int64, _ mutate: (inout CaptureSummary) -> Void) {
        guard let i = summaries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&summaries[i])
        persistIndex()
    }

    func writePayload(_ id: Int64, _ payload: Payload) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(payload) else { return }
        try? data.write(to: payloadURL(id), options: .atomic)
    }

    func mergePayload(_ id: Int64, response: String? = nil, sse: String? = nil,
                      request: String? = nil, rewritten: String? = nil) {
        var p = readPayload(id)
        if let request { p.request = request }
        if let rewritten { p.rewritten = rewritten }
        if let response { p.response = response }
        if let sse { p.sse = sse }
        writePayload(id, p)
    }

    func readPayload(_ id: Int64) -> Payload {
        guard let data = try? Data(contentsOf: payloadURL(id)),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Payload(request: "", rewritten: "", response: "", sse: "")
        }
        return p
    }

    func summary(id: Int64) -> CaptureSummary? {
        summaries.first { $0.id == id }
    }

    func delete(_ id: Int64) {
        summaries.removeAll { $0.id == id }
        deletePayload(id)
        persistIndex()
    }

    func clearAll() {
        let ids = summaries.map(\.id)
        summaries = []
        for id in ids { deletePayload(id) }
        persistIndex()
    }

    private func prune() {
        guard summaries.count > listLimit else { return }
        let drop = Array(summaries.dropFirst(listLimit))
        summaries = Array(summaries.prefix(listLimit))
        for s in drop { deletePayload(s.id) }
    }

    private func persistIndex() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var body = ""
        for s in summaries {
            let row = IndexRow(
                id: s.id,
                startedAt: iso.string(from: s.startedAt),
                endedAt: s.endedAt.map { iso.string(from: $0) },
                firstTokenAt: s.firstTokenAt.map { iso.string(from: $0) },
                kind: s.kind.rawValue,
                source: s.source.rawValue,
                providerName: s.providerName,
                model: s.model,
                path: s.path,
                isStream: s.isStream,
                state: s.state.rawValue,
                httpStatus: s.httpStatus,
                promptTokens: s.promptTokens,
                completionTokens: s.completionTokens,
                cacheReadTokens: s.cacheReadTokens,
                error: s.error,
                preview: s.preview)
            if let data = try? enc.encode(row), let line = String(data: data, encoding: .utf8) {
                body += line + "\n"
            }
        }
        try? Data(body.utf8).write(to: FilePaths.captureIndexFile, options: .atomic)
    }

    private func persistSeq() {
        try? String(nextId).data(using: .utf8)?.write(to: FilePaths.captureSeqFile, options: .atomic)
    }

    private func payloadURL(_ id: Int64) -> URL {
        FilePaths.capturePayloadsDir.appendingPathComponent("\(id).json")
    }

    private func deletePayload(_ id: Int64) {
        try? FileManager.default.removeItem(at: payloadURL(id))
        try? FileManager.default.removeItem(at: CaptureMedia.mediaDir(captureID: id))
    }

    private func summary(from row: IndexRow) -> CaptureSummary? {
        guard let kind = CaptureKind(rawValue: row.kind),
              let state = CaptureState(rawValue: row.state) else { return nil }
        let source = CaptureSource(rawValue: row.source) ?? .other
        return CaptureSummary(
            id: row.id,
            startedAt: iso.date(from: row.startedAt) ?? Date(),
            endedAt: row.endedAt.flatMap { iso.date(from: $0) },
            firstTokenAt: row.firstTokenAt.flatMap { iso.date(from: $0) },
            kind: kind, source: source,
            providerName: row.providerName,
            model: row.model,
            path: row.path,
            isStream: row.isStream,
            state: state,
            httpStatus: row.httpStatus,
            promptTokens: row.promptTokens,
            completionTokens: row.completionTokens,
            cacheReadTokens: row.cacheReadTokens,
            error: row.error,
            preview: row.preview)
    }
}
