import Foundation

/// 中国天气网（中央气象台数据）。免 key，国内 IP，命中 mihomo 的
/// `GEOIP,CN → Direct` —— 高德没配 key 或解析失败时的国内兜底。
///
/// cityid 来自编译进二进制的 `CNWeatherCityTable`（该站的名字搜索接口已失效，
/// 详见那张表与 `Tools/gen-cn-weather-cities.py`）。拿到 id 后
/// `d1.weather.com.cn/weather_index/{id}.html` 一次给出实况（`dataSK`）与
/// 5–7 天预报（`fc`）。响应是 JS 片段而非 JSON，解析走 `DomesticWeatherParser`
/// 的纯函数。
///
/// 坐标查询与表中没有的区/县名（如「浦东新区」）都无法解析，调用方会回落到
/// Open-Meteo。
enum WeatherCNFetcher {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func fetch(query: String) async -> WeatherReading? {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, DomesticWeatherParser.coordinate(name) == nil,
              let id = DomesticWeatherParser.cityID(forName: name, tableJSON: CNWeatherCityTable.json)
        else { return nil }
        return await reading(cityID: id)
    }

    private static func reading(cityID: String) async -> WeatherReading? {
        guard let url = URL(string: "http://d1.weather.com.cn/weather_index/\(cityID).html") else { return nil }
        var request = URLRequest(url: url)
        // The endpoint 403s without a weather.com.cn referer; `identity` keeps
        // the JS body readable as text (the response carries no gzip header,
        // but URLSession would otherwise still offer to decode).
        request.setValue("http://www.weather.com.cn/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let dataSK = DomesticWeatherParser.jsonVariable("dataSK", in: text) else { return nil }
        let forecast = DomesticWeatherParser.jsonVariable("fc", in: text)
        return DomesticWeatherParser.reading(dataSK: dataSK, forecast: forecast)
    }
}
