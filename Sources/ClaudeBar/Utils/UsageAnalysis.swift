import Foundation

/// Pure analysis of local records. Empty elapsed dates remain zero; future
/// dates are excluded. No inferred hourly usage, savings or billing history.
struct UsageAnalysis {
    struct Bucket: Identifiable {
        let date: Date
        let end: Date
        let label: String
        let total: Int
        let input: Int
        let write: Int
        let output: Int
        let prompt: Int
        let hit: Int
        var id: Date { date }
        var hitRate: Double? { prompt > 0 ? Double(hit) / Double(prompt) : nil }
    }
    struct Model: Identifiable {
        let name: String
        let tokens: Int
        var id: String { name }
    }
    let daily: [Bucket]
    let buckets: [Bucket]
    let models: [Model]
    let input: Int
    let hit: Int
    let write: Int
    let output: Int
    let grain: String
    var total: Int { input + hit + write + output }
    var prompt: Int { input + hit + write }
    var hitRate: Double? { prompt > 0 ? Double(hit) / Double(prompt) : nil }
    struct CurvePoint: Identifiable {
        let x: Double
        let y: Double
        var id: Double { x }
    }
    let distribution: [CurvePoint]
    let lorenz: [CurvePoint]
    let effectiveModels: Double
    let tokenScale: Double
    let activeDays: Int
    let median: Double
    let p95: Double
    let bucketMaximum: Int
    let bucketMinimumPositive: Int?
    let bucketMedian: Double
    let peak: Bucket?
    let temporalTotal: Int
    let calendarRows: [Bucket]
    let calendarMaximum: Int
    init(days: [DayUsage], stats: [ModelUsage], period: UsagePeriod,
         interval: DateInterval, now: Date = Date(), calendar: Calendar = .current) {
        var parts = [0, 0, 0, 0]
        var modelTotals: [String: Int] = [:]
        for stat in stats {
            parts[0] += stat.inputTokens; parts[1] += stat.cacheReadTokens
            parts[2] += stat.cacheCreationTokens; parts[3] += stat.outputTokens
            modelTotals[stat.model, default: 0] += stat.totalTokens
        }
        input = parts[0]; hit = parts[1]; write = parts[2]; output = parts[3]
        models = modelTotals.map { Model(name: $0.key, tokens: $0.value) }
            .filter { $0.tokens > 0 }.sorted { $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone; parser.dateFormat = "yyyy-MM-dd"
        var records: [Date: (total: Int, input: Int, write: Int, output: Int, prompt: Int, hit: Int)] = [:]
        for day in days {
            guard let date = parser.date(from: day.day) else { continue }
            let key = calendar.startOfDay(for: date)
            let old = records[key] ?? (0, 0, 0, 0, 0, 0)
            records[key] = (old.total + day.totalTokens, old.input + day.inputTokens, old.write + day.cacheCreationTokens, old.output + day.outputTokens,
                            old.prompt + day.inputTokens + day.cacheReadTokens + day.cacheCreationTokens,
                            old.hit + day.cacheReadTokens)
        }
        let start = period == .all ? (records.keys.min() ?? calendar.startOfDay(for: now)) : interval.start
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let end = min(interval.end, tomorrow)
        var cursor = calendar.startOfDay(for: start)
        var rows: [Bucket] = []
        while cursor < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            let values = records[cursor] ?? (0, 0, 0, 0, 0, 0)
            rows.append(Bucket(date: cursor, end: next,
                               label: "\(calendar.component(.month, from: cursor))/\(calendar.component(.day, from: cursor))",
                               total: values.total, input: values.input, write: values.write, output: values.output, prompt: values.prompt, hit: values.hit))
            cursor = next
        }
        daily = rows
        let monthly = period == .year || period == .all
        let yearly = period == .all && rows.count > 730
        grain = yearly ? "年" : monthly ? "月" : "日"
        if monthly {
            var grouped: [Date: (total: Int, input: Int, write: Int, output: Int, prompt: Int, hit: Int)] = [:]
            for row in rows {
                let unit: Calendar.Component = yearly ? .year : .month
                let date = calendar.dateInterval(of: unit, for: row.date)?.start ?? row.date
                let old = grouped[date] ?? (0, 0, 0, 0, 0, 0)
                grouped[date] = (old.total + row.total, old.input + row.input, old.write + row.write, old.output + row.output, old.prompt + row.prompt, old.hit + row.hit)
            }
            buckets = grouped.keys.sorted().map { date in
                let values = grouped[date]!
                let next = calendar.date(byAdding: yearly ? .year : .month, value: 1, to: date) ?? date
                let label = yearly ? "\(calendar.component(.year, from: date))" : "\(calendar.component(.month, from: date))月"
                return Bucket(date: date, end: min(next, end), label: label, total: values.total, input: values.input, write: values.write, output: values.output, prompt: values.prompt, hit: values.hit)
            }
        } else { buckets = rows }
        activeDays = rows.filter { $0.total > 0 }.count
        median = Self.quantile(rows.map { Double($0.total) }, fraction: 0.5)
        p95 = Self.quantile(rows.map { Double($0.total) }, fraction: 0.95)
        bucketMedian = Self.quantile(buckets.map { Double($0.total) }, fraction: 0.5)
        bucketMaximum = buckets.map(\.total).max() ?? 0
        bucketMinimumPositive = buckets.map(\.total).filter { $0 > 0 }.min()
        let ordered = buckets.map(\.total).sorted()
        tokenScale = max(1, Self.quantile(ordered.filter { $0 > 0 }.map(Double.init), fraction: 0.5))
        var empirical: [CurvePoint] = []
        for (index, value) in ordered.enumerated() {
            if index + 1 == ordered.count || ordered[index + 1] != value {
                empirical.append(CurvePoint(x: Double(value), y: Double(index + 1) / Double(ordered.count)))
            }
        }
        distribution = empirical
        let ascending = models.map(\.tokens).sorted()
        let modelSum = ascending.reduce(0, +)
        var concentration = [CurvePoint(x: 0, y: 0)]
        var cumulative = 0
        var squaredShares = 0.0
        for (index, value) in ascending.enumerated() {
            cumulative += value
            concentration.append(CurvePoint(x: Double(index + 1) / Double(ascending.count), y: Double(cumulative) / Double(modelSum)))
            squaredShares += pow(Double(value) / Double(modelSum), 2)
        }
        lorenz = concentration
        effectiveModels = squaredShares > 0 ? 1 / squaredShares : 0
        peak = rows.max { $0.total < $1.total }
        temporalTotal = rows.reduce(0) { $0 + $1.total }
        calendarRows = Array(rows.suffix(366))
        calendarMaximum = calendarRows.map(\.total).max() ?? 0
    }

    static func quantile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(max(fraction, 0), 1) * Double(sorted.count - 1)
        let low = Int(index), high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (index - Double(low))
    }

    static func share(_ value: Int, of total: Int) -> String {
        guard total > 0, value > 0 else { return "0%" }
        let percent = Double(value) / Double(total) * 100
        return percent < 0.1 ? "<0.1%" : String(format: "%.1f%%", percent)
    }
}
