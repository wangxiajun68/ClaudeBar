import Foundation

/// The 24 solar terms (`节气`) as an offline calendar, plus the season they
/// bound. Foundation's Chinese calendar knows lunar festivals but not solar
/// terms, so the dates are committed data.
///
/// Terms run 小寒 → 冬至 in calendar order; the table holds one Gregorian
/// `(month, day)` per term per year. Dates for 2026–2030 come from the Hong Kong
/// Observatory conversion tables (the same independent source the lunar
/// festival fixtures cite):
/// https://www.hko.gov.hk/en/gts/time/calendar/text/files/T2026e.txt
/// They agree with the apparent-solar-longitude crossings (λ = 285° + 15°·k)
/// computed with NOAA's low-precision Sun. Outside the table the nearest year
/// is reused: a one-day drift cannot move a season, and no date is invented.
enum SolarTerm: Int, CaseIterable, Identifiable {    case minorCold, majorCold, springBegins, springShowers, insectsWaken, vernalEquinox
    case brightAndClear, grainRain, summerBegins, grainFull, grainInEar, summerSolstice
    case minorHeat, majorHeat, autumnBegins, endOfHeat, whiteDew, autumnalEquinox
    case coldDew, frostDescent, winterBegins, lightSnow, heavySnow, winterSolstice

    var id: Int { rawValue }

    enum Season: String, CaseIterable, Identifiable {
        case spring, summer, autumn, winter
        var id: String { rawValue }
        var chineseName: String {
            switch self {
            case .spring: return "春"
            case .summer: return "夏"
            case .autumn: return "秋"
            case .winter: return "冬"
            }
        }
    }

    var chineseName: String {
        switch self {
        case .minorCold: return "小寒"
        case .majorCold: return "大寒"
        case .springBegins: return "立春"
        case .springShowers: return "雨水"
        case .insectsWaken: return "惊蛰"
        case .vernalEquinox: return "春分"
        case .brightAndClear: return "清明"
        case .grainRain: return "谷雨"
        case .summerBegins: return "立夏"
        case .grainFull: return "小满"
        case .grainInEar: return "芒种"
        case .summerSolstice: return "夏至"
        case .minorHeat: return "小暑"
        case .majorHeat: return "大暑"
        case .autumnBegins: return "立秋"
        case .endOfHeat: return "处暑"
        case .whiteDew: return "白露"
        case .autumnalEquinox: return "秋分"
        case .coldDew: return "寒露"
        case .frostDescent: return "霜降"
        case .winterBegins: return "立冬"
        case .lightSnow: return "小雪"
        case .heavySnow: return "大雪"
        case .winterSolstice: return "冬至"
        }
    }

    /// 立春 / 立夏 / 立秋 / 立冬 open a season; the term's opening date decides
    /// the reading, so a day an hour before the crossing still belongs to the
    /// season that is ending.
    var season: Season {
        switch rawValue {
        case 2...7: return .spring
        case 8...13: return .summer
        case 14...19: return .autumn
        default: return .winter // 小寒 / 大寒 and 立冬 … 冬至
        }
    }

    /// Committed `(month, day)` per term, in `allCases` order, from the HKO
    /// tables. Keyed by Gregorian year in the observer's timezone.
    private static let published: [Int: [(Int, Int)]] = [
        2026: [(1, 5), (1, 20), (2, 4), (2, 18), (3, 5), (3, 20), (4, 5), (4, 20), (5, 5), (5, 21),
               (6, 5), (6, 21), (7, 7), (7, 23), (8, 7), (8, 23), (9, 7), (9, 23), (10, 8), (10, 23),
               (11, 7), (11, 22), (12, 7), (12, 22)],
        2027: [(1, 5), (1, 20), (2, 4), (2, 19), (3, 6), (3, 21), (4, 5), (4, 20), (5, 6), (5, 21),
               (6, 6), (6, 21), (7, 7), (7, 23), (8, 8), (8, 23), (9, 8), (9, 23), (10, 8), (10, 23),
               (11, 7), (11, 22), (12, 7), (12, 22)],
        2028: [(1, 6), (1, 20), (2, 4), (2, 19), (3, 5), (3, 20), (4, 4), (4, 19), (5, 5), (5, 20),
               (6, 5), (6, 21), (7, 6), (7, 22), (8, 7), (8, 22), (9, 7), (9, 22), (10, 8), (10, 23),
               (11, 7), (11, 22), (12, 6), (12, 21)],
        2029: [(1, 5), (1, 20), (2, 3), (2, 18), (3, 5), (3, 20), (4, 4), (4, 20), (5, 5), (5, 21),
               (6, 5), (6, 21), (7, 7), (7, 22), (8, 7), (8, 23), (9, 7), (9, 23), (10, 8), (10, 23),
               (11, 7), (11, 22), (12, 7), (12, 21)],
        2030: [(1, 5), (1, 20), (2, 4), (2, 18), (3, 5), (3, 20), (4, 5), (4, 20), (5, 5), (5, 21),
               (6, 5), (6, 21), (7, 7), (7, 23), (8, 7), (8, 23), (9, 7), (9, 23), (10, 8), (10, 23),
               (11, 7), (11, 22), (12, 7), (12, 22)],
    ]

