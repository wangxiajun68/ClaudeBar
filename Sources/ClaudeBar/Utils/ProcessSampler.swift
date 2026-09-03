import Foundation
import Darwin
import IOKit
import AppKit
import Combine

/// Live process and host meters for the 本机负载 strip and session chips.
///
/// Sampling runs off-main. Headline numbers are the **machine** (all-core
/// CPU, IOKit GPU, physical memory). Per-agent chips still use one-core
/// CPU and `phys_footprint`. Family shares (Axon / CC / Cursor / Codex)
/// are those processes as a fraction of the machine, not of each other.
final class ProcessSampler: ObservableObject {
    static let shared = ProcessSampler()

    enum Key: Hashable {
        case pid(Int)
        case cursor
        case cwd(String)

        static func standardizedCwd(_ path: String) -> Key {
            .cwd((path as NSString).standardizingPath)
        }

        var family: Family {
            switch self {
            case .pid: return .claude
            case .cursor: return .cursor
            case .cwd: return .codex
            }
        }
    }

    enum Family: String, CaseIterable {
        case axon, claude, cursor, codex

        var label: String {
            switch self {
            case .axon: return "Axon"
            case .claude: return "CC"
            case .cursor: return "Cursor"
            case .codex: return "Codex"
            }
        }
    }

    struct Snapshot: Equatable {
        var cpu: Double = 0
        var gpu: Double = 0
        var memoryBytes: UInt64 = 0

        mutating func add(_ other: Snapshot) {
            cpu += other.cpu
            gpu += other.gpu
            memoryBytes &+= other.memoryBytes
        }
    }

    struct HostStats: Equatable {
        var cpu: Double = 0
        var gpu: Double = 0
        var memoryUsed: UInt64 = 0
        var memoryTotal: UInt64 = 0
        var coreCount: Int = 1

        var memoryLabel: String {
            let used = ProcessSampler.Snapshot(memoryBytes: memoryUsed).memoryLabel
            let total = ProcessSampler.Snapshot(memoryBytes: memoryTotal).memoryLabel
            return "\(used) / \(total)"
        }
    }

    struct Point: Equatable {
        var cpu: Double
        var gpu: Double
        var mem: Double
    }

    /// One product family's slice of the **machine**, not of the tracked set.
    struct Share: Equatable, Identifiable {
        var id: String
        var label: String
        var memoryBytes: UInt64
        /// Fraction of all cores / physical RAM / GPU (0...1).
        var cpuShare: Double
        var memShare: Double
        var gpuShare: Double
    }

    @Published var axon = Snapshot()
    @Published var host = HostStats()
    @Published var byKey: [Key: Snapshot] = [:]
    @Published var shares: [Share] = []
    @Published var trail: [Point] = []

