import Foundation
import Combine
import Observation

@MainActor
@Observable
final class FanMonitor {
    static let shared = FanMonitor()

    var fans: [FanInfo] = []
    var lastError: String?
    var helperInstalled = FanHelperInstaller.isInstalled()

    private var wakeObservation: AnyCancellable?
    private var timer: Timer?
    private var subscribers = 0
    private var pendingSpeedTasks: [Int: DispatchWorkItem] = [:]
    /// All privileged commands execute in submission order, away from the UI thread.
    private let commandQueue = DispatchQueue(label: "com.claudebar.fan-commands", qos: .userInitiated)
    private var commandRevision: UInt64 = 0
    private let readQueue = DispatchQueue(label: "com.claudebar.fan-read", qos: .utility)
    @ObservationIgnored private var reading = false

    private init() {}

    func start() {
        subscribers += 1
        helperInstalled = FanHelperInstaller.isInstalled()
        if wakeObservation == nil {
            wakeObservation = UIWakePolicy.observe { [weak self] in self?.syncPolling() }
        }
        syncPolling()
    }

    private func syncPolling() {
        guard subscribers > 0, UIWakePolicy.hasVisibleWindow else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.25
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        wakeObservation = nil
        timer?.invalidate()
        timer = nil
    }

    /// SMC reads (several IOKit round-trips per fan) run on `readQueue`;
    /// only the publish happens on the main actor. A poll with nothing on
    /// screen is skipped — the rotors it would feed are not being drawn.
    func refresh() {
        guard !reading, UIWakePolicy.hasVisibleWindow || fans.isEmpty else { return }
        reading = true
        readQueue.async { [weak self] in
            let smc = SMCController.shared
            let available = smc.isConnected
            let next = available ? smc.loadFans() : []
            Task { @MainActor in
                guard let self else { return }
                self.reading = false
                // 绝大多数 tick 数值不变 —— Equatable 守卫，避免资源区无谓重渲。
                if next != self.fans { self.fans = next }
            }
        }
    }

    func setAutomatic(_ fanID: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingSpeedTasks.removeValue(forKey: fanID)?.cancel()
            self.submit { FanHelperInstaller.setAutomatic(fanID: fanID) }
        }
    }

    func setManual(_ fanID: Int, rpm: Int) {
        // Defer the @Observable mutation out of the current view update, and
        // coalesce rapid repeats: a second tap within 0.1 s cancels the first,
        // so only the last RPM of a burst reaches the helper.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingSpeedTasks.removeValue(forKey: fanID)?.cancel()
            let task = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingSpeedTasks.removeValue(forKey: fanID)
                self.submit { FanHelperInstaller.setFanSpeed(fanID: fanID, rpm: rpm) }
            }
            self.pendingSpeedTasks[fanID] = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: task)
        }
    }

    func setMaxSpeed(_ fanID: Int) {
        guard let fan = fans.first(where: { $0.id == fanID }) else { return }
        setManual(fanID, rpm: fan.maxRPM)
    }

    /// The per-fan toggle both the tile pair and the detail panel ask for, in
    /// one place: hand the fan back to the system, or hold it at max.
    func toggleMode(of fan: FanInfo) {
        if fan.mode.isAutomatic { setMaxSpeed(fan.id) }
        else { setAutomatic(fan.id) }
    }

    /// Whether every detected fan is held off automatic — what the tile's
    /// 「最大」 caption and the KPI chip's label both read, and what decides
    /// which way the fleet-wide toggle goes.
    var allAtMax: Bool {
        guard !fans.isEmpty else { return false }
        return fans.allSatisfy { !$0.mode.isAutomatic }
    }

    /// The fleet-wide counterpart of `toggleMode(of:)`: hold every fan at max,
    /// or hand the whole set back to the system.
    func setAllMax(_ max: Bool) {
        if max {
            for fan in fans { setManual(fan.id, rpm: fan.maxRPM) }
        } else {
            resetAllToAutomatic()
        }
    }

    func resetAllToAutomatic() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingSpeedTasks.values.forEach { $0.cancel() }
            self.pendingSpeedTasks.removeAll()
            self.submit { FanHelperInstaller.resetAll() }
        }
    }

    /// Hand every fan back to the SMC on the way out.
    ///
    /// A fan pinned at max writes `F%dTg` / `F%dMd` and the SMC keeps that
    /// target after the process is gone, so quitting with the rotors held left
    /// the machine louder and hotter until something else reset it — the app
    /// was the only thing that knew the fans had been taken. `resetAll()` is
    /// synchronous on the command queue and idempotent, and a quit with every
    /// fan already automatic costs one `fanctl autoall` that writes the values
    /// the SMC already holds.
    ///
    /// Run before the reader timer is stopped: `fans` is how the call knows
    /// whether anything needs handing back, and it is the same list the UI's
    /// 拉满/恢复自动 toggles wrote through.
    func adoptSystemControlOnQuit() {
        guard BuildChannel.allowsSystemIntegration else { return }
        guard fans.contains(where: { !$0.mode.isAutomatic }) else { return }
        pendingSpeedTasks.values.forEach { $0.cancel() }
        pendingSpeedTasks.removeAll()
        // Synchronous on the command queue: `applicationWillTerminate` is
        // racing process exit, so a queue hop would be cut off before it ran.
        // `resetAll()` carries the helper's own 10 s timeout.
        commandQueue.sync {
            _ = FanHelperInstaller.resetAll()
        }
    }

    private func submit(_ command: @escaping @Sendable () -> String?) {
        lastError = nil
        // Re-stat before deciding: `helperInstalled` is written in `start()`
        // and by nothing else, and `start()` only runs again from a fresh
        // `ResourceStrip.onAppear`. So the *second* rotor click after a
        // successful install — the user's way of confirming it worked — still
        // read a stale `false`, re-raised the permission alert, and dropped the
        // requested RPM without ever applying it.
        helperInstalled = FanHelperInstaller.isInstalled()
        guard helperInstalled else { postPermissionNeeded(); return }
        commandRevision &+= 1
        let revision = commandRevision
        commandQueue.async { [weak self] in
            let error = command()
            Task { @MainActor in
                guard let self, self.commandRevision == revision else { return }
                self.lastError = error
                self.refresh()
            }
        }
    }

    /// 首次调速时若辅助工具未安装，弹窗引导安装 / 打开系统设置。
    private func postPermissionNeeded() {
        NotificationCenter.default.post(name: .fanPermissionNeeded, object: nil)
        lastError = "需要安装特权辅助工具才能调整风扇。"
    }
}
