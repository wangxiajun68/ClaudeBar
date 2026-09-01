import Foundation
import Darwin
import IOKit
import Combine

/// Live CPU / memory of Axon plus every tracked agent process, plus
/// machine-wide GPU. Sampled off-main at 1 Hz; published on the main queue.
///
/// CPU is Activity Monitor's "one-core" percent (can exceed 100 on SMP).
/// Memory is `ri_phys_footprint` when rusage is available, else RSS.
/// Per-process GPU needs `task_for_pid` (blocked for hardened tasks) so
/// session chips usually omit it; the strip's GPU meter is IOKit device
/// utilization, which does not need a task port.
final class ProcessSampler: ObservableObject {
    static let shared = ProcessSampler()

    enum Key: Hashable {
        case pid(Int)
        case cursor
        case cwd(String)

        static func standardizedCwd(_ path: String) -> Key {
            .cwd((path as NSString).standardizingPath)
        }

        var shareID: String {
            switch self {
            case .pid(let n): return "c-\(n)"
            case .cursor: return "cursor"
            case .cwd(let p): return "x-\(p)"
            }
        }

        var fallbackLabel: String {
            switch self {
            case .pid: return "Claude"
            case .cursor: return "Cursor"
            case .cwd(let p): return (p as NSString).lastPathComponent
            }
        }
    }

    struct Snapshot: Equatable {
        var cpu: Double = 0
        var gpu: Double = 0
        var memoryBytes: UInt64 = 0
    }

    struct Point: Equatable {
        var cpu: Double
        var gpu: Double
        var mem: Double
    }

    struct Share: Equatable, Identifiable {
        var id: String
        var label: String
        var cpu: Double
        var memoryBytes: UInt64
        var gpu: Double
        var cpuShare: Double
        var memShare: Double
        var gpuShare: Double
    }

    @Published var axon = Snapshot()
    @Published var agents = Snapshot()
    /// IOKit GPU core utilization 0...100. Falls back to Axon's own GPU energy.
    @Published var systemGPU: Double = 0
    @Published var byKey: [Key: Snapshot] = [:]
    @Published var shares: [Share] = []
    @Published var trail: [Point] = []

    private let queue = DispatchQueue(label: "com.claudebar.proc", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastCPU: [pid_t: (ticks: UInt64, at: TimeInterval)] = [:]
    private var lastGPU: [pid_t: (nanojoules: UInt64, at: TimeInterval)] = [:]
    private var claudeRoots: [pid_t] = []
    private var labels: [Key: String] = [:]
    private var index = ProcessIndex()
    private var lastIndexAt: TimeInterval = 0
    private let trailCap = 48
    private let gpuFullWatts = 2.0
    private let indexInterval: TimeInterval = 2.0

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func setAgentPIDs(_ pids: [Int]) {
        queue.async { self.claudeRoots = pids.map { pid_t($0) } }
    }

    func setLabels(_ map: [Key: String]) {
        queue.async { self.labels = map }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastIndexAt >= indexInterval {
            index = ProcessIndex.scan(claudeRoots: claudeRoots)
            lastIndexAt = now
        } else {
            index.claudeRoots = claudeRoots
        }

        let selfPID = getpid()
        var axonSnap = Snapshot()
        axonSnap.cpu = cpuPercent(pid: selfPID, now: now)
        axonSnap.memoryBytes = physFootprint() ?? footprint(pid: selfPID)
        axonSnap.gpu = gpuPercent(pid: selfPID, task: mach_task_self_, now: now)

        let sysGPU = IOKitGPU.utilization()
        let gpuForTrail = sysGPU > 0.5 ? sysGPU : axonSnap.gpu

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

        var agentSnap = Snapshot()
        for snap in byKey.values {
            agentSnap.cpu += snap.cpu
            agentSnap.gpu += snap.gpu
            agentSnap.memoryBytes &+= snap.memoryBytes
        }

        let memCap: Double = 512 * 1024 * 1024
        let point = Point(
            cpu: min(1, axonSnap.cpu / 100),
            gpu: min(1, gpuForTrail / 100),
            mem: min(1, Double(axonSnap.memoryBytes) / memCap)
        )

        var live = claimed
        live.insert(selfPID)
        lastCPU = lastCPU.filter { live.contains($0.key) }
        lastGPU = lastGPU.filter { live.contains($0.key) }

        let shares = Self.makeShares(axon: axonSnap, byKey: byKey, labels: labels, systemGPU: gpuForTrail)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.axon != axonSnap { self.axon = axonSnap }
            if self.agents != agentSnap { self.agents = agentSnap }
            if abs(self.systemGPU - gpuForTrail) > 0.4 { self.systemGPU = gpuForTrail }
            if self.byKey != byKey { self.byKey = byKey }
            if self.shares != shares { self.shares = shares }
            var trail = self.trail
            trail.append(point)
            if trail.count > self.trailCap { trail.removeFirst(trail.count - self.trailCap) }
            self.trail = trail
        }
    }

