import Foundation
import IOKit
import Darwin
import CoreWLAN
import IOBluetooth

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

    static func bootDisk() -> (used: UInt64, total: UInt64) {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return (0, 1) }
        let bsize = UInt64(fs.f_bsize)
        let total = max(UInt64(fs.f_blocks) * bsize, 1)
        let free = UInt64(fs.f_bavail) * bsize
        return (total - min(free, total), total)
    }

    struct LinkStatus: Equatable {
        var wifiOn = false
        var wifiName = ""
        var wifiRSSI = 0
        var bluetoothOn = false
        var wiredOn = false
    }

    /// Bluetooth controller power state.
    ///
    /// This is a privacy-gated read, but there is no TCC-free alternative:
    /// every route to the radio's power state on macOS 26 goes through
    /// CoreBluetooth. `IOBluetoothHostController.powerState` does, and so does
    /// the older-looking `IOBluetoothPreferenceGetControllerPowerState` — that
    /// one bridges to `+[IOBluetoothCoreBluetoothCoordinator sharedInstance]`,
    /// which boots a CoreBluetooth session. Nor is IOKit a way out:
    /// `IOBluetoothHCIController` carries no `IOPowerManagement`, and while
    /// `AppleBluetoothModule` does, its `CurrentPowerState` reflects the
    /// module's clock/reset state, not the user's Bluetooth toggle — it stays
    /// 1 even with Bluetooth switched off, so it cannot answer this question.
    ///
    /// So the bundle declares `NSBluetoothAlwaysUsageDescription` and we use the
    /// documented API. The consequence to know about: without that key TCC does
    /// not merely deny the read, it aborts the process
    /// (`Termination Namespace: TCC`), from a background queue, taking the whole
    /// app down mid-poll. With the key present a denial is just `powerState ==
    /// off`, which the UI already renders as 蓝牙 关.
    private static func bluetoothPowerState() -> Bool {
        (IOBluetoothHostController.default()?.powerState.rawValue ?? 0) != 0
    }

    static func linkStatus() -> LinkStatus {
        var status = LinkStatus()
        let wifi = CWWiFiClient.shared().interface()
        status.wifiOn = wifi?.powerOn() ?? false
        if let ssid = wifi?.ssid(), !ssid.isEmpty {
            status.wifiName = ssid
        }
        let rssi = Int(wifi?.rssiValue() ?? 0)
        status.wifiRSSI = rssi < 0 ? rssi : 0
        status.bluetoothOn = bluetoothPowerState()
        status.wiredOn = wiredInterfaceUp(excluding: wifi?.interfaceName)
        return status
    }

    private static func wiredInterfaceUp(excluding wifiName: String?) -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return false }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: p.pointee.ifa_name)
            if let wifiName, name == wifiName { continue }
            if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw")
                || name.hasPrefix("bridge") || name.hasPrefix("ap") { continue }
            if name.hasPrefix("en") { return true }
        }
        return false
    }
}
