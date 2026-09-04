import Foundation
import Darwin
import AppKit
import Combine
import SwiftUI

/// Live process and host meters for the 本机负载 strip and session chips.
///
/// Sampling runs off-main. Headline numbers are machine-wide (all-core CPU,
/// IOAccelerator GPU, physical memory, SMC / IOKit temperatures). Per-agent
/// chips use single-core CPU % and `phys_footprint`. Family shares are
/// fractions of the machine, not of each other.
final class ProcessSampler: ObservableObject {
    static let shared = ProcessSampler()

    enum MonitorScope: Hashable {
        case popup
        case dashboard
        case sessions
    }

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
        case claudeBar, claude, cursor, codex

        var label: String {
            switch self {
            case .claudeBar: return "ClaudeBar"
            case .claude: return "CC"
            case .cursor: return "Cursor"
            case .codex: return "Codex"
            }
        }
    }

    struct Snapshot: Equatable {
        var cpu: Double = 0
        var memoryBytes: UInt64 = 0
    }

    struct HostStats: Equatable {
        var cpu: Double = 0
        var gpu: Double = 0
        var memoryUsed: UInt64 = 0
        var memoryTotal: UInt64 = 0
        var coreCount: Int = 1
        var cpuTemperatureCelsius: Double?
        var gpuTemperatureCelsius: Double?
        var memoryPressureLevel: Int = 0

        var memoryLabel: String {
            let used = ProcessSampler.Snapshot(memoryBytes: memoryUsed).memoryLabel
            let total = ProcessSampler.Snapshot(memoryBytes: memoryTotal).memoryLabel
            return "\(used) / \(total)"
        }

        func temperatureLabel(celsius: Double?) -> String? {
            guard let celsius, celsius > 0 else { return nil }
            return String(format: "%.0f°C", celsius.rounded())
        }

        /// 高温分级：<75 正常，75–84 偏高（amber），≥85 过热（red）。
        func temperatureColor(celsius: Double?) -> Color? {
            guard let celsius, celsius > 0 else { return nil }
            if celsius >= 85 { return Theme.statusError }
            if celsius >= 75 { return Theme.statusWarning }
            return nil
        }
    }

    struct Point: Equatable {
        var cpu: Double
        var gpu: Double
        var mem: Double
    }

    struct Share: Equatable, Identifiable {
        var id: String
        var label: String
        var memoryBytes: UInt64
        var cpuShare: Double
        var memShare: Double
    }

    @Published private(set) var claudeBar = Snapshot()
    @Published private(set) var host = HostStats()
    @Published private(set) var byKey: [Key: Snapshot] = [:]
    @Published private(set) var shares: [Share] = []
    @Published private(set) var trail: [Point] = []

    private let queue = DispatchQueue(label: "com.claudebar.proc", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastCPU: [pid_t: (ticks: UInt64, at: TimeInterval)] = [:]
    private var lastHostTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var claudeRoots: [pid_t] = []
    private var index = ProcessIndex()
    private var lastDiscoveryAt: TimeInterval = 0
    private let trailCap = 24
    private let discoveryInterval: TimeInterval = 10
    private var live = false
    private var foreground = true
    private var activeScopes: Set<MonitorScope> = []
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

    func setScope(_ scope: MonitorScope, active: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if active {
                self.activeScopes.insert(scope)
            } else {
                self.activeScopes.remove(scope)
            }
            self.applyPeriod()
        }
    }

    func setLive(_ on: Bool) {
        queue.async { [weak self] in
            guard let self, self.live != on else { return }
            self.live = on
            self.applyPeriod()
        }
    }

    func setAgentPIDs(_ pids: [Int]) {
        queue.async { [weak self] in
            guard let self else { return }
            let next = pids.map { pid_t($0) }
            let changed = next != self.claudeRoots
            self.claudeRoots = next
            if changed {
                self.lastDiscoveryAt = 0
            }
        }
    }

    private var wantsAttribution: Bool {
        live || !activeScopes.isEmpty
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
        if !wantsAttribution {
            next = foreground ? 6 : 12
        } else if !foreground {
            next = 6
        } else if live {
            next = 1
        } else {
            next = 2.5
        }
        guard abs(period - next) > 0.05 else { return }
        period = next
        timer?.schedule(deadline: .now() + next, repeating: next)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if wantsAttribution, now - lastDiscoveryAt >= discoveryInterval || lastDiscoveryAt == 0 {
            index = ProcessIndex.scan(claudeRoots: claudeRoots, scratch: &scratch)
            lastDiscoveryAt = now
        } else {
            index.claudeRoots = claudeRoots
        }

        let gpu = foreground ? HardwareSensors.gpuReading() : HostAccelerator.Reading()
        let hostSnap = HostStats(
            cpu: hostCPUPercent(),
            gpu: gpu.utilization,
            memoryUsed: hostMemoryUsed(),
            memoryTotal: ProcessInfo.processInfo.physicalMemory,
            coreCount: max(ProcessInfo.processInfo.processorCount, 1),
            cpuTemperatureCelsius: foreground ? HardwareSensors.cpuTemperatureCelsius() : nil,
            gpuTemperatureCelsius: foreground ? gpu.temperatureCelsius : nil,
            memoryPressureLevel: HardwareSensors.memoryPressureLevel()
        )

        let memTotal = max(Double(hostSnap.memoryTotal), 1)
        let point = Point(
            cpu: min(1, hostSnap.cpu / 100),
            gpu: min(1, hostSnap.gpu / 100),
            mem: min(1, Double(hostSnap.memoryUsed) / memTotal)
        )

        guard wantsAttribution else {
            publish(claudeBar: Snapshot(), host: hostSnap, byKey: [:], shares: [], point: point, livePIDs: [getpid()])
            return
        }

        let selfPID = getpid()
        var claudeBarSnap = Snapshot()
        claudeBarSnap.cpu = cpuPercent(pid: selfPID, now: now)
        claudeBarSnap.memoryBytes = physFootprint() ?? footprint(pid: selfPID)

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
            let livePIDs = pids.filter { !claimed.contains($0) }
            guard !livePIDs.isEmpty else { continue }
            var group = Set<pid_t>()
            for pid in livePIDs { group.formUnion(index.descendants(of: pid)) }
            claimed.formUnion(group)
            byKey[.cwd(cwd)] = sum(pids: Array(group), now: now)
        }

        var livePIDs = claimed
        livePIDs.insert(selfPID)
        lastCPU = lastCPU.filter { livePIDs.contains($0.key) }

        let cores = Double(hostSnap.coreCount)
        let shares = Self.makeShares(claudeBar: claudeBarSnap, byKey: byKey, host: hostSnap, cores: cores)
        publish(claudeBar: claudeBarSnap, host: hostSnap, byKey: byKey, shares: shares, point: point, livePIDs: livePIDs)
    }

    private func publish(
        claudeBar: Snapshot,
        host: HostStats,
        byKey: [Key: Snapshot],
        shares: [Share],
        point: Point,
        livePIDs: Set<pid_t>
    ) {
        _ = livePIDs
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.claudeBar != claudeBar { self.claudeBar = claudeBar }
            if self.host != host { self.host = host }
            if self.byKey != byKey { self.byKey = byKey }
            if self.shares != shares { self.shares = shares }
            var trail = self.trail
            if let last = trail.last,
               abs(last.cpu - point.cpu) < 0.015,
               abs(last.gpu - point.gpu) < 0.015,
               abs(last.mem - point.mem) < 0.01 {
                return
            }
            trail.append(point)
            if trail.count > self.trailCap { trail.removeFirst(trail.count - self.trailCap) }
            self.trail = trail
        }
    }

    private static func makeShares(
        claudeBar: Snapshot,
        byKey: [Key: Snapshot],
        host: HostStats,
        cores: Double
    ) -> [Share] {
        var buckets: [Family: Snapshot] = [.claudeBar: claudeBar]
        for (key, snap) in byKey {
            buckets[key.family, default: Snapshot()].cpu += snap.cpu
            buckets[key.family, default: Snapshot()].memoryBytes &+= snap.memoryBytes
        }
        let memTotal = max(Double(host.memoryTotal), 1)
        return Family.allCases.compactMap { family in
            guard let snap = buckets[family] else { return nil }
            let present = snap.cpu >= 0.3 || snap.memoryBytes > 2 * 1024 * 1024
            guard present || family == .claudeBar else { return nil }
            return Share(
                id: family.rawValue,
                label: family.label,
                memoryBytes: snap.memoryBytes,
                cpuShare: min(1, (snap.cpu / cores) / 100),
                memShare: min(1, Double(snap.memoryBytes) / memTotal)
            )
        }
    }

    private func sum(pids: [pid_t], now: TimeInterval) -> Snapshot {
        var snap = Snapshot()
        for pid in pids {
            snap.cpu += cpuPercent(pid: pid, now: now)
            snap.memoryBytes &+= footprint(pid: pid)
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
        let active = UInt64(vm.active_count) &* page
        let inactive = UInt64(vm.inactive_count) &* page
        let speculative = UInt64(vm.speculative_count) &* page
        let wired = UInt64(vm.wire_count) &* page
        let compressed = UInt64(vm.compressor_page_count) &* page
        let purgeable = UInt64(vm.purgeable_count) &* page
        let external = UInt64(vm.external_page_count) &* page
        let used = active &+ inactive &+ speculative &+ wired &+ compressed &- purgeable &- external
        return min(used, ProcessInfo.processInfo.physicalMemory)
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
}

extension ProcessSampler.Snapshot {
    var memoryLabel: String {
        let mb = Double(memoryBytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 10 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    var cpuLabel: String { String(format: "%.0f%%", cpu) }

    var loadLabel: String {
        if memoryBytes == 0 && cpu < 0.5 { return "—" }
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
        for (child, parentPID) in parent where child != parentPID {
            kids[parentPID, default: []].append(child)
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
            if let parentPID = ppid(of: pid, scratch: &scratch) { idx.parent[pid] = parentPID }
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
