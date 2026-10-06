#!/usr/bin/env python3
"""The solar-term calendar against the Hong Kong Observatory tables.

Compiles the production `SolarTerm` value type; no app, stores or network. The
expected dates are transcribed from the HKO Gregorian-lunar conversion tables
(the same independent source the festival fixtures cite), one row per term in
`allCases` order, China Standard Time.

https://www.hko.gov.hk/en/gts/time/calendar/text/files/T2026e.txt
https://www.hko.gov.hk/en/gts/time/calendar/text/files/T2027e.txt
https://www.hko.gov.hk/en/gts/time/calendar/text/files/T2028e.txt
https://www.hko.gov.hk/en/gts/time/calendar/text/files/T2029e.txt
https://www.hko.gov.hk/en/gts/time/calendar/text/files/T2030e.txt
https://www.hko.gov.hk/en/gts/time/calendar/text/files/T2031e.txt
… through T2036e.txt (the same series; fetched through the project proxy).
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Utils/SolarTerm.swift').read_text()
source += r'''
@main struct Regression {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: String) -> Date {
            let parts = day.split(separator: "-").map { Int($0)! }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
        }
        func require(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
        }
        // HKO dates, one row per year in `allCases` order (小寒 … 冬至).
        let published: [Int: [(Int, Int)]] = [
            2026: [(1,5),(1,20),(2,4),(2,18),(3,5),(3,20),(4,5),(4,20),(5,5),(5,21),(6,5),(6,21),(7,7),(7,23),(8,7),(8,23),(9,7),(9,23),(10,8),(10,23),(11,7),(11,22),(12,7),(12,22)],
            2027: [(1,5),(1,20),(2,4),(2,19),(3,6),(3,21),(4,5),(4,20),(5,6),(5,21),(6,6),(6,21),(7,7),(7,23),(8,8),(8,23),(9,8),(9,23),(10,8),(10,23),(11,7),(11,22),(12,7),(12,22)],
            2028: [(1,6),(1,20),(2,4),(2,19),(3,5),(3,20),(4,4),(4,19),(5,5),(5,20),(6,5),(6,21),(7,6),(7,22),(8,7),(8,22),(9,7),(9,22),(10,8),(10,23),(11,7),(11,22),(12,6),(12,21)],
            2029: [(1,5),(1,20),(2,3),(2,18),(3,5),(3,20),(4,4),(4,20),(5,5),(5,21),(6,5),(6,21),(7,7),(7,22),(8,7),(8,23),(9,7),(9,23),(10,8),(10,23),(11,7),(11,22),(12,7),(12,21)],
            2030: [(1,5),(1,20),(2,4),(2,18),(3,5),(3,20),(4,5),(4,20),(5,5),(5,21),(6,5),(6,21),(7,7),(7,23),(8,7),(8,23),(9,7),(9,23),(10,8),(10,23),(11,7),(11,22),(12,7),(12,22)],
            2031: [(1,5),(1,20),(2,4),(2,19),(3,6),(3,21),(4,5),(4,20),(5,6),(5,21),(6,6),(6,21),(7,7),(7,23),(8,8),(8,23),(9,8),(9,23),(10,8),(10,23),(11,7),(11,22),(12,7),(12,22)],
            2032: [(1,6),(1,20),(2,4),(2,19),(3,5),(3,20),(4,4),(4,19),(5,5),(5,20),(6,5),(6,21),(7,6),(7,22),(8,7),(8,22),(9,7),(9,22),(10,8),(10,23),(11,7),(11,22),(12,6),(12,21)],
            2033: [(1,5),(1,20),(2,3),(2,18),(3,5),(3,20),(4,4),(4,20),(5,5),(5,21),(6,5),(6,21),(7,7),(7,22),(8,7),(8,23),(9,7),(9,23),(10,8),(10,23),(11,7),(11,22),(12,7),(12,21)],
            2034: [(1,5),(1,20),(2,4),(2,18),(3,5),(3,20),(4,5),(4,20),(5,5),(5,21),(6,5),(6,21),(7,7),(7,23),(8,7),(8,23),(9,7),(9,23),(10,8),(10,23),(11,7),(11,22),(12,7),(12,22)],
            2035: [(1,5),(1,20),(2,4),(2,19),(3,6),(3,21),(4,5),(4,20),(5,5),(5,21),(6,6),(6,21),(7,7),(7,23),(8,7),(8,23),(9,8),(9,23),(10,8),(10,23),(11,7),(11,22),(12,7),(12,22)],
            2036: [(1,6),(1,20),(2,4),(2,19),(3,5),(3,20),(4,4),(4,19),(5,5),(5,20),(6,5),(6,21),(7,6),(7,22),(8,7),(8,22),(9,7),(9,22),(10,8),(10,23),(11,7),(11,22),(12,6),(12,21)],
        ]
        var termDays = 0
        for (year, rows) in published.sorted(by: { $0.key < $1.key }) {
            require(rows.count == SolarTerm.allCases.count, "One HKO date per term")
            for (index, entry) in rows.enumerated() {
                let term = SolarTerm(rawValue: index)!
                let day = date(String(format: "%04d-%02d-%02d", year, entry.0, entry.1))
                require(SolarTerm.term(on: day, calendar: calendar) == term,
                        "\(term.chineseName) \(year)-\(entry.0)-\(entry.1)")
                termDays += 1
                // The day before and after are ordinary days, never a second
                // reading of the same term.
                let before = calendar.date(byAdding: .day, value: -1, to: day)!
                require(SolarTerm.term(on: before, calendar: calendar) != term,
                        "\(term.chineseName) must not repeat one day before")
            }
        }
        require(termDays == 24 * published.count, "Every HKO term day is exercised")
        // 立春 / 立夏 / 立秋 / 立冬 open a season, in both directions.
        let seasonChecks: [(String, SolarTerm.Season)] = [
            ("2026-02-03", .winter), ("2026-02-04", .spring), ("2026-04-30", .spring),
            ("2026-05-05", .summer), ("2026-07-31", .summer),
            ("2026-08-07", .autumn), ("2026-11-06", .autumn),
            ("2026-11-07", .winter), ("2026-12-31", .winter), ("2026-01-01", .winter),
        ]
        for (day, season) in seasonChecks {
            require(SolarTerm.season(on: date(day), calendar: calendar) == season,
                    "Season for \(day)")
        }
        // Names and season membership stay aligned with the raw ordering.
        require(SolarTerm.springBegins.chineseName == "立春" && SolarTerm.springBegins.season == .spring,
                "立春 opens spring")
        require(SolarTerm.winterSolstice.chineseName == "冬至" && SolarTerm.minorCold.season == .winter,
                "Winter runs 立冬 … 大寒")
        // The window now reaches 2036; 2033-02-03 is 立春 on the HKO table and
        // must read as the term (reusing the 2030 row used to answer nothing
        // here — 2033's crossing is a day earlier than 2030's).
        require(SolarTerm.term(on: date("2033-02-03"), calendar: calendar) == .springBegins,
                "2033's 立春 is Feb 3, not the 2030 row's Feb 4")
        // Past the window the nearest published year is reused rather than
        // inventing a date; a term day still reads as that term.
        let beyond = date("2037-02-04")
        require(SolarTerm.term(on: beyond, calendar: calendar) == .springBegins,
                "Outside the table the nearest published year is reused")
        // Every term carries at least one line in each language, and the
        // Chinese lines stay within the card's headline budget.
        for term in SolarTerm.allCases {
            require(!term.chineseVerses.isEmpty && !term.englishVerses.isEmpty,
                    "Every term needs a line in both languages")
            for (script, aside) in term.chineseVerses {
                require(script.count <= 10, "Chinese term line too long: \(script)")
                require(!aside.isEmpty, "Chinese term line needs a source: \(script)")
            }
            for (script, aside) in term.englishVerses {
                require(script.unicodeScalars.allSatisfy { $0.isASCII }, "English term line must be ASCII")
                require(!aside.isEmpty, "English term line needs a note: \(script)")
            }
        }
        for season in SolarTerm.Season.allCases {
            for daylight in [SolarTerm.Season.Daylight.night, .dawn, .day] {
                for chinese in [true, false] {
                    let lines = season.verses(chinese: chinese, daylight: daylight)
                    require(!lines.isEmpty, "Every season/daylight/chinese combination needs a line")
                    if chinese {
                        for (script, _) in lines {
                            require(script.count <= 10, "Chinese season line too long: \(script)")
                        }
                    } else {
                        for (script, _) in lines {
                            require(script.unicodeScalars.allSatisfy { $0.isASCII }, "English season line must be ASCII")
                        }
                    }
                }
            }
        }
        print("PASS: HKO solar-term dates 2026-2036, season boundaries, out-of-range reuse")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-solar-term-') as tmp:
    path = Path(tmp) / 'Regression.swift'
    path.write_text(source)
    binary = Path(tmp) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macos15.0', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