    /// The table for a year, clamped to the published window. Never nil.
    private static func schedule(for year: Int) -> [(Int, Int)] {
        let clamped = min(2030, max(2026, year))
        return published[clamped] ?? published[2026]!
    }

    private static func components(_ date: Date, calendar: Calendar) -> (year: Int, month: Int, day: Int)? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month, let day = c.day else { return nil }
        return (year, month, day)
    }

    /// Today's term, or nil on any ordinary day.
    static func term(on date: Date, calendar: Calendar = .current) -> SolarTerm? {
        guard let (year, month, day) = components(date, calendar: calendar) else { return nil }
        let days = schedule(for: year)
        for (index, entry) in days.enumerated() where entry.0 == month && entry.1 == day {
            return SolarTerm(rawValue: index)
        }
        return nil
    }

    /// The season the date falls in, opened by the most recent term boundary.
    static func season(on date: Date, calendar: Calendar = .current) -> Season {
        guard let (year, month, day) = components(date, calendar: calendar) else { return .winter }
        let days = schedule(for: year)
        var current: SolarTerm = .winterSolstice // before 小寒: still the winter 冬至 brought
        for (index, entry) in days.enumerated() {
            if (entry.0, entry.1) <= (month, day), let term = SolarTerm(rawValue: index) {
                current = term
            }
        }
        return current.season
    }

    /// Two real verse lines per term, with the source as the aside. Lines stay
    /// short enough for the card's single-line headline (≤ 7 characters).
    var chineseVerses: [(String, String)] {
        switch self {
        case .minorCold:
            return [("小寒连大吕", "元稹《咏廿四气诗》——天寒，记得添衣"),
                    ("霜严衣带断", "杜甫《自京赴奉先县咏怀》——冷起来了，多穿一件")]
        case .majorCold:
            return [("旧雪未及消", "邵雍《大寒吟》——天寒地冻，路上慢些"),
                    ("大寒须遣酒争豪", "文同《和仲蒙夜坐》——寒夜里，暖一暖自己")]
        case .springBegins:
            return [("万物生光辉", "汉乐府《长歌行》——春来了，一切都刚刚开始"),
                    ("柳色早黄浅", "白居易《立春日》——春日初醒，慢慢舒展")]
        case .springShowers:
            return [("润物细无声", "杜甫《春夜喜雨》——细雨无声，愿你也安稳"),
                    ("天街小雨润如酥", "韩愈《早春》——小雨初歇，路上留心")]
        case .insectsWaken:
            return [("春江水暖鸭先知", "苏轼《惠崇春江晚景》——春雷响，万物长"),
                    ("一雷惊蛰始", "韦应物《观田家》——惊蛰到了，愿你醒神")]
        case .vernalEquinox:
            return [("迟日江山丽", "杜甫《绝句》——昼夜平分，正好出发"),
                    ("万紫千红总是春", "朱熹《春日》——春分时节，正好")]
        case .brightAndClear:
            return [("清明时节雨纷纷", "杜牧《清明》——清明有雨，路上慢些"),
                    ("梨花落后清明", "晏殊《破阵子》——记得问候牵挂的人")]
        case .grainRain:
            return [("谷雨春光晓", "元稹《咏廿四气诗》——春将尽，绿正浓"),
                    ("绿遍山原白满川", "范成大《村居即事》——气清而暖，正好做事")]
        case .summerBegins:
            return [("绿树阴浓夏日长", "高骈《山亭夏日》——入夏了，记得多喝水"),
                    ("芭蕉分绿与窗纱", "杨万里《闲居初夏午睡起》——草木成荫，从容些")]
        case .grainFull:
            return [("小荷才露尖尖角", "杨万里《小池》——愿你也有小小的满足"),
                    ("夜莺啼绿柳", "欧阳修《小满》——将满未满，刚刚好")]
        case .grainInEar:
            return [("时雨及芒种", "陆游《时雨》——芒种时节，忙里也歇歇"),
                    ("田家少闲月", "白居易《观刈麦》——忙归忙，记得吃饭")]
        case .summerSolstice:
            return [("昼晷已云极", "韦应物《夏至避暑北池》——日最长，慢一点也好"),
                    ("接天莲叶无穷碧", "杨万里《晓出净慈寺》——盛夏正好")]
        case .minorHeat:
            return [("倏忽温风至", "元稹《咏廿四气诗》——暑气渐盛，记得避暑"),
                    ("月明船笛参差起", "秦观《纳凉》——找个阴凉，歇一歇")]
        case .majorHeat:
            return [("何以销烦暑", "白居易《消暑》——心静自然凉"),
                    ("懒摇白羽扇", "李白《夏日山中》——三伏天，多喝水")]
        case .autumnBegins:
            return [("风吹一片叶", "杜牧《早秋》——秋来了，天凉好个秋"),
                    ("睡起秋声无觅处", "刘翰《立秋》——暑气将退，慢慢来")]
        case .endOfHeat:
            return [("离离暑云散", "白居易《早秋曲江感怀》——暑气渐退，清凉正好"),
                    ("晴空一鹤排云上", "刘禹锡《秋词》——秋意初来，缓一缓")]
        case .whiteDew:
            return [("露从今夜白", "杜甫《月夜忆舍弟》——白露生，夜转凉"),
                    ("玉阶生白露", "李白《玉阶怨》——露重了，多添衣")]
        case .autumnalEquinox:
            return [("湖光秋月两相和", "刘禹锡《望洞庭》——秋分日，昼夜均而寒暑平"),
                    ("秋水共长天一色", "王勃《滕王阁序》——天高气爽，正好")]
        case .coldDew:
            return [("空山新雨后", "王维《山居秋暝》——寒露时节，天凉加衣"),
                    ("露似真珠月似弓", "白居易《暮江吟》——夜凉了，早些归家")]
        case .frostDescent:
            return [("霜叶红于二月花", "杜牧《山行》——霜降了，秋色正浓"),
                    ("月落乌啼霜满天", "张继《枫桥夜泊》——夜有霜，记添衣")]
        case .winterBegins:
            return [("冻笔新诗懒写", "李白《立冬》——立冬了，屋里暖一些"),
                    ("绿蚁新醅酒", "白居易《问刘十九》——天冷了，来杯热的")]
        case .lightSnow:
            return [("晚来天欲雪", "白居易《问刘十九》——可能要下雪了，路上慢些"),
                    ("忽如一夜春风来", "岑参《白雪歌》——初雪带寒，注意保暖")]
        case .heavySnow:
            return [("六出飞花入户时", "高骈《对雪》——雪落无声，愿你也安宁"),
                    ("大雪满弓刀", "卢纶《塞下曲》——雪大，注意保暖")]
        case .winterSolstice:
            return [("冬至阳生春又来", "杜甫《小至》——冬至到，白昼渐长"),
                    ("邯郸驿里逢冬至", "白居易《邯郸冬至夜思家》——愿有人相伴")]
        }
    }

    /// Short public-domain English fragments for the same term (kept brief so
    /// the single-line headline stays legible).
    var englishVerses: [(String, String)] {
        switch self {
        case .minorCold, .majorCold:
            return [("cold morning", "a chilly day, keep warm"),
                    ("frost at midnight", "Coleridge - a quiet, cold hour")]
        case .springBegins, .springShowers:
            return [("the darling buds", "Shakespeare - spring is beginning"),
                    ("soft spring rain", "a gentle season, no need to rush")]
        case .insectsWaken, .vernalEquinox:
            return [("a light in spring", "Dickinson - the world is waking"),
                    ("the waking year", "even light, gentle days")]
        case .brightAndClear, .grainRain:
            return [("april showers", "the green season, take it gently"),
                    ("green april", "a growing day, one step at a time")]
        case .summerBegins, .grainFull:
            return [("summer's breath", "warm days, drink some water"),
                    ("green and golden", "a slow summer afternoon")]
        case .grainInEar, .summerSolstice:
            return [("long june light", "the longest day, still take breaks"),
                    ("midsummer heat", "a bright day, be kind to yourself")]
        case .minorHeat, .majorHeat:
            return [("high summer", "find some shade, rest a little"),
                    ("noon of summer", "a warm day, drink often")]
        case .autumnBegins, .endOfHeat:
            return [("season of mists", "Keats - autumn is arriving"),
                    ("mellow fruitfulness", "Keats - a rich, soft season")]
        case .whiteDew, .autumnalEquinox:
            return [("dew on the grass", "a fresh morning, take your time"),
                    ("equal day and night", "balanced hours, a balanced pace")]
        case .coldDew, .frostDescent:
            return [("a touch of frost", "cold mornings, wear a layer"),
                    ("leaves turning", "autumn deepens, slow down")]
        case .winterBegins, .lightSnow:
            return [("first cold air", "winter is near, keep cozy"),
                    ("light snow falling", "quiet flakes, a quiet hour")]
        case .heavySnow, .winterSolstice:
            return [("the shortest day", "winter's heart, rest a little"),
                    ("snow, still night", "a hush outside, peace within")]
        }
    }
}

