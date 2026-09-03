import Foundation

/// Shared switch: SQLite vs JSON/JSONL logs. Read from UserDefaults so
/// background index/capture threads never touch `AppPreferences.shared`.
enum DiskPersistence {
    static var useDatabase: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: "databaseEnabled") == nil { return true }
        return d.bool(forKey: "databaseEnabled")
    }
}

/// File-backed usage rollup used when SQLite is turned off.
final class UsageJSONStore {
    struct FileRec: Codable {
        var mtime: Double
        var size: Int
        var offset: Int
        var headHash: Int64
        var cxIn: Int
        var cxOut: Int
        var cxCached: Int
        var cxModel: String

        init(mtime: Double, size: Int, offset: Int, headHash: Int64,
             cxIn: Int, cxOut: Int, cxCached: Int, cxModel: String = "") {
            self.mtime = mtime; self.size = size; self.offset = offset
            self.headHash = headHash; self.cxIn = cxIn; self.cxOut = cxOut
            self.cxCached = cxCached; self.cxModel = cxModel
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mtime = try c.decode(Double.self, forKey: .mtime)
            size = try c.decode(Int.self, forKey: .size)
            offset = try c.decode(Int.self, forKey: .offset)
            headHash = try c.decode(Int64.self, forKey: .headHash)
            cxIn = try c.decode(Int.self, forKey: .cxIn)
            cxOut = try c.decode(Int.self, forKey: .cxOut)
            cxCached = try c.decode(Int.self, forKey: .cxCached)
            cxModel = try c.decodeIfPresent(String.self, forKey: .cxModel) ?? ""
        }

        private enum CodingKeys: String, CodingKey {
            case mtime, size, offset, headHash, cxIn, cxOut, cxCached, cxModel
        }
    }

    struct RollupRec: Codable {
        var path: String
        var day: String
        var model: String
        var calls: Int
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheCreate: Int
    }

    struct CursorRec: Codable {
        var input: Int
        var output: Int
        var calls: Int
        var dbVersion: Int32
        var pageCount: Int64
    }

    static let shared = UsageJSONStore()

    private let lock = NSLock()
    private var files: [String: FileRec] = [:]
    private var rollup: [String: RollupRec] = [:]
    private var cursor: CursorRec?
    private var loaded = false

    func load() {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
    }

    func hasRows() -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return !rollup.isEmpty
    }

    func currentFiles() -> [String: FileRec] {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return files
    }

    func upsertFile(key: String, rec: FileRec) {
        lock.lock(); files[key] = rec; lock.unlock()
    }

    func deletePath(_ path: String) {
        lock.lock()
        files.removeValue(forKey: path)
        rollup = rollup.filter { $0.value.path != path }
        lock.unlock()
    }

    func replaceRollup(path: String, rows: [RollupRec]) {
        lock.lock()
        rollup = rollup.filter { $0.value.path != path }
        for row in rows { rollup[Self.key(row)] = row }
        lock.unlock()
    }

    func addRollup(path: String, rows: [RollupRec]) {
        lock.lock()
        for row in rows {
            let k = Self.key(row)
            if var cur = rollup[k] {
                cur.calls += row.calls
                cur.input += row.input
                cur.output += row.output
                cur.cacheRead += row.cacheRead
                cur.cacheCreate += row.cacheCreate
                rollup[k] = cur
            } else {
                rollup[k] = row
            }
        }
        lock.unlock()
    }

    func save() {
        lock.lock(); defer { lock.unlock() }
        persistLocked()
    }

    func fetch(startDay: String, endDay: String) -> [ModelUsage] {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        var byModel: [String: ModelUsage] = [:]
        for row in rollup.values where row.day >= startDay && row.day <= endDay && !row.path.hasPrefix("openclaw") {
            var u = byModel[row.model] ?? ModelUsage(model: row.model)
            u.calls += row.calls
            u.inputTokens += row.input
            u.outputTokens += row.output
            u.cacheReadTokens += row.cacheRead
            u.cacheCreationTokens += row.cacheCreate
            byModel[row.model] = u
        }
        return byModel.values.filter { $0.totalTokens > 0 }.sorted { $0.totalTokens > $1.totalTokens }
    }

    func fetchDaily(startDay: String, endDay: String) -> [DayUsage] {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        var byDay: [String: DayUsage] = [:]
        for row in rollup.values where row.day >= startDay && row.day <= endDay && !row.path.hasPrefix("openclaw") {
            var d = byDay[row.day] ?? DayUsage(day: row.day)
            d.inputTokens += row.input
            d.outputTokens += row.output
            d.cacheReadTokens += row.cacheRead
            d.cacheCreationTokens += row.cacheCreate
            byDay[row.day] = d
        }
        return byDay.values.filter { $0.totalTokens > 0 }.sorted { $0.day < $1.day }
    }

    func loadCursor() -> CursorRec? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return cursor
    }

    func saveCursor(_ rec: CursorRec) {
        lock.lock()
        cursor = rec
        persistCursorLocked()
        lock.unlock()
    }

    func reset() {
        lock.lock()
        files = [:]
        rollup = [:]
        cursor = nil
        loaded = false
        lock.unlock()
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: FilePaths.usageFilesJSON),
           let obj = try? JSONDecoder().decode([String: FileRec].self, from: data) {
            files = obj
        }
        if let data = try? Data(contentsOf: FilePaths.usageRollupJSONL),
           let text = String(data: data, encoding: .utf8) {
            let dec = JSONDecoder()
            for line in text.split(whereSeparator: \.isNewline) {
                guard let row = try? dec.decode(RollupRec.self, from: Data(line.utf8)) else { continue }
                rollup[Self.key(row)] = row
            }
        }
        if let data = try? Data(contentsOf: FilePaths.usageCursorJSON),
           let rec = try? JSONDecoder().decode(CursorRec.self, from: data) {
            cursor = rec
        }
        // Pre-cx_model rollups stamped every Codex turn as "codex". Drop the
        // Codex file rows so the next updateIndex re-parses the real slugs.
        let stale = rollup.values.contains { $0.path.hasPrefix("codex:") && $0.model.lowercased() == "codex" }
        if stale {
            files = files.filter { !$0.key.hasPrefix("codex:") }
            rollup = rollup.filter { !$0.value.path.hasPrefix("codex:") }
            persistLocked()
        }
    }

    private func persistLocked() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(files) {
            try? data.write(to: FilePaths.usageFilesJSON, options: .atomic)
        }
        var body = ""
        for row in rollup.values.sorted(by: { $0.day == $1.day ? $0.path < $1.path : $0.day < $1.day }) {
            if let data = try? enc.encode(row), let line = String(data: data, encoding: .utf8) {
                body += line + "\n"
            }
        }
        try? Data(body.utf8).write(to: FilePaths.usageRollupJSONL, options: .atomic)
        persistCursorLocked()
    }

    private func persistCursorLocked() {
        guard let cursor else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cursor) {
            try? data.write(to: FilePaths.usageCursorJSON, options: .atomic)
        }
    }

    private static func key(_ row: RollupRec) -> String {
        row.path + "\u{1F}" + row.day + "\u{1F}" + row.model
    }
}
