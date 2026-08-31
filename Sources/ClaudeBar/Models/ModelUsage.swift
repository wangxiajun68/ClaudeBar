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
