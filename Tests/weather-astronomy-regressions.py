#!/usr/bin/env python3
"""Compile production weather parsers/astronomy; synthetic fixtures, no accounts."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
weather = (root / 'Sources/ClaudeBar/Utils/WeatherFetcher.swift').read_text().split('/// The card\'s weather, fetched and cached.')[0]
source = weather + '\n' + (root / 'Sources/ClaudeBar/Utils/WeatherForecastFetcher.swift').read_text() + '\n' + (root / 'Sources/ClaudeBar/Utils/SkyAstronomy.swift').read_text()
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
        print("PASS: equinox, east/west, polar day/night, moon phase, sidereal stars, 10 weather families, day+5, timezone, null/partial data")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='weather-astronomy-') as tmp:
    path = Path(tmp)/'Probe.swift'; path.write_text(source)
    binary = Path(tmp)/'probe'
    subprocess.run(['swiftc','-parse-as-library',str(path),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
