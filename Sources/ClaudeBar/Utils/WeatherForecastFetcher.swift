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
    var id: Date { date }
    var sky: WeatherReading.Sky { WeatherReading.sky(for: code) }
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
            return Place(latitude: pair[0], longitude: pair[1], name: "当前位置")
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
            return WeatherDay(date: Date(timeIntervalSince1970: date), code: Int(code), high: high, low: low,
                rainChance: value("precipitation_probability_max", i).map { min(100, max(0, Int($0))) },
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
            humidity: Int(number(current["relative_humidity_2m"]) ?? 0), windKph: number(current["wind_speed_10m"]) ?? 0,
            windDirection: directions[(Int(wind / 45 + 0.5) % 8 + 8) % 8], isDay: number(current["is_day"]).map { $0 == 1 },
            sunrise: today?.sunrise.map(clock.string) ?? "—", sunset: today?.sunset.map(clock.string) ?? "—",
            rainChance: today?.rainChance ?? 0,
            observedAt: observed,
            latitude: lat, longitude: lon, timezone: timezone, forecast: days,
            forecastNote: days.count < 6 ? "部分日期预报暂不可用" : nil, source: "Open-Meteo")
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
}
