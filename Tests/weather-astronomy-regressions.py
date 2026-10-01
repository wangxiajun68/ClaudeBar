#!/usr/bin/env python3
"""Compile production weather parsers/astronomy; synthetic fixtures, no accounts."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
weather = (root / 'Sources/ClaudeBar/Utils/WeatherFetcher.swift').read_text().split('/// The card\'s weather, fetched and cached.')[0]
source = weather + '\n' + (root / 'Sources/ClaudeBar/Utils/WeatherForecastFetcher.swift').read_text() + '\n' + (root / 'Sources/ClaudeBar/Utils/SkyAstronomy.swift').read_text() + '\n' + (root / 'Sources/ClaudeBar/Utils/CNWeatherCityTable.swift').read_text()
source += r'''
@main struct Probe {
    static func main() throws {
        let iso = ISO8601DateFormatter()
        func date(_ s: String) -> Date { iso.date(from: s)! }
        let noon = SkyAstronomy.snapshot(date: date("2026-03-20T12:00:00Z"), latitude: 0, longitude: 0)
        let midnight = SkyAstronomy.snapshot(date: date("2026-03-20T00:00:00Z"), latitude: 0, longitude: 0)
        precondition(noon.sun.altitude > 85 && midnight.sun.altitude < -85)
        let east = SkyAstronomy.snapshot(date: date("2026-03-20T06:10:00Z"), latitude: 0, longitude: 0)
        let west = SkyAstronomy.snapshot(date: date("2026-03-20T18:00:00Z"), latitude: 0, longitude: 0)
        precondition(abs(east.sun.azimuth - 90) < 3 && abs(west.sun.azimuth - 270) < 3)
        let polarDay = SkyAstronomy.snapshot(date: date("2026-06-21T00:00:00Z"), latitude: 80, longitude: 0)
        let polarNight = SkyAstronomy.snapshot(date: date("2026-12-21T12:00:00Z"), latitude: 80, longitude: 0)
        precondition(polarDay.sun.altitude > 0 && polarNight.sun.altitude < 0)
        let full = SkyAstronomy.snapshot(date: date("2026-09-26T17:00:00Z"), latitude: 23.13, longitude: 113.26)
        precondition(abs(full.moonPhase - 0.5) < 0.04)
        let star1 = SkyAstronomy.star(raHours: 18.616, declination: 38.784, in: noon)
        let star2 = SkyAstronomy.star(raHours: 18.616, declination: 38.784, in: east)
        precondition(abs(star1.altitude - star2.altitude) > 5)
        let codes: [(Int, WeatherReading.Sky)] = [(51,.drizzle),(66,.sleet),(71,.snow),(95,.thunder),(99,.hail),(227,.snow),(113,.clear)]
        for (code, expected) in codes { precondition(WeatherReading.sky(for: code) == expected) }
        let start = date("2026-09-26T16:00:00Z").timeIntervalSince1970
        let times = (0..<6).map { start + Double($0)*86400 }
        var payload: [String: Any] = [
            "latitude": 23.13, "longitude": 113.26, "timezone": "Asia/Shanghai",
            "current": ["temperature_2m": 29, "weather_code": 2, "is_day": 0, "time": start+3600,
                        "relative_humidity_2m": 64, "wind_speed_10m": 18, "wind_direction_10m": 135],
            "daily": ["time": times, "weather_code": [0,2,61,95,71,99],
                      "temperature_2m_max": [32,31,30,29,28,27], "temperature_2m_min": [25,24,23,22,21,20],
                      "precipitation_probability_max": [0,20,60,90,40,99],
                      "sunrise": times.map { $0+6*3600 }, "sunset": times.map { $0+18*3600 },
                      "wind_speed_10m_max": [8,10,12,14,16,18]]
        ]
        let reading = WeatherForecastFetcher.parse(payload, place: "广州")!
        precondition(reading.forecast.count == 6)
        precondition(reading.forecast[5].date.timeIntervalSince(reading.forecast[0].date) == 5*86400)
        precondition(reading.sunrise == "06:00" && reading.sunset == "18:00")
        precondition(reading.timezone == "Asia/Shanghai" && reading.isDay == false)
        precondition(reading.windDirection == "东南" && reading.forecast[5].sky == .hail)
        var daily = payload["daily"] as! [String: Any]
        daily["sunrise"] = [NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull()]
        daily["precipitation_probability_max"] = [NSNull(), 20]
        daily["temperature_2m_max"] = [32, NSNull(), 30]
        payload["daily"] = daily
        let partial = WeatherForecastFetcher.parse(payload, place: "极区")!
        precondition(partial.forecast.count == 2 && partial.forecastNote != nil)
        precondition(partial.forecast[0].rainChance == nil && partial.forecast[0].sunrise == nil)
        precondition(partial.sunrise == "—")
        daily["temperature_2m_max"] = [NSNull(), 31, 30]
        payload["daily"] = daily
        let missingToday = WeatherForecastFetcher.parse(payload, place: "广州")!
        precondition(missingToday.forecast.first!.date > reading.forecast.first!.date)
        precondition(missingToday.highC == missingToday.temperatureC && missingToday.sunrise == "—")
        payload["current"] = ["temperature_2m": NSNull(), "weather_code": 0]
        precondition(WeatherForecastFetcher.parse(payload, place: "缺失数据") == nil)

        // Domestic sources: 中国天气网 code table, Chinese condition text, and the
        // Beaufort level → km/h conversion. 0–31 must not be read as WMO codes
        // (WMO 2 is "partly", the CN table's 2 is 阴), which is why the code
        // paths are separate functions.
        let cnCodes: [(String, WeatherReading.Sky)] = [
            ("d00", .clear), ("d0", .clear), ("n00", .clear),
            ("d01", .partly), ("d02", .cloudy),
            ("d7", .drizzle), ("d07", .drizzle), ("d07", .drizzle),
            ("d4", .thunder), ("d5", .hail), ("d6", .sleet),
            ("d13", .snow), ("d26", .snow), ("d53", .fog),
            ("d301", .rain), ("d9", .rain), ("d12", .rain), ("d19", .sleet), ("", .cloudy), ("dmoon", .cloudy)]
        for (code, expected) in cnCodes { precondition(WeatherReading.sky(forCNCode: code) == expected) }
        precondition(WeatherReading.sky(for: 2) == .partly)
        let texts: [(String, WeatherReading.Sky)] = [
            ("晴", .clear), ("多云", .partly), ("阴", .cloudy),
            ("小雨", .drizzle), ("中雨", .rain), ("大雨", .rain), ("暴雨", .rain),
            ("阵雨", .rain), ("雷阵雨", .thunder), ("雷雨", .thunder),
            ("冰雹", .hail), ("雨夹雪", .sleet), ("小雪", .snow),
            ("雾", .fog), ("霾", .fog), ("", .cloudy), ("下开水", .cloudy)]
        for (text, expected) in texts { precondition(WeatherReading.sky(forText: text) == expected) }
        precondition(DomesticWeatherParser.windKph(fromBeaufort: "≤3") == 15)
        precondition(DomesticWeatherParser.windKph(fromBeaufort: "1-3") == 8)
        precondition(DomesticWeatherParser.windKph(fromBeaufort: "4") == 24)
        precondition(DomesticWeatherParser.windKph(fromBeaufort: nil) == 0)
        precondition(DomesticWeatherParser.rainChance(fromText: "阵雨") > 0)
        precondition(DomesticWeatherParser.rainChance(fromText: "晴") == 0)
        precondition(DomesticWeatherParser.placeName(city: [], province: "上海市", district: "浦东新区") == "上海 · 浦东新区")
        precondition(DomesticWeatherParser.placeName(city: "杭州市", province: "浙江省", district: "西湖区") == "杭州 · 西湖区")
        let coordinate = DomesticWeatherParser.coordinate("121.473667,31.230525")
        precondition(coordinate?.latitude == 31.230525 && coordinate?.longitude == 121.473667)

        let amapLive: [String: Any] = ["city": "上海市", "temperature": "25", "humidity": "68",
                                       "winddirection": "东北", "windpower": "≤3", "weather": "阴",
                                       "reporttime": "2026-09-29 11:33:13"]
        // The two day cells are dated off *today in Asia/Shanghai*, because a
        // mainland source dates them there. Hard-coded dates here made the
        // suite read tomorrow's cell — and so assert tomorrow's high/low —
        // whenever the runner's UTC date was already the next day (CI runs at
        // 06:00 UTC), which is what turned this file red on 2026-09-29.
        let cnDay: (Int) -> String = { offset in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let day = calendar.date(byAdding: .day, value: offset, to: Date())!
            let f = DateFormatter()
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: day)
        }
        let amapCasts: [[String: Any]] = [
            ["date": cnDay(0), "dayweather": "小雨", "nightweather": "小雨",
             "daytemp": "26", "nighttemp": "22"],
            ["date": cnDay(1), "dayweather": "雷阵雨", "nightweather": "阴",
             "daytemp": "25", "nighttemp": "21"]]
        let amap = DomesticWeatherParser.reading(live: amapLive, forecast: ["casts": amapCasts],
                                                 place: "上海 · 浦东新区",
                                                 latitude: 31.23, longitude: 121.47)!
        precondition(amap.temperatureC == 25 && amap.humidity == 68 && amap.windDirection == "东北")
        precondition(amap.sky == .cloudy && amap.forecast.count == 2)
        precondition(amap.forecast[1].sky == .thunder && amap.forecastNote == nil)
        precondition(amap.latitude == 31.23 && amap.timezone == "Asia/Shanghai" && amap.source == "高德")
        precondition(amap.forecast[0].rainChance! > 0 && amap.forecast[1].rainChance! > 0)
        precondition(amap.highC == 26 && amap.lowC == 22)
        let bare = DomesticWeatherParser.reading(live: amapLive, forecast: nil, place: "上海",
                                                 latitude: nil, longitude: nil)!
        precondition(bare.forecast.isEmpty && bare.forecastNote != nil && bare.highC == bare.temperatureC)
        precondition(DomesticWeatherParser.reading(live: nil, forecast: nil, place: "x",
                                                   latitude: nil, longitude: nil) == nil)

        let dataSK: [String: Any] = ["cityname": "上海", "temp": "25.4", "sd": "68", "SD": "68%",
                                     "WD": "北风", "WS": "1级", "weather": "阴",
                                     "weathercode": "d02", "rain": "0"]
        let fc: [String: Any] = ["f": [
            ["fa": "d7", "fb": "n7", "fc": "26", "fd": "23", "fe": "东风", "fi": "9/29", "fj": "今天"],
            ["fa": "d00", "fb": "n00", "fc": "27", "fd": "22", "fe": "东北风", "fi": "9/30", "fj": "星期三"]]]
        let cn = DomesticWeatherParser.reading(dataSK: dataSK, forecast: fc)!
        precondition(cn.temperatureC == 25.4 && cn.humidity == 68 && cn.sky == .cloudy)
        precondition(cn.forecast.count == 2 && cn.forecast[0].sky == .drizzle && cn.forecast[1].sky == .clear)
        precondition(cn.place == "上海" && cn.source == "中国天气网" && cn.timezone == "Asia/Shanghai")
        let noPercent: [String: Any] = ["cityname": "上海", "temp": "25", "SD": "68%", "weathercode": "d02"]
        precondition(DomesticWeatherParser.reading(dataSK: noPercent, forecast: nil)!.humidity == 68)
        let script = #"var dataSK ={"temp":"25"};var fc ={"f":[{"fa":"d7","fb":"n7"}]};var alarmDZ ={"w":[]};"#
        precondition(DomesticWeatherParser.jsonVariable("dataSK", in: script)?["temp"] as? String == "25")
        precondition(DomesticWeatherParser.jsonVariable("fc", in: script)?["f"] != nil)
        precondition(DomesticWeatherParser.jsonVariable("alarmDZ", in: script) != nil)
        precondition(DomesticWeatherParser.jsonVariable("cityDZ", in: script) == nil)
        let search = #"([{"ref":"101020100~shanghai~上海~Shanghai~上海~Shanghai~21~200000~SH~上海"}])"#
        precondition(DomesticWeatherParser.searchCityID(fromSearchResponse: search) == "101020100")

        // The offline city table is what replaced 中国天气网's dead search API.
        precondition(DomesticWeatherParser.cityID(forName: "上海", tableJSON: CNWeatherCityTable.json) == "101020100")
        precondition(DomesticWeatherParser.cityID(forName: "上海市", tableJSON: CNWeatherCityTable.json) == "101020100")
        precondition(DomesticWeatherParser.cityID(forName: " 杭州 ", tableJSON: CNWeatherCityTable.json) == "101210101")
        precondition(DomesticWeatherParser.cityID(forName: "北京", tableJSON: CNWeatherCityTable.json) == "101010100")
        precondition(DomesticWeatherParser.cityID(forName: "浦东新区", tableJSON: CNWeatherCityTable.json) == nil)
        precondition(DomesticWeatherParser.cityID(forName: "东京", tableJSON: CNWeatherCityTable.json) == nil)
        precondition(DomesticWeatherParser.cityID(forName: "上海", tableJSON: "not json") == nil)
        precondition(DomesticWeatherParser.cityLookup(in: CNWeatherCityTable.json).count > 300)

        var located = reading.withCoordinates(latitude: 1, longitude: 2, timezone: "UTC")
        precondition(located.latitude == 1 && located.longitude == 2 && located.timezone == "UTC")
        located = reading.withCoordinates(latitude: nil, longitude: nil, source: "测试")
        precondition(located.latitude == reading.latitude && located.source == "测试")

        // Which forecast cell is "today" is asked in the *reading's* zone, not
        // the device's. Both domestic sources report mainland China; asking it
        // in the device's zone picked tomorrow's high/low for the last hours of
        // a Shanghai day from a Tokyo Mac, and the cell *before* the first when
        // the two zones are on different dates (which is how CI caught this:
        // the runner is at 06:00 UTC, where the Shanghai date is already ahead
        // of the flyer's own).
        //
        // Listed out of order on purpose: the *first* cell is Shanghai's
        // tomorrow, so a selection that falls back to `days.first` — or that
        // asks the device's calendar — cannot land on the intended cell.
        let shanghaiCasts: [[String: Any]] = [
            ["date": cnDay(1), "dayweather": "阴", "nightweather": "阴",
             "daytemp": "19", "nighttemp": "15"],
            ["date": cnDay(0), "dayweather": "小雨", "nightweather": "小雨",
             "daytemp": "26", "nighttemp": "22"]]
        let shanghaiLive: [String: Any] = ["city": "上海市", "temperature": "25", "weather": "阴",
                                           "windpower": "≤3", "reporttime": "2026-09-29 03:30:00"]
        let shanghai = DomesticWeatherParser.reading(live: shanghaiLive, forecast: ["casts": shanghaiCasts],
                                                     place: "上海", latitude: nil, longitude: nil)!
        precondition(shanghai.highC == 26 && shanghai.lowC == 22)
        precondition(shanghai.timezone == "Asia/Shanghai")
        precondition(shanghai.forecast.count == 2)

        let now = date("2026-09-28T10:30:00Z")
        let hourRoot: [String: Any] = ["hourly": [
            "time": [now.addingTimeInterval(-1800).timeIntervalSince1970,
                     now.addingTimeInterval(1800).timeIntervalSince1970,
                     now.addingTimeInterval(5400).timeIntervalSince1970,
                     now.addingTimeInterval(9000).timeIntervalSince1970],
            "temperature_2m": [21, 22, NSNull(), 24],
            "precipitation": [9, 1.2, NSNull(), -1],
            "precipitation_probability": [90, 70, NSNull(), 200],
            "wind_speed_10m": [3, 4, 5, 6]]]
        let parsedHours = WeatherForecastFetcher.parseHours(hourRoot)
        precondition(parsedHours.count == 4 && parsedHours[2].precipitation == nil && parsedHours[3].rainChance == nil)
        precondition(parsedHours[3].precipitation == nil && parsedHours[2].temperature == nil)
        var hourlyReading = reading
        hourlyReading.hourly = parsedHours
        precondition(hourlyReading.upcomingHours(at: now).count == 3)
        precondition(hourlyReading.hourMetric(at: now) == .precipitation)
        hourlyReading.skyHint = .clear
        hourlyReading.hourly = parsedHours.map { WeatherReading.Hour(date: $0.date, temperature: $0.temperature, precipitation: 0, rainChance: 0, wind: 30) }
        precondition(hourlyReading.hourMetric(at: now) == .wind)
        hourlyReading.hourly = parsedHours.map { WeatherReading.Hour(date: $0.date, temperature: $0.temperature, precipitation: 0, rainChance: 0, wind: 3) }
        precondition(hourlyReading.hourMetric(at: now) == .temperature)
        hourlyReading.hourly = parsedHours.map { WeatherReading.Hour(date: $0.date, temperature: 24, precipitation: nil, rainChance: 80, wind: 3) }
        precondition(hourlyReading.hourMetric(at: now) == .probability)
        precondition(hourlyReading.hourMetric(at: now.addingTimeInterval(7 * 3600)) == nil)
        precondition(WeatherForecastFetcher.parseHours([:]).isEmpty)
        print("PASS: equinox, east/west, polar day/night, moon phase, sidereal stars, 10 weather families, day+5, timezone, null/partial data, domestic sources")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='weather-astronomy-') as tmp:
    path = Path(tmp)/'Probe.swift'; path.write_text(source)
    binary = Path(tmp)/'probe'
    subprocess.run(['swiftc','-parse-as-library',str(path),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
