import SwiftUI

/// Period-aware contribution heatmap.
///
/// Cell size follows grain: 日 is 7 large weekday squares; 月 is that month's
/// ~30 days as a GitHub week-column grid (few columns → large cells); 年 is
/// the full 365-day grid (≈53 columns → small cells). One Canvas, not hundreds
/// of views — a year of `Button`s was a scroll hitch.
struct UsageHeatmap: View {
    let days: [DayUsage]
    var period: UsagePeriod
    var reference: Date
    var compact: Bool = false
    var onSelectDay: ((Date) -> Void)? = nil
    var onSelectMonth: ((Date) -> Void)? = nil

    private let cal = Calendar.current

    static func height(for period: UsagePeriod, compact: Bool) -> CGFloat {
        switch period {
        case .day, .custom: return compact ? 28 : 60
        case .month: return compact ? 56 : 132
        case .year: return compact ? 56 : 108
        }
    }

    var body: some View {
        // Derived once per render. `byDay` rebuilds a dictionary over the whole
        // `days` array on every read (it is a computed property), and the week
        // strip used to read it *and* `peak` per cell — seven dictionary
        // rebuilds and seven max passes for a seven-cell row. The month/year
        // Canvas read it again inside its draw closure, so every frame of the
        // period-change animation rebuilt it too.
        let by = byDay
        let peak = max(Double(by.values.max() ?? 1), 1)
        // Read once per render instead of inline in the view tree below, where
        // it was evaluated again for every frame of the period-change animation.
        let summary = accessibilityText
        return Group {
            switch period {
            case .day, .custom:
                weekStrip(by: by, peak: peak)
            case .month, .year:
                contributionGrid(by: by, peak: peak)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height(for: period, compact: compact))
        .accessibilityLabel(summary)
        .animation(Theme.Motion.state, value: period)
    }

    // MARK: Day — seven large cells for the week containing `reference`

    private func weekStrip(by: [String: Int], peak: Double) -> some View {
        let items = weekItems(by: by, peak: peak)
        return GeometryReader { geo in
            let gap: CGFloat = compact ? 4 : 6
            let n = CGFloat(max(items.count, 1))
            let cell = max(12, (geo.size.width - gap * (n - 1)) / n)
            HStack(spacing: gap) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button {
                        if let date = item.date { onSelectDay?(date) }
                    } label: {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(fill(item.intensity, empty: item.empty))
                            .overlay(alignment: .bottom) {
                                Text(item.label)
                                    .font(.system(size: compact ? 8 : 9, weight: .medium, design: .rounded))
                                    .foregroundColor(item.isToday ? Theme.textPrimary : Theme.textTertiary())
                                    .padding(.bottom, 4)
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(width: cell, height: geo.size.height)
                    .help(item.help)
                    // `.help` is a tooltip, not a label: without this the cell
                    // announces the weekday glyph alone — seven buttons reading
                    // "一 二 三 …" in zh_CN, with the date and the token count
                    // (which is the whole point of the strip) unreadable.
                    .accessibilityLabel(item.help)
                }
            }
        }
    }

    // MARK: Month / year — GitHub week-column grid, Canvas

    private func contributionGrid(by: [String: Int], peak: Double) -> some View {
        GeometryReader { geo in
            let layout = HeatLayout.make(
                interval: gridInterval,
                size: geo.size,
                cal: cal,
                compact: compact)
            Canvas { ctx, _ in
                for col in 0..<layout.cols {
                    for row in 0..<7 {
                        let i = col * 7 + row - layout.leading
                        let rect = layout.rect(col: col, row: row)
                        let path = Path(roundedRect: rect, cornerRadius: min(3, layout.cellW * 0.28), style: .continuous)
                        if i >= 0, i < layout.dayCount,
                           let date = cal.date(byAdding: .day, value: i, to: layout.start) {
                            let tokens = by[Self.dayKey(date)]
                            ctx.fill(path, with: .color(fill(tokens.map { Double($0) / peak }, empty: tokens == nil)))
                        } else {
                            ctx.fill(path, with: .color(Theme.cardFill(0.04)))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let date = layout.date(at: location, cal: cal) else { return }
                // In the year grid a cell is one day of one month, and drilling
                // into that month is what a click means there; `onSelectDay` on
                // a 365-cell grid just jumped the period to a day the user was
                // aiming at only approximately. `onSelectMonth` had no caller at
                // all before this.
                if period == .year, let onSelectMonth {
                    onSelectMonth(date)
                } else {
                    onSelectDay?(date)
                }
            }
        }
    }

    private var gridInterval: DateInterval {
        switch period {
        case .year:
            return cal.dateInterval(of: .year, for: reference)
                ?? DateInterval(start: reference, duration: 365 * 86400)
        default:
            return cal.dateInterval(of: .month, for: reference)
                ?? DateInterval(start: reference, duration: 30 * 86400)
        }
    }

    // MARK: Color

    private func fill(_ intensity: Double?, empty: Bool) -> Color {
        if empty { return Theme.cardFill(0.06) }
        guard let v = intensity else { return Theme.cardFill(0.06) }
        return Theme.chartPurple.opacity(0.16 + 0.84 * v)
    }

    // MARK: Week data

    private struct Cell {
        var date: Date?
        var intensity: Double?
        var empty = true
        var label = ""
        var help = ""
        var isToday = false
    }

    private var byDay: [String: Int] {
        Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0.totalTokens) })
    }

    private func weekItems(by: [String: Int], peak: Double) -> [Cell] {
        let week = cal.dateInterval(of: .weekOfYear, for: reference)
            ?? DateInterval(start: reference, duration: 7 * 86400)
        let today = cal.startOfDay(for: Date())
        let selected = cal.startOfDay(for: reference)
        return (0..<7).map { offset -> Cell in
            guard let date = cal.date(byAdding: .day, value: offset, to: week.start) else {
                return Cell()
            }
            let key = Self.dayKey(date)
            let tokens = by[key]
            let weekday = cal.component(.weekday, from: date)
            return Cell(
                date: date,
                intensity: tokens.map { Double($0) / peak },
                empty: tokens == nil,
                label: cal.veryShortWeekdaySymbols[weekday - 1],
                help: helpText(date: date, tokens: tokens),
                isToday: cal.isDate(date, inSameDayAs: today) || cal.isDate(date, inSameDayAs: selected)
            )
        }
    }

    private func helpText(date: Date, tokens: Int?) -> String {
        // Cached formatter — this runs once per strip cell on every render,
        // and a fresh DateFormatter re-parses the pattern each time. (The
        // month/year grid is a Canvas with no per-cell tooltip.)
        let label = UsageStats.formatter("M月d日").string(from: date)
        if let tokens { return "\(label) · \(UsageStats.formatTokens(tokens))" }
        return "\(label) · 无用量"
    }

    private var accessibilityText: String {
        switch period {
        case .day, .custom: return "本周用量，\(days.count) 天有数据"
        case .month: return "本月用量热力图，\(days.count) 天"
        case .year: return "本年用量热力图，\(days.count) 天"
        }
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Week-column GitHub layout math, shared by draw + hit testing.
private struct HeatLayout {
    let cols: Int
    let leading: Int
    let dayCount: Int
    let start: Date
    let cellW: CGFloat
    let cellH: CGFloat
    let gap: CGFloat

    static func make(interval: DateInterval, size: CGSize, cal: Calendar, compact: Bool) -> HeatLayout {
        let start = cal.startOfDay(for: interval.start)
        let end = interval.end.addingTimeInterval(-1)
        let dayCount = max(1, cal.dateComponents([.day], from: start, to: cal.startOfDay(for: end)).day ?? 0) + 1
        let weekday = cal.component(.weekday, from: start)
        let leading = (weekday - cal.firstWeekday + 7) % 7
        let cols = Int(ceil(Double(leading + dayCount) / 7.0))
        let gap: CGFloat = compact ? 2 : 3
        let cellW = max(3, (size.width - gap * CGFloat(max(cols - 1, 0))) / CGFloat(max(cols, 1)))
        let cellH = max(3, (size.height - gap * 6) / 7)
        return HeatLayout(cols: max(cols, 1), leading: leading, dayCount: dayCount,
                          start: start, cellW: cellW, cellH: cellH, gap: gap)
    }

    func rect(col: Int, row: Int) -> CGRect {
        CGRect(x: CGFloat(col) * (cellW + gap),
               y: CGFloat(row) * (cellH + gap),
               width: cellW, height: cellH)
    }

    func date(at p: CGPoint, cal: Calendar) -> Date? {
        let col = Int(floor(p.x / (cellW + gap)))
        let row = Int(floor(p.y / (cellH + gap)))
        guard col >= 0, col < cols, row >= 0, row < 7 else { return nil }
        let i = col * 7 + row - leading
        guard i >= 0, i < dayCount else { return nil }
        return cal.date(byAdding: .day, value: i, to: start)
    }
}

/// Sliding-pill period strip, rendered by the shared `SegmentedCapsule` so the
/// usage page and the popup read as the same control as the connector and
/// provider filters. Compact mode uses two-character labels so 「自定义」
/// cannot wrap in the 400pt popup.
struct PeriodTabs: View {
    var period: UsagePeriod
    var compact: Bool = false
    var onSelect: (UsagePeriod) -> Void

    var body: some View {
        SegmentedCapsule(items: UsagePeriod.allCases,
                         selection: period,
                         title: { compact ? $0.compactLabel : $0.label },
                         tint: Theme.Ink.cursor,
                         onSelect: onSelect)
    }
}
