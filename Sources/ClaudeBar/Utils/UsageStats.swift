import Foundation

/// Aggregate per-model token usage. Query path for the usage panel — the
/// heavy lifting lives in `UsageIndex` (persistent SQLite rollup, updated
/// incrementally before each query).
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

    /// Query cost is O(interval rollup rows). Call `UsageIndex.updateIndex()`
    /// separately when transcripts may have changed.
    static func fetch(in interval: DateInterval) -> [ModelUsage] {
        UsageIndex.fetch(in: interval)
    }

    // MARK: - Formatting

    /// Compact token count, honoring the user's unit preference:
    /// - `.chinese`: 38690638 → "3869.1万", 3.28e9 → "32.8亿"
    /// - `.metric`:  38690638 → "38.7M", 3.28e9 → "3.28B"
    /// Sub-万 counts render identically in both styles ("318K" / "942").
    static func formatTokens(_ n: Int) -> String {
        formatTokens(n, style: AppPreferences.shared.tokenUnitStyle)
    }

    /// Style-explicit variant (Widget and previews pass their own style).
    static func formatTokens(_ n: Int, style: TokenUnitStyle) -> String {
        switch style {
        case .chinese:
            if n >= 100_000_000 {
                return String(format: "%.1f亿", Double(n) / 100_000_000)
            } else if n >= 10_000 {
                return String(format: "%.1f万", Double(n) / 10_000)
            } else if n >= 1_000 {
                return String(format: "%dK", Int(round(Double(n) / 1_000)))
            } else {
                return "\(n)"
            }
        case .metric:
            if n >= 1_000_000_000 {
                return String(format: "%.2fB", Double(n) / 1_000_000_000)
            } else if n >= 1_000_000 {
                return String(format: "%.1fM", Double(n) / 1_000_000)
            } else if n >= 1_000 {
                return String(format: "%dK", Int(round(Double(n) / 1_000)))
            } else {
                return "\(n)"
            }
        }
    }

    /// Context-window sizes on session tiles: always k, never 万/亿.
    /// 200000 → "200k", 15900 → "16k", 800 → "800".
    static func formatContext(_ n: Int) -> String {
        guard n >= 1_000 else { return "\(n)" }
        let k = Double(n) / 1_000
        if k >= 10 { return "\(Int((k).rounded()))k" }
        if abs(k - k.rounded()) < 0.05 { return "\(Int(k.rounded()))k" }
        return String(format: "%.1fk", k)
    }
}