extension SolarTerm.Season {
    /// Which band of the day the greeting is drawn for. Kept local to the
    /// calendar so the season pools compile without the greeting's `DayPart`.
    enum Daylight { case night, dawn, day }

    /// The lines an ordinary day draws from: a restful quartet for bedtime, a
    /// quiet couplet for dawn, and season-coloured verses for the working day.
    func verses(chinese: Bool, daylight: Daylight) -> [(String, String)] {
        if chinese {
            switch daylight {
            case .night: return restfulChinese
            case .dawn: return dawnChinese
            case .day: return dayChinese
            }
        }
        switch daylight {
        case .night: return restfulEnglish
        case .dawn: return dawnEnglish
        case .day: return dayEnglish
        }
    }

    /// Weekend lines stay warm rather than poetic; the day is already restful.
    func weekendVerses(chinese: Bool) -> [(String, String)] {
        chinese
            ? [("周末愉快", "愿今天有一点闲，也有一点喜欢"),
               ("慢一点也好", "留点时间，做一件让自己开心的事"),
               ("今天自在些", "不赶路的时候，也看看身边的风景"),
               ("给生活留白", "一顿好饭，一段散步，都很值得"),
               ("愿你轻松些", "忙里也记得，给自己一个小小的休息"),
               ("把日子过暖", "和喜欢的人，说说话，笑一笑")]
            : [("a quiet weekend", "some time to yourself, and something you like"),
               ("take it slow", "leave room for one small happy thing"),
               ("easy does it", "no need to hurry anywhere today"),
               ("space to breathe", "a good meal, a long walk, both worthwhile"),
               ("rest a little", "a small pause, even in a busy day"),
               ("warm the hours", "talk and laugh with someone you like")]
    }