    private let queue = DispatchQueue(label: "com.claudebar.proc", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastCPU: [pid_t: (ticks: UInt64, at: TimeInterval)] = [:]
    private var lastGPU: [pid_t: (nanojoules: UInt64, at: TimeInterval)] = [:]
    private var lastHostTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var claudeRoots: [pid_t] = []
    private var index = ProcessIndex()
    private var lastIndexAt: TimeInterval = 0
    private let trailCap = 24
    private let gpuFullWatts = 2.0
    private var live = false
    private var foreground = true
    private var period: TimeInterval = 2.5
    private var scratch = ProcessScanScratch()
    private var activeObs: NSObjectProtocol?
    private var resignObs: NSObjectProtocol?

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: self.period)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
        observeAppState()
    }

    /// 1 Hz while a session is mid-turn; 2.5 s when idle; 6 s in background.
    func setLive(_ on: Bool) {
        queue.async { [weak self] in
            guard let self, self.live != on else { return }
            self.live = on
            self.applyPeriod()
        }
    }

    func setAgentPIDs(_ pids: [Int]) {
        queue.async { self.claudeRoots = pids.map { pid_t($0) } }
    }

    private func observeAppState() {
        guard activeObs == nil else { return }
        let center = NotificationCenter.default
        activeObs = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queue.async {
                self?.foreground = true
                self?.applyPeriod()
            }
        }
        resignObs = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queue.async {
                self?.foreground = false
                self?.applyPeriod()
            }
        }
    }

    private func applyPeriod() {
        let next: TimeInterval
        if !foreground { next = 6 }
        else if live { next = 1 }
        else { next = 2.5 }
        guard abs(period - next) > 0.05 else { return }
        period = next
        timer?.schedule(deadline: .now() + next, repeating: next)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastIndexAt >= period {
            index = ProcessIndex.scan(claudeRoots: claudeRoots, scratch: &scratch)
            lastIndexAt = now
        } else {
            index.claudeRoots = claudeRoots
        }

        let selfPID = getpid()
        var axonSnap = Snapshot()
        axonSnap.cpu = cpuPercent(pid: selfPID, now: now)
        axonSnap.memoryBytes = physFootprint() ?? footprint(pid: selfPID)
        axonSnap.gpu = gpuPercent(pid: selfPID, task: mach_task_self_, now: now)

        let sysGPU = foreground ? IOKitGPU.utilization() : 0
        let hostSnap = HostStats(
            cpu: hostCPUPercent(),
            gpu: sysGPU,
            memoryUsed: hostMemoryUsed(),
            memoryTotal: ProcessInfo.processInfo.physicalMemory,
            coreCount: max(ProcessInfo.processInfo.processorCount, 1)
        )

        var byKey: [Key: Snapshot] = [:]
        var claimed = Set<pid_t>()

        for root in claudeRoots {
            let group = index.descendants(of: root)
            claimed.formUnion(group)
            byKey[.pid(Int(root))] = sum(pids: group, now: now)
        }

        let cursorPIDs = index.cursorPIDs.filter { !claimed.contains($0) }
        claimed.formUnion(cursorPIDs)
        if !cursorPIDs.isEmpty {
            byKey[.cursor] = sum(pids: cursorPIDs, now: now)
        }

        for (cwd, pids) in index.codexByCwd {
            let live = pids.filter { !claimed.contains($0) }
            guard !live.isEmpty else { continue }
            var group = Set<pid_t>()
            for p in live { group.formUnion(index.descendants(of: p)) }
            claimed.formUnion(group)
            byKey[.cwd(cwd)] = sum(pids: Array(group), now: now)
        }

        let memTotal = max(Double(hostSnap.memoryTotal), 1)
        let cores = Double(hostSnap.coreCount)
        let point = Point(
            cpu: min(1, hostSnap.cpu / 100),
            gpu: min(1, hostSnap.gpu / 100),
            mem: min(1, Double(hostSnap.memoryUsed) / memTotal)
        )

        var live = claimed
        live.insert(selfPID)
        lastCPU = lastCPU.filter { live.contains($0.key) }
        lastGPU = lastGPU.filter { live.contains($0.key) }

        let shares = Self.makeShares(axon: axonSnap, byKey: byKey, host: hostSnap, cores: cores)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.axon != axonSnap { self.axon = axonSnap }
            if self.host != hostSnap { self.host = hostSnap }
            if self.byKey != byKey { self.byKey = byKey }
            if self.shares != shares { self.shares = shares }
            var trail = self.trail
            if let last = trail.last,
               abs(last.cpu - point.cpu) < 0.015,
               abs(last.gpu - point.gpu) < 0.015,
               abs(last.mem - point.mem) < 0.01 {
                // Idle: keep the ribbon, skip the 1 Hz SwiftUI publish.
            } else {
                trail.append(point)
                if trail.count > self.trailCap { trail.removeFirst(trail.count - self.trailCap) }
                self.trail = trail
            }
        }
    }

    /// Four family buckets as fractions of the machine.
    private static func makeShares(axon: Snapshot, byKey: [Key: Snapshot],
                                   host: HostStats, cores: Double) -> [Share] {
        var buckets: [Family: Snapshot] = [.axon: axon]
        for (key, snap) in byKey {
            buckets[key.family, default: Snapshot()].add(snap)
        }
        let memTotal = max(Double(host.memoryTotal), 1)
        return Family.allCases.compactMap { family in
            guard let snap = buckets[family] else { return nil }
            let present = snap.cpu >= 0.3 || snap.memoryBytes > 2 * 1024 * 1024 || snap.gpu >= 0.3
            guard present || family == .axon else { return nil }
            return Share(
                id: family.rawValue,
                label: family.label,
                memoryBytes: snap.memoryBytes,
                cpuShare: min(1, (snap.cpu / cores) / 100),
                memShare: min(1, Double(snap.memoryBytes) / memTotal),
                gpuShare: min(1, snap.gpu / 100))
        }
    }

    private func sum(pids: [pid_t], now: TimeInterval) -> Snapshot {
        var snap = Snapshot()
        for pid in pids {
            snap.cpu += cpuPercent(pid: pid, now: now)
            snap.memoryBytes &+= footprint(pid: pid)
            if let task = taskPort(pid) {
                snap.gpu += gpuPercent(pid: pid, task: task, now: now)
                if pid != getpid() { mach_port_deallocate(mach_task_self_, task) }
            }
        }
        return snap
    }

    // MARK: - CPU / memory

    private func cpuPercent(pid: pid_t, now: TimeInterval) -> Double {
        var info = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { return 0 }
        let ticks = info.pti_total_user &+ info.pti_total_system
        defer { lastCPU[pid] = (ticks, now) }
        guard let prev = lastCPU[pid], now > prev.at else { return 0 }
        let dt = now - prev.at
        let dTicks = ticks &- prev.ticks
        return (Double(dTicks) / 1_000_000_000 / dt) * 100
    }

    /// All-core utilization 0...100 from `HOST_CPU_LOAD_INFO` tick deltas.
    private func hostCPUPercent() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = info.cpu_ticks.0
        let system = info.cpu_ticks.1
        let idle = info.cpu_ticks.2
        let nice = info.cpu_ticks.3
        defer { lastHostTicks = (user, system, idle, nice) }
        guard let prev = lastHostTicks else { return 0 }
        let dUser = UInt64(user &- prev.user)
        let dSys = UInt64(system &- prev.system)
        let dIdle = UInt64(idle &- prev.idle)
        let dNice = UInt64(nice &- prev.nice)
        let total = dUser + dSys + dIdle + dNice
        guard total > 0 else { return 0 }
        return Double(dUser + dSys + dNice) / Double(total) * 100
    }

    /// App + wired + compressed pages. Capped at physical RAM.
    private func hostMemoryUsed() -> UInt64 {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(vm.active_count) &+ UInt64(vm.wire_count) &+ UInt64(vm.compressor_page_count)) &* page
        let total = ProcessInfo.processInfo.physicalMemory
        return min(used, total)
    }

    private func footprint(pid: pid_t) -> UInt64 {
        if let bytes = rusageFootprint(pid), bytes > 0 { return bytes }
        var info = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { return 0 }
        return info.pti_resident_size
    }

    private func rusageFootprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard kr == 0 else { return nil }
        return info.ri_phys_footprint
    }

    private func physFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    // MARK: - GPU

    private struct PowerInfoV2 {
        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var interruptWakeups: UInt64 = 0
        var platformIdleWakeups: UInt64 = 0
        var gpuEnergy: UInt64 = 0
        var taskEnergy: UInt64 = 0
        var taskPtime: UInt64 = 0
        var psetSwitches: UInt64 = 0
    }
    private static let taskPowerInfoV2: Int32 = 21

    private func taskPort(_ pid: pid_t) -> mach_port_t? {
        if pid == getpid() { return mach_task_self_ }
        var task: mach_port_t = 0
        guard task_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS, task != 0 else { return nil }
        return task
    }

    private func gpuPercent(pid: pid_t, task: mach_port_t, now: TimeInterval) -> Double {
        var info = PowerInfoV2()
        var count = mach_msg_type_number_t(MemoryLayout<PowerInfoV2>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(Self.taskPowerInfoV2), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let energy = info.gpuEnergy
        defer { lastGPU[pid] = (energy, now) }
        guard let prev = lastGPU[pid], now > prev.at else { return 0 }
        let dt = now - prev.at
        let dE = energy &- prev.nanojoules
        let watts = Double(dE) / dt / 1_000_000_000
        return max(0, min(100, (watts / gpuFullWatts) * 100))
    }
}

