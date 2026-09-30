import SwiftUI

extension WeatherReading.Sky {
    func symbol(night: Bool = false) -> String {
        switch self {
        case .clear: return night ? "moon.stars.fill" : "sun.max.fill"
        case .partly: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .thunder: return "cloud.bolt.rain.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .sleet: return "cloud.sleet.fill"
        case .hail: return "cloud.hail.fill"
        }
    }
    var caption: String {
        switch self {
        case .clear: return "晴"
        case .partly: return "晴间多云"
        case .cloudy: return "多云"
        case .fog: return "雾"
        case .rain: return "雨"
        case .snow: return "雪"
        case .thunder: return "雷雨"
        case .drizzle: return "毛毛雨"
        case .sleet: return "雨夹雪"
        case .hail: return "冰雹"
        }
    }
}

/// One open weather instrument: a magnetic date rail, comparable temperature
/// ranges, then a horizon plot and readings. No nested panel backgrounds.
