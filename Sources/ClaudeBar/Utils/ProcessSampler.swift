import Foundation
import Darwin
import Combine

/// Live CPU / memory / GPU of this process (Axon) plus an aggregate of
/// tracked Claude Code PIDs. Sampled off-main; published on the main queue.
///
/// CPU is Activity Monitor's "one-core" percent (can exceed 100 on SMP).
/// Memory is `phys_footprint` for Axon and `pti_resident_size` for agents
/// (task_for_pid is not available on other processes). GPU is Axon-only:
/// `task_power_info_v2.gpu_energy` converted to milliwatts, then scaled so
/// 2 W = 100% — a menu-bar app rarely exceeds a few hundred mW.
final class ProcessSampler: ObservableObject {
    static let shared = ProcessSampler()

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

    @Published var axon = Snapshot()
    @Published var agents = Snapshot()
    @Published var trail: [Point] = []

    private let queue = DispatchQueue(label: "com.claudebar.proc", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastCPU: [pid_t: (ticks: UInt64, at: TimeInterval)] = [:]
    private var lastGPU: (nanojoules: UInt64, at: TimeInterval)?
    private var agentPIDs: [pid_t] = []
    private let trailCap = 48
    private let gpuFullWatts = 2.0

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
        queue.async { self.agentPIDs = pids.map { pid_t($0) } }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let selfPID = getpid()
        var axonSnap = Snapshot()
        axonSnap.cpu = cpuPercent(pid: selfPID, now: now)
        axonSnap.memoryBytes = physFootprint() ?? residentSize(pid: selfPID)
        axonSnap.gpu = gpuPercent(now: now)

        var agentSnap = Snapshot()
        var agentCPU = 0.0
        var agentMem: UInt64 = 0
        for pid in agentPIDs {
            agentCPU += cpuPercent(pid: pid, now: now)
            agentMem += residentSize(pid: pid)
        }
        agentSnap.cpu = agentCPU
        agentSnap.memoryBytes = agentMem

        let memCap: Double = 512 * 1024 * 1024
        let point = Point(
            cpu: min(1, axonSnap.cpu / 100),
            gpu: min(1, axonSnap.gpu / 100),
            mem: min(1, Double(axonSnap.memoryBytes) / memCap)
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.axon = axonSnap
            self.agents = agentSnap
            var trail = self.trail
            trail.append(point)
            if trail.count > self.trailCap { trail.removeFirst(trail.count - self.trailCap) }
            self.trail = trail
        }
    }

    // MARK: - CPU

    private func cpuPercent(pid: pid_t, now: TimeInterval) -> Double {
        var info = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { return 0 }
        let ticks = info.pti_total_user &+ info.pti_total_system
        defer { lastCPU[pid] = (ticks, now) }
        guard let prev = lastCPU[pid], now > prev.at else { return 0 }
        let dt = now - prev.at
        let dTicks = ticks &- prev.ticks
        // pti_total_* is nanoseconds of CPU time.
        return (Double(dTicks) / 1_000_000_000 / dt) * 100
    }

    private func residentSize(pid: pid_t) -> UInt64 {
        var info = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { return 0 }
        return info.pti_resident_size
    }

    // MARK: - Self memory / GPU

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

    /// Darwin's `task_power_info_v2` is not imported into Swift; layout matches
    /// osfmk/mach/task_info.h (cpu_energy is four uint64s, then gpu_energy).
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

    private func gpuPercent(now: TimeInterval) -> Double {
        var info = PowerInfoV2()
        var count = mach_msg_type_number_t(MemoryLayout<PowerInfoV2>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(Self.taskPowerInfoV2), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let energy = info.gpuEnergy
        defer { lastGPU = (energy, now) }
        guard let prev = lastGPU, now > prev.at else { return 0 }
        let dt = now - prev.at
        let dE = energy &- prev.nanojoules
        // nanojoules / seconds = nanowatts; / 1e9 = watts.
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
}
