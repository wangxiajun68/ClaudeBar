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
    /// 拖动滑杆期间暂停轮询，避免实时转速把滑杆位置“拽回去”。
    private(set) var isUserAdjusting = false

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

    func refresh() {
        if isUserAdjusting { return } // 拖动时不刷新，松手后恢复
        let available = SMCController.shared.isConnected
        if smcAvailable != available { smcAvailable = available }
        guard available else {
            // 无 SMC：仅在状态真的变化时发布，避免每 2s 让资源区重渲一次。
            if !fans.isEmpty { fans = [] }
            return
        }
        let next = SMCController.shared.loadFans()
        // 转速是无条件发布的定时器结果，绝大多数 tick 数值不变 —— 加
        // Equatable 守卫，与 ProviderStore 的既有模式一致。
        if next != fans { fans = next }
    }

    /// 拖动开始/结束（由滑杆的 onEditingChanged 调用）。
    func setUserAdjusting(_ adjusting: Bool) {
        isUserAdjusting = adjusting
        if !adjusting {
            // 松手后稍等转速跟上再恢复轮询。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.isUserAdjusting else { return }
                self.refresh()
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
