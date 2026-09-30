#!/usr/bin/env python3
"""Exercise the production analytics and record models, without app startup."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
models = (root / 'Sources/ClaudeBar/Models/ModelUsage.swift').read_text()
models = models[models.index('enum UsagePeriod:'):models.index('/// Today\'s totals')]
analysis = (root / 'Sources/ClaudeBar/Utils/UsageAnalysis.swift').read_text()
driver = r'''
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(secondsFromGMT: 0)!
func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    cal.date(from: DateComponents(year: year, month: month, day: day))!
}
let stats = [ModelUsage(model: "a", inputTokens: 40, outputTokens: 10, cacheReadTokens: 30, cacheCreationTokens: 20),
             ModelUsage(model: "a", inputTokens: 10), ModelUsage(model: "b", inputTokens: 5)]
let records = [DayUsage(day: "2026-09-01", inputTokens: 10),
               DayUsage(day: "2026-09-01", inputTokens: 20, cacheReadTokens: 30),
               DayUsage(day: "2026-09-03", inputTokens: 90)]
let interval = DateInterval(start: date(2026,9,1), end: date(2026,10,1))
let a = UsageAnalysis(days: records, stats: stats, period: .month, interval: interval,
                      now: date(2026,9,4), calendar: cal)
precondition(a.daily.count == 4, "future dates must not dilute statistics")
precondition(a.activeDays == 2 && a.daily[1].total == 0, "empty elapsed dates must remain")
precondition(a.buckets.allSatisfy { $0.input + $0.hit + $0.write + $0.output == $0.total && $0.input + $0.hit + $0.write == $0.prompt })
precondition(a.daily[0].total == 60, "duplicate day records aggregate")
precondition(a.median == 30 && abs(a.p95 - 85.5) < 0.001, "quantiles interpolate, including zero dates")
precondition(a.models.count == 2 && a.models[0].tokens == 110, "duplicate models merge")
precondition(abs(a.hitRate! - 30.0/105.0) < 0.0001, "prompt denominator excludes output")
precondition(a.buckets.count == 4, "monthly view uses daily buckets")
let single = UsageAnalysis(days: [records[0]], stats: stats, period: .day,
                          interval: DateInterval(start: date(2026,9,1), end: date(2026,9,2)),
                          now: date(2026,9,4), calendar: cal)
precondition(single.buckets.count == 1, "day must not manufacture a week")
let empty = UsageAnalysis(days: [], stats: [], period: .month, interval: interval,
                          now: date(2026,9,4), calendar: cal)
precondition(empty.total == 0 && empty.hitRate == nil && empty.p95 == 0)
let future = UsageAnalysis(days: [], stats: [], period: .month,
    interval: DateInterval(start: date(2027,1,1), end: date(2027,2,1)), now: date(2026,9,4), calendar: cal)
precondition(future.daily.isEmpty)
let year = UsageAnalysis(days: records, stats: stats, period: .year,
    interval: DateInterval(start: date(2026,1,1), end: date(2027,1,1)), now: date(2026,9,4), calendar: cal)
precondition(year.buckets.count == 9 && year.grain == "月")
let leap = UsageAnalysis(days: [], stats: [], period: .month,
    interval: DateInterval(start: date(2024,2,1), end: date(2024,3,1)), now: date(2026,9,4), calendar: cal)
precondition(leap.daily.count == 29)
precondition(UsageAnalysis.share(1, of: 10000) == "<0.1%")
precondition(UsageAnalysis.share(1, of: 100) == "1.0%")
precondition(UsageAnalysis.quantile([], fraction: 0.5) == 0)
let history = UsageAnalysis(days: [DayUsage(day: "2022-01-01", inputTokens: 1000), DayUsage(day: "2026-09-01", inputTokens: 10)], stats: [], period: .all,
    interval: DateInterval(start: date(2020,1,1), end: date(2027,1,1)), now: date(2026,9,4), calendar: cal)
precondition(history.grain == "年" && history.buckets.count == 5)
precondition(history.calendarRows.count == 366 && history.calendarMaximum == 10, "calendar legend follows visible dates")
cal.timeZone = TimeZone(identifier: "America/New_York")!
let dst = UsageAnalysis(days: [DayUsage(day: "2026-03-08", inputTokens: 10)], stats: [], period: .month,
    interval: DateInterval(start: date(2026,3,1), end: date(2026,4,1)), now: date(2026,4,2), calendar: cal)
precondition(dst.daily.count == 31 && dst.daily[7].total == 10)
precondition(dst.daily[7].end.timeIntervalSince(dst.daily[7].date) == 23 * 3600, "DST uses calendar days")
precondition(a.distribution.count == 3 && a.distribution[0].x == 0 && a.distribution[0].y == 0.5, "CDF ties include zero dates")
precondition(a.distribution.last!.y == 1)
precondition(empty.distribution.count == 1 && empty.distribution[0].y == 1)
precondition(future.distribution.isEmpty && future.effectiveModels == 0)
precondition(a.lorenz.first!.x == 0 && a.lorenz.last!.y == 1)
precondition(a.lorenz.allSatisfy { $0.y <= $0.x + 0.00001 }, "Lorenz is ascending and below equality")
let equal = UsageAnalysis(days: [], stats: [ModelUsage(model: "a", inputTokens: 10), ModelUsage(model: "b", inputTokens: 10)], period: .day, interval: interval, now: date(2026,9,4), calendar: cal)
precondition(abs(equal.effectiveModels - 2) < 0.0001 && equal.lorenz[1].x == equal.lorenz[1].y)
precondition(abs(a.effectiveModels - 1 / (pow(110.0 / 115, 2) + pow(5.0 / 115, 2))) < 0.00001)
print("usage analysis OK · calendar gaps, quantiles, prompt denominator, period grains")
'''
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / 'main.swift'
    source.write_text('import Foundation\n' + models + '\n' + analysis + '\n' + driver)
    binary = Path(tmp) / 'checks'
    subprocess.run(['swiftc', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
