#!/usr/bin/env python3
"""Local usage statistics and raincloud density through production value code.

Compiles the actual model declarations and UsageAnalysis in a temporary folder;
does not launch the app, read user records or access system integrations.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
models = (root / 'Sources/ClaudeBar/Models/ModelUsage.swift').read_text()


def declaration(marker):
    start = models.index(marker)
    opening = models.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (models[end] == '{') - (models[end] == '}')
        end += 1
    return models[start:end]


source = 'import Foundation\n' + '\n'.join(declaration(marker) for marker in [
    'enum UsagePeriod', 'struct DayUsage', 'struct ModelUsage'
])
source += '\n' + (root / 'Sources/ClaudeBar/Utils/UsageAnalysis.swift').read_text()
source += r'''
@main struct Regression {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        func date(_ day: String) -> Date { formatter.date(from: day)! }
        let october = DateInterval(start: date("2026-10-01"), end: date("2026-11-01"))

        // Dates merge before aggregation, missing elapsed dates count as zero,
        // and records after today cannot lengthen the selected time series.
        let days = [DayUsage(day: "2026-10-01", inputTokens: 10, outputTokens: 5, cacheReadTokens: 10, cacheCreationTokens: 5),
                    DayUsage(day: "2026-10-01", outputTokens: 20),
                    DayUsage(day: "2026-10-03", inputTokens: 100),
                    DayUsage(day: "2026-10-05", inputTokens: 999)]
        let stats = [ModelUsage(model: "a", inputTokens: 20, outputTokens: 10, cacheReadTokens: 30, cacheCreationTokens: 10),
                     ModelUsage(model: "a", outputTokens: 30),
                     ModelUsage(model: "b", inputTokens: 100), ModelUsage(model: "zero")]
        let a = UsageAnalysis(days: days, stats: stats, period: .month, interval: october,
                              now: date("2026-10-03"), calendar: calendar)
        precondition(a.daily.map(\.total) == [50, 0, 100])
        precondition(a.grain == "日" && a.activeDays == 2 && a.buckets.count == 3)
        precondition(a.median == 50 && a.p95 == 95 && a.bucketMedian == 50 && a.tokenScale == 75,
                     "Quantiles include elapsed zero days and interpolate adjacent observations")
        precondition(a.distribution.map(\.x) == [0, 50, 100])
        precondition(abs(a.distribution[0].y - 1.0 / 3) < 0.00001 && a.distribution.last!.y == 1)
        precondition(a.density.isEmpty && a.densityBandwidth == nil,
                     "Three actual observations cannot support a density estimate")
        precondition(a.bucketQ25 == 25 && a.bucketQ75 == 75)
        precondition(a.models.map(\.name) == ["a", "b"] && a.models.map(\.tokens) == [100, 100])
        precondition(a.total == 200 && a.temporalTotal == 150,
                     "Model records and dated records retain their own actual coverage")
        precondition(a.prompt == 160 && a.hitRate! == 30.0 / 160,
                     "Output is excluded from the cache-hit denominator")
        precondition(a.effectiveModels == 2 && a.lorenz[1].x == 0.5 && a.lorenz[1].y == 0.5)
        precondition(a.lorenz.last!.y == 1)

        // Empty dates and zero records differ: all observed zeros retain their
        // real frequency, while a future interval has no observations.
        let zero = UsageAnalysis(days: [], stats: [], period: .month, interval: october,
                                 now: date("2026-10-03"), calendar: calendar)
        precondition(zero.daily.count == 3 && zero.daily.allSatisfy { $0.total == 0 })
        precondition(zero.hitRate == nil && zero.tokenScale == 1 && zero.distribution[0].y == 1)
        precondition(zero.density.isEmpty && zero.densityMaximum == 0 && zero.densityBandwidth == nil)
        precondition(zero.effectiveModels == 0 && zero.lorenz.count == 1)
        let future = UsageAnalysis(days: days, stats: stats, period: .month,
                                   interval: DateInterval(start: date("2026-11-01"), end: date("2026-12-01")),
                                   now: date("2026-10-03"), calendar: calendar)
        precondition(future.daily.isEmpty && future.distribution.isEmpty && future.density.isEmpty)

        func observed(_ values: [Int]) -> UsageAnalysis {
            let first = date("2026-09-01")
            let rows = values.enumerated().map { index, value in
                DayUsage(day: formatter.string(from: calendar.date(byAdding: .day, value: index, to: first)!),
                         inputTokens: value)
            }
            let last = calendar.date(byAdding: .day, value: values.count - 1, to: first)!
            let end = calendar.date(byAdding: .day, value: 1, to: last)!
            return UsageAnalysis(days: rows, stats: [], period: .custom,
                                 interval: DateInterval(start: first, end: end), now: last, calendar: calendar)
        }
        let single = observed([900])
        precondition(single.density.isEmpty && single.densityBandwidth == nil && single.distribution[0].x == 900)
        precondition(single.bucketQ25 == 900 && single.bucketQ75 == 900)
        let repeated = observed([25, 25, 25, 25, 25, 25])
        precondition(repeated.density.isEmpty && repeated.densityBandwidth == nil)
        precondition(repeated.distribution.count == 1 && repeated.distribution[0].y == 1)

        // The estimate requires both enough buckets and enough distinct values.
        precondition(observed([0, 10, 20, 30]).density.isEmpty)
        let sparse = observed([0, 0, 0, 0, 0, 6_000_000_000])
        precondition(sparse.density.isEmpty && sparse.distribution.count == 2,
                     "Repeated zeros and one extreme value cannot fabricate a smooth distribution")
        let boundary = observed([0, 10, 20, 30, 40])
        precondition(boundary.density.count == 96 && boundary.densityBandwidth! > 0)
        precondition(boundary.densityLower == 0 && boundary.densityUpper > 40)
        precondition(boundary.density.first!.x == 0 && boundary.density.first!.y > 0,
                     "Reflection retains true zero observations without extending below zero")
        precondition(boundary.density.last!.x == boundary.densityUpper)
        precondition(boundary.density.allSatisfy { $0.x >= 0 && $0.y.isFinite && $0.y >= 0 })
        precondition(boundary.densityMaximum == boundary.density.map(\.y).max()!)
        let mass = zip(boundary.density, boundary.density.dropFirst()).reduce(0.0) {
            $0 + ($1.1.x - $1.0.x) * ($1.0.y + $1.1.y) / 2
        }
        precondition(abs(mass - 1) < 0.005, "Reflected Gaussian density conserves probability mass")
        let shifted = observed([1_000, 1_010, 1_020, 1_030, 1_040])
        precondition(shifted.densityLower > 0 && shifted.densityUpper > 1_040)
        precondition(shifted.bucketQ25 == 1_010 && shifted.bucketQ75 == 1_030)
        let large = observed([0, 100_000_000, 200_000_000, 300_000_000, 6_000_000_000])
        precondition(large.density.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        precondition(large.densityMaximum > 0 && large.densityBandwidth! > 0)
        let repeatedZeros = observed([0, 0, 0, 0, 0, 0, 0, 10, 20])
        precondition(repeatedZeros.bucketQ25 == 0 && repeatedZeros.bucketQ75 == 0)
        precondition(repeatedZeros.density.count == 96 && repeatedZeros.densityBandwidth! > 0,
                     "A zero IQR falls back to sample deviation without losing repeated zero observations")
        precondition(repeatedZeros.buckets.count == 9 && repeatedZeros.distribution[0].y == 7.0 / 9)

        // Time-grain decisions also apply to raincloud observations: a year
        // measures monthly buckets, and >730 elapsed days measure years.
        let year = UsageAnalysis(days: days, stats: stats, period: .year,
                                 interval: DateInterval(start: date("2026-01-01"), end: date("2027-01-01")),
                                 now: date("2026-10-03"), calendar: calendar)
        precondition(year.grain == "月" && year.buckets.count == 10 && year.buckets.last!.total == 150)
        precondition(year.density.isEmpty, "Only two different monthly values do not support KDE")
        let all = UsageAnalysis(days: [DayUsage(day: "2024-09-30", inputTokens: 1),
                                      DayUsage(day: "2026-10-01", inputTokens: 7)], stats: [], period: .all,
                                interval: DateInterval(start: date("2020-01-01"), end: date("2026-11-01")),
                                now: date("2026-10-01"), calendar: calendar)
        precondition(all.daily.count > 730 && all.grain == "年" && all.buckets.count == 3)
        precondition(all.density.isEmpty, "Three yearly observations are too few for KDE")
        precondition(all.calendarRows.count == 366 && all.calendarMaximum == 7 && all.temporalTotal == 8)
        precondition(UsageAnalysis.quantile([], fraction: 0.95) == 0 && UsageAnalysis.quantile([9], fraction: 0.95) == 9)
        precondition(UsageAnalysis.share(1, of: 10_000) == "<0.1%" && UsageAnalysis.share(0, of: 0) == "0%")
        print("PASS: production usage dates, totals, quantiles, cache rates, ECDF/Lorenz, time grains, calendar truncation and raincloud density eligibility/boundaries/mass")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-usage-analysis-tests-') as folder:
    swift = Path(folder) / 'Regression.swift'
    swift.write_text(source)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
