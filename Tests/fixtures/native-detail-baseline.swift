// Frozen production formatting oracle from c985f1f. Synthetic regression only.
// Keeps default make test independent of Git history in shallow CI checkouts.
import Foundation
import Darwin
import os

/// One ChatGPT Codex rate-limit window returned by Codex App Server.
struct OriginalQuotaWindow: Equatable, Identifiable {
    /// Where the window sits in the account payload — `primary` / `secondary`
    /// for Codex — and the key everything that tracks a window per-window
    /// uses.
    ///
    /// The label cannot serve as that key: it is derived from
    /// `windowDurationMins`, which the API is free to omit, and a payload
    /// without it gives **both** windows the same 「额度」. Keyed by label the
    /// two impersonate each other — `QuotaResetDetector` read the secondary
    /// window's first sighting against the primary's percentage and fired a
    /// rollover alert on the spot, every later real rollover of the 5-hour
    /// window was compared against the 7-day window, and the popup's gauge row
    /// built two cells with one identity. The slot is stable across readings
    /// whatever the payload says about durations.
    var slot: String = ""
    /// Window identity: the slot when there is one, the label otherwise (a
    /// window a caller builds without a slot to give — Cursor's pools).
    var id: String { slot.isEmpty ? label : slot }
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    /// The window's own length in minutes, straight from the API
    /// (`windowDurationMins`); 0 when the response did not say.
    ///
    /// It rides on the window because the display label is a *presentation* of
    /// it (`300 → "5 小时"`) and a view that wants to know "is this the short
    /// window?" must not re-parse that string to find out. `resetCompact` is the
    /// one reader: a short window shows a clock, a long one a day count.
    var durationMinutes: Int = 0

    var usedText: String {
        let rounded = usedPercent.rounded()
        if abs(usedPercent - rounded) < 0.05 { return "\(Int(rounded))%" }
        return String(format: "%.1f%%", usedPercent)
    }

    /// Clock time of the next allowance refresh. Today omits the date.
    var resetClock: String {
        guard let resetsAt else { return "重置时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(resetsAt) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return "\(formatter.string(from: resetsAt)) 重置"
    }

    /// How long until that refresh, for the dashboard detail line.
    var resetWait: String {
        guard let resetsAt else { return "" }
        let delta = resetsAt.timeIntervalSinceNow
        if delta <= 60 { return "即将重置" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "\(minutes) 分钟后重置" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours < 48 {
            return rest == 0 ? "\(hours) 小时后重置" : "\(hours) 小时 \(rest) 分后重置"
        }
        return "\(hours / 24) 天后重置"
    }

    /// The reset moment in the fewest characters that still say it — for the
    /// popup header, where two windows share a 133pt cell.
    ///
    /// The popup's Codex chip is three columns wide with a model name and a
    /// vendor line above the gauges, so a *full* clock does not fit: `09-27
    /// 21:00` beside both windows pushes the second one off the cell ("7d 剩…"),
    /// which is a worse readout than no clock at all. What fits is the shortest
    /// honest form of each window's own answer, and the choice follows the
    /// window's **length**, not the calendar day:
    ///
    /// * a **short** window (hours — the 5 小时 one) always prints `HH:mm`. Its
    ///   reset is within hours, so the clock is the reading a person is waiting
    ///   on, and it says *when* rather than *how long*. That holds **even when
    ///   the reset falls just after midnight**: `01:00` is still the exact
    ///   answer, and it is shorter than any date-qualified form.
    /// * a **long** window (days — the 7 天 one) prints `2天`. A wall clock there
    ///   is days away and only looks precise; the day count is the useful
    ///   reading, and it is short.
    ///
    /// The threshold is 24 hours: below it the window resets at most once a day,
    /// so an unqualified `HH:mm` cannot be misread as a far-off instant; at or
    /// above it the answer is genuinely a number of days.
    ///
    /// Minutes are dropped from the clock on purpose — the tooltip and the
    /// dashboard's own clock line carry the exact time, and this is the one place
    /// the reading is abbreviated, so it is abbreviated in one place.
    var resetCompact: String {
        guard let resetsAt else { return "" }
        if durationMinutes > 0, durationMinutes <= 1_440 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: resetsAt)
        }
        // Midnight-to-midnight day difference, not a 24h span: "明天" has to mean
        // the next calendar day, because that is what a person reads it as.
        //
        // Every branch below one day is false for a reset that is *today* and
        // for a stale instant that has already passed, so `<= 1` used to print
        // 明天 for both — the same window whose tooltip `resetClock` says
        // "HH:mm 重置". 0 is today (the clock is the honest form, exactly as a
        // short window prints it) and anything already past belongs to the
        // current cycle, which is also today or earlier.
        let days = Calendar.current.dateComponents([.day],
                                                   from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: resetsAt)).day ?? 0
        if days <= 0 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: resetsAt)
        }
        if days == 1 { return "明天" }
        return "\(days)天"
    }
}