extension ProcessSampler.Snapshot {
    var memoryLabel: String {
        let mb = Double(memoryBytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 10 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    var cpuLabel: String { String(format: "%.0f%%", cpu) }
    var gpuLabel: String { String(format: "%.0f%%", gpu) }

    var loadLabel: String {
        if memoryBytes == 0 && cpu < 0.5 { return "—" }
        if gpu >= 0.5 { return "\(cpuLabel) · \(memoryLabel) · GPU \(gpuLabel)" }
        return "\(cpuLabel) · \(memoryLabel)"
    }
}

// MARK: - Process index (sampler queue only)

private struct ProcessScanScratch {
    var pids: [pid_t] = Array(repeating: 0, count: 512)
    var name = [CChar](repeating: 0, count: 64)
    var info = [UInt8](repeating: 0, count: 512)
    var path = [UInt8](repeating: 0, count: 4096)
    var argv = [UInt8](repeating: 0, count: 4096)
}

private struct ProcessIndex {
    var claudeRoots: [pid_t] = []
    var cursorPIDs: [pid_t] = []
    var codexByCwd: [String: [pid_t]] = [:]
    var parent: [pid_t: pid_t] = [:]

    func descendants(of root: pid_t) -> [pid_t] {
        var kids: [pid_t: [pid_t]] = [:]
        kids.reserveCapacity(parent.count)
        for (child, p) in parent where child != p {
            kids[p, default: []].append(child)
        }
        var out: [pid_t] = [root]
        var seen: Set<pid_t> = [root]
        var i = 0
        while i < out.count {
            for child in kids[out[i]] ?? [] where seen.insert(child).inserted {
                out.append(child)
            }
            i += 1
            if out.count > 512 { break }
        }
        return out
    }

    static func scan(claudeRoots: [pid_t], scratch: inout ProcessScanScratch) -> ProcessIndex {
        var idx = ProcessIndex(claudeRoots: claudeRoots)
        let pids = allPIDs(scratch: &scratch)
        var cursor: [pid_t] = []
        var codex: [pid_t] = []
        idx.parent.reserveCapacity(pids.count)
        for pid in pids {
            if let p = ppid(of: pid, scratch: &scratch) { idx.parent[pid] = p }
            let lower = processName(pid, scratch: &scratch).lowercased()
            if lower == "cursor" || lower.hasPrefix("cursor helper") {
                cursor.append(pid)
            } else if lower == "codex" {
                codex.append(pid)
            } else if lower.hasPrefix("node"), argvMentionsCodex(pid, scratch: &scratch) {
                codex.append(pid)
            }
        }
        idx.cursorPIDs = cursor

        var byCwd: [String: [pid_t]] = [:]
        for pid in codex {
            guard let cwd = cwd(of: pid, scratch: &scratch), !cwd.isEmpty else { continue }
            let key = (cwd as NSString).standardizingPath
            byCwd[key, default: []].append(pid)
        }
        idx.codexByCwd = byCwd
        return idx
    }

    private static func ppid(of pid: pid_t, scratch: inout ProcessScanScratch) -> pid_t? {
        let got = scratch.info.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0.baseAddress, Int32($0.count))
        }
        guard got >= 20 else { return nil }
        let buf = scratch.info
        return pid_t(UInt32(buf[16]) | UInt32(buf[17]) << 8 | UInt32(buf[18]) << 16 | UInt32(buf[19]) << 24)
    }

