import Foundation
import SwiftUI

/// Where a token came from. Claude Code and Codex are read from their own
/// transcripts; anything else only ever appears through the local proxy and is
/// aggregated from proxied requests.
enum UsageSource: String, CaseIterable, Identifiable {
    case claude, codex, thirdParty

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .thirdParty: return "第三方"
        }
    }

    var shortLabel: String {
        switch self {
        case .claude: return "CC"
        case .codex: return "Codex"
        case .thirdParty: return "第三方"
        }
    }

    /// Same hues the Traffic page's source chip uses, so a source keeps one
    /// color across the app.
    var color: Color {
        switch self {
        case .claude: return Theme.claude
        case .codex: return Theme.codex
        case .thirdParty: return Theme.cursor
        }
    }

    /// `color` as readable text, index-aligned with it — the source cards paint
    /// their title and counts as glyphs, and the raw hues are 1.8–3.4:1 on the
    /// ice canvas (see `Theme.Ink`). Bars and rings keep `color`.
    var ink: Color {
        switch self {
        case .claude: return Theme.Ink.claude
        case .codex: return Theme.Ink.codex
        case .thirdParty: return Theme.Ink.cursor
        }
    }
}

/// Granularity for usage aggregation.
enum UsagePeriod: String, CaseIterable, Identifiable {
    case day, month, year, all, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "日"
        case .month: return "月"
        case .year: return "年"
        case .all: return "全部"
        case .custom: return "自定义"
        }
    }

    /// Two-character label so the popup period strip cannot wrap.
    var compactLabel: String {
        switch self {
        case .custom: return "自定"
        case .all: return "全部"
        default: return label
        }
    }
}

/// One local-calendar day of aggregated usage — the river chart's column.
struct DayUsage: Identifiable, Equatable {
    var id: String { day }
    let day: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}

struct ModelUsage: Identifiable, Hashable {
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
    var isZero: Bool { calls == 0 && totalTokens == 0 }

    /// Cache-hit share of prompt-side tokens.
    ///
    /// The denominator is the full prompt side (`input + read + create`) and
    /// the numerator is the cached portion. That reads correctly for all three
    /// sources only because each is stored with **disjoint** buckets: Claude's
    /// `input_tokens` excludes the cache fields; the Codex parser subtracts
    /// `cached_input_tokens` from `input_tokens`; and the proxy's `TokenTotals`
    /// folds the hit out of the upstream's prompt count before the third-party
    /// rollup ever sees it (DeepSeek's `prompt_tokens` and OpenAI's
    /// `input_tokens` both include it).
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
