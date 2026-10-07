import Combine
import Foundation
import Observation

/// Current conditions and optional daily forecasts for the same location.
struct WeatherReading: Equatable {
    /// The place name as a person would say it ("上海 · 浦东新区").
    var place: String
    var temperatureC: Double
    var feelsLikeC: Double
    /// `ww`-style condition code from the source (WW O, e.g. 176, 143).
    var conditionCode: Int
    var conditionText: String
    var highC: Double
    var lowC: Double
    var humidity: Int
    var windKph: Double
    var windDirection: String
    /// 1 = day, 0 = night, nil = unknown.
    var isDay: Bool?
    /// Sunrise / sunset as the source reports them (`HH:mm`), for the tooltip.
    var sunrise: String
    var sunset: String
    /// How much rain the next few hours are carrying, 0…100. Drives the rain
    /// animation's droplet count, so a drizzle and a downpour are different
    /// pictures rather than the same one at a different label.
    var rainChance: Int
    var observedAt: Date
    var latitude: Double? = nil
    var longitude: Double? = nil
    var timezone: String = TimeZone.current.identifier
    var forecast: [WeatherDay] = []
    var forecastNote: String? = nil
    var source = "wttr.in"
    /// A sky the source stated outright, overriding the code table. The
    /// domestic sources (高德 / 中国天气网) name the weather in Chinese or in a
    /// code table of their own, and both would collide with the WMO / WW codes
    /// in `sky(for:)` if folded in there.
    var skyHint: Sky? = nil

    struct Hour: Equatable, Identifiable {
        var date: Date
        var temperature: Double?
        /// Accumulated precipitation during the hour ending at `date`.
        var precipitation: Double?
        var rainChance: Int?
        var wind: Double?
        var id: Date { date }
    }
    var hourly: [Hour] = []
    var hourlySource: String? = nil

    enum HourMetric: String {
        case precipitation, probability, temperature, wind
        var title: String {
            switch self {
            case .precipitation: return "小时降水量"
            case .probability: return "降水概率"
            case .temperature: return "小时气温"
            case .wind: return "小时风速"
            }
        }
        var unit: String {
            switch self {
            case .precipitation: return "mm"
            case .probability: return "%"
            case .temperature: return "°C"
            case .wind: return "km/h"
            }
        }
        func value(_ hour: Hour) -> Double? {
            switch self {
            case .precipitation: return hour.precipitation
            case .probability: return hour.rainChance.map(Double.init)
            case .temperature: return hour.temperature
            case .wind: return hour.wind
            }
        }
    }

    func upcomingHours(at date: Date) -> [Hour] {
        // Never replay the morning's rain or bridge a missing bucket as zero.
        Array(hourly.filter { $0.date > date && $0.date <= date.addingTimeInterval(6 * 3600) }
            .sorted { $0.date < $1.date }.prefix(6))
    }

    func hourMetric(at date: Date) -> HourMetric? {
        let hours = upcomingHours(at: date)
        let wet = [.rain, .drizzle, .thunder, .sleet, .snow, .hail].contains(sky)
            || hours.contains { ($0.precipitation ?? 0) > 0 || ($0.rainChance ?? 0) >= 50 }
        if wet {
            if hours.contains(where: { $0.precipitation != nil }) { return .precipitation }
            if hours.contains(where: { $0.rainChance != nil }) { return .probability }
            return nil
        }
        if hours.contains(where: { ($0.wind ?? 0) >= 28 }), hours.contains(where: { $0.wind != nil }) { return .wind }
        return hours.contains(where: { $0.temperature != nil }) ? .temperature : nil
    }

    func astronomy(at date: Date) -> SkyAstronomy.Snapshot? {
        guard let latitude, let longitude else { return nil }
        return SkyAstronomy.snapshot(date: date, latitude: latitude, longitude: longitude)
    }

    /// The sky family the animations are built on. Several WMO / WW codes are
    /// the same weather to a viewer ("patchy rain nearby" and "light drizzle"
    /// both mean *it is raining*), so the drawing is keyed on this, never on
    /// the raw code.
    enum Sky: String {
        case clear, partly, cloudy, fog, drizzle, rain, sleet, snow, hail, thunder

    }

    var sky: Sky { skyHint ?? Self.sky(for: conditionCode) }

