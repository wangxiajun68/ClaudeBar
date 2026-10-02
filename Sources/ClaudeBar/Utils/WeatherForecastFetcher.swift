import CoreLocation
import Foundation

struct WeatherDay: Equatable, Identifiable {
    var date: Date
    var code: Int
    var high: Double
    var low: Double
    var rainChance: Int?
    var wind: Double?
    var sunrise: Date?
    var sunset: Date?
    /// A sky stated by the source rather than derived from `code`, for the
    /// domestic tables (see `WeatherReading.skyHint`).
    var skyHint: WeatherReading.Sky? = nil
    var id: Date { date }
    var sky: WeatherReading.Sky { skyHint ?? WeatherReading.sky(for: code) }
}

/// Open-Meteo WMO daily forecast. Six dates means today AND day +5.
enum WeatherForecastFetcher {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()
    private struct Place { var latitude: Double; var longitude: Double; var name: String }
    private static func json(_ url: URL?) async throws -> [String: Any]? {
        guard let url else { return nil }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private static func resolve(_ query: String) async throws -> Place? {
        let pair = query.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if pair.count == 2, (-90...90).contains(pair[0]), (-180...180).contains(pair[1]) {
            let name = await PlaceNamer.shared.name(latitude: pair[0], longitude: pair[1]) ?? "当前位置"
            return Place(latitude: pair[0], longitude: pair[1], name: name)
        }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [URLQueryItem(name: "name", value: query), URLQueryItem(name: "count", value: "1"), URLQueryItem(name: "language", value: "zh")]
        guard let root = try await json(url.url), let place = (root["results"] as? [[String: Any]])?.first,
              let lat = place["latitude"] as? Double, let lon = place["longitude"] as? Double else { return nil }
        return Place(latitude: lat, longitude: lon, name: place["name"] as? String ?? query)
    }
    static func fetch(query: String) async -> WeatherReading? {
        do {
            guard let place = try await resolve(query) else { return nil }
            var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            url.queryItems = [
                .init(name: "latitude", value: String(place.latitude)), .init(name: "longitude", value: String(place.longitude)),
                .init(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m,wind_direction_10m"),
                .init(name: "hourly", value: "temperature_2m,precipitation,precipitation_probability,wind_speed_10m"),
                .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_probability_max,wind_speed_10m_max"),
                .init(name: "timezone", value: "auto"), .init(name: "timeformat", value: "unixtime"),
                .init(name: "forecast_days", value: "6")
            ]
            guard let root = try await json(url.url) else { return nil }
            return parse(root, place: place.name)
        } catch { return nil }
    }
    static func parse(_ root: [String: Any], place: String) -> WeatherReading? {
        guard let current = root["current"] as? [String: Any],
              let temperature = number(current["temperature_2m"]),
              let code = number(current["weather_code"]),
              let lat = number(root["latitude"]), let lon = number(root["longitude"]), (-90...90).contains(lat), (-180...180).contains(lon),
              (-100...100).contains(temperature), (0...999).contains(code) else { return nil }
        let timezone = root["timezone"] as? String ?? "UTC"
        let daily = root["daily"] as? [String: Any] ?? [:]
        let dates = daily["time"] as? [Any] ?? []
        func value(_ key: String, _ index: Int) -> Double? {
            guard let array = daily[key] as? [Any], array.indices.contains(index) else { return nil }
            return number(array[index])
        }
        let days: [WeatherDay] = dates.indices.prefix(6).compactMap { i in
            guard let date = number(dates[i]), let code = value("weather_code", i),
                  let high = value("temperature_2m_max", i), let low = value("temperature_2m_min", i) else { return nil }
            return WeatherDay(date: Date(timeIntervalSince1970: date), code: int(code), high: high, low: low,
                rainChance: value("precipitation_probability_max", i).map { min(100, max(0, int($0))) },
                wind: value("wind_speed_10m_max", i), sunrise: value("sunrise", i).map { Date(timeIntervalSince1970: $0) },
                sunset: value("sunset", i).map { Date(timeIntervalSince1970: $0) })
        }
        let observed = number(current["time"]).map { Date(timeIntervalSince1970: $0) } ?? Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)!
        let today = days.first { calendar.isDate($0.date, inSameDayAs: observed) }
        let clock = DateFormatter(); clock.timeZone = TimeZone(identifier: timezone); clock.dateFormat = "HH:mm"
        let wind = number(current["wind_direction_10m"]) ?? 0
        let directions = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        return WeatherReading(place: place, temperatureC: temperature,
            feelsLikeC: number(current["apparent_temperature"]) ?? temperature, conditionCode: Int(code), conditionText: "",
            highC: today?.high ?? temperature, lowC: today?.low ?? temperature,
            humidity: int(current["relative_humidity_2m"]), windKph: number(current["wind_speed_10m"]) ?? 0,
            windDirection: directions[(int(wind / 45 + 0.5) % 8 + 8) % 8], isDay: number(current["is_day"]).map { $0 == 1 },
            sunrise: today?.sunrise.map(clock.string) ?? "—", sunset: today?.sunset.map(clock.string) ?? "—",
            rainChance: today?.rainChance ?? 0,
            observedAt: observed,
            latitude: lat, longitude: lon, timezone: timezone, forecast: days,
            forecastNote: days.count < 6 ? "部分日期预报暂不可用" : nil, source: "Open-Meteo",
            hourly: parseHours(root), hourlySource: "Open-Meteo")
    }
    static func fetchHours(latitude: Double, longitude: Double) async -> [WeatherReading.Hour] {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return [] }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(latitude)), .init(name: "longitude", value: String(longitude)),
            .init(name: "hourly", value: "temperature_2m,precipitation,precipitation_probability,wind_speed_10m"),
            .init(name: "forecast_hours", value: "12"), .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto")
        ]
        do {
            guard let root = try await json(url.url) else { return [] }
            return parseHours(root)
        } catch { return [] }
    }

    static func parseHours(_ root: [String: Any]) -> [WeatherReading.Hour] {
        guard let hourly = root["hourly"] as? [String: Any], let times = hourly["time"] as? [Any] else { return [] }
        func value(_ key: String, _ index: Int, bounds: ClosedRange<Double>) -> Double? {
            guard let values = hourly[key] as? [Any], values.indices.contains(index),
                  let value = number(values[index]), bounds.contains(value) else { return nil }
            return value
        }
        var seen = Set<Date>()
        return times.indices.prefix(144).compactMap { i in
            guard let time = number(times[i]), time > 0 else { return nil }
            let date = Date(timeIntervalSince1970: time)
            guard seen.insert(date).inserted else { return nil }
            return WeatherReading.Hour(date: date,
                temperature: value("temperature_2m", i, bounds: -100...100),
                precipitation: value("precipitation", i, bounds: 0...1000),
                rainChance: value("precipitation_probability", i, bounds: 0...100).map { Int($0) },
                wind: value("wind_speed_10m", i, bounds: 0...500))
        }.sorted { $0.date < $1.date }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    /// A JSON number → Int, zero when absent, invalid or out of `Int` range.
    /// Truncates like `Int(_:)` (so the wind bearing's `+ 0.5` rounding still
    /// works), but an out-of-range value like 1e300 — which `number(_:)`
    /// accepts as finite — yields 0 instead of trapping the process.
    private static func int(_ value: Any?) -> Int {
        guard let number = number(value), number >= Double(Int.min), number < Double(Int.max) else { return 0 }
        return Int(number)
    }
}

