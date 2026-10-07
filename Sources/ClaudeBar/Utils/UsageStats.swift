import Foundation

/// Aggregate per-model token usage. Query path for the usage panel — the
/// heavy lifting lives in `UsageIndex` (persistent SQLite rollup, updated
/// incrementally before each query).
struct UsageStats {

    /// Day mode includes its surrounding week; calendar grids need the full query window.
    static func heatmapDays(for period: UsagePeriod, periodDays: [DayUsage], weekDays: [DayUsage]) -> [DayUsage] {
        switch period {
        case .day, .custom: return weekDays
        case .month, .year, .all: return periodDays
        }
    }

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

    /// Human-readable label for the period, e.g. "2026年7月30日", "2026年7月",
    /// "2026年"; `.all` renders "全部记录".
    ///
    /// Formatters are cached: this is called from `body` (dashboard, usage page
    /// and the popup header), so building one per call allocated on every
    /// layout pass of the densest views in the app.
    ///
    /// The cache is keyed by pattern **and zone**, and guarded: read off-main by
    /// `ExchangeRate.note` and `CursorLedgerStore`, which is why the lock is
    /// here rather than an actor hop. The zone is part of the key because a
    /// formatter's `timeZone` is captured when it is built, so a machine that
    /// changes zone (`TimeZone.current` moves, DST rules are updated) would keep
    /// rendering old-zone dates from the cache while freshly parsed rows — which
    /// bucket days with `Calendar.current` — already use the new one. Day
    /// captions and the heatmap would then disagree with the rollup keys for the
    /// rest of the process's life.
    private static let formatterLock = NSLock()
    private static var labelFormatters: [String: DateFormatter] = [:]

    /// Larger than any plausible run of distinct zones, so the sweep only ever
    /// fires on real zone churn (travel, a DST rules update) rather than on a
    /// normal 4-pattern day. The entries are all of a few microsecond
    /// constructions, so the bound only needs to keep the resident count near
    /// its steady state.
    private static let labelFormatterLimit = 32

    /// Cached `DateFormatter` for a fixed pattern, in the app's zh_CN locale.
    /// Shared with the heatmap tooltips, which build one per cell.
    static func formatter(_ format: String) -> DateFormatter {
        let zone = TimeZone.current.identifier
        let key = format + "\u{1}" + zone
        formatterLock.lock(); defer { formatterLock.unlock() }
        if let cached = labelFormatters[key] { return cached }
        // The zone is part of the key so a machine that changes zone never
        // renders old-zone dates from the cache, but nothing else ever drops a
        // key: a couple of trips a day would leave every zone's formatters
        // (each carrying its localized data) resident until the process exits.
        // Sweep the zones that are no longer current once the cache has grown
        // past any steady number of them.
        if labelFormatters.count >= labelFormatterLimit {
            labelFormatters = labelFormatters.filter { $0.key.hasSuffix("\u{1}" + zone) }
        }
        let made = DateFormatter()
        made.locale = Locale(identifier: "zh_CN")
        // Resolved by identifier so the formatter shares the process's own
        // `TimeZone.current` instance rather than falling back to the system
        // default; the zone is in the key precisely so this stays current.
        made.timeZone = TimeZone(identifier: zone) ?? .current
        made.dateFormat = format
        labelFormatters[key] = made
        return made
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

    /// Style-explicit variant, for callers that already resolved the style
    /// (previews) or that are not in the app's process at all. The arithmetic
    /// itself lives in `TokenMagnitude` so the widget extension — which cannot
    /// see this file — formats the same number the same way instead of
    /// carrying a second copy whose thresholds could drift unnoticed.
    static func formatTokens(_ n: Int, style: TokenUnitStyle) -> String {
        TokenMagnitude.format(n, style: style.rawValue)
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