    private static func makeShares(axon: Snapshot, byKey: [Key: Snapshot],
                                   labels: [Key: String], systemGPU: Double) -> [Share] {
        var raw: [(id: String, label: String, snap: Snapshot)] = [
            ("axon", "Axon", axon)
        ]
        for (key, snap) in byKey {
            raw.append((key.shareID, labels[key] ?? key.fallbackLabel, snap))
        }
        let visible = raw.filter { $0.snap.cpu >= 0.4 || $0.snap.memoryBytes > 3 * 1024 * 1024 }
        let cpuTotal = max(visible.reduce(0) { $0 + $1.snap.cpu }, 0.01)
        let memTotal = max(visible.reduce(0.0) { $0 + Double($1.snap.memoryBytes) }, 1)
        let gpuPieces = visible.filter { $0.snap.gpu >= 0.4 }
        let gpuKnown = gpuPieces.reduce(0) { $0 + $1.snap.gpu }
        let gpuTotal = max(systemGPU, gpuKnown, 0.01)
        return visible
            .sorted { $0.snap.cpu > $1.snap.cpu }
            .map { row in
                Share(id: row.id, label: row.label,
                      cpu: row.snap.cpu, memoryBytes: row.snap.memoryBytes, gpu: row.snap.gpu,
                      cpuShare: row.snap.cpu / cpuTotal,
                      memShare: Double(row.snap.memoryBytes) / memTotal,
                      gpuShare: gpuTotal > 0 ? row.snap.gpu / gpuTotal : 0)
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

// MARK: - Process index (refreshed every 2s)

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

    static func scan(claudeRoots: [pid_t]) -> ProcessIndex {
        var idx = ProcessIndex(claudeRoots: claudeRoots)
        let pids = allPIDs()
        var names: [pid_t: String] = [:]
        names.reserveCapacity(pids.count)
        for pid in pids {
            if let p = ppid(of: pid) { idx.parent[pid] = p }
            names[pid] = processName(pid)
        }

        var cursor: [pid_t] = []
        var codex: [pid_t] = []
        for pid in pids {
            let name = names[pid] ?? ""
            let lower = name.lowercased()
            if lower == "cursor" || lower.hasPrefix("cursor helper") {
                cursor.append(pid)
                continue
            }
            if lower == "codex" {
                codex.append(pid)
                continue
            }
            if lower.hasPrefix("node"), argvMentionsCodex(pid) {
                codex.append(pid)
            }
        }
        idx.cursorPIDs = cursor

        var byCwd: [String: [pid_t]] = [:]
        for pid in codex {
            guard let cwd = cwd(of: pid), !cwd.isEmpty else { continue }
            let key = (cwd as NSString).standardizingPath
            byCwd[key, default: []].append(pid)
        }
        idx.codexByCwd = byCwd
        return idx
    }

    private static func ppid(of pid: pid_t) -> pid_t? {
        var buf = [UInt8](repeating: 0, count: 512)
        let got = buf.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0.baseAddress, Int32($0.count))
        }
        guard got >= 20 else { return nil }
        return pid_t(UInt32(buf[16]) | UInt32(buf[17]) << 8 | UInt32(buf[18]) << 16 | UInt32(buf[19]) << 24)
    }

    private static func allPIDs() -> [pid_t] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(needed) + 32)
        let filled = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return [] }
        return buf.prefix(Int(filled)).filter { $0 > 0 }
    }

    private static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    private static func cwd(of pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 4096)
        let got = buf.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0.baseAddress, Int32($0.count))
        }
        guard got > 0 else { return nil }
        return firstPath(in: buf, count: Int(got))
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
    private static func argvMentionsCodex(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size < 256 * 1024 else { return false }
        var buf = [UInt8](repeating: 0, count: size)
        let ok = buf.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) == 0 }
        guard ok else { return false }
        guard let text = String(bytes: buf, encoding: .utf8) ?? String(bytes: buf, encoding: .isoLatin1) else {
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
