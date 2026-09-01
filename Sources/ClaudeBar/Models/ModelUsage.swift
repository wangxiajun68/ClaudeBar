import Foundation

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

/// One local-calendar day of aggregated usage — the river chart's column.
struct DayUsage: Identifiable {
    var id: String { day }
    let day: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}

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

    /// Cache-hit share of prompt-side tokens (Claude Code / Codex).
    var cacheHitRate: Double {
        let denom = totalInputTokens
        guard denom > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(denom)
    }

    var cacheHitPercent: Int { Int((cacheHitRate * 100).rounded()) }

    mutating func merge(_ other: ModelUsage) {
        calls += other.calls
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreationTokens += other.cacheCreationTokens
    }

    /// Merge a list by model id — used when several sources (Claude
    /// transcripts, external tools, Cursor) contribute entries for the same
    /// model name.
    static func merged(_ list: [ModelUsage]) -> [ModelUsage] {
        var agg: [String: ModelUsage] = [:]
        for item in list {
            var entry = agg[item.model] ?? ModelUsage(model: item.model)
            entry.merge(item)
            agg[item.model] = entry
        }
        return Array(agg.values)
    }
}
