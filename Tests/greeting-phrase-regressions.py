#!/usr/bin/env python3
"""Date-aware greetings through production value code; no app, stores or network."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Utils/GreetingPhrase.swift').read_text()
source += r'''
@main struct Regression {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: String, _ hour: Int = 12) -> Date {
            let parts = day.split(separator: "-").map { Int($0)! }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
        }
        func require(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
        }
        // Independently dated fixtures: Hong Kong Observatory conversion tables.
        // https://www.hko.gov.hk/en/gts/time/calendar/pdf/files/2028e.pdf
        // https://www.hko.gov.hk/en/gts/time/calendar/pdf/files/2029e.pdf
        for (day, name) in [
            ("2026-02-16", "除夕快乐"), ("2026-02-17", "新春快乐"),
            ("2026-03-03", "元宵快乐"), ("2026-06-19", "端午安康"),
            ("2026-09-25", "中秋快乐"), ("2027-02-06", "新春快乐"),
            ("2028-01-26", "新春快乐"), ("2029-02-13", "新春快乐"),
            ("2026-05-10", "母亲节快乐"), ("2027-05-09", "母亲节快乐"),
            ("2026-06-21", "父亲节快乐"), ("2027-06-20", "父亲节快乐"),
            ("2026-10-01", "国庆快乐")
        ] {
            require(GreetingPhrase.holiday(on: date(day), calendar: calendar)?.name == name, "Wrong holiday: \(day)")
        }
        require(GreetingPhrase.holiday(on: date("2028-06-27"), calendar: calendar) == nil,
                "Leap fifth month must not repeat Dragon Boat Festival")
        for day in ["2026-05-12", "2027-06-21"] {
            require(GreetingPhrase.holiday(on: date(day), calendar: calendar) == nil, "Parent holidays must not use a fixed day")
        }
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = date("2026-10-01", 0)
        require(GreetingPhrase.holiday(on: midnight, calendar: calendar)?.name == "国庆快乐", "Local midnight holiday")
        require(GreetingPhrase.holiday(on: midnight, calendar: utc) == nil, "Date must follow supplied timezone")
        let baseline = date("2026-09-28", 9)
        let stable = GreetingPhrase.forDate(baseline, calendar: calendar)
        for offset in 0..<60 {
            require(GreetingPhrase.forDate(baseline.addingTimeInterval(Double(offset)), calendar: calendar) == stable,
                    "A greeting must not change with seconds or redraws")
        }
        for language in GreetingPhrase.Language.allCases {
            require(GreetingPhrase.resolve(.automatic, date: baseline, calendar: calendar, language: language)
                    == GreetingPhrase.forDate(baseline, calendar: calendar, language: language),
                    "Automatic preserves the contextual selection")
            for selection in GreetingPhrase.Selection.allCases where selection != .automatic && selection != .custom {
                let fixed = GreetingPhrase.resolve(selection, date: baseline, calendar: calendar, language: language)
                require(!fixed.script.isEmpty, "Every selectable greeting needs text")
                if selection != .monthly {
                    require(fixed == GreetingPhrase.resolve(selection, date: date("2026-10-01", 23),
                            calendar: calendar, language: language), "Fixed greetings must override dates/holidays")
                }
            }
        }
        require(GreetingPhrase.resolve(.monthly, date: date("2026-10-01"), calendar: calendar,
                language: .english).script == "Hello, October", "Month follows the supplied local calendar")
        require(GreetingPhrase.resolve(.custom, custom: "  Hello\nWorld  ", date: baseline).script == "Hello World",
                "Custom greetings normalize lines without changing authored case")
        require(GreetingPhrase.resolve(.custom, custom: String(repeating: "字", count: 100), date: baseline).script.count == 80,
                "Custom greetings remain bounded even with old stored values")
        require(GreetingPhrase.resolve(.custom, custom: " \n ", date: baseline, calendar: calendar) == stable,
                "Empty custom text returns to automatic")
        var varied: Set<String> = []
        for offset in 0..<60 {
            let next = calendar.date(byAdding: .day, value: offset, to: baseline)!
            let phrase = GreetingPhrase.forDate(next, calendar: calendar)
            require(!phrase.script.isEmpty && !(phrase.aside ?? "").isEmpty, "Every greeting needs a complete warm line")
            require(phrase.script.count <= 10, "Headline should remain readable on narrow cards")
            varied.insert(phrase.script)
        }
        require(varied.count >= 8, "Ordinary days need variety")
        let rainy = GreetingPhrase.Context(weather: .rain, temperature: 35)
        require(GreetingPhrase.forDate(baseline, calendar: calendar, context: rainy).aside!.contains("伞")
                || GreetingPhrase.forDate(baseline, calendar: calendar, context: rainy).aside!.contains("雨")
                || GreetingPhrase.forDate(baseline, calendar: calendar, context: rainy).script.contains("雨"), "Rain should get a warm reminder")
        let rainyNight = GreetingPhrase.forDate(date("2026-09-28", 23), calendar: calendar, context: rainy)
        require(!rainyNight.script.contains("雨"), "Rest takes precedence over weather at bedtime")
        let festivalNight = GreetingPhrase.forDate(date("2026-10-01", 23), calendar: calendar, context: rainy)
        require(festivalNight.script == "国庆快乐" && festivalNight.aside!.contains("休息"), "Holiday nights must acknowledge rest")
        let english = GreetingPhrase.forDate(baseline, calendar: calendar, language: .english)
        require(english.script.unicodeScalars.allSatisfy { $0.isASCII }, "English choice must use English copy")
        require(stable.salutation.hasSuffix("，") && english.salutation.hasSuffix(","), "Language-aware punctuation")
        require(GreetingPhrase.forDate(baseline, calendar: calendar, context: .init(temperature: .nan)) == stable,
                "Invalid temperature must not alter the greeting")
        require(GreetingPhrase.DayPart.of(hour: 21) == .evening && GreetingPhrase.DayPart.of(hour: 22) == .night
                && GreetingPhrase.DayPart.of(hour: 0) == .late && GreetingPhrase.DayPart.of(hour: 5) == .dawn,
                "Bedtime and dawn boundaries")
        let rainyEvening = GreetingPhrase.forDate(date("2026-09-28", 18), calendar: calendar, context: rainy)
        require(rainyEvening.script.contains("回家") && rainyEvening.aside!.contains("慢"), "Evening rain should care about the journey home")
        let storm = GreetingPhrase.Context(weather: .storm, temperature: 25)
        let stormWork = GreetingPhrase.forDate(date("2026-09-28", 14), calendar: calendar, context: storm)
        require(stormWork.aside!.contains("安心做事") && !stormWork.aside!.contains("回家"), "Workday rain must not assume a commute")
        let rainyHoliday = GreetingPhrase.forDate(date("2026-10-01", 18), calendar: calendar, context: storm)
        require(rainyHoliday.script == "国庆快乐" && rainyHoliday.aside!.contains("伞"), "Holiday title must retain a weather-aware aside")
        let englishRain = GreetingPhrase.forDate(baseline, calendar: calendar, language: .english, context: rainy)
        require(englishRain != english && englishRain.script.unicodeScalars.allSatisfy { $0.isASCII }, "English weather copy")
        print("PASS: local dates, lunar festivals beyond 2027, leap-month exclusion, moving parent holidays, warm variety, stable redraws, rest precedence and languages")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-greeting-phrase-') as tmp:
    path = Path(tmp) / 'Regression.swift'
    path.write_text(source)
    binary = Path(tmp) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macos15.0', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
