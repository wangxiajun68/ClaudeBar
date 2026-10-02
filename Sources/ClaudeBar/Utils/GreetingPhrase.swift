import Foundation

/// Warm greetings follow the person's local day, not the sky preview's clock.
/// A deterministic daily/hourly choice stays still through redraws and launches.
enum GreetingPhrase {
    enum Language: String, CaseIterable, Identifiable {
        case chinese, english
        var id: String { rawValue }
        var label: String { self == .chinese ? "中文" : "English" }
    }

    enum Selection: String, CaseIterable, Identifiable {
        case automatic, everyday, hello, morning, afternoon, evening, night, welcome, gentle, monthly, verse, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "自动"
            case .everyday: return "日常问候"
            case .hello: return "你好呀"
            case .morning: return "早上好呀"
            case .afternoon: return "下午好呀"
            case .evening: return "晚上好呀"
            case .night: return "晚安好梦"
            case .welcome: return "欢迎回来"
            case .gentle: return "慢慢来就好"
            case .monthly: return "你好，本月"
            case .verse: return "诗词"
            case .custom: return "自定义"
            }
        }
    }

    /// `automatic` reads the day (festivals, weather, hour); `verse` answers
    /// with a line of poetry from the solar term or season, ignoring festivals
    /// and weather, so a click on the card can hand the headline back to the
    /// time of year alone. `everyday` keeps the plain human greetings — a warm
    /// "早上好" or "早点休息" for the hour — and never reaches for a verse.
    enum Mode {
        case automatic, everyday, verse
    }

    static func resolve(_ selection: Selection, custom: String = "", date: Date,
                        calendar: Calendar = .current, language: Language = .chinese,
                        context: Context = Context()) -> Phrase {
        let chinese = language == .chinese
        let script: String
        switch selection {
        case .automatic: return forDate(date, calendar: calendar, language: language, context: context, mode: .automatic)
        case .everyday: return forDate(date, calendar: calendar, language: language, context: context, mode: .everyday)
        case .verse: return forDate(date, calendar: calendar, language: language, context: context, mode: .verse)
        case .hello: script = chinese ? "你好呀" : "Hello"
        case .morning: script = chinese ? "早上好呀" : "Good morning"
        case .afternoon: script = chinese ? "下午好呀" : "Good afternoon"
        case .evening: script = chinese ? "晚上好呀" : "Good evening"
        case .night: script = chinese ? "晚安好梦" : "Sweet dreams"
        case .welcome: script = chinese ? "欢迎回来" : "Welcome back"
        case .gentle: script = chinese ? "慢慢来就好" : "Keep it gentle"
        case .monthly:
            if chinese { script = "你好，\(calendar.component(.month, from: date))月" }
            else {
                let style = Date.FormatStyle(locale: Locale(identifier: "en_US"),
                                             calendar: calendar, timeZone: calendar.timeZone).month(.wide)
                script = "Hello, " + date.formatted(style)
            }
        case .custom:
            script = String(custom.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            if script.isEmpty { return forDate(date, calendar: calendar, language: language, context: context) }
        }
        return Phrase(script: script, aside: nil)
    }

    struct Phrase: Equatable {
        var script: String
        var aside: String?
        var salutation: String { script + (script.unicodeScalars.contains { !$0.isASCII } ? "，" : ",") }
    }

    enum DayPart: String, CaseIterable {
        case late, dawn, morning, noon, afternoon, evening, night
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

    struct Context {
        enum Weather { case rain, storm, snow, fog }
        var weather: Weather? = nil
        var temperature: Double? = nil
        var windKph: Double? = nil
    }

    struct Holiday: Equatable {
        var name: String
        var wish: String
        var englishName: String
        var englishWish: String
    }

    /// Festivals first; rest at late hours next; then weather, the solar term of
    /// the day, weekend and the ordinary season. Presence is enough for a
    /// gentle wish — no activity tracking or assumption that the person has
    /// been working all night.
    ///
    /// `verse` skips festivals and weather so the headline is always a line of
    /// poetry, chosen for the solar term or the season and hour.
    static func forDate(_ date: Date, calendar: Calendar = .current,
                        language: Language = .chinese, context: Context = Context(),
                        mode: Mode = .automatic) -> Phrase {
        let part = DayPart.of(hour: calendar.component(.hour, from: date))
        let seed = (calendar.ordinality(of: .day, in: .era, for: date) ?? 0)
            + calendar.component(.hour, from: date)
        func choose(_ lines: [(String, String)]) -> Phrase {
            let line = lines[abs(seed % lines.count)]
            return Phrase(script: line.0, aside: line.1)
        }
        let weatherWish = weatherPhrase(part: part, hour: calendar.component(.hour, from: date), language: language, context: context)
        if mode == .automatic, let holiday = holiday(on: date, calendar: calendar) {
            let late = part == .late || part == .night
            let wish = language == .chinese ? holiday.wish : holiday.englishWish
            let aside = late ? (language == .chinese ? "\(wish)；也记得早点休息" : "\(wish) · rest when you can")
                : (weatherWish?.aside ?? wish)
            return Phrase(script: language == .chinese ? holiday.name : holiday.englishName, aside: aside)
        }
        if mode == .automatic, part != .late && part != .night, let weatherWish { return weatherWish }

        // The everyday choice keeps the plain human greeting for the hour
        // ("早上好呀", "早点休息"), so the card can stay warm without a verse.
        if mode == .everyday {
            return choose(everydayLines(part: part, language: language))
        }

        // Rest still wins over a poem at bedtime; a verse for the night reads
        // quieter than one for the working day.
        if let term = SolarTerm.term(on: date, calendar: calendar), part != .late, part != .night {
            return choose(language == .chinese ? term.chineseVerses : term.englishVerses)
        }
        let season = SolarTerm.season(on: date, calendar: calendar)
        let daylight: SolarTerm.Season.Daylight = (part == .late || part == .night) ? .night : (part == .dawn ? .dawn : .day)
        let weekday = calendar.component(.weekday, from: date)
        if mode == .automatic, weekday == 1 || weekday == 7 {
            return choose(season.weekendVerses(chinese: language == .chinese))
        }
        return choose(season.verses(chinese: language == .chinese, daylight: daylight))
    }

    /// The everyday pool: the plain, familiar greetings for each band of the
    /// day. No poetry, no weather — just the human thing a person says. The
    /// script rotates within the hour's band; the aside is the warm extra.
    private static func everydayLines(part: DayPart, language: Language) -> [(String, String)] {
        if language == .chinese {
            switch part {
            case .late, .night:
                return [("早点休息", "夜深了，手头的事明天再说，好好睡一觉"),
                        ("晚安好梦", "放下手机，安心休息，明天会更好"),
                        ("早点睡呀", "再忙也别忘了照顾自己，晚安"),
                        ("夜深了", "事情做不完没关系，先好好休息")]
            case .dawn:
                return [("清晨好呀", "新的一天开始了，慢慢来"),
                        ("早上好呀", "天刚亮，先喝口水，照顾好自己"),
                        ("醒来真好", "清晨安静，愿你今天心情好"),
                        ("早安呀", "新的一天，愿你顺顺利利")]
            case .morning:
                return [("早上好呀", "新的一天，愿你顺顺利利，慢慢来"),
                        ("早呀", "吃早饭了吗？先照顾好自己"),
                        ("早上好", "愿你今天有好心情，事情一件件来"),
                        ("新的一天", "深呼吸，慢慢开始今天")]
            case .noon:
                return [("中午好呀", "记得吃午饭，也歇一会儿"),
                        ("午安", "忙了半天，给自己留一点时间"),
                        ("午饭时间", "吃顿热乎的，别对付自己"),
                        ("中午好", "放下手头的事，好好吃个饭")]
            case .afternoon:
                return [("下午好呀", "忙了半天，记得站起来走走"),
                        ("下午好", "喝口水，伸个懒腰，慢慢来"),
                        ("午后时光", "不着急，一件一件来"),
                        ("下午好", "愿你此刻不慌不忙")]
            case .evening:
                return [("晚上好呀", "今天辛苦了，给自己一点放松的时间"),
                        ("晚上好", "忙了一天，晚上好好休息"),
                        ("辛苦了", "回家路上慢一点，晚上吃顿好的"),
                        ("晚上好", "把今天放一放，享受夜晚的安静")]
            }
        }
        switch part {
        case .late, .night:
            return [("get some rest", "it is late; let the day go and sleep well"),
                    ("sweet dreams", "put work down for tonight, and rest"),
                    ("time to rest", "tomorrow can wait; take care of yourself"),
                    ("good night", "sleep is a kind thing; go get some")]
        case .dawn:
            return [("good morning", "a new day, take it gently"),
                    ("morning already", "start slow and be kind to yourself"),
                    ("a quiet morning", "a fresh day, one thing at a time"),
                    ("happy morning", "hope today treats you well")]
        case .morning:
            return [("good morning", "have some breakfast, take care of yourself"),
                    ("morning", "one thing at a time, it is all fine"),
                    ("good morning", "a new day, and there is no rush"),
                    ("rise and shine", "breathe, and start gently")]
        case .noon:
            return [("good afternoon", "have some lunch, and a little break"),
                    ("it is noon", "you have worked hard; take a rest"),
                    ("lunch time", "eat something warm, do not skip it"),
                    ("midday hello", "put the work down and have a meal")]
        case .afternoon:
            return [("good afternoon", "stand up and stretch for a moment"),
                    ("afternoon", "some water, a little stretch, no rush"),
                    ("hello again", "one step at a time, you are doing fine"),
                    ("slow afternoon", "take your time, there is no hurry")]
        case .evening:
            return [("good evening", "you have worked hard; take a little time"),
                    ("evening", "the day is done, now let yourself rest"),
                    ("you made it", "slow down on the way home, and eat well"),
                    ("welcome to the evening", "put the day aside and enjoy the quiet")]
        }
    }

    private static func weatherPhrase(part: DayPart, hour: Int, language: Language, context: Context) -> Phrase? {
        let headingHome = part == .evening || hour == 17
        switch context.weather {
        case .storm:
            return language == .chinese
                ? Phrase(script: "雨大，慢慢来", aside: headingHome ? "准备回家就带好伞，路上慢一点，到家吃顿热饭" : "窗外雨有点大，安心做事，出门时记得带伞")
                : Phrase(script: "Stay cozy", aside: headingHome ? "take an umbrella home, and take your time" : "rain outside, a warm drink beside you")
        case .rain:
            return language == .chinese
                ? Phrase(script: headingHome ? "带伞回家呀" : "雨天也温柔", aside: headingHome ? "收尾不用急，回家的路上慢一点，别淋湿了" : "手边放杯热茶，忙一会儿，也记得歇一歇")
                : Phrase(script: headingHome ? "Take care going home" : "A rainy hello", aside: headingHome ? "umbrella ready, no need to rush" : "a warm cup, a little pause, one thing at a time")
        case .snow:
            return language == .chinese ? Phrase(script: "愿你暖暖的", aside: "窗外有雪，多添一件衣服，出门慢慢走")
                : Phrase(script: "Keep warm", aside: "a little extra layer, and careful steps outside")
        case .fog:
            return language == .chinese ? Phrase(script: "雾里慢慢走", aside: "路上留心，愿你平安抵达；手头的事不用急")
                : Phrase(script: "Take it gently", aside: "fog outside; take your time on the way")
        case nil: break
        }
        if let wind = context.windKph, wind.isFinite, wind >= 39 {
            return language == .chinese ? Phrase(script: "风大，照顾好自己", aside: "出门添件外套，走稳一点，忙里也记得歇一歇")
                : Phrase(script: "A windy hello", aside: "bring a layer, and take it gently outside")
        }
        if let temperature = context.temperature, temperature.isFinite {
            if temperature >= 33 {
                return language == .chinese ? Phrase(script: "记得喝水呀", aside: "天气有点热，忙里喝口水，给自己找一点清凉")
                    : Phrase(script: "Keep cool", aside: "a little water, a little shade, a little break")
            }
            if temperature <= 8 {
                return language == .chinese ? Phrase(script: "暖和一点呀", aside: "手边放杯热饮，出门添件衣服，别着凉啦")
                    : Phrase(script: "Keep warm", aside: "a warm drink nearby, an extra layer outside")
            }
        }
        return nil
    }

    /// Lunar festivals use Foundation's Chinese calendar, including leap-month
    /// exclusion and New Year's Eve as the day before lunar 1/1. No year table.
    static func holiday(on date: Date, calendar: Calendar = .current) -> Holiday? {
        var solar = Calendar(identifier: .gregorian)
        solar.timeZone = calendar.timeZone
        let c = solar.dateComponents([.month, .day, .weekday], from: date)
        guard let month = c.month, let day = c.day else { return nil }
        func holiday(_ name: String, _ wish: String, _ englishName: String, _ englishWish: String) -> Holiday {
            Holiday(name: name, wish: wish, englishName: englishName, englishWish: englishWish)
        }
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = calendar.timeZone
        let l = lunar.dateComponents([.month, .day, .isLeapMonth], from: date)
        if l.isLeapMonth != true {
            switch (l.month ?? 0, l.day ?? 0) {
            case (1, 1...5): return holiday("新春快乐", "愿新的一年，平安喜乐，万事顺意", "Happy New Year", "a warm and wonderful year ahead")
            case (1, 15): return holiday("元宵快乐", "愿灯火可亲，月圆人也圆", "Lantern Festival", "warm lights and sweet moments")
            case (5, 5): return holiday("端午安康", "愿粽香里的日子，平安又温暖", "Dragon Boat", "peace and good health to you")
            case (7, 7): return holiday("七夕快乐", "愿你被爱，也记得好好爱自己", "Happy Qixi", "a little love in every day")
            case (8, 15): return holiday("中秋快乐", "愿月圆人安，想念的人就在身边", "Mid-Autumn", "a full moon and a warm heart")
            case (9, 9): return holiday("重阳安康", "愿岁岁平安，记得问候牵挂的人", "Double Ninth", "peace and warmth to those you love")
            case (12, 8): return holiday("腊八快乐", "一碗热粥，愿你暖暖地迎接新年", "Laba Festival", "a warm bowl and a gentle day")
            default: break
            }
        }
        if let next = solar.date(byAdding: .day, value: 1, to: date) {
            let n = lunar.dateComponents([.month, .day, .isLeapMonth], from: next)
            if n.month == 1, n.day == 1, n.isLeapMonth != true {
                return holiday("除夕快乐", "愿今夜团圆，明年也有满满的欢喜", "New Year's Eve", "togetherness tonight, joy tomorrow")
            }
        }
        switch (month, day) {
        case (1, 1): return holiday("新年快乐", "新的一年，愿你平安，也愿你如愿", "Happy New Year", "a fresh start and lovely things ahead")
        case (2, 14): return holiday("情人节快乐", "愿你心有所爱，也一直被温柔以待", "Happy Valentine's", "love and kindness, today and always")
        case (3, 8): return holiday("愿你自在绽放", "妇女节快乐，愿你自由、勇敢，也快乐", "Women's Day", "may you flourish in your own way")
        case (5, 1): return holiday("劳动节快乐", "认真生活的你，值得一个好好的休息", "Happy May Day", "your efforts deserve a little rest")
        case (6, 1): return holiday("童心快乐", "愿你长大，也不丢掉小小的快乐", "Children's Day", "keep a little wonder in your day")
        case (9, 10): return holiday("教师节快乐", "谢谢每一份耐心，和每一盏引路的灯", "Teachers' Day", "thank you for every patient little lesson")
        case (10, 1): return holiday("国庆快乐", "愿你与喜欢的人，共度一段好时光", "Happy National Day", "good company and beautiful moments")
        case (10, 2...7): return holiday("金秋好时光", "愿这个十月，有风景，也有好心情", "Hello, October", "a little autumn beauty, a little joy")
        case (12, 24): return holiday("平安夜快乐", "愿今晚平安，也愿每个明天温暖", "Christmas Eve", "peace tonight and warmth tomorrow")
        case (12, 25): return holiday("圣诞快乐", "愿你有惊喜，有陪伴，也有暖意", "Merry Christmas", "small surprises and warm company")
        case (12, 31): return holiday("一起迎新年", "谢谢这一年的自己，愿来年更加自在", "See you next year", "thank yourself for making it this far")
        default: break
        }
        if c.weekday == 1 {
            if month == 5, (8...14).contains(day) {
                return holiday("母亲节快乐", "愿牵挂你的人，也被温柔照顾", "Mother's Day", "send a little love to those who care for you")
            }
            if month == 6, (15...21).contains(day) {
                return holiday("父亲节快乐", "给关心你的人，留一句温暖的问候", "Father's Day", "a warm word for someone who cares")
            }
        }
        return nil
    }
}
