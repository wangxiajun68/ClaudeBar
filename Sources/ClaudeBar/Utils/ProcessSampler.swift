import Foundation
import Darwin
import AppKit
import Combine
import SwiftUI
import Observation

/// Live process and host meters for the 本机负载 strip and session chips.
///
/// Sampling runs off-main. Headline numbers are machine-wide (all-core CPU,
/// IOAccelerator GPU, physical memory, SMC / IOKit temperatures). Per-agent
/// chips use single-core CPU % and `phys_footprint`. Family shares are
/// fractions of the machine, not of each other.
///
/// `@Observable` so a session chip that only reads `byKey` is not redrawn
/// when host CPU ticks — the old `ObservableObject` broadcast was the
/// dashboard's largest scroll hitch.
@Observable
final class ProcessSampler {
    static let shared = ProcessSampler()

    enum MonitorScope: Hashable {
        case popup
        case dashboard
        case sessions
        case island
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
        /// Busy fraction per logical core, 0…1, in core order. Empty until the
        /// sampler's second tick establishes the baseline.
        var coreLoad: [Double] = []
        /// GPU core count as the driver publishes it, and the three sub-unit
        /// readings (device / renderer / tiler) as 0…100. Zero and empty on a
        /// machine whose driver publishes neither.
        var gpuCoreCount: Int = 0
        var gpuRenderers: [Double] = []
        /// Physical memory by page category, in bytes. These are the *real*
        /// buckets `vm_statistics64` reports — not an apportionment of
        /// `memoryUsed`, which is `active + inactive + speculative + wired +
        /// compressed − purgeable − external` and would double-count two of
        /// them. `used` is the sampler's own pressure figure and is the one the
        /// percentage on screen comes from; the parts are for the mark.
        ///
        /// They do **not** sum to `used`: `free` counts bytes that are nobody's
        /// (`speculative` is a subset of neither), and the categories are
        /// sampled independently. That is why they are carried as raw bytes and
        /// normalised by the mark rather than as pre-divided shares.
        var memoryActive: UInt64 = 0
        var memoryWired: UInt64 = 0
        var memoryCompressed: UInt64 = 0
        var memoryCached: UInt64 = 0
        /// `free_count + speculative_count` — what is genuinely available,
        /// which is the number a person means by "空闲".
        var memoryFree: UInt64 = 0
        var cpuTemperatureCelsius: Double?
        var gpuTemperatureCelsius: Double?
        /// Battery cell temperature, when the SMC reports one. Distinct from
        /// the CPU / GPU sensors: on battery the cell is what gets warm.
        var batteryTemperatureCelsius: Double?
        var memoryPressureLevel: Int = 0
        var diskUsed: UInt64 = 0
        var diskTotal: UInt64 = 1
        var wifiOn: Bool = false
        var wifiName: String = ""
        var wifiRSSI: Int = 0
        var bluetoothOn: Bool = false
        var wiredOn: Bool = false
        var batteryPercent: Int = 0
        var batteryInstalled: Bool = false
        var batteryCharging: Bool = false
        var batteryExternalPower: Bool = false
        var batteryChargingWatts: Double?
        var powerInputWatts: Double?
        var powerSystemWatts: Double?
        var powerBatteryWatts: Double?
        var powerIsEstimated = false
        var adapterRatedWatts: Int?

        var diskPercent: Double {
            guard diskTotal > 0 else { return 0 }
            return Double(diskUsed) / Double(diskTotal) * 100
        }

        var diskLabel: String {
            let used = ProcessSampler.Snapshot(memoryBytes: diskUsed).memoryLabel
            let total = ProcessSampler.Snapshot(memoryBytes: diskTotal).memoryLabel
            return "\(used) / \(total)"
        }

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

        /// The memory mark's own reading: the page categories the percentage is
        /// made of, each normalised by *physical* memory — the denominator a
        /// person means by "用了多少内存".
        ///
        /// A share, not a stacked sum: `active` and `cached` each count bytes
        /// that are nobody else's, and stacking them would claim the machine
        /// was using more than it has. The mark draws one well per category
        /// against the same total for that reason.
        var memoryWells: [Double] {
            guard memoryTotal > 0 else { return [] }
            let total = Double(memoryTotal)
            let bytes = [memoryActive, memoryWired, memoryCompressed]
            guard bytes.contains(where: { $0 > 0 }) else { return [] }
            return bytes.map { min(1, Double($0) / total) }
        }

        /// The terms `memoryWells` are in, formatted with the same byte
        /// formatter as every other label in the strip.
        var memoryWellCaptions: [String] {
            guard memoryTotal > 0 else { return [] }
            let bytes = [memoryActive, memoryWired, memoryCompressed]
            guard bytes.contains(where: { $0 > 0 }) else { return [] }
            return bytes.map { Snapshot(memoryBytes: $0).memoryLabel }
        }

