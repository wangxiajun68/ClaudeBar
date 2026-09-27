import Foundation

/// What the handwritten salutation says, and why.
///
/// The card used to print one word — `Hello` — at every hour of every day. That
/// is a *stamp*, not a greeting: at 23:28 it says the same thing as at 06:00,
/// and it says the same thing on Lunar New Year as on an ordinary Tuesday. This type is
/// the whole decision, kept out of the view so it is testable without a clock
/// or a screen and so the card only has to render the answer.
///
/// The order of precedence is deliberate and is the interesting part:
///
/// 1. **Festival** wins over everything. A holiday is the largest fact about a
///    day, and a plain "Good morning" on Lunar New Year is a smaller greeting
///    than the day deserves.
/// 2. **Part of day** next, in six bands rather than three. A single
///    "good morning" / "good evening" pair collapses four hours of the morning
///    and four of the afternoon into one word each; the boundaries below (dawn
///    / morning / noon / afternoon / evening / night) are where a person's *own*
///    sense of the day changes, not where the clock's does.
/// 3. **Late night is addressed as late night.** 23:28 is not "evening" — a
///    person still awake at that hour is being kept up by work, and the honest
///    greeting is not "Good evening" but a line that acknowledges the hour.
///
/// Nothing here is randomised. A greeting that changes on every re-render is a
/// slot machine, and the card re-renders on every pointer move; a stable phrase
/// per (time, date) is what lets the entrance animation be *the* event rather
/// than one of several.
enum GreetingPhrase {
    /// The salutation and the small English hand that accompanies it.
    ///
    /// `script` is the word set in the script face — the big handwritten mark.
    /// `aside` is the optional quiet line under it, used only where a second
    /// sentence adds something the word cannot (a festival's name, an hour that
    /// deserves acknowledging). It is deliberately `nil` most of the day: a
    /// card that always says two things says neither well.
    struct Phrase: Equatable {
        var script: String
        var aside: String?
    }

    /// The six parts of a day, in the order they occur.
    ///
    /// Boundaries are clock hours in the *device's* timezone — this is a
    /// greeting about the person's day, so unlike the star field it must follow
    /// local time rather than UTC. `late` wraps midnight and is therefore
    /// matched first rather than being a range inside the day.
    enum DayPart: String, CaseIterable {
        case late      // 00:00–04:59  still up, or already up
        case dawn      // 05:00–06:59  before the day starts
        case morning   // 07:00–10:59
        case noon      // 11:00–13:59
        case afternoon // 14:00–17:59
        case evening   // 18:00–21:59  the working evening
        case night     // 22:00–23:59  bedtime, and the hour past it

        /// Which band a clock hour falls in.
        ///
        /// The 22:00 line between `evening` and `night` is the one that had to
        /// move during review: 23:28 is not an evening, it is the hour a person
        /// is still at the desk *past* the evening, and "Good evening" at 23:28 was the
        /// exact tone-deafness this whole change exists to fix. 22:00 is where
        /// "the evening's work" turns into "you should be asleep".
        static func of(hour: Int) -> DayPart {
            switch hour {
            case 0..<5: return .late
            case 5..<7: return .dawn
            case 7..<11: return .morning
            case 11..<14: return .noon
            case 14..<18: return .afternoon
            case 18..<22: return .evening
            default: return .night
            }
        }
    }

    /// A holiday the card knows by name.
    ///
    /// A fixed list rather than a computed lunar calendar: the lunar festivals
    /// below are the ones whose *date* moves each year, so each is stored as its
    /// Gregorian day for the years this build knows. `holiday(_:on:)` falls back
    /// to `nil` for a year that is not listed, which degrades to an ordinary
    /// greeting — the right failure for a greeting card, and the reason this is
    /// a table rather than a lunar conversion (a wrong Lunar New Year date would be worse
    /// than no line at all).
    struct Holiday: Equatable {
        var name: String
        /// A shorter line for the aside, already phrased as a wish.
        var wish: String
    }

    /// The greeting for `date`, in `calendar`'s timezone.
    static func forDate(_ date: Date, calendar: Calendar = .current) -> Phrase {
        let hour = calendar.component(.hour, from: date)
        let part = DayPart.of(hour: hour)
        if let holiday = holiday(on: date, calendar: calendar) {
            return festivalPhrase(holiday, part: part)
        }
        return ordinaryPhrase(part)
    }

    // MARK: Ordinary days

