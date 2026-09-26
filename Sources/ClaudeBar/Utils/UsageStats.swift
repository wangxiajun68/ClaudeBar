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
        case .all:
            // The rollup is keyed by day, so a wide bound is a range scan, not
            // a walk of empty years. 2020 is before this app's transcripts.
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
            let start = cal.date(from: DateComponents(year: 2020, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
            return DateInterval(start: start, end: end)
        }
    }

    /// Human-readable label for the period, e.g. "2026-07-30", "JULY 2026", "2026".
    ///
    /// Formatters are cached: this is called from `body` (dashboard, usage page
    /// and the popup header), so building one per call allocated on every
    /// layout pass of the densest views in the app. They are only ever touched
    /// on the main actor, which is where every caller renders.
    private static var labelFormatters: [String: DateFormatter] = [:]

    /// Cached `DateFormatter` for a fixed pattern, in the app's zh_CN locale.
    /// Shared with the heatmap tooltips, which build one per cell.
    static func formatter(_ format: String) -> DateFormatter {
        labelFormatters[format] ?? {
            let made = DateFormatter()
            made.locale = Locale(identifier: "zh_CN")
            made.timeZone = TimeZone.current
            made.dateFormat = format
            labelFormatters[format] = made
            return made
        }()
    }

    static func label(for period: UsagePeriod, reference: Date) -> String {
        let format: String
        switch period {
        case .day, .custom: format = "yyyy年M月d日"
        case .month: format = "yyyy年M月"
        case .year: format = "yyyy年"
        case .all: return "全部记录"
        }
        return formatter(format).string(from: reference)
    }

    /// Short form for a pill in a tile header, where `label(for:reference:)`
    /// ("2026年9月") does not fit: "今天" for the current day, otherwise the
    /// period's own granularity ("9月" / "2026年").
    ///
    /// The widget snapshot's period line is the same string, which is why this
    /// lives here rather than in the one view that needs the pill.
    static func compactLabel(for period: UsagePeriod, reference: Date) -> String {
        switch period {
        case .day, .custom:
            return Calendar.current.isDateInToday(reference) ? "今天" : "当日"
        case .month:
            return formatter("M月").string(from: reference)
        case .year:
            return formatter("yyyy年").string(from: reference)
        case .all:
            return "全部"
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
        case .all:
            return reference
        }
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
