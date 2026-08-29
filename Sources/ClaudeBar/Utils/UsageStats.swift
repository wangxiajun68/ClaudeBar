import Foundation

struct ModelUsage: Identifiable {
    var id: String { model }
    let model: String
    var calls: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    /// All prompt-side tokens processed (fresh input + cache read + cache creation).
    var totalInputTokens: Int { inputTokens + cacheReadTokens + cacheCreationTokens }
    var totalTokens: Int { totalInputTokens + outputTokens }

    mutating func merge(_ other: ModelUsage) {
        calls += other.calls
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreationTokens += other.cacheCreationTokens
    }
}

/// Granularity for usage aggregation.
enum UsagePeriod: String, CaseIterable, Identifiable {
    case day, month, year, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "日"
        case .month: return "月"
        case .year: return "年"
        case .custom: return "指定"
        }
    }
}

/// Scans Claude Code transcript files (~/.claude/projects/**/*.jsonl) and
/// aggregates per-model token usage within a date interval.
struct UsageStats {

    /// The date interval covered by a period anchored at `reference`.
    static func interval(for period: UsagePeriod, reference: Date) -> DateInterval {
        let cal = Calendar.current
        switch period {
        case .day, .custom:
            return cal.dateInterval(of: .day, for: reference) ?? DateInterval(start: reference, duration: 86400)
        case .month:
            return cal.dateInterval(of: .month, for: reference) ?? DateInterval(start: reference, duration: 86400)
        case .year:
            return cal.dateInterval(of: .year, for: reference) ?? DateInterval(start: reference, duration: 86400)
        }
    }