/// A location fix → "城市 · 区", the same shape a typed city resolves to.
///
/// Apple's reverse geocoder, in Chinese, keyed on the coordinate rounded to
/// ~1 km (the fix's own accuracy). It is rate-limited per app, so a name is
/// asked for once per place and reused by every 15-minute weather refresh.
actor PlaceNamer {
    static let shared = PlaceNamer()

    private var cache: [String: String] = [:]

    func name(latitude: Double, longitude: Double) async -> String? {
        let key = String(format: "%.2f,%.2f", latitude, longitude)
        if let cached = cache[key] { return cached }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")).first,
              let name = Self.format(mark) else { return nil }
        cache[key] = name
        return name
    }

    /// "上海市 · 浦东新区" → "上海 · 浦东新区". A municipality's `locality` and
    /// `administrativeArea` are the same city, so it is named once.
    static func format(_ mark: CLPlacemark) -> String? {
        func trimmed(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }
        guard let city = trimmed(mark.locality) ?? trimmed(mark.administrativeArea) ?? trimmed(mark.name) else { return nil }
        let short = city.count > 2 && city.hasSuffix("市") ? String(city.dropLast()) : city
        guard let district = trimmed(mark.subLocality), district != city else { return short }
        return "\(short) · \(district)"
    }
}