    private var restfulChinese: [(String, String)] {
        switch self {
        case .spring: return [("夜来风雨声", "孟浩然《春晓》——夜深了，安心睡吧"),
                              ("春眠不觉晓", "孟浩然《春晓》——早点休息，做个好梦")]
        case .summer: return [("明月来相照", "王维《竹里馆》——夜深了，早些歇息"),
                              ("清风半夜鸣蝉", "辛弃疾《西江月》——夜凉了，慢慢收尾吧")]
        case .autumn: return [("银烛秋光冷画屏", "杜牧《秋夕》——夜已深，早些安睡"),
                              ("明月松间照", "王维《山居秋暝》——夜里转凉，早点休息")]
        case .winter: return [("风雪夜归人", "刘长卿《逢雪宿芙蓉山》——夜深了，屋里暖一些"),
                              ("独钓寒江雪", "柳宗元《江雪》——夜静了，早些休息吧")]
        }
    }

    private var dawnChinese: [(String, String)] {
        switch self {
        case .spring: return [("春眠不觉晓", "孟浩然《春晓》——新的一天，慢慢来"),
                              ("清晨入古寺", "常建《题破山寺后禅院》——清晨好，先照顾好自己")]
        case .summer: return [("接天莲叶无穷碧", "杨万里——夏日清晨，愿你有好心情"),
                              ("小荷才露尖尖角", "杨万里《小池》——清晨好，一切正好")]
        case .autumn: return [("空山新雨后", "王维《山居秋暝》——新的一天，轻轻开始"),
                              ("霜叶红于二月花", "杜牧《山行》——晨光里，别急着出发")]
        case .winter: return [("忽如一夜春风来", "岑参《白雪歌》——清晨好，屋里暖一些"),
                              ("窗含西岭千秋雪", "杜甫《绝句》——新的一天，慢慢来")]
        }
    }

