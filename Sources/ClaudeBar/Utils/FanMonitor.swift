import Foundation
import Combine

@MainActor
final class FanMonitor: ObservableObject {
    static let shared = FanMonitor()

    @Published private(set) var fans: [FanInfo] = []
    @Published private(set) var smcAvailable = false
    @Published private(set) var lastError: String?
    @Published private(set) var helperInstalled = FanHelperInstaller.isInstalled()

    private var timer: Timer?
    private var subscribers = 0
    private var pendingSpeedTasks: [Int: DispatchWorkItem] = [:]
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
        smcAvailable = SMCController.shared.isConnected
        guard smcAvailable else {
            fans = []
            return
        }
        fans = SMCController.shared.loadFans()
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
            self.lastError = nil
            guard self.helperInstalled else { self.postPermissionNeeded(); return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let err = FanHelperInstaller.setAutomatic(fanID: fanID)
                Task { @MainActor in
                    self?.lastError = err
                    self?.refresh()
                }
            }
        }
    }

    func setManual(_ fanID: Int, rpm: Int) {
        pendingSpeedTasks[fanID]?.cancel()
        // Slider 回调处于 SwiftUI 视图更新中；同步改 @Published 会触发 Combine 断言崩溃，
        // 必须跳出一帧再碰任何 @Published 状态。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastError = nil
            guard self.helperInstalled else { self.postPermissionNeeded(); return }
            let task = DispatchWorkItem { [weak self] in
                let err = FanHelperInstaller.setFanSpeed(fanID: fanID, rpm: rpm)
                Task { @MainActor in
                    self?.lastError = err
                    self?.refresh()
                }
            }
            self.pendingSpeedTasks[fanID] = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: task)
        }
    }

    func setMinSpeed(_ fanID: Int) {
        guard let fan = fans.first(where: { $0.id == fanID }) else { return }
        setManual(fanID, rpm: fan.minRPM)
    }

    func setMaxSpeed(_ fanID: Int) {
        guard let fan = fans.first(where: { $0.id == fanID }) else { return }
        setManual(fanID, rpm: fan.maxRPM)
    }

    func resetAllToAutomatic() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastError = nil
            guard self.helperInstalled else { self.postPermissionNeeded(); return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let err = FanHelperInstaller.resetAll()
                Task { @MainActor in
                    self?.lastError = err
                    self?.refresh()
                }
            }
        }
    }

    /// 首次调速时若辅助工具未安装，弹窗引导安装 / 打开系统设置。
    private func postPermissionNeeded() {
        NotificationCenter.default.post(name: .fanPermissionNeeded, object: nil)
        lastError = "需要安装特权辅助工具才能调整风扇。"
    }
}
