import SwiftUI

/// Where this period's tokens came from, as shares of one whole.
///
/// Three free-floating bars each had their own length, so a 99 / 1 split and a
/// 50 / 50 split could look like the same kind of picture. One track is 100 %
/// of the period: a segment's width *is* its share. The rows underneath name
/// the absolute count, which the track cannot.
struct SourceTriad: View {
    let totals: [(source: UsageSource, tokens: Int)]
    /// The queried span. The track morphs when this changes (a new range) and
    /// stays put when only the token totals tick inside the same span.
    var spanKey: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Int { max(totals.reduce(0) { $0 + $1.tokens }, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(totals, id: \.source) { row in
                        let share = CGFloat(row.tokens) / CGFloat(total)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LinearGradient(
                                colors: [row.source.color.opacity(row.tokens > 0 ? 1 : 0.2),
                                         row.source.color.opacity(row.tokens > 0 ? 0.55 : 0.1)],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: row.tokens > 0
                                   ? max(10, (geo.size.width - 6) * share) : 0)
                    }
                }
            }
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardFill(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            ForEach(totals, id: \.source) { row in
                let share = Int((Double(row.tokens) / Double(total) * 100).rounded())
                HStack(spacing: 8) {
                    Circle().fill(row.source.color).frame(width: 7, height: 7)
                    Text(row.source.label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    Text("\(share)%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(row.source.ink)
                    RollingNumberText(UsageStats.formatTokens(row.tokens))
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.84), value: spanKey)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(totals.map { "\($0.source.label) \(UsageStats.formatTokens($0.tokens))" }.joined(separator: "，"))
    }
}

/// Input / cache-hit / cache-write / output as a labeled stacked track.
struct TokenMixStrip: View {
    let stats: [ModelUsage]
    var compact: Bool = false

    /// The four sums, computed in one pass.
    ///
    /// They were four computed properties, each a full `reduce` over `stats`;
    /// `total` was a fifth, and `slice(_:_:_:)` read it again per slice — so
    /// one body pass walked the model list nine times.
    private struct Totals {
        var input = 0
        var hit = 0
        var write = 0
        var output = 0
        var sum: Int { max(input + hit + write + output, 1) }
    }

    private static func totals(_ stats: [ModelUsage]) -> Totals {
        var out = Totals()
        for stat in stats {
            out.input += stat.inputTokens
            out.hit += stat.cacheReadTokens
            out.write += stat.cacheCreationTokens
            out.output += stat.outputTokens
        }
        return out
    }

    var body: some View {
        let t = Self.totals(stats)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    slice(t.input, geo.size.width, Theme.claude, total: t.sum)
                    slice(t.hit, geo.size.width, Theme.external, total: t.sum)
                    slice(t.write, geo.size.width, Theme.statusWarning, total: t.sum)
                    slice(t.output, geo.size.width, Theme.cursor, total: t.sum)
                }
                .clipShape(Capsule())
            }
            .frame(height: compact ? 8 : 10)
            .background(Capsule().fill(Theme.cardFill(0.08)))
            HStack(spacing: compact ? 8 : 12) {
                cap("输入", t.input, Theme.claude)
                cap("命中", t.hit, Theme.external)
                cap("写入", t.write, Theme.statusWarning)
                cap("输出", t.output, Theme.cursor)
            }
        }
    }

    @ViewBuilder
    private func slice(_ n: Int, _ width: CGFloat, _ color: Color, total: Int) -> some View {
        if n > 0 {
            color.opacity(0.9)
                .frame(width: max(2, width * CGFloat(n) / CGFloat(total)))
        }
    }

    private func cap(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            RollingNumberText(compact ? label : "\(label) \(UsageStats.formatTokens(n))")
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(1)
        }
    }
}

/// When the tokens landed, at the grain of the selected range.
///
/// 日 is the week around that day, 月 is one column per calendar day, 年 is
/// twelve months, 全部 is one column per month (or per year once the span is
/// longer than two years). Empty columns stay, short, so a quiet week is
/// visible as a gap and not dropped from the axis. The spring runs when that
/// axis changes — a new range — and not when a token total ticks inside it.
struct UsageDaySpark: View {
    let days: [DayUsage]
    let interval: DateInterval
    var period: UsagePeriod = .month
    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Column: Identifiable {
        let id: Int
        let label: String
        let showsLabel: Bool
        let detail: String
        let tokens: Int
        let peak: Bool
    }

