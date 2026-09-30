import Foundation

/// Low precision geocentric ephemerides for a weather illustration, not navigation.
/// J2000 orbital elements → equatorial coordinates → the observer's horizon.
/// UTC drives sidereal rotation; the device's timezone never changes the sky.
enum SkyAstronomy {
    struct Position: Equatable {
        var altitude: Double
        var azimuth: Double // north = 0°, east = 90°
    }
    struct Snapshot {
        var sun: Position
        var moon: Position
        var moonPhase: Double
        var sidereal: Double
        var latitude: Double
        var night: Bool { sun.altitude < -6 }
        var twilight: Double { max(0, 1 - abs(sun.altitude + 2) / 12) }
    }
    struct SolarEvents: Equatable {
        var sunrise: Date?
        var sunset: Date?
    }
    private struct SolarKey: Hashable {
        var day: Date
        var zone: String
        var latitude: Double
        var longitude: Double
    }
    private final class SolarCache: @unchecked Sendable {
        let lock = NSLock()
        var values: [SolarKey: SolarEvents] = [:]
        var order: [SolarKey] = []
    }
    private static let solarCache = SolarCache()

    /// Civil-day solar crossings at the standard apparent horizon (-0.833°).
    /// Forecast timestamps remain authoritative; this is a coordinate-based fallback.
    /// Missing crossings (including polar day/night) stay nil rather than invented clocks.
    static func solarEvents(on date: Date, latitude: Double, longitude: Double, zone: TimeZone) -> SolarEvents {
        let missing = SolarEvents()
        guard date.timeIntervalSince1970.isFinite, latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180 else { return missing }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let day = calendar.dateInterval(of: .day, for: date) else { return missing }
        let key = SolarKey(day: day.start, zone: zone.identifier, latitude: latitude, longitude: longitude)
        solarCache.lock.lock()
        defer { solarCache.lock.unlock() }
        if let cached = solarCache.values[key] { return cached }
        func altitude(_ instant: Date) -> Double {
            snapshot(date: instant, latitude: latitude, longitude: longitude).sun.altitude + 0.833
        }
        var result = missing
        var start = day.start
        var previous = altitude(start)
        // Bounded work once per location/day, never one solve per animation frame.
        while start < day.end {
            let end = min(start.addingTimeInterval(300), day.end)
            let next = altitude(end)
            if (previous <= 0 && next > 0) || (previous > 0 && next <= 0) {
                let rising = next > previous
                var low = start, high = end
                while high.timeIntervalSince(low) > 0.5 {
                    let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                    if (altitude(middle) > 0) == rising { high = middle } else { low = middle }
                }
                let crossing = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                if crossing < day.end {
                    if rising { result.sunrise = crossing } else { result.sunset = crossing }
                }
            }
            start = end
            previous = next
        }
        if solarCache.order.count >= 32 {
            solarCache.values.removeValue(forKey: solarCache.order.removeFirst())
        }
        solarCache.values[key] = result
        solarCache.order.append(key)
        return result
    }

    private static let rad = Double.pi / 180
    static func snapshot(date: Date, latitude: Double, longitude: Double) -> Snapshot {
        let d = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545
        let e = 23.4397 * rad
        let mean = (357.5291 + 0.98560028 * d) * rad
        let solarLongitude = mean + (1.9148 * sin(mean) + 0.02 * sin(2 * mean) + 0.0003 * sin(3 * mean)) * rad + (102.9372 + 180) * rad
        let lunarMean = (218.316 + 13.176396 * d) * rad
        let lunarAnomaly = (134.963 + 13.064993 * d) * rad
        let lunarDistance = (93.272 + 13.229350 * d) * rad
        let lunarLongitude = lunarMean + 6.289 * rad * sin(lunarAnomaly)
        let lunarLatitude = 5.128 * rad * sin(lunarDistance)
        let sidereal = (280.16 + 360.9856235 * d + longitude) * rad
        func position(_ longitude: Double, _ latitude: Double) -> Position {
            let ra = atan2(sin(longitude) * cos(e) - tan(latitude) * sin(e), cos(longitude))
            let dec = asin(sin(latitude) * cos(e) + cos(latitude) * sin(e) * sin(longitude))
            return horizon(ra: ra, dec: dec, sidereal: sidereal, latitude: latitudeObserver)
        }
        let latitudeObserver = latitude
        var phase = (lunarLongitude - solarLongitude) / (2 * .pi)
        phase -= floor(phase)
        return Snapshot(sun: position(solarLongitude, 0), moon: position(lunarLongitude, lunarLatitude),
                        moonPhase: phase, sidereal: sidereal, latitude: latitude)
    }
    private static func horizon(ra: Double, dec: Double, sidereal: Double, latitude: Double) -> Position {
        let h = sidereal - ra, phi = latitude * rad
        let altitude = asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h))
        let azimuth = atan2(sin(h), cos(h) * sin(phi) - tan(dec) * cos(phi)) + .pi
        return Position(altitude: altitude / rad, azimuth: azimuth / rad)
    }
    static func star(raHours: Double, declination: Double, in sky: Snapshot) -> Position {
        horizon(ra: raHours * 15 * rad, dec: declination * rad, sidereal: sky.sidereal, latitude: sky.latitude)
    }
    // Bright stars anchor the field to real right ascension / declination.
    static let stars: [(Double, Double, Double)] = [
        (6.752, -16.716, 1.8), (14.261, 19.182, 1.6), (18.616, 38.784, 1.6),
        (5.278, 45.998, 1.5), (5.243, -8.202, 1.5), (7.655, 5.225, 1.4),
        (5.919, 7.407, 1.4), (19.846, 8.868, 1.4), (4.599, 16.509, 1.4),
        (13.42, -11.161, 1.3), (16.49, -26.432, 1.3), (7.755, 28.026, 1.3),
        (22.961, -29.622, 1.3), (20.691, 45.28, 1.3), (10.139, 11.967, 1.2),
        (2.53, 89.264, 1.1), (11.062, 61.751, 1.1), (11.031, 56.382, 1.0),
        (11.897, 53.695, 1.0), (12.257, 57.033, 1.0), (12.9, 55.96, 1.0),
        (13.398, 54.925, 1.0), (13.792, 49.313, 1.1), (0.675, 56.537, 1.1),
        (0.153, 59.15, 1.0), (0.945, 60.717, 1.1), (1.43, 60.235, 1.0),
        (1.906, 63.67, 1.0), (21.736, 9.875, 0.8), (3.405, 49.861, 1.0)
    ]
}