    /// Human-readable label for the period, e.g. "2026-07-30", "JULY 2026", "2026".
    static func label(for period: UsagePeriod, reference: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        switch period {
        case .day, .custom:
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: reference)
        case .month:
            f.dateFormat = "MMMM yyyy"
            return f.string(from: reference).uppercased()
        case .year:
            f.dateFormat = "yyyy"
            return f.string(from: reference)
        }
    }

    /// Shift the reference date by one unit of the current period (±1).
    static func shift(_ period: UsagePeriod, reference: Date, by amount: Int) -> Date {
        let cal = Calendar.current
        switch period {
        case .day, .custom:
            return cal.date(byAdding: .day, value: amount, to: reference) ?? reference
        case .month:
            return cal.date(byAdding: .month, value: amount, to: reference) ?? reference
        case .year:
            return cal.date(byAdding: .year, value: amount, to: reference) ?? reference
        }
    }

    // MARK: - Incremental file cache
    //
    // Parsing is the bottleneck on large transcript trees (a month/year scan
    // re-reads thousands of files). Cache each file's parsed usage entries
    // keyed by mtime + size: transcript files are append-only, so an unchanged
    // file can never produce different results and is skipped entirely on the
    // next scan. Entries are date-filtered at aggregation time, so one cache
    // serves every period (day/month/year/custom).

    private struct UsageEntry {
        let date: Date
        let model: String
        var calls: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreationTokens: Int = 0
    }

    private struct FileCacheEntry {
        var mtime: Date
        var size: Int
        var entries: [UsageEntry]
    }

    private static var fileCache: [String: FileCacheEntry] = [:]
    private static let cacheLock = NSLock()

    /// Aggregate usage per model within `interval`, sorted by total tokens descending.
    /// Optimized with: file-mtime prefilter, incremental per-file cache,
    /// timestamp-string prefilter, parallel parsing.
    static func fetch(in interval: DateInterval) -> [ModelUsage] {
        let projectsDir = FilePaths.claudeDir.appendingPathComponent("projects")

        guard FileManager.default.fileExists(atPath: projectsDir.path),
              let enumerator = FileManager.default.enumerator(
                  at: projectsDir,
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                  options: [.skipsHiddenFiles]) else {
            return []
        }

        // --- File-level mtime prefilter ---
        // A file last modified before the interval began cannot contain entries
        // in the interval (entries are appended at message time, mtime = last write).
        let candidateFiles: [(url: URL, mtime: Date?, size: Int?)] = enumerator.compactMap { item -> (URL, Date?, Int?)? in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                return (url, nil, nil)
            }
            if let mod = attrs.contentModificationDate, mod < interval.start {
                return nil
            }
            return (url, attrs.contentModificationDate, attrs.fileSize)
        }

        // --- Split candidates into cache hits (reuse) and misses (parse) ---
        var cachedEntries: [[UsageEntry]] = []
        var toParse: [(url: URL, mtime: Date?, size: Int?)] = []
        for file in candidateFiles {
            if let mtime = file.mtime, let size = file.size {
                cacheLock.lock()
                let hit = fileCache[file.url.path]
                cacheLock.unlock()
                if let hit, hit.mtime == mtime, hit.size == size {
                    cachedEntries.append(hit.entries)
                    continue
                }
            }
            toParse.append(file)
        }

        // --- Parallel parse only the cache misses ---
        var parsed = [[UsageEntry]](repeating: [], count: toParse.count)
        DispatchQueue.concurrentPerform(iterations: toParse.count) { j in
            let file = toParse[j]
            let entries = parseFile(file.url)
            parsed[j] = entries
            // Store for the next scan — append-only files keep this valid.
            if let mtime = file.mtime, let size = file.size {
                cacheLock.lock()
                fileCache[file.url.path] = FileCacheEntry(mtime: mtime, size: size, entries: entries)
                cacheLock.unlock()
            }
        }

        // --- Filter by interval + merge ---
        var agg: [String: ModelUsage] = [:]
        func merge(_ entries: [UsageEntry]) {
            for e in entries where interval.contains(e.date) {
                var entry = agg[e.model] ?? ModelUsage(model: e.model)
                entry.calls += e.calls
                entry.inputTokens += e.inputTokens
                entry.outputTokens += e.outputTokens
                entry.cacheReadTokens += e.cacheReadTokens
                entry.cacheCreationTokens += e.cacheCreationTokens
                agg[e.model] = entry
            }
        }
        for entries in cachedEntries { merge(entries) }
        for entries in parsed { merge(entries) }

        return agg.values
            .filter { $0.totalTokens > 0 }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: - File parsing

    /// Parse a transcript file into raw usage entries (date + model + token
    /// counts). Interval filtering happens later, so one parsed result is
    /// reusable across all periods via the incremental cache.
    private static func parseFile(_ url: URL) -> [UsageEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var entries: [UsageEntry] = []
        let tsKey = "\"timestamp\":\""

        // One shared formatter — ISO8601DateFormatter is thread-safe (unlike DateFormatter).
        let tsFormatter = ISO8601DateFormatter()
        tsFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            // 1) Cheap presence check — `usage` only appears on assistant messages.
            guard line.contains("\"usage\"") else { continue }

            // 2) Locate the timestamp before any JSON parsing.
            guard let r = line.range(of: tsKey) else { continue }
            let after = line[r.upperBound...]
            guard let q = after.firstIndex(of: "\"") else { continue }
            let tsStr = after[..<q]
            guard tsStr.count >= 10 else { continue }

            // 3) Precise parse (the full timestamp is needed for interval filtering).
            guard let date = tsFormatter.date(from: String(tsStr)) else { continue }

            // 4) Only now do the expensive full-JSON parse.
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (obj["type"] as? String) == "assistant" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            let model = (message["model"] as? String) ?? "unknown"
            guard !model.isEmpty, !model.hasPrefix("<") else { continue }
            guard let usage = message["usage"] as? [String: Any] else { continue }

            var entry = UsageEntry(date: date, model: model)
            entry.calls = 1
            entry.inputTokens = JSONCoerce.intVal(usage["input_tokens"])
            entry.outputTokens = JSONCoerce.intVal(usage["output_tokens"])
            entry.cacheReadTokens = JSONCoerce.intVal(usage["cache_read_input_tokens"])
            entry.cacheCreationTokens = JSONCoerce.intVal(usage["cache_creation_input_tokens"])
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Formatting

    /// Compact token count: 38690638 → "38.7M", 317579 → "318K", 942 → "942".
    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%dK", Int(round(Double(n) / 1_000)))
        } else {
            return "\(n)"
        }
    }

    // MARK: - Helpers
}
