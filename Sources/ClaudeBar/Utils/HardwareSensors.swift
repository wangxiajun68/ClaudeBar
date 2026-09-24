import Foundation
import IOKit
import Darwin
import CoreWLAN
import IOBluetooth
import SystemConfiguration

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

    /// The internal battery, for the 电量 mark on the 连接 card.
    ///
    /// `BatteryInstalled` is the load-bearing field, not `CurrentCapacity == 0`.
    /// A Mac mini, a Mac Studio or a MacBook in some service states has an
    /// `AppleSmartBattery` node with no pack behind it, and reporting that as
    /// "0 %" would be a flat-battery alarm about a machine that has no battery.
    /// The mark is simply not drawn in that case, the same way the headset marks
    /// are not drawn when no headset is on the link.
    ///
    /// `IsCharging` and `ExternalConnected` are separate claims and are kept
    /// separate here: a Mac on a charger that is holding at 100 % is *connected*
    /// but not *charging*, and the tile says 已接通 rather than 充电中 for it.
    struct BatteryStatus: Equatable {
        var installed = false
        var percent = 0
        var charging = false
        var externalPower = false
        var chargingWatts: Double?
        var inputWatts: Double?
        var systemWatts: Double?
        var batteryWatts: Double? // Positive = charging, negative = discharging.
        var powerIsEstimated = false
        /// The adapter's negotiated rating (`AdapterDetails.Watts`), e.g. 65.
        var adapterRatedWatts: Int?
    }

    /// The previous `PDTR` reading. `PSTR` trails `PDTR` by about a second,
    /// so pairing this sample's `PSTR` with the last `PDTR` keeps a load step
    /// from showing up as a momentary charge/discharge swing.
    private static var lastAdapterReading: (watts: Double, at: Date)?
    private static let adapterReadingLock = NSLock()

    static func batteryStatus() -> BatteryStatus {
        var status = BatteryStatus()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return status }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return status }

        status.installed = (dict["BatteryInstalled"] as? Bool) ?? ((dict["BatteryInstalled"] as? NSNumber)?.boolValue ?? false)
        guard status.installed else { return status }

        // `CurrentCapacity` is already a 0–100 percentage on every Mac this app
        // supports; `MaxCapacity` is 100 alongside it, and dividing by it was
        // how the older API produced the same number with more ways to be wrong.
        if let raw = (dict["CurrentCapacity"] as? NSNumber)?.intValue {
            status.percent = max(0, min(100, raw))
        } else if let current = (dict["AppleRawCurrentCapacity"] as? NSNumber)?.doubleValue,
                  let maxCapacity = (dict["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue,
                  maxCapacity > 0 {
            status.percent = max(0, min(100, Int((current / maxCapacity * 100).rounded())))
        } else {
            status.installed = false
        }
        status.charging = (dict["IsCharging"] as? NSNumber)?.boolValue ?? false
        status.externalPower = (dict["ExternalConnected"] as? NSNumber)?.boolValue ?? false
        if let adapter = dict["AdapterDetails"] as? [String: Any],
           let rated = (adapter["Watts"] as? NSNumber)?.intValue, rated > 0, rated <= 500 {
            status.adapterRatedWatts = rated
        }
        applyPowerReadings(to: &status, battery: dict)
        if let battery = status.batteryWatts, battery > 0 {
            status.chargingWatts = battery
        }
        return status
    }

    /// Adapter / system / battery watts, read the way AlDente does:
    ///
    /// - adapter = SMC `PDTR` (DC-in power), system = SMC `PSTR` (total
    ///   system power), battery = adapter − system. Both are live meters.
    /// - The battery's **direction** comes from the gauge's `InstantAmperage`,
    ///   not from the difference. The difference carries the charger's
    ///   conversion loss and the meters' skew, so on a battery holding at its
    ///   limit it hovers at ±1–2 W and would flip between 充电 and 补电 every
    ///   sample. When the gauge and the difference disagree, the gauge's own
    ///   V × I is used instead.
    ///
    /// `PowerTelemetryData` is deliberately not used: it refreshes on the
    /// order of minutes and was observed reporting a 92 W load with the
    /// battery discharging while the Mac drew 23 W and charged at 38 W.
    /// Without SMC power keys (older Intel Macs) only the gauge's V × I is
    /// known, and the reading is marked estimated.
    private static func applyPowerReadings(to status: inout BatteryStatus, battery dict: [String: Any]) {
        var gaugeWatts: Double?
        var milliamps: Double?
        if let current = (dict["InstantAmperage"] ?? dict["Amperage"]) as? NSNumber,
           let voltage = (dict["Voltage"] as? NSNumber)?.doubleValue {
            let raw = Double(Int64(bitPattern: current.uint64Value))
            if abs(raw) < 30_000, voltage > 0, voltage < 30_000 {
                milliamps = raw
                gaugeWatts = raw * voltage / 1_000_000
            }
        }
        // ~0.5 W at pack voltage: below this the pack is idle, whatever the
        // meters' difference says.
        let idle = abs(milliamps ?? 0) < 40
        let smc = SMCController.shared
        let system = smc.getValue("PSTR").flatMap(plausibleWatts)

        guard let system else {
            status.batteryWatts = idle ? 0 : gaugeWatts
            status.powerIsEstimated = true
            return
        }
        status.systemWatts = system

        guard status.externalPower else {
            status.inputWatts = nil
            status.batteryWatts = -system
            return
        }

        let now = Date()
        let current = smc.getValue("PDTR").flatMap(plausibleWatts) ?? 0
        adapterReadingLock.lock()
        let previous = lastAdapterReading
        lastAdapterReading = (current, now)
        adapterReadingLock.unlock()
        let adapter = previous.map { now.timeIntervalSince($0.at) <= 1.6 ? $0.watts : current } ?? current
        status.inputWatts = adapter

        let difference = adapter - system
        guard !idle, let milliamps else {
            status.batteryWatts = 0
            return
        }
        let charging = milliamps > 0
        if (difference > 0) == charging {
            status.batteryWatts = difference
        } else {
            status.batteryWatts = gaugeWatts
        }
    }

    private static func plausibleWatts(_ value: Double) -> Double? {
        value.isFinite && value >= 0 && value <= 500 ? value : nil
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
    /// off`. The 连接 card no longer draws a Bluetooth-radio mark, but the
    /// status is still sampled: a Mac with neither Wi-Fi nor Ethernet still
    /// reports 本机 when the radio is on.
    private static func bluetoothPowerState() -> Bool {
        guard PermissionGate.allows(.bluetooth) else { return false }
        return (IOBluetoothHostController.default()?.powerState.rawValue ?? 0) != 0
    }

    static func linkStatus() -> LinkStatus {
        var status = LinkStatus()
        let wifi = CWWiFiClient.shared().interface()
        status.wifiOn = wifi?.powerOn() ?? false
        if PermissionGate.allows(.location), let ssid = wifi?.ssid(), !ssid.isEmpty {
            status.wifiName = ssid
        }
        let rssi = Int(wifi?.rssiValue() ?? 0)
        status.wifiRSSI = rssi < 0 ? rssi : 0
        status.bluetoothOn = bluetoothPowerState()
        status.wiredOn = wiredInterfaceActive(excluding: wifi?.interfaceName)
        return status
    }

    /// Is an **Ethernet cable plugged in** — not "does an `en*` interface
    /// exist", which is what this used to ask and why unplugging the cable
    /// changed nothing on screen.
    ///
    /// Two independent facts have to be true, and neither alone is sufficient:
    ///
    /// 1. **The interface is a real Ethernet port.** `SCNetworkInterface` says
    ///    so from the hardware port list. `name.hasPrefix("en")` does *not*:
    ///    on Apple silicon `en1`/`en2`/`en3` are the Thunderbolt ports and
    ///    `en4`–`en6` are USB-Ethernet adapters that exist whether or not
    ///    anything is plugged into them. All of them pass `IFF_RUNNING`.
    /// 2. **It has carrier.** `IFF_UP | IFF_RUNNING` is a property of the
    ///    *driver*, and a USB NIC with no cable still reports both. The carrier
    ///    state lives in the dynamic store's `Link` entry, which is the same
    ///    source System Settings reads: `Active` is true only with a live link.
    ///
    /// Thunderbolt Ethernet (a dock with a live cable) stays in scope.
    /// Thunderbolt *Bridge*, iPhone USB, Bluetooth PAN and similar "Ethernet-
    /// typed but not a cable" ports are skipped: they made this Mac look wired
    /// — and the old USB-plug glyph look like it was charging — when it was
    /// not. `bridge`/`utun`/`awdl`/`llw`/`ap` are excluded by type already.
    ///
    /// Carrier is the only "on" signal. A missing Link entry is treated as off
    /// rather than guessed from the default route: that fallback lit unused
    /// Thunderbolt ports.
    private static func wiredInterfaceActive(excluding wifiName: String?) -> Bool {
        let store = SCDynamicStoreCreate(nil, "ClaudeBar.wired" as CFString, nil, nil)
        let wired = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for interface in wired {
            guard let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  type == (kSCNetworkInterfaceTypeEthernet as String),
                  let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  !bsd.isEmpty, bsd != wifiName,
                  isPhysicalEthernet(interface) else { continue }
            if let store, carrierState(store: store, bsd: bsd) == true {
                return true
            }
        }
        return false
    }

    /// Ethernet-typed ports that are not a cable in the wall / dock.
    private static func isPhysicalEthernet(_ interface: SCNetworkInterface) -> Bool {
        let name = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? ""
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let skip = ["bridge", "桥接", "iphone", "ipad", "bluetooth pan", "蓝牙网络"]
        return !skip.contains { folded.contains($0) }
    }

    private static func carrierState(store: SCDynamicStore, bsd: String) -> Bool? {
        let key = "State:/Network/Interface/\(bsd)/Link" as CFString
        guard let value = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let active = value["Active"] else { return nil }
        return (active as? NSNumber)?.boolValue ?? (active as? Bool)
    }
}
