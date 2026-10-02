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
        case automatic, hello, morning, afternoon, evening, night, welcome, gentle, monthly, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "自动"
            case .hello: return "你好呀"
            case .morning: return "早上好呀"
            case .afternoon: return "下午好呀"
            case .evening: return "晚上好呀"
            case .night: return "晚安好梦"
            case .welcome: return "欢迎回来"
            case .gentle: return "慢慢来就好"
            case .monthly: return "你好，本月"
            case .custom: return "自定义"
            }
        }
    }

    static func resolve(_ selection: Selection, custom: String = "", date: Date,
                        calendar: Calendar = .current, language: Language = .chinese,
                        context: Context = Context()) -> Phrase {
        let chinese = language == .chinese
        let script: String
        switch selection {
        case .automatic: return forDate(date, calendar: calendar, language: language, context: context)
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

    /// Festivals first; rest at late hours next; then weather, weekend and the
    /// ordinary day. Presence is enough for a gentle wish — no activity tracking
    /// or assumption that the person has been working all night.
    static func forDate(_ date: Date, calendar: Calendar = .current,
                        language: Language = .chinese, context: Context = Context()) -> Phrase {
        let part = DayPart.of(hour: calendar.component(.hour, from: date))
        let seed = (calendar.ordinality(of: .day, in: .era, for: date) ?? 0)
            + calendar.component(.hour, from: date)
        func choose(_ lines: [(String, String)]) -> Phrase {
            let line = lines[abs(seed % lines.count)]
            return Phrase(script: line.0, aside: line.1)
        }
        let weatherWish = weatherPhrase(part: part, hour: calendar.component(.hour, from: date), language: language, context: context)
        if let holiday = holiday(on: date, calendar: calendar) {
            let late = part == .late || part == .night
            let wish = language == .chinese ? holiday.wish : holiday.englishWish
            let aside = late ? (language == .chinese ? "\(wish)；也记得早点休息" : "\(wish) · rest when you can")
                : (weatherWish?.aside ?? wish)
            return Phrase(script: language == .chinese ? holiday.name : holiday.englishName, aside: aside)
        }
        if part != .late && part != .night, let weatherWish { return weatherWish }

        if language == .english {
            switch part {
            case .late: return choose([("Still up", "let tomorrow take its turn"), ("Rest a little", "you have done enough for today"), ("Sleep well", "the world can wait a little")])
            case .night: return choose([("Wind down", "leave a little time for yourself"), ("Good night", "rest when you can"), ("Sweet dreams", "tomorrow is a fresh start")])
            case .dawn: return choose([("Hello, sunrise", "start gently, there is no rush"), ("A new day", "a little breakfast, a little sunshine")])
            case .morning: return choose([("Good morning", "may today be kind to you"), ("Morning, sunshine", "one small step at a time"), ("Hello, today", "make room for something lovely")])
            case .noon: return choose([("Time for lunch", "take a proper little break"), ("Good afternoon", "don't forget to eat"), ("Pause a little", "stretch, sip, breathe")])
            case .afternoon: return choose([("Good afternoon", "slow progress is still progress"), ("Take a breath", "a little water, a little rest"), ("Keep it gentle", "you don't have to do it all today")])
            case .evening: return choose([("Good evening", "save some of the evening for yourself"), ("Welcome back", "something warm, something peaceful"), ("Hello, evening", "let the day soften a little")])
            }
        }
        switch part {
        case .late:
            return choose([
                ("夜深了", "手头的事先放一放，早点休息吧"),
                ("早点睡呀", "明天还有新的阳光，不急在这一晚"),
                ("该歇一歇啦", "合上电脑，也给自己一个晚安"),
                ("晚安好梦", "愿你睡得安稳，醒来轻松一些"),
                ("别太晚睡", "留一点精力，给明天的自己"),
                ("辛苦啦", "这一晚已经够长了，休息也很重要"),
                ("让夜慢下来", "喝口水，放松肩膀，再好好睡一觉"),
                ("明天再继续", "今天做到这里，也已经很好了")])
        case .night:
            return choose([
                ("早点休息呀", "忙了一天，给自己留一点安静的时间"),
                ("晚安啦", "把今天轻轻放下，愿今晚有个好梦"),
                ("慢慢收尾吧", "没做完的事，可以留给明天"),
                ("今天辛苦了", "关掉一点忙碌，打开一点松弛"),
                ("好好睡一觉", "愿明天醒来，又是轻盈的一天"),
                ("给自己晚安", "记得放松眼睛，也放松心情"),
                ("夜色温柔", "别忘了，你也值得被好好照顾"),
                ("准备好梦吧", "今晚就让自己早一点休息")])
        default: break
        }
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 || weekday == 7 {
            return choose([("周末愉快", "愿今天有一点闲，也有一点喜欢"), ("慢一点也好", "留点时间，做一件让自己开心的事"), ("今天自在些", "不赶路的时候，也看看身边的风景"), ("给生活留白", "一顿好饭，一段散步，都很值得"), ("愿你轻松些", "忙里也记得，给自己一个小小的休息"), ("把日子过暖", "和喜欢的人，说说话，笑一笑")])
        }
        switch part {
        case .dawn:
            return choose([("早呀", "新的一天慢慢来，先照顾好自己"), ("你好晨光", "喝口温水，让今天有个柔软的开始"), ("清晨好呀", "愿第一缕光，带来一点好心情"), ("一天刚刚好", "吃点早餐，再开始今天的旅程"), ("迎接新一天", "不必急着出发，先伸个懒腰吧"), ("早起辛苦啦", "愿今天的努力，都有温柔的回响")])
        case .morning:
            return choose([("早上好呀", "愿今天顺顺利利，也有小小惊喜"), ("今天也加油", "一步一步来，慢慢也能走很远"), ("你好新一天", "吃好早餐，带着好心情出发"), ("愿你有好心情", "今天也别忘了，对自己温柔一点"), ("阳光正好", "愿你眼里有光，心里有盼望"), ("早安呀", "把今天过成，你喜欢的一小段时光"), ("好日子开始啦", "从一杯水、一个微笑开始吧"), ("新的一天啦", "愿你遇见好事，也遇见好的人")])
        case .noon:
            return choose([("记得吃饭呀", "再忙也先好好吃一顿，别饿着自己"), ("午安呀", "吃顿热乎的饭，再歇一小会儿"), ("该歇一歇啦", "让眼睛离开屏幕，也让肩膀放松一下"), ("午饭要吃好", "照顾好胃，也照顾好今天的心情"), ("休息一会吧", "喝口水，伸个懒腰，再慢慢继续"), ("给自己充充电", "午间留一点空白，下午会轻松些"), ("好好吃饭呀", "日子再忙，一餐一饭也值得认真"), ("午间小憩吧", "闭目休息一下，不必一直绷紧")])
        case .afternoon:
            return choose([("下午好呀", "喝口水，让接下来的时间轻松一点"), ("慢慢来就好", "不必一次做好所有事，先做好眼前这件"), ("休息一下吧", "看看远处，给眼睛和心情都放个小假"), ("愿你从容些", "一点一点推进，也是在向前走"), ("今天也不错", "别只盯着没做完的，也看看已经做到的"), ("给自己一点甜", "一杯喜欢的饮料，也能让下午亮起来"), ("伸个懒腰吧", "放松肩颈，再舒舒服服地继续"), ("保持好心情", "认真做事，也记得好好照顾自己")])
        case .evening:
            return choose([("晚上好呀", "把忙碌放缓一点，给自己留些时间"), ("今天辛苦了", "吃顿暖暖的晚饭，慢慢享受夜晚"), ("夜色正温柔", "愿今晚安静，也愿你心里轻松"), ("歇一歇吧", "这一天已经很努力了，也该照顾自己"), ("愿今晚轻松", "听首喜欢的歌，把心情慢慢放松"), ("让日子慢下来", "留一点夜晚，给自己和喜欢的人"), ("灯火可亲", "愿你有热饭，有陪伴，也有好心情"), ("今晚也温暖", "忙碌之外，别忘了生活的小小美好")])
        // .late and .night returned in the first switch above, so this one only
        // phrases the five daytime parts; the trap is what keeps every path
        // from falling out of the end of the function.
        default: preconditionFailure("late and night return above")
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