    private var dayChinese: [(String, String)] {
        switch self {
        case .spring: return [("春色满园关不住", "叶绍翁《游园不值》——春正好，慢慢做事"),
                              ("等闲识得东风面", "朱熹《春日》——愿你眼里有光"),
                              ("迟日江山丽", "杜甫《绝句》——阳光正好，慢慢来"),
                              ("润物细无声", "杜甫《春夜喜雨》——一步一步，也在向前")]
        case .summer: return [("绿树阴浓夏日长", "高骈《山亭夏日》——天热了，记得喝水"),
                              ("接天莲叶无穷碧", "杨万里《晓出净慈寺》——觅一处清凉"),
                              ("映日荷花别样红", "杨万里《晓出净慈寺》——夏日悠长，从容些"),
                              ("稻花香里说丰年", "辛弃疾《西江月》——愿你也有好心情")]
        case .autumn: return [("停车坐爱枫林晚", "杜牧《山行》——秋色正好，慢一点"),
                              ("湖光秋月两相和", "刘禹锡《望洞庭》——天高气爽，正好做事"),
                              ("自古逢秋悲寂寥", "刘禹锡《秋词》——我言秋日胜春朝"),
                              ("月落乌啼霜满天", "张继——秋深了，记得添衣")]
        case .winter: return [("绿蚁新醅酒", "白居易《问刘十九》——天冷了，暖一暖"),
                              ("忽如一夜春风来", "岑参《白雪歌》——冬日里，愿你温暖"),
                              ("晚来天欲雪", "白居易——可能下雪，路上慢些"),
                              ("墙角数枝梅", "王安石《梅花》——凌寒独自开，愿你坚韧")]
        }
    }

    private var restfulEnglish: [(String, String)] {
        switch self {
        case .spring: return [("rain full of ghosts", "a soft night, rest well"),
                              ("sleep, that knits up", "Shakespeare - rest a little")]
        case .summer: return [("fireflies, warm night", "wind down, and sleep soon"),
                              ("the murmuring of bees", "a still evening, rest soon")]
        case .autumn: return [("a late lark twitters", "a cool night, rest when you can"),
                              ("soft autumn rain", "let the day go, and rest")]
        case .winter: return [("snowy evening", "Frost - a cold night, get warm"),
                              ("the darkest evening", "Frost - rest, and sleep well")]
        }
    }

    private var dawnEnglish: [(String, String)] {
        switch self {
        case .spring: return [("a light in spring", "Dickinson - a new day, start gently"),
                              ("the first morning", "take your time, there is no rush")]
        case .summer: return [("a bright summer morning", "warm and early, take it easy"),
                              ("sun upon the lake", "a fresh start, one step at a time")]
        case .autumn: return [("mists and mellow fruit", "Keats - a gentle morning"),
                              ("a calm bright morning", "a good day to begin slowly")]
        case .winter: return [("pale winter morning", "start warm and unhurried"),
                              ("a kind frosty morning", "a new day, take your time")]
        }
    }

    private var dayEnglish: [(String, String)] {
        switch self {
        case .spring: return [("the darling buds", "Shakespeare - spring all around"),
                              ("daffodils, a lake", "Wordsworth - a bright, gentle day"),
                              ("a light in spring", "Dickinson - room for something lovely"),
                              ("rain-washed green", "one small step at a time")]
        case .summer: return [("green and golden", "warm hours, drink some water"),
                              ("summer's breath", "a slow afternoon, ease along"),
                              ("sunlight on leaves", "a bright day, rest a little"),
                              ("long june light", "a long day, no need to hurry")]
        case .autumn: return [("season of mists", "Keats - autumn is here, be gentle"),
                              ("leaves turning", "a cool day, slow down"),
                              ("a touch of frost", "autumn deepens, wear a layer"),
                              ("mellow fruitfulness", "Keats - a rich, soft season")]
        case .winter: return [("first cold air", "winter is near, keep cozy"),
                              ("light snow falling", "quiet flakes, a quiet hour"),
                              ("winter's heart", "the shortest day, rest a little"),
                              ("snow, still night", "a hush outside, peace within")]
        }
    }
}