    /// WW / WMO condition codes → the drawing family.
    ///
    /// Two numbering schemes arrive here and they overlap in the low hundreds,
    /// so the mapping is written against the *WW* table wttr.in serves (which
    /// is what the card actually gets) and the WMO codes are folded in
    /// explicitly rather than by range: 176/263/266/293/296/299/302/305/308/
    /// 311/314/353/356/359 are rain, 200/386/389/392/395 thunder, 179/182/185/
    /// 281/284/317/320/362/365/374/377 sleet/ice, 227/230/320s snow,
    /// 143/248/260 fog, 116/119/122 cloudy. Anything unrecognized falls to
    /// `cloudy`, which is the safe reading — a wrong grey card is a smaller
    /// lie than a wrong sun.
    static func sky(for code: Int) -> Sky {
        switch code {
        case 113: return .clear                          // Sunny / Clear
        case 116: return .partly                         // Partly cloudy
        case 119, 122: return .cloudy                    // Cloudy / Overcast
        case 143, 248, 260: return .fog                  // Mist / Fog
        case 263, 266, 51, 53, 55: return .drizzle
        case 176, 293, 296, 299, 302, 305, 308, 311, 314,
             353, 356, 359: return .rain
        case 179, 182, 185, 281, 284, 317, 320, 362, 365, 374, 377, 56, 57, 66, 67: return .sleet
        case 200, 386, 389, 392, 395: return .thunder
        case 227, 230, 323, 326, 329, 332, 335, 338, 350, 368, 371: return .snow
        case 0, 1: return .clear                         // WMO clear / mainly clear
        case 2: return .partly
        case 3: return .cloudy
        case 45, 48: return .fog
        case 61, 63, 65, 80, 81, 82: return .rain
        case 71, 73, 75, 77, 85, 86: return .snow
        case 95: return .thunder
        case 96, 99: return .hail
        default: return .cloudy
        }
    }

    /// A Chinese condition string → the drawing family, for the domestic
    /// sources (高德 "阴"/"雷阵雨", 中国天气网's `dataSK.weather`). Longer and more
    /// specific needles are tested first, because "雷阵雨" also contains "雨"
    /// and "雨夹雪" contains both "雨" and "雪".
    static func sky(forText text: String) -> Sky {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return .cloudy }
        func has(_ needles: String...) -> Bool { needles.contains { t.contains($0) } }
        if has("雷阵雨", "雷雨", "雷") { return .thunder }
        if has("冰雹") { return .hail }
        if has("雨夹雪", "冻雨", "雨雪", "雨凇") { return .sleet }
        if has("暴雨", "大雨", "中雨", "阵雨", "雷阵雨", "雨") {
            return has("暴雨", "大雨", "中雨", "阵雨") ? .rain : .drizzle
        }
        if has("毛毛雨", "细雨") { return .drizzle }
        if has("雪") { return .snow }
        if has("雾", "霾", "浮尘", "扬沙", "沙尘", "沙") { return .fog }
        if has("阴") { return .cloudy }
        if has("多云", "少云", "晴间") { return .partly }
        if has("晴") { return .clear }
        return .cloudy
    }

    /// 中国天气网's own code table (`d00`/`n7`/`d301` …). The digits live in
    /// 0–31 (plus 53 霾 and 301 雨) and would collide with the WMO codes in
    /// `sky(for:)`, so they are read here. Short and zero-padded forms are the
    /// same table (`dataSK` writes `d02`, a forecast cell writes `d2`).
    static func sky(forCNCode raw: String) -> Sky {
        switch cnCodeNumber(raw) {
        case 0: return .clear                 // 晴
        case 1: return .partly                // 多云
        case 2: return .cloudy                // 阴
        case 3, 21, 22, 23, 24, 25: return .rain   // 阵雨 / 小到中雨…大到暴雨
        case 4: return .thunder               // 雷阵雨
        case 5: return .hail                  // 雷阵雨伴有冰雹
        case 6, 19: return .sleet             // 雨夹雪 / 冻雨
        case 7: return .drizzle               // 小雨
        case 8, 9, 10, 11, 12, 301: return .rain   // 中雨…特大暴雨 / 雨
        case 13, 14, 15, 16, 17: return .snow // 阵雪 / 小雪…暴雪
        case 26, 27, 28: return .snow         // 小到中雪…大到暴雪
        case 18, 20, 29, 30, 31, 53: return .fog   // 雾 / 沙尘 / 浮尘 / 扬沙 / 霾
        default: return .cloudy
        }
    }

    /// The number in a 中国天气网 code ("d02" → 2, "n301" → 301, "d2" → 2).
    /// Nil when the string is not a code at all.
    static func cnCodeNumber(_ raw: String) -> Int? {
        Int(raw.drop { $0 == "d" || $0 == "n" })
    }

    /// The card's own caption for the sky — the source's English string
    /// translated to the one-word Chinese the rest of the app speaks. The raw
    /// text is kept for the tooltip, where there is room for it.
    var skyLabel: String {
        switch sky {
        case .clear: return isDay == false ? "晴夜" : "晴"
        case .partly: return isDay == false ? "少云" : "晴间多云"
        case .cloudy: return "多云"
        case .fog: return "有雾"
        case .rain: return rainChance >= 60 ? "有雨" : "阵雨"
        case .snow: return "有雪"
        case .thunder: return "雷雨"
        case .drizzle: return "毛毛雨"
        case .sleet: return "雨夹雪"
        case .hail: return "雷暴冰雹"
        }
    }

    /// `Double` → `Int` with a range guard, for every count that comes off a
    /// network payload. `Int(_:)` traps for any finite value outside `Int`'s
    /// range, so an odd number from a weather endpoint (`sd: 1e300`) would take
    /// the whole app down inside a refresh instead of leaving the last good
    /// reading on screen. `WeatherForecastFetcher` keeps the same guard for the
    /// same reason.
    ///
    /// The greeting card renders these values directly, so the guard has to be
    /// at the conversion rather than at the parse: `WeatherReading` carries
    /// whatever the source sent, and a consumer that says `Int(value.rounded())`
    /// reintroduces the trap the parsers were fixed for.
    static func wholeNumber(_ value: Double) -> Int {
        guard value >= Double(Int.min), value < Double(Int.max) else { return 0 }
        return Int(value)
    }

    /// A temperature as the card prints it — one decimal of a degree is noise
    /// on a tile read at a glance. Every label that shows a temperature goes
    /// through here, so the guard above cannot be bypassed by a consumer that
    /// rounds first and converts second.
    static func degreeText(_ value: Double) -> String {
        "\(wholeNumber(value.rounded()))°"
    }
}