    private static func ordinaryPhrase(_ part: DayPart) -> Phrase {
        switch part {
        case .late:
            // Not "Good evening": at 23:28 or 03:00 the honest reading is that
            // the person is still working, and a bright greeting is tone-deaf.
            return Phrase(script: "Still up", aside: "past midnight")
        case .dawn:
            return Phrase(script: "Morning", aside: "a new day")
        case .morning:
            return Phrase(script: "Good morning", aside: nil)
        case .noon:
            return Phrase(script: "Good afternoon", aside: "don't skip lunch")
        case .afternoon:
            return Phrase(script: "Good afternoon", aside: nil)
        case .evening:
            return Phrase(script: "Good evening", aside: nil)
        case .night:
            // 22:00 onward. The word stays "Good evening" — it is still the
            // evening, and swapping it for "Still up" at 22:00 would be early —
            // but the aside carries the hour's actual advice, which is the part
            // that was missing when a bright "Hello" sat above a 23:28 clock.
            return Phrase(script: "Good evening", aside: "rest when you can")
        }
    }

    // MARK: Festivals

    /// The festival line for a holiday, phrased for the part of day.
    ///
    /// A festival changes the *aside* as well as the word: at 09:00 the wish is
    /// the greeting, at 23:00 the same wish has to acknowledge that the person
    /// is still at the desk on a holiday, which is a different sentence.
    private static func festivalPhrase(_ holiday: Holiday, part: DayPart) -> Phrase {
        switch part {
        case .late, .night:
            return Phrase(script: holiday.name, aside: "don't stay up for it")
        case .dawn, .morning:
            return Phrase(script: holiday.name, aside: holiday.wish)
        case .noon:
            return Phrase(script: holiday.name, aside: "\(holiday.wish), don't skip lunch")
        case .afternoon, .evening:
            return Phrase(script: holiday.name, aside: holiday.wish)
        }
    }

    /// The holiday on `date`, or `nil`.
    static func holiday(on date: Date, calendar: Calendar = .current) -> Holiday? {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month, let day = c.day else { return nil }

        // Fixed-date holidays: the same Gregorian day every year.
        switch (month, day) {
        case (1, 1): return Holiday(name: "New Year", wish: "Happy New Year")
        case (2, 14): return Holiday(name: "Valentine's", wish: "Happy Valentine's")
        case (3, 8): return Holiday(name: "Women's Day", wish: "Happy Women's Day")
        case (5, 1): return Holiday(name: "May Day", wish: "Happy May Day")
        case (6, 1): return Holiday(name: "Children's Day", wish: "Happy Children's Day")
        case (10, 1): return Holiday(name: "National Day", wish: "Happy National Day")
        case (12, 24): return Holiday(name: "Christmas Eve", wish: "Peace and quiet")
        case (12, 25): return Holiday(name: "Christmas", wish: "Merry Christmas")
        case (12, 31): return Holiday(name: "New Year's Eve", wish: "see you next year")
        default: break
        }

        // Lunar festivals, stored as the Gregorian day they fall on. See
        // `Holiday` for why this is a table and not a conversion.
        switch (year, month, day) {
        case (2026, 2, 17): return Holiday(name: "Lunar New Year", wish: "Happy New Year")
        case (2026, 3, 3): return Holiday(name: "Lantern Festival", wish: "Happy Lantern Festival")
        case (2026, 6, 19): return Holiday(name: "Dragon Boat", wish: "Happy Dragon Boat Festival")
        case (2026, 9, 25): return Holiday(name: "Mid-Autumn", wish: "Happy Mid-Autumn")
        case (2027, 2, 6): return Holiday(name: "Lunar New Year", wish: "Happy New Year")
        case (2027, 2, 20): return Holiday(name: "Lantern Festival", wish: "Happy Lantern Festival")
        case (2027, 6, 9): return Holiday(name: "Dragon Boat", wish: "Happy Dragon Boat Festival")
        case (2027, 9, 15): return Holiday(name: "Mid-Autumn", wish: "Happy Mid-Autumn")
        default: break
        }

        // Solar terms and the two days that carry a wish without being a day
        // off. Kept after the festivals above so nothing here can shadow one.
        switch (month, day) {
        case (5, 12): return Holiday(name: "Mother's Day", wish: "call your mother")
        case (6, 21): return Holiday(name: "Father's Day", wish: "call your father")
        case (12, 22): return Holiday(name: "Solstice", wish: "the year turns today")
        default: return nil
        }
    }
}
