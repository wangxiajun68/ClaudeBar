import Foundation
import Observation

@MainActor
@Observable
final class FanMonitor {
    static let shared = FanMonitor()

    var fans: [FanInfo] = []
    var smcAvailable = false
    var lastError: String?
    var helperInstalled = FanHelperInstaller.isInstalled()

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
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
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
                if self.smcAvailable != available { self.smcAvailable = available }
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
        // Defer observable mutations until the slider's update has completed.
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

    func resetAllToAutomatic() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingSpeedTasks.values.forEach { $0.cancel() }
            self.pendingSpeedTasks.removeAll()
            self.submit { FanHelperInstaller.resetAll() }
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