        /// The disk mark's own reading: used and free, each against capacity.
        /// Two wells rather than a percentage, because that is what a capacity
        /// mark is for — the figure above it already says how full it is.
        var diskWells: [Double] {
            guard diskTotal > 0 else { return [] }
            let used = min(diskUsed, diskTotal)
            return [Double(used) / Double(diskTotal), Double(diskTotal - used) / Double(diskTotal)]
        }

        var diskWellCaptions: [String] {
            guard diskTotal > 0 else { return [] }
            let used = min(diskUsed, diskTotal)
            return [Snapshot(memoryBytes: used).memoryLabel, Snapshot(memoryBytes: diskTotal - used).memoryLabel]
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

    var claudeBar = Snapshot()
    var host = HostStats()
    var byKey: [Key: Snapshot] = [:]
    var shares: [Share] = []
    var trail: [Point] = []

    private let queue = DispatchQueue(label: "com.claudebar.proc", qos: .utility)
    private var timer: DispatchSourceTimer?
    // Disk capacity changes slowly; keep filesystem queries off the live power cadence.
    private var diskSample: (used: UInt64, total: UInt64)?
    private var diskSampleAt: TimeInterval = 0
    private var linkSample: HardwareSensors.LinkStatus?
    private var linkSampleAt: TimeInterval = 0
    private var cpuTemperature: Double?
    private var batteryTemperature: Double?
    private var temperatureSampleAt: TimeInterval = -.infinity
    private var lastCPU: [pid_t: (ticks: UInt64, at: TimeInterval)] = [:]
    private var lastHostTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    /// Per-core busy fraction, in *logical core* order (0…`coreCount`-1), the
    /// counterpart of `hostCPUPercent`'s single aggregate figure. Empty until
    /// the second sample — the first one only establishes a baseline.
    ///
    /// `PROCESSOR_CPU_LOAD_INFO` returns the same CPU_STATE_* counters that
    /// `HOST_CPU_LOAD_INFO` does, once per core, so the two never disagree
    /// about the machine: the array's mean is the aggregate (modulo the
    /// per-sample rounding). That matters because the strip draws both — a
    /// twelve-core glyph whose cells average to something other than the number
    /// printed underneath it is worse than no glyph at all.
    private var lastPerCoreTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var claudeRoots: [pid_t] = []
    private var index = ProcessIndex()
    private var lastDiscoveryAt: TimeInterval = 0
    private let trailCap = 24
    private let discoveryInterval: TimeInterval = 10
    private var live = false
    private var foreground = true
    private var activeScopes: Set<MonitorScope> = []
    private var period: TimeInterval = 2.5
    private var timerSuspended = false
    private var scratch = ProcessScanScratch()
    private var activeObs: NSObjectProtocol?
    private var resignObs: NSObjectProtocol?

    private var visibilityCancel: AnyCancellable?

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: self.period)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
            // A suspend may have been recorded before the timer existed
            // (start() runs off-main while UIWakePolicy can fire immediately).
            if self.timerSuspended { self.setTimerSuspended(true) }
            // Apply the launch-time visibility state: the observer only fires
            // on *changes*, so a launch with no visible window would otherwise
            // sample forever at the default cadence.
            self.applyPeriod()
        }
        observeAppState()
        // Nothing on screen and nobody to attribute to: the sampler's whole
        // output (CPU %, GPU, memory, SMC temperature sweep) has no consumer.
        // Suspend it rather than sampling a machine no one is watching.
        if visibilityCancel == nil {
            visibilityCancel = UIWakePolicy.observe { [weak self] in
                guard let self else { return }
                self.queue.async { self.applyPeriod() }
            }
        }
    }

    /// Suspend / resume the sampling timer. `timer` is created once on the
    /// private queue and only ever touched there. Creation already resumed
    /// once, so a single matching `resume()` restores it.
    private func setTimerSuspended(_ suspended: Bool) {
        guard let timer else { return }
        if suspended {
            timer.suspend()
        } else {
            timer.resume()
        }
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
        // No consumer: no visible window and no session to attribute to.
        let wasSuspended = timerSuspended
        let shouldSuspend = !wantsAttribution && !UIWakePolicy.hasVisibleWindow
        if shouldSuspend != timerSuspended {
            timerSuspended = shouldSuspend
            setTimerSuspended(shouldSuspend)
            if shouldSuspend { return }
        }
        guard !timerSuspended else { return }

        let next: TimeInterval
        if !wantsAttribution {
            next = foreground ? 6 : 12
        } else if !foreground {
            next = 6
        } else if live {
            next = 1
        } else {
            // A resource UI is open but every session is idle: 2 s keeps the
            // gauges current at half the IOKit/SMC traffic.
            next = 2
        }
        guard wasSuspended || abs(period - next) > 0.05 else { return }
        period = next
        timer?.schedule(deadline: .now(), repeating: next, leeway: .milliseconds(50))
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
        if diskSample == nil || now - diskSampleAt >= 10 {
            diskSample = HardwareSensors.bootDisk()
            diskSampleAt = now
        }
        let disk = diskSample ?? (used: 0, total: 1)
        // CoreWLAN + SCDynamicStore + IOBluetooth; a link state older than
        // 3 s is not stale for a status mark.
        if linkSample == nil || now - linkSampleAt >= 3 {
            linkSample = HardwareSensors.linkStatus()
            linkSampleAt = now
        }
        let links = linkSample ?? HardwareSensors.LinkStatus()
        // The SMC temperature sweep is the dearest read in the tick, and
        // package temperature moves on a scale of seconds.
        if foreground, now - temperatureSampleAt >= 5 {
            cpuTemperature = HardwareSensors.cpuTemperatureCelsius()
            batteryTemperature = HardwareSensors.batteryTemperatureCelsius()
            temperatureSampleAt = now
        }
        // Read on *every* tier, not just the foreground one. The 电量 mark is
        // permanent (`ConnectLaneRow` draws it whether or not a pack is fitted),
        // so a background-tier sample that left it at 0 would repaint the tile
        // with a flat battery on the first popup tick. It is one
        // `IORegistryEntryCreateCFProperties` on an already-matched service —
        // cheaper than the GPU and temperature reads beside it, which *are*
        // still tiered because they are the expensive ones.
        let battery = HardwareSensors.batteryStatus()
        // One `vm_statistics64` serves both the pressure figure and the mark's
        // parts, so the two cannot be read a tick apart.
        let memory = memoryBreakdown()
        let hostSnap = HostStats(
            cpu: hostCPUPercent(),
            gpu: gpu.utilization,
            memoryUsed: memory.used,
            memoryTotal: ProcessInfo.processInfo.physicalMemory,
            coreCount: max(ProcessInfo.processInfo.processorCount, 1),
            coreLoad: hostCoreLoad(),
            gpuCoreCount: gpu.coreCount,
            gpuRenderers: gpu.renderers,
            memoryActive: memory.active,
            memoryWired: memory.wired,
            memoryCompressed: memory.compressed,
            memoryCached: memory.cached,
            memoryFree: memory.free,
            cpuTemperatureCelsius: foreground ? cpuTemperature : nil,
            gpuTemperatureCelsius: foreground ? gpu.temperatureCelsius : nil,
            batteryTemperatureCelsius: foreground ? batteryTemperature : nil,
            memoryPressureLevel: HardwareSensors.memoryPressureLevel(),
            diskUsed: disk.used,
            diskTotal: disk.total,
            wifiOn: links.wifiOn,
            wifiName: links.wifiName,
            wifiRSSI: links.wifiRSSI,
            bluetoothOn: links.bluetoothOn,
            wiredOn: links.wiredOn,
            batteryPercent: battery.percent,
            batteryInstalled: battery.installed,
            batteryCharging: battery.charging,
            batteryExternalPower: battery.externalPower,
            batteryChargingWatts: battery.chargingWatts,
            powerInputWatts: battery.inputWatts,
            powerSystemWatts: battery.systemWatts,
            powerBatteryWatts: battery.batteryWatts,
            powerIsEstimated: battery.powerIsEstimated,
            adapterRatedWatts: battery.externalPower ? battery.adapterRatedWatts : nil
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

        // One pid→children pass for the whole tick; `descendants` is called
        // once per session root below.
        index.buildChildIndex()

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
            var host = host
            host.cpu = host.cpu.rounded()
            host.gpu = host.gpu.rounded()
            host.memoryUsed = (host.memoryUsed / 1_048_576) * 1_048_576
            host.diskUsed = (host.diskUsed / 1_048_576) * 1_048_576
            host.diskTotal = (host.diskTotal / 1_048_576) * 1_048_576
            if let t = host.cpuTemperatureCelsius { host.cpuTemperatureCelsius = t.rounded() }
            if let t = host.gpuTemperatureCelsius { host.gpuTemperatureCelsius = t.rounded() }
            if let t = host.batteryTemperatureCelsius { host.batteryTemperatureCelsius = t.rounded() }
            // RSSI jitters ±1 dBm and the power rails in milliwatts between
            // samples; below these steps nothing on screen changes, so the
            // equality check below can actually hold.
            host.wifiRSSI = (host.wifiRSSI / 2) * 2
            func tenth(_ value: Double?) -> Double? { value.map { ($0 * 10).rounded() / 10 } }
            host.powerInputWatts = tenth(host.powerInputWatts)
            host.powerSystemWatts = tenth(host.powerSystemWatts)
            host.powerBatteryWatts = tenth(host.powerBatteryWatts)
            host.batteryChargingWatts = tenth(host.batteryChargingWatts)

            if self.claudeBar != claudeBar { self.claudeBar = claudeBar }
            if self.host != host { self.host = host }
            if self.byKey != byKey { self.byKey = byKey }
            if self.shares != shares { self.shares = shares }
            var trail = self.trail
            if let last = trail.last,
               abs(last.cpu - point.cpu) < 0.02,
               abs(last.gpu - point.gpu) < 0.02,
               abs(last.mem - point.mem) < 0.015 {
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

    /// One busy fraction per logical core, in core order.
    ///
    /// Sibling of `hostCPUPercent`, and it exists for the same reason the fan
    /// rotors read real RPM: the dashboard's CPU mark draws `coreCount` cells,
    /// and a cell that is not wired to a real core is a decoration wearing a
    /// measurement's clothes. The alternative — one glyph with a single
    /// brightness — was rejected because it would have to pick a number, and
    /// any single number here is either the aggregate (already printed three
    /// lines below) or a lie about 12 independent cores.
    ///
    /// Cost: one `host_processor_info` per tick. It is the same class of call
    /// as the `host_statistics` beside it, system-wide and O(cores), and it is
    /// already inside the sampler's tick — no new timer, no new wake-up.
    ///
    /// The returned array is allocated by the kernel and must be handed back;
    /// `defer` does that on every path out, including the failure ones.
    private func hostCoreLoad() -> [Double] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let cores = Int(cpuCount)
        guard cores > 0, Int(infoCount) >= cores * Int(CPU_STATE_MAX) else { return [] }
        let stateMax = Int(CPU_STATE_MAX)
        var next: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        next.reserveCapacity(cores)
        for core in 0..<cores {
            let base = core * stateMax
            next.append((user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                         system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                         idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                         nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        // The core count can change under us (a core coming online), and a
        // mismatched baseline would difference two different cores' counters.
        let prev = lastPerCoreTicks.count == cores ? lastPerCoreTicks : nil
        lastPerCoreTicks = next
        guard let prev else { return [] }
        return (0..<cores).map { core in
            let now = next[core], before = prev[core]
            let dUser = UInt64(now.user &- before.user)
            let dSys = UInt64(now.system &- before.system)
            let dIdle = UInt64(now.idle &- before.idle)
            let dNice = UInt64(now.nice &- before.nice)
            let total = dUser + dSys + dIdle + dNice
            guard total > 0 else { return 0 }
            return Double(dUser + dSys + dNice) / Double(total)
        }
    }

    private func hostMemoryUsed() -> UInt64 {
        memoryBreakdown().used
    }

    /// The real page buckets behind `hostMemoryUsed`, in one `vm_statistics64`
    /// call. Split out because the dashboard's memory mark draws the parts and
    /// the hero figure is their own pressure sum — two reads of the same counter
    /// set could disagree at the boundary, and a mark that contradicts the
    /// number above it is worse than no mark.
    private func memoryBreakdown() -> (used: UInt64, active: UInt64, wired: UInt64,
                                       compressed: UInt64, cached: UInt64, free: UInt64) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0, 0, 0, 0, 0) }
        let page = UInt64(vm_kernel_page_size)
        let active = UInt64(vm.active_count) &* page
        let inactive = UInt64(vm.inactive_count) &* page
        let speculative = UInt64(vm.speculative_count) &* page
        let wired = UInt64(vm.wire_count) &* page
        let compressed = UInt64(vm.compressor_page_count) &* page
        let purgeable = UInt64(vm.purgeable_count) &* page
        let external = UInt64(vm.external_page_count) &* page
        let used = active &+ inactive &+ speculative &+ wired &+ compressed &- purgeable &- external
        return (min(used, ProcessInfo.processInfo.physicalMemory), active, wired, compressed,
                inactive &+ purgeable, UInt64(vm.free_count) &* page &+ speculative)
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

    /// pid → children, built once per tick. `descendants` is called for every
    /// root (one per session); rebuilding this dictionary per call was O(roots
    /// × processes) inside the 1s busy-path sample.
    private var kids: [pid_t: [pid_t]]? = nil

    mutating func buildChildIndex() {
        var map: [pid_t: [pid_t]] = [:]
        map.reserveCapacity(parent.count)
        for (child, parentPID) in parent where child != parentPID {
            map[parentPID, default: []].append(child)
        }
        kids = map
    }

    func descendants(of root: pid_t) -> [pid_t] {
        guard let kids else {
            var index = self
            index.buildChildIndex()
            return index.descendants(of: root)
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
