import SwiftUI

/// Compact CC / Codex / 第三方 share — three vertical meters, not a VPN gauge.
///
/// Each meter is a single `LinearGradient` fill rather than a flat one: the
/// reference bar card's bars are lit from the top, and at this height (6–52pt)
/// a flat fill reads as a rectangle while a 20 % vertical falloff reads as a
/// quantity. One fill either way — no extra layers, no extra cost.
struct SourceTriad: View {
    let totals: [(source: UsageSource, tokens: Int)]

    /// Share of the period's *total*, not of the largest source.
    ///
    /// Normalising against the peak pinned the leading source to the full 52pt
    /// in every period, so a 99 / 0.5 / 0.5 split and a 45 / 30 / 25 split drew
    /// identical meters — the one comparison the triad exists to make. Scaling
    /// by the sum keeps the height a fraction of the whole, and a period with a
    /// single source still fills the meter.
    private var total: Int { max(totals.reduce(0) { $0 + $1.tokens }, 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(totals, id: \.source) { row in
                let h = CGFloat(row.tokens) / CGFloat(total)
                VStack(spacing: 4) {
                    RollingNumberText(UsageStats.formatTokens(row.tokens))
                        .font(Theme.Font.microMono)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LinearGradient(colors: [row.source.color.opacity(row.tokens > 0 ? 1 : 0.28),
                                                      row.source.color.opacity(row.tokens > 0 ? 0.62 : 0.14)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: max(6, 52 * h))
                    Text(row.source.shortLabel)
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 86)
        .accessibilityLabel("来源用量")
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

/// Seven period buckets with an average guide and hoverable daily totals.
///
/// The bars keep the reference chart's own two-stop gradient and its `top` cap
/// dot, but the hover *scales* the bar rather than re-tinting it: a bar whose
/// colour changes under the pointer reads as a different series, while a 7 %
/// scale reads as "this is the one you are on" without touching the encoding.
struct UsageDaySpark: View {
    let days: [DayUsage]
    /// The period the page is on. The buckets describe *the period*, so the
    /// span has to come from the calendar interval the data was queried with,
    /// not from the data that came back — see `buckets`.
    let interval: DateInterval
    @State private var hoveredBucket: Int?

    private struct Bucket: Identifiable {
        let id: Int
        let label: String
        let range: String
        let tokens: Int
    }

    /// Seven equal *calendar* spans of the period, labelled by the bucket's own
    /// end date.
    ///
    /// This used to chunk the days that actually had data (`index *
    /// ordered.count / count`), so the label was the last day present in each
    /// chunk: a sparse month produced labels like "25 25 22 22 22 13 13", which
    /// name a bucket by whatever happened to be in it rather than by the date
    /// it covers. Splitting the calendar instead gives one label per span, and
    /// empty spans read as zero bars — which is information, not noise.
    ///
    /// The span comes from `interval` rather than from `days.first`/`days.last`
    /// for the reason above: a month whose only activity is today returns one
    /// row, and deriving the span from the data collapsed all seven buckets
    /// onto that single day — six zero bars and seven axis labels reading the
    /// same date, under a header saying "2026年9月".
    private var buckets: [Bucket] {
        guard !days.isEmpty else { return [] }
        let totals = Dictionary(days.map { ($0.day, $0.totalTokens) }, uniquingKeysWith: +)
        let cal = Calendar.current
        // Buckets end on the period's last day, inclusive.
        let end = cal.startOfDay(for: interval.end.addingTimeInterval(-1))
        let start = cal.startOfDay(for: interval.start)
        let spanDays = max(1, (cal.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
        let count = 7
        let per = max(1, Int((Double(spanDays) / Double(count)).rounded(.up)))
        return (0..<count).map { index in
            let bucketEnd = cal.date(byAdding: .day, value: -(count - 1 - index) * per, to: end) ?? end
            let bucketStart = cal.date(byAdding: .day, value: -(per - 1), to: bucketEnd) ?? bucketEnd
            var tokens = 0
            for offset in 0..<per {
                if let day = cal.date(byAdding: .day, value: offset, to: bucketStart) {
                    tokens += totals[Self.key(day)] ?? 0
                }
            }
            let first = Self.key(bucketStart), last = Self.key(bucketEnd)
            return Bucket(id: index, label: String(last.suffix(2)),
                          range: first == last ? first : "\(first) – \(last)",
                          tokens: tokens)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func key(_ date: Date) -> String { dayFormatter.string(from: date) }

    var body: some View {
        let rows = buckets
        let peak = max(rows.map(\.tokens).max() ?? 0, 1)
        let average = rows.isEmpty ? 0 : rows.reduce(0) { $0 + $1.tokens } / rows.count
        return GeometryReader { geometry in
            let barHeight = max(geometry.size.height - 31, 1)
            let guideY = barHeight * (1 - CGFloat(average) / CGFloat(peak))
            ZStack(alignment: .topTrailing) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: guideY))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: guideY))
                }
                .stroke(Theme.textTertiary().opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(height: barHeight)

                HStack(alignment: .bottom, spacing: 9) {
                    ForEach(rows) { row in
                        VStack(spacing: 6) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(LinearGradient(colors: [Color(red: 1, green: 0.37, blue: 0.49),
                                                              Color(red: 1, green: 0.62, blue: 0.66)],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(maxWidth: 30)
                                .frame(height: max(6, barHeight * CGFloat(row.tokens) / CGFloat(peak)))
                                .overlay(alignment: .top) {
                                    Circle().fill(Theme.cardSurface)
                                        .frame(width: 7, height: 7)
                                        .overlay(Circle().strokeBorder(Color(red: 1, green: 0.37, blue: 0.49), lineWidth: 1.5))
                                        .offset(y: -3)
                                }
                                .scaleEffect(hoveredBucket == row.id ? 1.07 : 1)
                            Text(row.label)
                                .font(Theme.Font.micro)
                                .foregroundStyle(hoveredBucket == row.id ? Theme.textPrimary : Theme.textTertiary())
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onHover { hoveredBucket = $0 ? row.id : nil }
                        .help("\(row.range)：\(UsageStats.formatTokens(row.tokens)) Token")
                    }
                }
                Text("均值 \(UsageStats.formatTokens(average))")
                    .font(Theme.Font.microSemibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.textPrimary, in: RoundedRectangle(cornerRadius: 5))
                    // `ZStack(alignment: .topTrailing)` puts the badge's top at
                    // the guide's y only if the stack is the full height; the
                    // guide is inside a `.frame(height: barHeight)`, which the
                    // stack centres, so subtracting the badge height alone put
                    // the badge ~15pt above its own dashed line.
                    .offset(y: max(0, (geometry.size.height - barHeight) / 2 + guideY - 18))
            }
        }
        .frame(height: 108)
        .accessibilityLabel("每日 Token 分布，平均 \(UsageStats.formatTokens(average))")
    }
}
