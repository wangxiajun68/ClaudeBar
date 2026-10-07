import Foundation
import Darwin
import IOKit
import IOKit.ps

/// Permission-free host reads. No SMC, helper, network subprocess or TCC API.
struct CLISystem: Codable {
    var sampledAt: Date
    var hostname: String
    var os: String
    var chip: String
    var cores: Int
    var uptimeSeconds: Double
    var cpuPercent: Double?
    var gpuPercent: Double?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64
    var diskAvailableBytes: UInt64?
    var diskTotalBytes: UInt64?
    var loadAverage: [Double]
    var batteryPercent: Int?
    var batteryCharging: Bool?
    var externalPower: Bool?
    var networkDownBytesPerSecond: Double?
    var networkUpBytesPerSecond: Double?

    static func read() -> Self {
        let cpuBefore = cpuTicks()
        let networkBefore = networkBytes()
        let start = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: 0.15)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let cpuAfter = cpuTicks()
        let networkAfter = networkBytes()
        var cpu: Double?
        if let before = cpuBefore, let after = cpuAfter {
            let deltas = zip(before, after).map { Double($1 &- $0) }
            let total = deltas.reduce(0, +)
            if total > 0 { cpu = max(0, min(100, (total - deltas[Int(CPU_STATE_IDLE)]) / total * 100)) }
        }
        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, 3)
        if loadCount < 0 { loads = [] }
        var disk = statfs()
        let diskOK = statfs(FileManager.default.homeDirectoryForCurrentUser.path, &disk) == 0
        let battery = battery()
        var down: Double?, up: Double?
        if let before = networkBefore, let after = networkAfter, elapsed > 0 {
            var input: UInt64 = 0, output: UInt64 = 0
            for (name, counters) in after {
                guard let previous = before[name] else { continue }
                input += UInt64(counters.0 &- previous.0)
                output += UInt64(counters.1 &- previous.1)
            }
            down = Double(input) / elapsed; up = Double(output) / elapsed
        }
        return .init(sampledAt: Date(), hostname: ProcessInfo.processInfo.hostName,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon", cores: ProcessInfo.processInfo.activeProcessorCount,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime, cpuPercent: cpu, gpuPercent: gpu(),
            memoryUsedBytes: memoryUsed(), memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
            diskAvailableBytes: diskOK ? UInt64(disk.f_bavail) * UInt64(disk.f_bsize) : nil,
            diskTotalBytes: diskOK ? UInt64(disk.f_blocks) * UInt64(disk.f_bsize) : nil,
            loadAverage: loads, batteryPercent: battery?.percent, batteryCharging: battery?.charging,
            externalPower: battery?.external, networkDownBytesPerSecond: down, networkUpBytesPerSecond: up)
    }

    private static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    private static func memoryUsed() -> UInt64? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let pages = Int64(info.active_count) + Int64(info.inactive_count) + Int64(info.speculative_count)
            + Int64(info.wire_count) + Int64(info.compressor_page_count) - Int64(info.purgeable_count) - Int64(info.external_page_count)
        return min(ProcessInfo.processInfo.physicalMemory, UInt64(max(0, pages)) * UInt64(vm_kernel_page_size))
    }

    private static func sysctlString(_ key: String) -> String? {
        var length = 0
        guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname(key, &buffer, &length, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func battery() -> (percent: Int, charging: Bool, external: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  raw[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = raw[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = raw[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return (max(0, min(100, current * 100 / maximum)), raw[kIOPSIsChargingKey] as? Bool ?? false,
                    raw[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }

    private static func gpu() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var reading: Double?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let raw = properties?.takeRetainedValue() as? [String: Any],
                  let stats = raw["PerformanceStatistics"] as? [String: Any] else { continue }
            for key in ["Device Utilization %", "Renderer Utilization %", "Tiler Utilization %"] {
                let value = (stats[key] as? NSNumber)?.doubleValue ?? (stats[key] as? String).flatMap(Double.init)
                if let value, value.isFinite { reading = max(reading ?? 0, max(0, min(100, value))) }
            }
        }
        return reading
    }

    private static func networkBytes() -> [String: (UInt32, UInt32)]? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return nil }
        defer { freeifaddrs(head) }
        var counters: [String: (UInt32, UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let node = cursor {
            let item = node.pointee
            let name = String(cString: item.ifa_name)
            if item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), item.ifa_flags & UInt32(IFF_UP) != 0,
               name.hasPrefix("en"), let data = item.ifa_data?.assumingMemoryBound(to: if_data.self) {
                counters[name] = (data.pointee.ifi_ibytes, data.pointee.ifi_obytes)
            }
            cursor = item.ifa_next
        }
        return counters
    }
}