    private static func allPIDs(scratch: inout ProcessScanScratch) -> [pid_t] {
        let neededBytes = proc_listallpids(nil, 0)
        guard neededBytes > 0 else { return [] }
        let count = Int(neededBytes) / MemoryLayout<pid_t>.stride + 32
        if scratch.pids.count < count {
            scratch.pids = [pid_t](repeating: 0, count: count)
        }
        let filled = scratch.pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.stride))
        }
        guard filled > 0 else { return [] }
        let n = min(scratch.pids.count, Int(filled) / MemoryLayout<pid_t>.stride)
        return Array(scratch.pids.prefix(n).filter { $0 > 0 })
    }

    private static func processName(_ pid: pid_t, scratch: inout ProcessScanScratch) -> String {
        scratch.name[0] = 0
        guard proc_name(pid, &scratch.name, UInt32(scratch.name.count)) > 0 else { return "" }
        return String(cString: scratch.name)
    }

    private static func cwd(of pid: pid_t, scratch: inout ProcessScanScratch) -> String? {
        let got = scratch.path.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0.baseAddress, Int32($0.count))
        }
        guard got > 0 else { return nil }
        return firstPath(in: scratch.path, count: Int(got))
    }

    private static func firstPath(in buf: [UInt8], count: Int) -> String? {
        let n = min(count, buf.count)
        var i = 0
        while i < n {
            if buf[i] == 0x2F {
                var j = i
                while j < n && buf[j] != 0 { j += 1 }
                if j > i + 1, let s = String(bytes: buf[i..<j], encoding: .utf8), s.hasPrefix("/") {
                    return s
                }
            }
            i += 1
        }
        return nil
    }

    /// `KERN_PROCARGS2` — only called for node processes, not the full table.
    private static func argvMentionsCodex(_ pid: pid_t, scratch: inout ProcessScanScratch) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size < 256 * 1024 else { return false }
        if scratch.argv.count < size {
            scratch.argv = [UInt8](repeating: 0, count: size)
        }
        var sz = size
        let ok = scratch.argv.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &sz, nil, 0) == 0 }
        guard ok else { return false }
        let slice = scratch.argv.prefix(sz)
        guard let text = String(bytes: slice, encoding: .utf8) ?? String(bytes: slice, encoding: .isoLatin1) else {
            return false
        }
        return text.localizedCaseInsensitiveContains("codex")
    }
}

// MARK: - System GPU via IOAccelerator

private enum IOKitGPU {
    static func utilization() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }
        var best = 0.0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else { continue }
            for key in ["Device Utilization %", "GPU Activity%", "Renderer Utilization %", "Tiler Utilization %"] {
                if let n = stats[key] as? Double { best = max(best, n) }
                else if let n = stats[key] as? Int { best = max(best, Double(n)) }
                else if let n = stats[key] as? NSNumber { best = max(best, n.doubleValue) }
            }
        }
        return max(0, min(100, best))
    }
}