/// Open-Meteo current + six-day weather, with wttr.in as a current-only fallback.
/// Named cities or permission-gated coordinates are provided by WeatherStore.
enum WeatherFetcher {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// `GET https://wttr.in/<city>?format=j1`. `lang=zh` gets the Chinese
    /// condition strings the caption prefers; the numeric `weatherCode` is what
    /// the drawing actually keys on, so a missing translation is harmless.
    static func url(city: String) -> URL? {
        let cleaned = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        var components = URLComponents(string: "https://wttr.in/\(cleaned)")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "j1"),
            // WMO/国内源全不可用时 this is the only source left, and the card
            // shows `conditionText` verbatim. wttr.in answers English without
            // this; with it, the WW-code → 中文 mapping the caption reads.
            URLQueryItem(name: "lang", value: "zh"),
        ]
        return components?.url
    }

    /// Pure, so the mapping can be exercised without a network — see
    /// `Tests/weather-card-regressions.py`.
    static func parse(_ data: Data) -> WeatherReading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = (root["current_condition"] as? [[String: Any]])?.first else { return nil }

        func double(_ key: String) -> Double? {
            if let n = current[key] as? NSNumber { return n.doubleValue }
            if let s = current[key] as? String { return Double(s) }
            return nil
        }
        func int(_ key: String) -> Int? {
            // `NSNumber.intValue` *saturates*: a numeric `1e300` becomes
            // `Int.max` and prints as 9223372036854775807% instead of being
            // rejected, which is a worse failure than a missing reading. Keep
            // the same bounded conversion the parsers elsewhere use — and take
            // the string spelling through it too, since `Int("9223372036854775807")`
            // parses exactly at the boundary and lands the same garbage figure.
            if let n = current[key] as? NSNumber {
                let d = n.doubleValue
                guard d >= Double(Int.min), d < Double(Int.max) else { return nil }
                return n.intValue
            }
            if let s = current[key] as? String, let d = Double(s) {
                guard d >= Double(Int.min), d < Double(Int.max) else { return nil }
                return Int(d)
            }
            return nil
        }

        guard let temperature = double("temp_C") else { return nil }

        let today = (root["weather"] as? [[String: Any]])?.first
        let high = today.flatMap { ($0["maxtempC"] as? String).flatMap(Double.init) } ?? temperature
        let low = today.flatMap { ($0["mintempC"] as? String).flatMap(Double.init) } ?? temperature

        var sunrise = "", sunset = ""
        if let astro = (today?["astronomy"] as? [[String: Any]])?.first {
            sunrise = astro["sunrise"] as? String ?? ""
            sunset = astro["sunset"] as? String ?? ""
        }

        // The rain chance for the next few hours, not the whole day: a 30 %
        // daily chance that already fell at dawn should not paint rain on a
        // clear afternoon, and the hourly buckets are what the source knows.
        var rainChance = 0
        if let hours = today?["hourly"] as? [[String: Any]] {
            rainChance = upcomingRainChance(
                buckets: hours, localHour: Calendar.current.component(.hour, from: Date()))
        }

        let description = ((current["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? ""

        return WeatherReading(
            place: placeName(from: root),
            temperatureC: temperature,
            feelsLikeC: double("FeelsLikeC") ?? temperature,
            conditionCode: int("weatherCode") ?? 119,
            conditionText: description,
            highC: high,
            lowC: low,
            humidity: int("humidity") ?? 0,
            windKph: double("windspeedKmph") ?? 0,
            windDirection: current["winddir16Point"] as? String ?? "",
            isDay: int("isdaytime").map { $0 == 1 } ?? dayGuess(
                localObservation: current["localObsDateTime"] as? String,
                sunrise: sunrise, sunset: sunset),
            sunrise: sunrise,
            sunset: sunset,
            rainChance: rainChance,
            observedAt: Date(),
            latitude: ((root["nearest_area"] as? [[String: Any]])?.first?["latitude"] as? String).flatMap(Double.init),
            longitude: ((root["nearest_area"] as? [[String: Any]])?.first?["longitude"] as? String).flatMap(Double.init)
        )
    }

    /// The highest rain chance in the three-hour window starting at `localHour`.
    ///
    /// A wttr.in bucket's `time` is the hour as `HHMM` without the minutes
    /// ("300" = 03:00) **in the location's local time**, and the array always
    /// starts at local midnight — so reading the first four quotes midnight to
    /// 09:00 no matter what the clock says, and by the afternoon the card is
    /// showing a morning that has already fallen. Which is exactly the failure
    /// the "next few hours" wording exists to prevent.
    ///
    /// `localHour` is the caller's own clock. That is a deliberate, bounded
    /// approximation: the endpoint publishes no timezone, `observation_time`
    /// is UTC (Shanghai, London and Los Angeles all read ~04:00 while Auckland
    /// read 05:07 — the same instant, not their local clocks), and synthesising
    /// a zone from coordinates puts a mainland IP's city in the wrong one
    /// entirely. For the place a person watches, the device clock and the
    /// location clock agree; when they do not, the window is off by the zone
    /// offset, which is the same error the old code made unconditionally.
    static func upcomingRainChance(buckets: [[String: Any]], localHour: Int) -> Int {
        let mark = max(0, localHour) * 100
        var start = 0
        for (index, entry) in buckets.enumerated() {
            if ((entry["time"] as? String).flatMap(Int.init) ?? 0) <= mark { start = index } else { break }
        }
        return buckets[start...].prefix(4)
            .compactMap { ($0["chanceofrain"] as? String).flatMap(Int.init) }
            .max() ?? 0
    }

    /// `nearest_area` → "上海 · 浦东新区". The region is dropped when it merely
    /// repeats the city (the common case for a municipality like 上海).
    private static func placeName(from root: [String: Any]) -> String {
        guard let area = (root["nearest_area"] as? [[String: Any]])?.first else { return "" }
        func value(_ key: String) -> String {
            ((area[key] as? [[String: Any]])?.first?["value"] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
        let city = value("areaName")
        let region = value("region")
        if city.isEmpty { return region }
        if region.isEmpty || region == city { return city }
        return "\(city) · \(region)"
    }

    /// Observation_time is UTC; astronomy is local. Compare local minutes so
    /// evening skies do not stay sunny and sunrise does not round to the hour.
    private static func dayGuess(localObservation: String?, sunrise: String, sunset: String) -> Bool? {
        guard let localObservation else { return nil }
        let clock: String
        if let space = localObservation.firstIndex(of: " "), localObservation.prefix(upTo: space).contains("-") {
            clock = String(localObservation[localObservation.index(after: space)...])
        } else { clock = localObservation }
        guard let now = minutes(clock), let rise = minutes(sunrise), let set = minutes(sunset) else { return nil }
        return now >= rise && now < set
    }

    private static func minutes(_ clock: String) -> Int? {
        let trimmed = clock.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2 else { return nil }
        let hourPart = parts[0].trimmingCharacters(in: .whitespaces)
        let minutePart = parts[1].prefix(while: \.isNumber)
        guard let hour = Int(hourPart), let minute = Int(minutePart),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let isPM = trimmed.uppercased().contains("PM")
        let isAM = trimmed.uppercased().contains("AM")
        var hour24 = hour
        if isPM { hour24 = hour % 12 + 12 }
        if isAM { hour24 = hour % 12 }
        return hour24 * 60 + minute
    }
}

/// AMap (高德) and 中国天气网 parse helpers, kept as free functions so both the
/// fetchers and the regression probe reach them. Everything here is pure: JSON
/// or JS text in, a `WeatherReading` out.
///
/// The two domestic sources are the point of the exercise — they answer over
/// Chinese IPs, so mihomo's `GEOIP,CN → Direct` rule keeps weather working with
/// no proxy at all. Neither speaks WMO codes, and neither serves a timezone,
/// sunrise or rain probability, so the readings they produce lean on `skyHint`
/// and on a condition string mapped through `WeatherReading.sky(forText:)`.
enum DomesticWeatherParser {
    /// Beaufort level ("≤3", "1-3", "4") → a wind speed the dial can draw.
    /// AMap's `windpower` is a level, not a speed; feeding it to `windKph`
    /// would label the dial with the level number as if it were km/h.
    static func windKph(fromBeaufort text: String?) -> Double {
        guard let level = beaufortLevel(text) else { return 0 }
        // Mid-band km/h for each Beaufort number, generous but monotone.
        let bands = [0.0, 3.0, 8.0, 15.0, 24.0, 34.0, 45.0, 57.0, 70.0,
                     84.0, 99.0, 115.0, 131.0]
        return bands[min(level, bands.count - 1)]
    }

    /// The level a power string states: the mean of an open range ("1-3" → 2,
    /// "4-5" → 4) and the value itself for "≤3" / "3级" / "3".
    ///
    /// The tokens are split, not the characters: taking the digits one by one
    /// reads "10" as [1, 0] → level 1 → 3 km/h, so a typhoon-force observation
    /// renders as a breeze on the dial and in the VoiceOver string. AMap's
    /// `windpower` goes up to 12 and 中国天气网's `WS` spells the same scale as
    /// "10级".
    static func beaufortLevel(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        // Each token is capped before the sum: `(a + b + 1)` on two
        // wire-supplied 19-digit values traps the whole app under `-O`, and
        // this is a band, not arithmetic — AMap's `windpower` and 中国天气网's
        // `WS` top out at 17 in the published scale.
        let parts = text.split { !$0.isNumber }.compactMap { Int($0) }.prefix(2).map { min($0, 17) }
        guard !parts.isEmpty else { return nil }
        if parts.count >= 2 { return (parts[0] + parts[1] + 1) / 2 }
        return parts[0]
    }

    /// How much rain the next few hours are carrying, estimated from the
    /// condition word — the domestic sources do not publish a probability.
    /// Only drives the droplet count and the 阵雨/有雨 caption, so a coarse
    /// band is honest enough.
    static func rainChance(fromText text: String) -> Int {
        rainChance(forSky: WeatherReading.sky(forText: text), severity: text)
    }

    /// The same band keyed on a sky family instead of a word, for the forecast
    /// cells that carry only a code.
    static func rainChance(forSky sky: WeatherReading.Sky, severity: String = "") -> Int {
        switch sky {
        case .thunder: return 80
        case .hail: return 70
        case .rain:
            if severity.contains("暴雨") { return 90 }
            if severity.contains("大雨") { return 85 }
            if severity.contains("中雨") { return 65 }
            return 40
        case .drizzle: return 35
        case .sleet, .snow: return 50
        default: return 0
        }
    }

    /// "上海市 · 浦东新区"-shaped place from a regeo `addressComponent`.
    /// Municipalities leave `city` empty in AMap's payload — the province *is*
    /// the city there — so the fallback order matters. `district` is only
    /// appended when it is not the city repeating itself, matching
    /// `PlaceNamer.format`.
    static func placeName(city: Any?, province: Any?, district: Any?) -> String {
        func text(_ value: Any?) -> String {
            (value as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let cityText = text(city)
        let provinceText = text(province)
        let districtText = text(district)
        let base = !cityText.isEmpty ? cityText : provinceText
        guard !base.isEmpty else { return districtText }
        let short = base.count > 2 && base.hasSuffix("市") ? String(base.dropLast()) : base
        guard !districtText.isEmpty, districtText != base else { return short }
        return "\(short) · \(districtText)"
    }

    /// "lon,lat" → (lat, lon). AMap orders location strings longitude-first.
    static func coordinate(_ location: Any?) -> (latitude: Double, longitude: Double)? {
        guard let location = location as? String else { return nil }
        let parts = location.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return (latitude: parts[1], longitude: parts[0])
    }

    /// A `WeatherReading` from AMap's `weatherInfo` (`lives`) plus its
    /// `forecasts[].casts[]` (zero to four days), or nil when neither is
    /// usable. `latitude` / `longitude` are filled from the geocode step when
    /// one was made.
    static func reading(live: [String: Any]?, forecast: [String: Any]?,
                        place: String, latitude: Double?, longitude: Double?) -> WeatherReading? {
        func liveValue(_ key: String) -> Double? {
            if let n = live?[key] as? NSNumber { return n.doubleValue }
            if let s = live?[key] as? String { return Double(s) }
            return nil
        }
        let casts = (forecast?["casts"] as? [[String: Any]]) ?? []
        guard let temperature = liveValue("temperature") else { return nil }
        let weatherText = (live?["weather"] as? String) ?? ""
        let skyHint = WeatherReading.sky(forText: weatherText)

        var days: [WeatherDay] = []
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        for cast in casts {
            guard let dateText = cast["date"] as? String,
                  let date = formatter.date(from: dateText),
                  let high = number(cast["daytemp"]), let low = number(cast["nighttemp"]) else { continue }
            let text = [cast["dayweather"], cast["nightweather"]].compactMap { $0 as? String }.joined()
            days.append(WeatherDay(date: date, code: -1, high: high, low: low,
                                   rainChance: rainChance(fromText: text),
                                   wind: nil, sunrise: nil, sunset: nil,
                                   skyHint: WeatherReading.sky(forText: text)))
        }
        // Today in the *reading's* timezone, not the device's.
        //
        // Both domestic sources report mainland China, and both date their
        // forecast cells in Asia/Shanghai, so "which cell is today" has to be
        // asked in that zone too. Asking it in the device's zone (the default
        // calendar) is wrong twice over: a Mac in Tokyo reads the card an hour
        // before midnight in Shanghai and gets *tomorrow's* high/low for two
        // hours of every day, and a Mac in London or New York lands on the
        // cell *before* the first one when the two zones are on different
        // dates. `WeatherForecastFetcher` and the 中国天气网 path already pass
        // the right zone; this was the one left on the device's.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? calendar.timeZone
        let today = days.first { calendar.isDate($0.date, inSameDayAs: Date()) } ?? days.first
        return WeatherReading(
            place: place.isEmpty ? (live?["city"] as? String ?? "当前位置") : place,
            temperatureC: temperature,
            feelsLikeC: temperature,
            conditionCode: -1,
            conditionText: weatherText,
            highC: today?.high ?? temperature,
            lowC: today?.low ?? temperature,
            humidity: WeatherReading.wholeNumber(liveValue("humidity") ?? 0),
            windKph: windKph(fromBeaufort: live?["windpower"] as? String),
            windDirection: live?["winddirection"] as? String ?? "",
            isDay: nil,
            sunrise: "—", sunset: "—",
            rainChance: today?.rainChance ?? 0,
            observedAt: reportDate(live?["reporttime"] as? String),
            latitude: latitude, longitude: longitude,
            timezone: "Asia/Shanghai", forecast: days,
            forecastNote: days.isEmpty ? "预报暂不可用 · 点击刷新重试" : nil,
            source: "高德", skyHint: skyHint)
    }

    /// A single reading from 中国天气网's `dataSK` plus its `fc.f[]` array.
    /// `weather_index` is a JS file, not JSON: `var dataSK ={…};var fc ={"f":[…]}`.
    /// The value is pulled out by brace matching rather than a non-greedy regex,
    /// because the payload has nested objects and `};` appears inside it.
    static func jsonVariable(_ name: String, in text: String) -> [String: Any]? {
        guard let range = text.range(of: "var \(name)") else { return nil }
        guard let start = text[range.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let json = text[start...index]
                    return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func reading(dataSK: [String: Any], forecast: [String: Any]?) -> WeatherReading? {
        guard let temperature = number(dataSK["temp"]) else { return nil }
        let weatherText = (dataSK["weather"] as? String) ?? ""

        let days = cnForecastDays(forecast)
        // The cell whose own date is today in Asia/Shanghai, not `days.first`.
        // The source's first cell keeps `fj: "今天"` from the previous day's
        // refresh until it recomputes a few hours after midnight — measured
        // 2026-10-06 02:10 Asia/Shanghai on four cities: `dataSK.date` read
        // "10月06日(星期二)" while `fc.f[0]` was still `(fi: "10/5", fj: "今天")`.
        // Reading it as today put yesterday's high/low on the card in the small
        // hours. Same rule, and the same reason, as the 高德 path above.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? calendar.timeZone
        let today = days.first { calendar.isDate($0.date, inSameDayAs: Date()) } ?? days.first
        // `rain` is millimetres of precipitation, not a probability — a live
        // reading carries "0" on a dry hour and "2.7" in a shower, so the old
        // `rain * 100` painted a 3 mm hour as 270 % and the umbrella at 100 %.
        // The field's own probability is the forecast cells' business; for the
        // live hour the condition word is the only probability there is.
        let rainChance = rainChance(fromText: weatherText)
        return WeatherReading(
            place: (dataSK["cityname"] as? String) ?? "",
            temperatureC: temperature,
            feelsLikeC: temperature,
            conditionCode: -1,
            conditionText: weatherText,
            highC: today?.high ?? temperature,
            lowC: today?.low ?? temperature,
            humidity: WeatherReading.wholeNumber(number(dataSK["sd"]) ?? percent(dataSK["SD"]) ?? 0),
            windKph: windKph(fromBeaufort: dataSK["WS"] as? String),
            windDirection: (dataSK["WD"] as? String) ?? "",
            isDay: nil,
            sunrise: "—", sunset: "—",
            rainChance: rainChance,
            observedAt: Date(),
            timezone: "Asia/Shanghai", forecast: days,
            forecastNote: days.isEmpty ? "预报暂不可用 · 点击刷新重试" : nil,
            source: "中国天气网",
            skyHint: WeatherReading.sky(forCNCode: (dataSK["weathercode"] as? String) ?? ""))
    }

    /// `fc.f[]` → days. The date arrives as "9/29"; the code as "d00"/"n7"/"d1".
    /// Year is taken from `now`, which is right for a rolling forecast and for
    /// the New Year boundary the source would have to disambiguate anyway.
    ///
    /// `fc`/`fd` are the day high and the day low. Measured against the live
    /// payload (上海, 2026-10-06): `fc` 23 / `fd` 15, then 25/17, 25/17, 24/18
    /// — day-minus-night gaps of 6–8 °C, which is the 5-day range this feed
    /// publishes, not the hour-to-hour pair. `fa`/`fb` are the *day* and
    /// *night* condition codes, and the temperature on this site tracks the
    /// civil day, so the pair is a daily high/low.
    static func cnForecastDays(_ forecast: [String: Any]?) -> [WeatherDay] {
        guard let entries = forecast?["f"] as? [[String: Any]] else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? calendar.timeZone
        let year = calendar.component(.year, from: Date())
        var days: [WeatherDay] = []
        for entry in entries {
            guard let date = cnDate(entry["fi"] as? String, year: year, calendar: calendar) else { continue }
            let high = number(entry["fc"]) ?? number(entry["fd"]) ?? 0
            let low = number(entry["fd"]) ?? high
            let sky = WeatherReading.sky(forCNCode: (entry["fa"] as? String) ?? "")
            days.append(WeatherDay(date: date, code: -1, high: high, low: low,
                                   rainChance: rainChance(forSky: sky),
                                   wind: nil, sunrise: nil, sunset: nil,
                                   skyHint: sky))
        }
        return days
    }

    private static func cnDate(_ text: String?, year: Int, calendar: Calendar) -> Date? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = parts[0]
        components.day = parts[1]
        components.hour = 12
        return calendar.date(from: components)
    }

    private static func reportDate(_ text: String?) -> Date {
        guard let text else { return Date() }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text) ?? Date()
    }

    /// Last-resort name → cityid: a frozen city table compiled into the binary,
    /// fetched by `Tools/gen-cn-weather-cities.py`. 中国天气网's own search API
    /// (`toy1.weather.com.cn/search`) started answering `()` for every name, so
    /// the lookup has to come from our side.
    ///
    /// Two deliberate limits: the table holds prefecture-level cities only (a
    /// district like 浦东新区 is not in it), and it has no redirect layer — a
    /// name the table misses returns nil and the caller falls through to
    /// Open-Meteo rather than guessing.
    static func cityID(forName name: String, tableJSON: String) -> String? {
        cityLookup(in: tableJSON)[normalizedCity(name)]
    }
    /// The JSON is decoded on every call — the table is ~7 KB and the lookup
    /// happens once per 15-minute refresh, so a cache would cost more than it
    /// saves. Kept as text in the source so the regression probe compiles it
    /// without a bundle.
    static func cityLookup(in tableJSON: String) -> [String: String] {
        guard let data = tableJSON.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return rows
    }

    /// "上海市"/"杭州 市" → "上海"/"杭州", and "浙江杭州" → "杭州". The table's
    /// keys are bare prefecture names.
    static func normalizedCity(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: " ", with: "")
        if text.count > 2, text.hasSuffix("市") { text = String(text.dropLast()) }
        return text
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }


    /// 中国天气网 writes humidity twice — `sd` as a number and `SD` as "68%".
    /// A percentage sign is not a Double, so the string form needs stripping.
    private static func percent(_ value: Any?) -> Double? {
        guard let text = value as? String else { return number(value) }
        return Double(text.filter { $0.isNumber || $0 == "." })
    }
}

/// The card's weather, fetched and cached.
///
/// One `@Observable` object rather than a `@State` per view: the greeting card
/// is the only reader today, and if a second surface ever wants the same
/// reading it should not pay for a second request to a public endpoint that
/// asks callers to be gentle.
///
/// **Refresh policy**: a reading is stale after 15 minutes (weather does not
/// move faster than that at the resolution a city name gives), the request is
/// single-flight, and a failure keeps the last good reading rather than
/// blanking the card — the same discipline the proxy / usage stores use. The
/// card checks freshness while visible at roughly 15-minute intervals. Hidden
/// windows cancel that task; reappearing checks freshness immediately.
@Observable
@MainActor
final class WeatherStore {
    static let shared = WeatherStore()

    private(set) var reading: WeatherReading?
    private(set) var loading = false
    /// Why there is no reading, when there is none. Shown in the tooltip and
    /// as the caption under the clock — never as a red banner.
    private(set) var note: String?
    private(set) var fetchedAt: Date?

    /// How long a reading stays good. Long on purpose: this is a public
    /// endpoint shared with everyone else who uses wttr.in.
    static let staleAfter: TimeInterval = 15 * 60

    private var inflight: Task<Void, Never>?
    /// A refresh arrived while a request was in flight (a location fix landing
    /// on top of a city fetch). Run one more pass when the current one ends.
    private var rerun = false

    private var city: String { AppPreferences.shared.weatherCity }

    private init() {
        NotificationCenter.default.publisher(for: .permissionDidChange)
            .compactMap { $0.object as? AppPermission }
            .receive(on: RunLoop.main)
            .sink { permission in
                guard permission == .currentLocation else { return }
                MainActor.assumeIsolated { WeatherStore.shared.refresh() }
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    /// Fetch unless the current reading is fresh. A location switch with no
    /// fix yet always fetches: a city reading from two minutes ago must not
    /// hide the position the user just allowed.
    ///
    /// The build gate is read alongside the switch so the card never enters the
    /// "waiting for a fix" state in a build that will not ask for one: without
    /// it, `refresh` would park on a coordinate that can never arrive and the
    /// card would show nothing instead of the city.
    func refreshIfStale() {
        if BuildChannel.promptsForSystemPermissions,
           PermissionGate.allows(.currentLocation), CurrentLocation.shared.query == nil {
            refresh()
            return
        }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.staleAfter { return }
        refresh()
    }

    /// Force a fetch (the card's own refresh affordance, and the city change).
    /// With 当前位置 on and a fix in hand, the query is `lat,lon`. Without a
    /// fix yet, this asks for one and returns; the fix calls back into here.
    func refresh() {
        guard inflight == nil else { rerun = true; return }
        if BuildChannel.promptsForSystemPermissions, PermissionGate.allows(.currentLocation) {
            switch CurrentLocation.shared.status {
            case .authorizedAlways, .authorizedWhenInUse:
                if let query = CurrentLocation.shared.query {
                    fetch(query: query, fallbackNote: nil)
                } else {
                    loading = true
                    CurrentLocation.shared.requestFix()
                }
                return
            case .notDetermined:
                loading = true
                CurrentLocation.shared.requestFix()
                return
            default:
                fetch(query: city, fallbackNote: "定位未允许，显示天气城市")
                return
            }
        }
        fetch(query: city, fallbackNote: nil)
    }

    /// CLI requests never enter the location-aware refresh/rerun path.
    /// An existing fetch is allowed to finish; a repeated command can retry.
    func refreshCityForCLI() {
        guard inflight == nil else { return }
        fetch(query: city, fallbackNote: nil)
    }

    /// Location failed or was refused. The city name is the fallback, and the
    /// note is why the card is not showing where you are.
    func refreshFromCity(note: String) {
        guard inflight == nil else { rerun = true; return }
        fetch(query: city, fallbackNote: note)
    }

    private func fetch(query: String, fallbackNote: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            loading = false
            note = reading == nil ? "未设置天气城市" : nil
            return
        }
        loading = true
        inflight = Task { [weak self] in
            // Validated at launch by `Tests/weather-astronomy-regressions.py`; a
            // broken table is a bug, not a runtime condition the user can hit.
            assert(DomesticWeatherParser.cityLookup(in: CNWeatherCityTable.json).count > 300,
                   "中国天气网 city table is empty or unparseable")
            let result = await WeatherFetcher.fetch(city: trimmed)
            guard let self else { return }
            self.loading = false
            self.inflight = nil
            if let result {
                self.reading = result
                self.fetchedAt = Date()
                self.note = fallbackNote
            } else {
                self.note = self.reading == nil ? "天气暂不可用" : "天气更新失败，显示上次读数"
            }
            // The latch is consumed in a loop, not a single `if`. The nested
            // `refresh()` used to run with `inflight` still pointing at *this*
            // task — so its own single-flight guard set `rerun = true` and
            // returned without fetching, and the pass it was meant to trigger
            // never happened (the card then served the old city's reading until
            // the next 15-minute tick). Clearing the reference is what lets the
            // rerun actually start, and the loop covers a rerun requested while
            // that one is in flight.
            while self.rerun {
                self.rerun = false
                self.refresh()
                if self.inflight != nil { return }
            }
        }
    }
}

/// Fetches the weather in the order that keeps it working without a proxy:
/// the two domestic sources first — they answer over Chinese IPs, which mihomo
/// sends `Direct` under `GEOIP,CN` — then Open-Meteo and wttr.in as fallbacks
/// for overseas cities and for whatever the domestic pair cannot answer.
///
/// An extension, not a new type, for two reasons: it needs `WeatherFetcher`'s
/// private session and URL builder, and it sits *below* the marker the
/// regression probe slices on, so the probe never has to see the provider types
/// (which live in files of their own).
extension WeatherFetcher {
    static func fetch(city: String) async -> WeatherReading? {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let reading = await WeatherAmapFetcher.fetch(query: trimmed) { return await withHourly(reading) }
        if let reading = await WeatherCNFetcher.fetch(query: trimmed) { return await withHourly(reading) }
        if let reading = await WeatherForecastFetcher.fetch(query: trimmed) { return reading }
        guard let url = url(city: trimmed) else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  var reading = parse(data) else { return nil }
            reading.forecastNote = "预报暂不可用 · 点击刷新重试"
            return await withHourly(reading)
        } catch { return nil }
    }

    private static func withHourly(_ reading: WeatherReading) async -> WeatherReading {
        guard let lat = reading.latitude, let lon = reading.longitude else { return reading }
        var copy = reading
        copy.hourly = await WeatherForecastFetcher.fetchHours(latitude: lat, longitude: lon)
        copy.hourlySource = copy.hourly.isEmpty ? nil : "Open-Meteo"
        if let chance = copy.upcomingHours(at: Date()).compactMap(\.rainChance).max() {
            copy.rainChance = chance
        }
        return copy
    }
}
