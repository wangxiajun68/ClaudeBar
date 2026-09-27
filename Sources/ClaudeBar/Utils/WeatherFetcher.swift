import Foundation
import SwiftUI

/// The one reading a weather card needs: where, how warm, what sky, and — for
/// the clock card's day/night switch — whether the sun is up.
///
/// Deliberately not a forecast model. The card shows *current* conditions and
/// the day's high / low; a five-day strip would be a second product living
/// inside a dashboard tile.
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

    /// The sky family the animations are built on. Several WMO / WW codes are
    /// the same weather to a viewer ("patchy rain nearby" and "light drizzle"
    /// both mean *it is raining*), so the drawing is keyed on this, never on
    /// the raw code.
    enum Sky: String {
        case clear, partly, cloudy, fog, rain, snow, thunder

        /// Every sky the card can draw, for the regression sweep.
        static let all: [Sky] = [.clear, .partly, .cloudy, .fog, .rain, .snow, .thunder]
    }

    var sky: Sky { Self.sky(for: conditionCode) }

    /// WW / WMO condition codes → the drawing family.
    ///
    /// Two numbering schemes arrive here and they overlap in the low hundreds,
    /// so the mapping is written against the *WW* table wttr.in serves (which
    /// what the card actually gets) and the WMO codes are folded in explicitly
    /// rather than by range: 176/263/266/293/296/299/302/305/308/311/314/353/356/
    /// 359 are rain, 200–233 thunder, 179/182/185/281/284/317/320/362/365/374/377
    /// sleet/ice, 227/230/320s snow, 143/248/260 fog, 116/119/122 cloudy,
    /// 353… thunder-showers. Anything unrecognized falls to `cloudy`, which is
    /// the safe reading — a wrong grey card is a smaller lie than a wrong sun.
    static func sky(for code: Int) -> Sky {
        switch code {
        case 113: return .clear                          // Sunny / Clear
        case 116: return .partly                         // Partly cloudy
        case 119, 122: return .cloudy                    // Cloudy / Overcast
        case 143, 248, 260: return .fog                  // Mist / Fog
        case 176, 263, 266, 293, 296, 299, 302, 305, 308, 311, 314,
             353, 356, 359: return .rain
        case 179, 182, 185, 281, 284, 317, 320, 362, 365, 374, 377: return .rain
        case 200, 227, 230, 386, 389, 392, 395: return .thunder
        case 323, 326, 329, 332, 335, 338, 350, 368, 371: return .snow
        case 0, 1: return .clear                         // WMO clear / mainly clear
        case 2: return .partly
        case 3: return .cloudy
        case 45, 48: return .fog
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82: return .rain
        case 71, 73, 75, 77, 85, 86: return .snow
        case 95, 96, 99: return .thunder
        default: return .cloudy
        }
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
        }
    }

    /// The temperature the card prints, rounded — one decimal of a degree is
    /// noise on a tile that is read at a glance.
    var temperatureText: String { "\(Int(temperatureC.rounded()))°" }
}

/// wttr.in's `j1` payload for a named place. Chosen over the alternatives for
/// three reasons, in order:
///
///  1. **No API key.** A dashboard card may not add a signup step to a local
///     mac app, and every keyed provider (OpenWeather, WeatherAPI) does.
///  2. **No location permission and no account.** A city name in the URL means
///     the app never has to ask macOS for 定位 — the permission this codebase
///     spends a whole settings section keeping opt-in — and never has to ship
///     an IP-geolocation hop whose answer (a datacenter, behind a proxy) is
///     routinely in another country.
///  3. It returns the day's high / low, the sunrise / sunset and the next hours'
///     rain chance in the same response, so one request fills the card.
///
/// The city is a preference (`AppPreferences.weatherCity`, default 上海), so a
/// user who does not live there changes one string instead of granting
/// location. A failure is not an error state: the card falls back to the
/// clock, and the tooltip says why.
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
        ]
        return components?.url
    }

    static func fetch(city: String) async -> WeatherReading? {
        guard let url = url(city: city) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("ClaudeBar/1.13 (macOS weather card)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parse(data)
        } catch {
            return nil
        }
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
            if let n = current[key] as? NSNumber { return n.intValue }
            if let s = current[key] as? String { return Int(s) }
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
            let soon = hours.prefix(4)
            rainChance = soon.compactMap { ($0["chanceofrain"] as? String).flatMap(Int.init) }.max() ?? 0
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
                observedHour: (current["observation_time"] as? String).flatMap(hourOfDay),
                sunrise: sunrise, sunset: sunset),
            sunrise: sunrise,
            sunset: sunset,
            rainChance: rainChance,
            observedAt: Date()
        )
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

    private static func hourOfDay(_ observation: String) -> Int? {
        // "09:06 AM" → 9
        let parts = observation.split(separator: ":", maxSplits: 1)
        guard let hour = parts.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        let upper = observation.uppercased()
        if upper.contains("PM"), hour != 12 { return hour + 12 }
        if upper.contains("AM"), hour == 12 { return 0 }
        return hour
    }

    /// When the source omits its day/night flag, sunrise / sunset decide it.
    private static func dayGuess(observedHour: Int?, sunrise: String, sunset: String) -> Bool? {
        guard let hour = observedHour else { return nil }
        guard let rise = minutes(sunrise), let set = minutes(sunset) else { return nil }
        let now = hour * 60
        return now >= rise && now < set
    }

    private static func minutes(_ clock: String) -> Int? {
        let trimmed = clock.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2 else { return nil }
        let hourPart = parts[0].trimmingCharacters(in: .whitespaces)
        let minutePart = parts[1].prefix(while: \.isNumber)
        guard let hour = Int(hourPart), let minute = Int(minutePart) else { return nil }
        let isPM = trimmed.uppercased().contains("PM")
        let isAM = trimmed.uppercased().contains("AM")
        var hour24 = hour % 12
        if isPM { hour24 += 12 }
        if isAM { hour24 = hour % 12 }
        return hour24 * 60 + minute
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
/// card is *not* on a timer: it refreshes when it appears and when the stale
/// window has passed on a later appearance, so a dashboard left open overnight
/// makes one request per window instead of one per second.
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

    private var city: String { AppPreferences.shared.weatherCity }

    /// Whether the card should show a figure at all.
    var hasReading: Bool { reading != nil }

    /// Fetch unless the current reading is fresh. Safe to call from
    /// `onAppear` / `onChange` — it is a no-op in the common case.
    func refreshIfStale() {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.staleAfter { return }
        refresh()
    }

    /// Force a fetch (the card's own refresh affordance, and the city change).
    func refresh() {
        guard inflight == nil else { return }
        let city = self.city
        loading = true
        inflight = Task { [weak self] in
            let result = await WeatherFetcher.fetch(city: city)
            guard let self else { return }
            self.loading = false
            self.inflight = nil
            if let result {
                self.reading = result
                self.fetchedAt = Date()
                self.note = nil
            } else {
                // Keep the last good reading; only the *note* changes.
                self.note = self.reading == nil ? "天气暂不可用" : "天气更新失败，显示上次读数"
            }
        }
    }
}
