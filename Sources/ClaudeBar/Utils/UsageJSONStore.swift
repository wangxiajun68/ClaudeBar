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
        /// Last cumulative `total_token_usage.total_tokens` for a Codex file —
        /// the dedupe key for re-emitted `token_count` records across an
        /// append boundary. Mirrors the SQLite `cx_total` column.
        var cxTotal: Int
        var cxModel: String
        /// Parser generation of the rows this record produced. 10 introduced
        /// per-turn Codex deltas; 11 claims each Claude `message.id` once for
        /// the whole corpus (`UsageClaims`). A rec stamped below the current
        /// generation is dropped by `loadLocked`, so the next pass re-parses
        /// it under the current rules.
        var parserVersion: Int = 11

        init(mtime: Double, size: Int, offset: Int, headHash: Int64,
             cxIn: Int, cxOut: Int, cxCached: Int, cxTotal: Int = 0, cxModel: String = "") {
            self.mtime = mtime; self.size = size; self.offset = offset
            self.headHash = headHash; self.cxIn = cxIn; self.cxOut = cxOut
            self.cxCached = cxCached; self.cxTotal = cxTotal; self.cxModel = cxModel
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
            cxTotal = try c.decodeIfPresent(Int.self, forKey: .cxTotal) ?? 0
            cxModel = try c.decodeIfPresent(String.self, forKey: .cxModel) ?? ""
            parserVersion = try c.decodeIfPresent(Int.self, forKey: .parserVersion) ?? 0
        }

        private enum CodingKeys: String, CodingKey {
            case mtime, size, offset, headHash, cxIn, cxOut, cxCached, cxTotal, cxModel, parserVersion
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

    static let shared = UsageJSONStore()

    private let lock = NSLock()
    private var files: [String: FileRec] = [:]
    private var rollup: [String: RollupRec] = [:]
    /// A transcript rewrite removes only that transcript's rows, even when
    /// the corpus holds years of other sessions. Kept under the same lock.
    private var rollupKeysByPath: [String: Set<String>] = [:]
    private var rollupKeysByDay: [String: Set<String>] = [:]
    /// Sorted only when date membership changes, not after every token append.
    private var sortedRollupDays: [String]?
    private var loaded = false
    /// Set by every mutation, cleared once `persistLocked` has written the
    /// files. Index passes fire on FSEvents bursts where every transcript was
    /// skipped as unchanged, and the caller still saves at the end of each
    /// one; without this, those bursts re-encoded and rewrote the whole
    /// rollup for nothing.
    private var dirty = false

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
        lock.lock(); files[key] = rec; dirty = true; lock.unlock()
    }

    func deletePath(_ path: String) {
        lock.lock()
        files.removeValue(forKey: path)
        removeRollupLocked(path)
        dirty = true
        lock.unlock()
    }

    func replaceRollup(path: String, rows: [RollupRec]) {
        lock.lock()
        removeRollupLocked(path)
        for row in rows { insertRollupLocked(row) }
        dirty = true
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
                insertRollupLocked(row)
            }
        }
        dirty = true
        lock.unlock()
    }

    func save() {
        lock.lock(); defer { lock.unlock() }
        persistLocked()
    }

    func fetch(startDay: String, endDay: String, pathPrefix: String? = nil) -> [ModelUsage] {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        var byModel: [String: ModelUsage] = [:]
        forEachRollupLocked(startDay: startDay, endDay: endDay) { row in
            guard !row.path.hasPrefix("openclaw"),
                  pathPrefix.map({ row.path.hasPrefix($0) }) ?? true else { return }
            Self.accumulate(row, into: &byModel)
        }
        return byModel.values.filter { $0.totalTokens > 0 }.sorted { $0.totalTokens > $1.totalTokens }
    }

    /// Period rows retaining transcript identity for provider attribution.
    func fetchByPath(startDay: String, endDay: String, pathPrefix: String) -> [String: [ModelUsage]] {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        var grouped: [String: [String: ModelUsage]] = [:]
        forEachRollupLocked(startDay: startDay, endDay: endDay) { row in
            guard row.path.hasPrefix(pathPrefix) else { return }
            Self.accumulate(row, into: &grouped[row.path, default: [:]])
        }
        return grouped.mapValues { Array($0.values) }
    }

    /// All-time usage belonging to one transcript, identified by its file
    /// suffix. Claude and Codex use different filename forms.
    func fetchSession(pathPrefix: String, pathSuffix: String) -> [ModelUsage] {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        var byModel: [String: ModelUsage] = [:]
        for (path, keys) in rollupKeysByPath where path.hasPrefix(pathPrefix) && path.hasSuffix(pathSuffix) {
            for key in keys {
                if let row = rollup[key] { Self.accumulate(row, into: &byModel) }
            }
        }
        return byModel.values.filter { $0.totalTokens > 0 }.sorted { $0.totalTokens > $1.totalTokens }
    }

    func fetchDailyModels(startDay: String, endDay: String) -> [String: [ModelUsage]] {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        var days: [String: [ModelUsage]] = [:]
        forEachRollupLocked(startDay: startDay, endDay: endDay) { row in
            guard row.path.hasPrefix("claude:") || row.path.hasPrefix("codex:") else { return }
            days[row.day, default: []].append(ModelUsage(model: row.model, calls: row.calls,
                inputTokens: row.input, outputTokens: row.output,
                cacheReadTokens: row.cacheRead, cacheCreationTokens: row.cacheCreate))
        }
        return days.mapValues { ModelUsage.merged($0) }
    }

    func fetchDaily(startDay: String, endDay: String, pathPrefix: String? = nil) -> [DayUsage] {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        var byDay: [String: DayUsage] = [:]
        forEachRollupLocked(startDay: startDay, endDay: endDay) { row in
            guard !row.path.hasPrefix("openclaw"),
                  pathPrefix.map({ row.path.hasPrefix($0) }) ?? true else { return }
            Self.accumulate(row, into: &byDay)
        }
        return byDay.values.filter { $0.totalTokens > 0 }.sorted { $0.day < $1.day }
    }

    func reset() {
        lock.lock()
        files = [:]
        rollup = [:]
        rollupKeysByPath = [:]
        rollupKeysByDay = [:]
        sortedRollupDays = nil
        loaded = false
        dirty = false
        lock.unlock()
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: FilePaths.usageFilesJSON),
           let obj = try? JSONDecoder().decode([String: FileRec].self, from: data) {
            files = obj
        }
        // Lossy decode: the writer rewrites this file atomically in full, so a
        // half-written line is on-disk damage (corruption or a hand-edit), not
        // a torn append. Skipping the bad line keeps the rest of the rollup
        // readable — strict decoding threw away every other line with it.
        if let data = try? Data(contentsOf: FilePaths.usageRollupJSONL) {
            let text = String(decoding: data, as: UTF8.self)
            let dec = JSONDecoder()
            for line in text.split(whereSeparator: \.isNewline) {
                guard let row = try? dec.decode(RollupRec.self, from: Data(line.utf8)) else { continue }
                rollup[Self.key(row)] = row
            }
        }
        // Pre-cx_model rollups stamped every Codex turn as "codex". Drop the
        // Codex file rows so the next updateIndex re-parses the real slugs.
        let stale = rollup.values.contains { $0.path.hasPrefix("codex:") && $0.model.lowercased() == "codex" }
        // Pre-cx_total rows double-counted cached input and re-emitted
        // token_count records, and carry no cumulative stamp to dedupe
        // against. A Codex file row with usage but no stamp predates it.
        let unprefixed = files.contains { key, rec in
            key.hasPrefix("codex:") && rec.cxTotal == 0
                && (rec.cxIn + rec.cxOut + rec.cxCached) > 0
        }
        let oldParser = files.contains { $0.key.hasPrefix("codex:") && $0.value.parserVersion < 10 }
        // v11 claims each Claude `message.id` once for the whole corpus, so
        // rows written before it hold both copies of a resumed or forked
        // transcript. SQLite rebuilds the same rows on its `user_version` 11
        // step; this is the JSON backend's half of that migration, and it
        // reads `parserVersion` rather than a stamp of its own because the
        // tried-and-true shape of a rebuild already lives here.
        let oldClaude = files.contains { $0.key.hasPrefix("claude:") && $0.value.parserVersion < 11 }
        if stale || unprefixed || oldParser || oldClaude {
            files = files.filter { key, _ in
                guard key.hasPrefix("codex:") || key.hasPrefix("claude:") else { return true }
                if key.hasPrefix("codex:") { return !(stale || unprefixed || oldParser) }
                return !oldClaude
            }
            rollup = rollup.filter { row in
                guard row.value.path.hasPrefix("codex:") || row.value.path.hasPrefix("claude:") else { return true }
                if row.value.path.hasPrefix("codex:") { return !(stale || unprefixed || oldParser) }
                return !oldClaude
            }
            dirty = true
            persistLocked()
        }
        rollupKeysByPath.removeAll(keepingCapacity: true)
        rollupKeysByDay.removeAll(keepingCapacity: true)
        sortedRollupDays = nil
        for (key, row) in rollup {
            rollupKeysByPath[row.path, default: []].insert(key)
            rollupKeysByDay[row.day, default: []].insert(key)
        }
    }

    private func removeRollupLocked(_ path: String) {
        guard let keys = rollupKeysByPath.removeValue(forKey: path) else { return }
        for key in keys {
            if let row = rollup.removeValue(forKey: key) { removeDayKeyLocked(key, day: row.day) }
        }
    }

    private func insertRollupLocked(_ row: RollupRec) {
        let key = Self.key(row)
        // Preserve the existing composite-key semantics, including a legacy
        // path containing the separator that collides with another key.
        if let previous = rollup[key] {
            if previous.path != row.path {
                rollupKeysByPath[previous.path]?.remove(key)
                if rollupKeysByPath[previous.path]?.isEmpty == true {
                    rollupKeysByPath.removeValue(forKey: previous.path)
                }
            }
            if previous.day != row.day { removeDayKeyLocked(key, day: previous.day) }
        }
        rollup[key] = row
        rollupKeysByPath[row.path, default: []].insert(key)
        if rollupKeysByDay[row.day] == nil { sortedRollupDays = nil }
        rollupKeysByDay[row.day, default: []].insert(key)
    }

    private func removeDayKeyLocked(_ key: String, day: String) {
        rollupKeysByDay[day]?.remove(key)
        if rollupKeysByDay[day]?.isEmpty == true {
            rollupKeysByDay.removeValue(forKey: day)
            sortedRollupDays = nil
        }
    }

    /// Binary-search inclusive string bounds, then visit only matching dates.
    /// Use the contiguous dictionary values for an all-history query to avoid
    /// paying an extra key lookup for every row in the corpus.
    private func forEachRollupLocked(startDay: String, endDay: String, _ body: (RollupRec) -> Void) {
        guard startDay <= endDay else { return }
        if sortedRollupDays == nil { sortedRollupDays = rollupKeysByDay.keys.sorted() }
        let days = sortedRollupDays ?? []
        func bound(_ value: String, inclusive: Bool) -> Int {
            var low = 0, high = days.count
            while low < high {
                let middle = low + (high - low) / 2
                if days[middle] < value || (inclusive && days[middle] == value) { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
        let low = bound(startDay, inclusive: false), high = bound(endDay, inclusive: true)
        guard low < high else { return }
        if low == 0 && high == days.count {
            for row in rollup.values { body(row) }
            return
        }
        let selectedDays = days[low..<high]
        // Random hash lookups lose to a contiguous scan for broad windows.
        // Count keys without reading rows, stopping as soon as the crossover
        // (measured with narrow/broad synthetic windows) is reached.
        let scanThreshold = max(1, rollup.count / 16)
        var selectedCount = 0
        for day in selectedDays {
            selectedCount += rollupKeysByDay[day]?.count ?? 0
            if selectedCount >= scanThreshold { break }
        }
        if selectedCount >= scanThreshold {
            for row in rollup.values where row.day >= startDay && row.day <= endDay { body(row) }
        } else {
            for day in selectedDays {
                for key in rollupKeysByDay[day] ?? [] {
                    if let row = rollup[key] { body(row) }
                }
            }
        }
    }

    private func persistLocked() {
        guard dirty else { return }
        dirty = false
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
    }

    private static func key(_ row: RollupRec) -> String {
        row.path + "\u{1F}" + row.day + "\u{1F}" + row.model
    }

    /// Fold one rollup row into a per-model bucket — `fetch`, `fetchByPath`
    /// and `fetchSession` share this body, they differ only in the bucket.
    private static func accumulate(_ row: RollupRec, into byModel: inout [String: ModelUsage]) {
        var u = byModel[row.model] ?? ModelUsage(model: row.model)
        u.calls += row.calls
        u.inputTokens += row.input
        u.outputTokens += row.output
        u.cacheReadTokens += row.cacheRead
        u.cacheCreationTokens += row.cacheCreate
        byModel[row.model] = u
    }

    /// Same fold for per-day totals, which carry no call or model counts.
    private static func accumulate(_ row: RollupRec, into byDay: inout [String: DayUsage]) {
        var d = byDay[row.day] ?? DayUsage(day: row.day)
        d.inputTokens += row.input
        d.outputTokens += row.output
        d.cacheReadTokens += row.cacheRead
        d.cacheCreationTokens += row.cacheCreate
        byDay[row.day] = d
    }
}
