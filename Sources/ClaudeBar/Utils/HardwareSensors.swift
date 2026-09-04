import Foundation
import IOKit

// MARK: - Host accelerator (GPU utilization + temperature)

/// Cached IOAccelerator services — avoids re-walking IOKit every sample.
enum HostAccelerator {
    struct Reading: Equatable {
        var utilization: Double = 0
        var temperatureCelsius: Double?
    }

    private static let lock = NSLock()
    private static var services: [io_object_t] = []
    private static var primed = false

    static func reading() -> Reading {
        lock.lock()
        defer { lock.unlock() }
        if !primed { refreshLocked() }
        var best = Reading()
        for service in services {
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else { continue }
            best.utilization = max(best.utilization, utilization(from: stats))
            if let temp = temperature(from: stats) {
                best.temperatureCelsius = max(best.temperatureCelsius ?? 0, temp)
            }
        }
        best.utilization = max(0, min(100, best.utilization))
        return best
    }

    private static func refreshLocked() {
        for service in services { IOObjectRelease(service) }
        services.removeAll()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            primed = true
            return
        }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            services.append(service)
        }
        primed = true
    }

    private static func utilization(from stats: [String: Any]) -> Double {
        let keys = ["Device Utilization %", "GPU Activity%", "Renderer Utilization %", "Tiler Utilization %"]
        var best = 0.0
        for key in keys {
            if let n = stats[key] as? Double { best = max(best, n) }
            else if let n = stats[key] as? Int { best = max(best, Double(n)) }
            else if let n = stats[key] as? NSNumber { best = max(best, n.doubleValue) }
        }
        return best
    }

    private static func temperature(from stats: [String: Any]) -> Double? {
        if let n = stats["Temperature(C)"] as? Int, n > 0, n < 120 { return Double(n) }
        if let n = stats["Temperature(C)"] as? Double, n > 0, n < 120 { return n }
        if let n = stats["Temperature(C)"] as? NSNumber {
            let v = n.doubleValue
            if v > 0, v < 120 { return v }
        }
        return nil
    }
}

enum HardwareSensors {
    static func cpuTemperatureCelsius() -> Double? { SMCController.shared.cpuTemperatureCelsius() }

    /// GPU 温度：IOAccelerator 的 PerformanceStatistics 在 Apple Silicon 上通常没有
    /// Temperature(C)，所以兜底读 SMC 的 GPU 温度键。
    /// SMC 内核按键名字节序匹配，同一物理键需正/反拼写都试（M3 Pro 实测 G0eT/g0pT/G1pT）。
    static func gpuTemperatureCelsius() -> Double? {
        let candidates = [
            ["G0eT", "Te0G"],
            ["g0pT", "Tp0g"],
            ["G1pT", "Tp1G"],
        ]
        var readings: [Double] = []
        for pair in candidates {
            for key in pair {
                if let v = SMCController.shared.getValue(key), v > 20, v < 120 {
                    readings.append(v)
                    break
                }
            }
        }
        guard !readings.isEmpty else { return nil }
        return readings.max() // 取最热的一个（更接近 hotspot）
    }

    static func gpuReading() -> HostAccelerator.Reading {
        var reading = HostAccelerator.reading()
        if reading.temperatureCelsius == nil {
            reading.temperatureCelsius = gpuTemperatureCelsius()
        }
        return reading
    }

    /// 0 = normal, 2 = warning, 4 = critical (`kern.memorystatus_vm_pressure_level`).
    static func memoryPressureLevel() -> Int {
        var level = 0
        var size = MemoryLayout.size(ofValue: level)
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return level
    }
}
