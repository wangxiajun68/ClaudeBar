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

    /// Aggregate usage per model within `interval`, sorted by total tokens descending.
    /// Optimized with: file-mtime prefilter, timestamp-string prefilter, parallel parsing.
    static func fetch(in interval: DateInterval) -> [ModelUsage] {
        let projectsDir = FilePaths.claudeDir.appendingPathComponent("projects")

        guard FileManager.default.fileExists(atPath: projectsDir.path),
              let enumerator = FileManager.default.enumerator(
                  at: projectsDir,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]) else {
            return []
        }

        // --- File-level mtime prefilter ---
        // A file last modified before the interval began cannot contain entries
        // in the interval (entries are appended at message time, mtime = last write).
        let candidateFiles: [URL] = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            if let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let mod = attrs.contentModificationDate,
               mod < interval.start {
                return nil
            }
            return url
        }

        // --- Coarse timestamp-string window (UTC date prefix, ±1 day slack for tz) ---
        // ISO timestamps are UTC and zero-padded (yyyy-MM-dd...), so their first 10
        // chars sort lexicographically == chronologically. Reject lines whose UTC date
        // clearly falls outside [interval.start - 1d, interval.end + 1d] BEFORE parsing.
        let slackStart = interval.start.addingTimeInterval(-86400)
        let slackEnd = interval.end.addingTimeInterval(86400)
        let minDateStr = utcDateString(slackStart)
        let maxDateStr = utcDateString(slackEnd)

        // One shared formatter — ISO8601DateFormatter is thread-safe (unlike DateFormatter).
        let tsFormatter = ISO8601DateFormatter()
        tsFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // --- Parallel parse: each file → its own [String: ModelUsage] ---
        let n = candidateFiles.count
        var partial = [[String: ModelUsage]](repeating: [:], count: n)
        if n > 0 {
            DispatchQueue.concurrentPerform(iterations: n) { i in
                partial[i] = parseFile(
                    candidateFiles[i],
                    interval: interval,
                    minDateStr: minDateStr,
                    maxDateStr: maxDateStr,
                    tsFormatter: tsFormatter
                )
            }
        }

        // --- Merge ---
        var agg: [String: ModelUsage] = [:]
        for dict in partial {
            for (model, usage) in dict {
                var entry = agg[model] ?? ModelUsage(model: model)
                entry.merge(usage)
                agg[model] = entry
            }
        }
        return agg.values
            .filter { $0.totalTokens > 0 }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: - File parsing

    private static func parseFile(
        _ url: URL,
        interval: DateInterval,
        minDateStr: String,
        maxDateStr: String,
        tsFormatter: ISO8601DateFormatter
    ) -> [String: ModelUsage] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var local: [String: ModelUsage] = [:]
        let tsKey = "\"timestamp\":\""

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            // 1) Cheap presence check — `usage` only appears on assistant messages.
            guard line.contains("\"usage\"") else { continue }

            // 2) Coarse timestamp window — reject before any JSON parsing.
            guard let r = line.range(of: tsKey) else { continue }
            let after = line[r.upperBound...]
            guard let q = after.firstIndex(of: "\"") else { continue }
            let tsStr = after[..<q]
            guard tsStr.count >= 10 else { continue }
            let datePart = String(tsStr.prefix(10))
            if datePart < minDateStr || datePart > maxDateStr { continue }

            // 3) Precise parse + interval check (handles tz boundary exactly).
            guard let date = tsFormatter.date(from: String(tsStr)),
                  interval.contains(date) else { continue }

            // 4) Only now do the expensive full-JSON parse.
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (obj["type"] as? String) == "assistant" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            let model = (message["model"] as? String) ?? "unknown"
            guard !model.isEmpty, !model.hasPrefix("<") else { continue }
            guard let usage = message["usage"] as? [String: Any] else { continue }

            var entry = local[model] ?? ModelUsage(model: model)
            entry.calls += 1
            entry.inputTokens += JSONCoerce.intVal(usage["input_tokens"])
            entry.outputTokens += JSONCoerce.intVal(usage["output_tokens"])
            entry.cacheReadTokens += JSONCoerce.intVal(usage["cache_read_input_tokens"])
            entry.cacheCreationTokens += JSONCoerce.intVal(usage["cache_creation_input_tokens"])
            local[model] = entry
        }
        return local
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

    /// UTC yyyy-MM-dd for a Date (for coarse string comparison against ISO timestamps).
    private static func utcDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
