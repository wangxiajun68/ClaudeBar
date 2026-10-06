import Foundation

/// 高德 (AMap) Web 服务天气。国内 IP，命中 mihomo 的 `GEOIP,CN → Direct`，
/// 因此开不开 VPN 都走直连 —— 这是「天气不再依赖代理」的主源。
///
/// 只覆盖中国大陆：海外城市 `count` 为 0，逆地理对境外坐标返回空
/// `addressComponent`，都由调用方回落到 Open-Meteo。
///
/// 解析全在 `DomesticWeatherParser`（纯函数，随 WeatherFetcher.swift 一起进回归
/// 测试），这里只负责网络与组装。
enum WeatherAmapFetcher {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static let endpoint = "https://restapi.amap.com/v3"

    /// Key comes from settings (blank by default). A blank key means AMap is
    /// skipped outright — no request, no quota spent, no error surfaced.
    static func fetch(query: String) async -> WeatherReading? {
        let key = AppPreferences.shared.amapAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        do {
            guard let located = try await locate(query: query, key: key) else { return nil }
            return await reading(adcode: located.adcode, place: located.place,
                                 latitude: located.latitude, longitude: located.longitude, key: key)
        } catch { return nil }
    }

    private struct Located {
        var adcode: String
        var place: String
        var latitude: Double?
        var longitude: Double?
    }

    /// Coordinates reverse-geocode; a city name forward-geocodes. The raw query
    /// is tried first, then again with `city=query` so a bare district name
    /// ("浦东新区") resolves inside its own municipality.
    private static func locate(query: String, key: String) async throws -> Located? {
        if let pair = Self.coordinates(query) {
            var components = URLComponents(string: "\(endpoint)/geocode/regeo")!
            components.queryItems = [
                .init(name: "location", value: "\(pair.longitude),\(pair.latitude)"),
                .init(name: "key", value: key), .init(name: "extensions", value: "base"),
            ]
            guard let root = try await json(components.url),
                  (root["status"] as? String) == "1",
                  let component = ((root["regeocode"] as? [String: Any])?["addressComponent"] as? [String: Any]),
                  let adcode = component["adcode"] as? String, !adcode.isEmpty else { return nil }
            return Located(adcode: adcode,
                           place: DomesticWeatherParser.placeName(city: component["city"],
                                                                  province: component["province"],
                                                                  district: component["district"]),
                           latitude: pair.latitude, longitude: pair.longitude)
        }

        for cityHint in [nil, query] {
            var components = URLComponents(string: "\(endpoint)/geocode/geo")!
            var items = [URLQueryItem(name: "address", value: query), URLQueryItem(name: "key", value: key)]
            if let cityHint { items.append(URLQueryItem(name: "city", value: cityHint)) }
            components.queryItems = items
            guard let root = try await json(components.url), (root["status"] as? String) == "1",
                  let geo = (root["geocodes"] as? [[String: Any]])?.first,
                  let adcode = geo["adcode"] as? String, !adcode.isEmpty else { continue }
            let pair = DomesticWeatherParser.coordinate(geo["location"])
            return Located(adcode: adcode, place: geo["formatted_address"] as? String ?? query,
                           latitude: pair?.latitude, longitude: pair?.longitude)
        }
        return nil
    }

    /// Live conditions and the forecast, fetched together. The forecast can be
    /// missing without sinking the reading — a live temperature alone still
    /// paints the card.
    ///
    /// One request, not two: `extensions=all` already carries `lives` beside
    /// `forecasts`, so the `extensions=base` call that used to run in parallel
    /// spent the key's free quota twice for a figure the same payload held.
    private static func reading(adcode: String, place: String,
                                latitude: Double?, longitude: Double?, key: String) async -> WeatherReading? {
        // A payload the key is refused for is "no reading", not a throw: the
        // chain below falls through to 中国天气网.
        guard let root = (try? await payload(adcode: adcode, key: key, extensions: "all")) ?? nil else { return nil }
        guard let lives = (root["lives"] as? [[String: Any]])?.first else { return nil }
        let casts = (root["forecasts"] as? [[String: Any]])?.first
        let parsed = DomesticWeatherParser.reading(
            live: lives,
            forecast: casts.flatMap { $0["casts"] as? [[String: Any]] }.map { ["casts": $0] },
            place: place, latitude: latitude, longitude: longitude)
        return parsed
    }

    private static func payload(adcode: String, key: String, extensions: String) async throws -> [String: Any]? {
        var components = URLComponents(string: "\(endpoint)/weather/weatherInfo")!
        components.queryItems = [
            .init(name: "city", value: adcode), .init(name: "key", value: key),
            .init(name: "extensions", value: extensions),
        ]
        guard let root = try await json(components.url), (root["status"] as? String) == "1" else { return nil }
        return root
    }

    /// AMap's own `location` strings are longitude-first, but the queried
    /// coordinate the app holds is latitude-first; this reads the app's shape.
    private static func coordinates(_ query: String) -> (latitude: Double, longitude: Double)? {
        let pair = query.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard pair.count == 2, (-90...90).contains(pair[0]), (-180...180).contains(pair[1]) else { return nil }
        return (latitude: pair[0], longitude: pair[1])
    }

    private static func json(_ url: URL?) async throws -> [String: Any]? {
        guard let url else { return nil }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