enum OriginalRichText {
    static func allowedURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        return (["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil)
            || (url.scheme?.lowercased() == "mailto" && !url.path.isEmpty)
    }
    static func escapedHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func html(_ markdown: String) -> String {
        let lines = markdown.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if let first = lines.first, let last = lines.last, lines.count >= 2,
           first.hasPrefix("```"), last.allSatisfy({ $0 == "`" }), last.count >= first.prefix(while: { $0 == "`" }).count {
            let language = String(first.drop(while: { $0 == "`" }))
            return "<pre lang=\"" + escapedHTML(language) + "\"><code>" + escapedHTML(lines.dropFirst().dropLast().joined(separator: "\n")) + "</code></pre>"
        }
        let text = attributed(markdown, size: 15)
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var value = (text.string as NSString).substring(with: range)
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br/>")
            let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            if traits.contains(.fixedPitchFontMask) || (attributes[.documentCode] as? Bool == true) { value = "<code>" + value + "</code>" }
            if traits.contains(.italicFontMask) || (attributes[.documentEmphasis] as? Bool == true) { value = "<em>" + value + "</em>" }
            if traits.contains(.boldFontMask) || (attributes[.documentStrong] as? Bool == true) { value = "<strong>" + value + "</strong>" }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { value = "<del>" + value + "</del>" }
            if let link = attributes[.link] as? URL, allowedURL(link) {
                let address = link.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                value = "<a href=\"" + address + "\">" + value + "</a>"
            }
            result += value
        }
        return result
    }
    static func attributed(_ markdown: String, size: CGFloat, semibold: Bool = false) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: markdown, attributes: [.font: NSFont.systemFont(ofSize: size, weight: semibold ? .semibold : .regular)])
        }
        let result = NSMutableAttributedString(string: String(parsed.characters))
        let full = NSRange(location: 0, length: result.length)
        result.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: semibold ? .semibold : .regular), .foregroundColor: NSColor(Theme.textPrimary)], range: full)
        var offset = 0
        for run in parsed.runs {
            let length = String(parsed.characters[run.range]).utf16.count
            let range = NSRange(location: offset, length: length)
            offset += length
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            result.addAttribute(.font, value: font, range: range)
            if intent.contains(.stronglyEmphasized) { result.addAttribute(.documentStrong, value: true, range: range) }
            if intent.contains(.emphasized) { result.addAttributes([.documentEmphasis: true, .obliqueness: 0.12], range: range) }
            if intent.contains(.code) { result.addAttributes([.documentCode: true, .backgroundColor: NSColor(Theme.bgSecondary)], range: range) }
            if intent.contains(.strikethrough) { result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            if let link = run.link, allowedURL(link) {
                result.addAttributes([.link: link, .foregroundColor: NSColor(Theme.Ink.claude)], range: range)
            }
        }
        // Native automatic detection runs after edits; detect initial bare URLs too.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: result.string, range: full) {
                guard let url = match.url, allowedURL(url), match.range.length > 0 else { continue }
                var canLink = true
                result.enumerateAttributes(in: match.range) { attributes, _, _ in
                    if attributes[.link] != nil || attributes[.documentCode] as? Bool == true { canLink = false }
                }
                if canLink { result.addAttributes([.link: url, .foregroundColor: NSColor(Theme.Ink.claude)], range: match.range) }
            }
        }
        return result
    }
    static func markdown(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let raw = (text.string as NSString).substring(with: range)
            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            var value: String
            if traits.contains(.fixedPitchFontMask) || (attributes[.documentCode] as? Bool == true) {
                let fence = String(repeating: "`", count: (raw.split(separator: "`", omittingEmptySubsequences: false).count))
                value = fence + " " + raw + " " + fence
            } else {
                value = raw.reduce(into: "") { output, character in
                    if "\\`*_[]<>~".contains(character) { output.append("\\") }
                    output.append(character)
                }
            }
            let leading = String(raw.prefix(while: { $0.isWhitespace }))
            let trailing = String(raw.reversed().prefix(while: { $0.isWhitespace }).reversed())
            if !traits.contains(.fixedPitchFontMask) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { result += raw; return }
                value = trimmed.reduce(into: "") { output, character in
                    if "\\`*_[]<>~".contains(character) { output.append("\\") }
                    output.append(character)
                }
            }
            if traits.contains(.italicFontMask) || (attributes[.documentEmphasis] as? Bool == true) { value = "*" + value + "*" }
            if traits.contains(.boldFontMask) || (attributes[.documentStrong] as? Bool == true) { value = "**" + value + "**" }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { value = "~~" + value + "~~" }
            let link = (attributes[.link] as? URL) ?? (attributes[.link] as? String).flatMap(URL.init(string:))
            if let link, allowedURL(link) {
                let address = link.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                value = "[" + value + "](" + address + ")"
            }
            result += traits.contains(.fixedPitchFontMask) ? value : leading + value + trailing
        }
        return result
    }
}