    private var columns: [Column] {
        let totals = Dictionary(days.map { ($0.day, $0.totalTokens) }, uniquingKeysWith: +)
        let cal = Calendar.current
        switch period {
        case .day, .custom:
            let week = cal.dateInterval(of: .weekOfYear, for: interval.start) ?? interval
            return (0..<7).map { offset in
                let date = cal.date(byAdding: .day, value: offset, to: week.start) ?? week.start
                let key = Self.key(date)
                let weekday = cal.veryShortWeekdaySymbols[cal.component(.weekday, from: date) - 1]
                return Column(id: offset, label: weekday, showsLabel: true,
                              detail: UsageStats.formatter("M月d日").string(from: date),
                              tokens: totals[key] ?? 0, peak: false)
            }
        case .month:
            let start = cal.startOfDay(for: interval.start)
            let end = cal.startOfDay(for: interval.end.addingTimeInterval(-1))
            let count = max(1, (cal.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
            return (0..<count).map { offset in
                let date = cal.date(byAdding: .day, value: offset, to: start) ?? start
                let day = cal.component(.day, from: date)
                return Column(id: offset, label: "\(day)",
                              showsLabel: day == 1 || day == 10 || day == 20 || offset == count - 1,
                              detail: UsageStats.formatter("M月d日").string(from: date),
                              tokens: totals[Self.key(date)] ?? 0, peak: false)
            }
        case .year, .all:
            return monthColumns(totals: totals, cal: cal)
        }
    }

    private func monthColumns(totals: [String: Int], cal: Calendar) -> [Column] {
        let startBound = period == .all
            ? (days.compactMap { Self.parse($0.day) }.min() ?? interval.start)
            : interval.start
        let endBound = period == .all ? Date() : interval.end.addingTimeInterval(-1)
        var cursor = cal.date(from: cal.dateComponents([.year, .month], from: startBound)) ?? startBound
        let endMonth = cal.date(from: cal.dateComponents([.year, .month], from: endBound)) ?? endBound
        var spans: [(date: Date, tokens: Int)] = []
        while cursor <= endMonth && spans.count < 120 {
            let prefix = Self.key(cursor).prefix(7)
            let tokens = totals.reduce(0) { partial, pair in
                pair.key.hasPrefix(prefix) ? partial + pair.value : partial
            }
            spans.append((cursor, tokens))
            guard let next = cal.date(byAdding: .month, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        let byYear = spans.count > 24
        if byYear {
            var years: [Int: Int] = [:]
            for span in spans {
                let year = cal.component(.year, from: span.date)
                years[year, default: 0] += span.tokens
            }
            return years.keys.sorted().enumerated().map { index, year in
                Column(id: index, label: "\(year % 100)", showsLabel: true,
                       detail: "\(year)年", tokens: years[year] ?? 0, peak: false)
            }
        }
        return spans.enumerated().map { index, span in
            let month = cal.component(.month, from: span.date)
            return Column(id: index, label: "\(month)",
                          showsLabel: spans.count <= 12 || month == 1 || index == spans.count - 1,
                          detail: UsageStats.formatter("yyyy年M月").string(from: span.date),
                          tokens: span.tokens, peak: false)
        }
    }

    private var marked: [Column] {
        let rows = columns
        let peak = rows.map(\.tokens).max() ?? 0
        guard peak > 0 else { return rows }
        return rows.map { row in
            Column(id: row.id, label: row.label, showsLabel: row.showsLabel,
                   detail: row.detail, tokens: row.tokens, peak: row.tokens == peak)
        }
    }

    private var motionKey: String {
        let rows = columns
        return "\(period.rawValue)|\(rows.count)|\(rows.first?.detail ?? "")|\(rows.last?.detail ?? "")"
    }

    private static func key(_ date: Date) -> String { UsageHeatmap.dayKey(date) }

    private static func parse(_ day: String) -> Date? {
        UsageStats.formatter("yyyy-MM-dd").date(from: day)
    }

    /// What the axis is counting, written next to the title by the page.
    var grainCaption: String {
        switch period {
        case .day, .custom: return "这一周，按日"
        case .month: return "这个月，按日"
        case .year: return "这一年，按月"
        case .all: return columns.count <= 24 ? "全部，按月" : "全部，按年"
        }
    }

    var body: some View {
        let rows = marked
        let peak = max(rows.map(\.tokens).max() ?? 0, 1)
        let average = rows.isEmpty ? 0 : rows.reduce(0) { $0 + $1.tokens } / max(rows.count, 1)
        let peakRow = rows.first { $0.peak }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(grainCaption)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if let peakRow, peakRow.tokens > 0 {
                    Text("峰值 \(peakRow.detail) · \(UsageStats.formatTokens(peakRow.tokens))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.Ink.cursor)
                        .lineLimit(1)
                }
            }
            GeometryReader { geometry in
                let plot = max(geometry.size.height - 16, 1)
                let guide = plot * (1 - CGFloat(average) / CGFloat(peak))
                ZStack(alignment: .bottom) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: guide))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: guide))
                    }
                    .stroke(Theme.textTertiary().opacity(0.45),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .frame(height: plot, alignment: .top)
                    HStack(alignment: .bottom, spacing: rows.count > 16 ? 2 : 4) {
                        ForEach(rows) { row in
                            let h = row.tokens == 0
                                ? 3
                                : max(6, plot * CGFloat(row.tokens) / CGFloat(peak))
                            VStack(spacing: 4) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: rows.count > 20 ? 2 : 4, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [Theme.chartPurple.opacity(row.peak ? 1 : 0.85),
                                                 Theme.chartPurple.opacity(row.tokens == 0 ? 0.16 : 0.45)],
                                        startPoint: .top, endPoint: .bottom))
                                    .frame(height: h)
                                    .overlay(alignment: .top) {
                                        if row.peak {
                                            Circle().fill(Theme.cardSurface)
                                                .frame(width: 6, height: 6)
                                                .overlay(Circle().strokeBorder(Theme.chartPurple, lineWidth: 1.5))
                                                .offset(y: -3)
                                        }
                                    }
                                Text(row.showsLabel ? row.label : " ")
                                    .font(.system(size: 9, weight: hovered == row.id ? .semibold : .medium, design: .rounded))
                                    .foregroundStyle(hovered == row.id || row.peak ? Theme.textPrimary : Theme.textTertiary())
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
                            .help("\(row.detail)：\(UsageStats.formatTokens(row.tokens))")
                        }
                    }
                }
            }
            .frame(height: 132)
            Text("均值 \(UsageStats.formatTokens(average))")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary())
        }
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82), value: motionKey)
        .accessibilityLabel("\(grainCaption)，峰值 \(UsageStats.formatTokens(peak))，均值 \(UsageStats.formatTokens(average))")
    }
}
