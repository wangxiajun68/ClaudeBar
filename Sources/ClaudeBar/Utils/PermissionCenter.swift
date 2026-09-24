import AppKit
import Combine
import CoreBluetooth
import CoreLocation
import IOBluetooth
import SwiftUI
import UserNotifications

extension Notification.Name {
    /// A permission switch in Settings flipped. `object` is the `AppPermission`.
    static let permissionDidChange = Notification.Name("com.claudebar.permissionDidChange")
    /// Navigate the main window to Settings.
    static let openSettingsPage = Notification.Name("com.claudebar.openSettingsPage")
}

/// Everything ClaudeBar can do that macOS gates behind a privacy prompt, plus
/// the one data source that reads another app's private store. Each is
/// **opt-in**: nothing here touches the gated API until its switch in
/// Settings → 权限与隐私 is on, so a fresh launch never prompts.
enum AppPermission: String, CaseIterable, Identifiable {
    case widgetData
    case notifications
    case screenRecording
    case automation
    case bluetooth
    case location
    case cursorData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .widgetData: return "桌面小组件"
        case .notifications: return "空闲通知"
        case .screenRecording: return "区域截图 ⌘⇧A"
        case .automation: return "在终端继续会话"
        case .bluetooth: return "蓝牙与耳机电量"
        case .location: return "Wi-Fi 名称"
        case .cursorData: return "读取 Cursor 会话"
        }
    }

    /// The macOS privacy category the switch leads to.
    var systemCategory: String {
        switch self {
        case .widgetData: return "其他 App 的数据"
        case .notifications: return "通知"
        case .screenRecording: return "屏幕录制"
        case .automation: return "自动化"
        case .bluetooth: return "蓝牙"
        case .location: return "定位服务"
        case .cursorData: return "无系统弹窗"
        }
    }

    var purpose: String {
        switch self {
        case .widgetData:
            return "把用量与会话快照写入小组件的共享容器。关闭时不写入，小组件保持上次内容。"
        case .notifications:
            return "会话由运行转为空闲时发送系统通知。"
        case .screenRecording:
            return "注册全局热键，拉框截图并复制到剪贴板。"
        case .automation:
            return "通过 AppleScript 在 Warp / 终端里执行 resume 命令；关闭时只打开终端并把命令复制到剪贴板。Otty 走本机通道，不需要此权限。"
        case .bluetooth:
            return "连接卡片显示蓝牙开关，读取 AirPods 等耳机电量。"
        case .location:
            return "macOS 把 Wi-Fi 名称视为位置信息；只读名称与信号，不定位。"
        case .cursorData:
            return "只读打开 Cursor 的 state.vscdb，列出进行中的 Cursor 会话。"
        }
    }

    var symbol: String {
        switch self {
        case .widgetData: return "square.grid.2x2"
        case .notifications: return "bell"
        case .screenRecording: return "camera.viewfinder"
        case .automation: return "terminal"
        case .bluetooth: return "headphones"
        case .location: return "wifi"
        case .cursorData: return "cursorarrow.rays"
        }
    }

    /// Two switches predate this center and keep their original keys so the
    /// user's stored choice survives.
    var defaultsKey: String {
        switch self {
        case .notifications: return "idleNotifyEnabled"
        case .screenRecording: return "screenshotHotkeyEnabled"
        default: return "permission." + rawValue
        }
    }

    /// Only the prompt-free data source defaults on.
    var defaultEnabled: Bool { self == .cursorData }

    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .widgetData: anchor = "com.apple.preference.security?Privacy"
        case .notifications: anchor = "com.apple.preference.notifications"
        case .screenRecording: anchor = "com.apple.preference.security?Privacy_ScreenCapture"
        case .automation: anchor = "com.apple.preference.security?Privacy_Automation"
        case .bluetooth: anchor = "com.apple.preference.security?Privacy_Bluetooth"
        case .location: anchor = "com.apple.preference.security?Privacy_LocationServices"
        case .cursorData: return nil
        }
        return URL(string: "x-apple.systempreferences:" + anchor)
    }
}

/// Thread-safe switch reads for background pollers (the sampler queue, the
/// audio engine, detached scans). Reads `UserDefaults` directly so no caller
/// has to hop to the main actor.
enum PermissionGate {
    static func allows(_ permission: AppPermission) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: permission.defaultsKey) != nil else { return permission.defaultEnabled }
        return defaults.bool(forKey: permission.defaultsKey)
    }
}

/// What macOS currently says about a permission.
enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
    /// macOS exposes no query; it asks at the moment of use.
    case askOnUse
    /// No system authorization involved.
    case notRequired

    var label: String {
        switch self {
        case .granted: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未授权"
        case .askOnUse: return "使用时询问"
        case .notRequired: return "无需授权"
        }
    }

    var tint: Color {
        switch self {
        case .granted: return Theme.statusSuccess
        case .denied: return Theme.statusError
        case .notDetermined: return Theme.statusWarning
        case .askOnUse, .notRequired: return Theme.statusIdle
        }
    }

    var ink: Color {
        switch self {
        case .granted: return Theme.Ink.success
        case .denied: return Theme.Ink.error
        case .notDetermined: return Theme.Ink.warning
        case .askOnUse, .notRequired: return Theme.Ink.idle
        }
    }
}

/// Main-actor owner of the switches and the system-side status shown next to
/// them. Status is refreshed on app activation and shortly after a request —
/// never on a timer, so the Settings page costs nothing while it sits open.
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    @Published private(set) var enabled: [AppPermission: Bool] = [:]
    @Published private(set) var statuses: [AppPermission: PermissionStatus] = [:]

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        for permission in AppPermission.allCases {
            enabled[permission] = PermissionGate.allows(permission)
        }
        let prefs = AppPreferences.shared
        prefs.$idleNotifyEnabled.dropFirst().removeDuplicates()
            .sink { [weak self] on in MainActor.assumeIsolated { self?.enabled[.notifications] = on } }
            .store(in: &cancellables)
        prefs.$screenshotHotkeyEnabled.dropFirst().removeDuplicates()
            .sink { [weak self] on in MainActor.assumeIsolated { self?.enabled[.screenRecording] = on } }
            .store(in: &cancellables)
        WiFiNameAuthorization.shared.$status.dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatus() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatus() }
            }
            .store(in: &cancellables)
        refreshStatus()
    }

    func isEnabled(_ permission: AppPermission) -> Bool {
        enabled[permission] ?? permission.defaultEnabled
    }

    func systemStatus(_ permission: AppPermission) -> PermissionStatus {
        statuses[permission] ?? .askOnUse
    }

    var enabledCount: Int { AppPermission.allCases.filter { isEnabled($0) }.count }

    /// Flip a switch. Turning one on asks macOS right away, while the user is
    /// looking at the reason — not later, from some background poll.
    func setEnabled(_ permission: AppPermission, _ on: Bool) {
        guard isEnabled(permission) != on else { return }
        switch permission {
        case .notifications:
            AppPreferences.shared.idleNotifyEnabled = on
        case .screenRecording:
            AppPreferences.shared.screenshotHotkeyEnabled = on
        default:
            UserDefaults.standard.set(on, forKey: permission.defaultsKey)
        }
        enabled[permission] = on
        if on { request(permission) }
        NotificationCenter.default.post(name: .permissionDidChange, object: permission)
        scheduleStatusRefresh()
    }

    func openSystemSettings(for permission: AppPermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Request

    private func request(_ permission: AppPermission) {
        switch permission {
        case .notifications:
            // `idleNotifyEnabled.didSet` already asks.
            break
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        case .bluetooth:
            // Any controller read is what raises the prompt; do it off-main
            // like the sampler would.
            DispatchQueue.global(qos: .userInitiated).async {
                _ = IOBluetoothHostController.default()?.powerState
            }
        case .location:
            WiFiNameAuthorization.shared.request()
        case .widgetData, .automation, .cursorData:
            // Widget: the next snapshot write asks (posted via
            // `.permissionDidChange`). Automation: macOS asks per target app
            // on first use. Cursor: no system prompt.
            break
        }
    }

    // MARK: - Status

    func refreshStatus() {
        var next = statuses
        next[.widgetData] = .askOnUse
        next[.automation] = .askOnUse
        next[.cursorData] = .notRequired
        next[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        next[.bluetooth] = {
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .askOnUse
            }
        }()
        next[.location] = {
            switch WiFiNameAuthorization.shared.status {
            case .authorizedAlways, .authorizedWhenInUse: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .askOnUse
            }
        }()
        if next != statuses { statuses = next }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let mapped: PermissionStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional: mapped = .granted
            case .denied: mapped = .denied
            case .notDetermined: mapped = .notDetermined
            @unknown default: mapped = .askOnUse
            }
            Task { @MainActor [weak self] in
                guard let self, self.statuses[.notifications] != mapped else { return }
                self.statuses[.notifications] = mapped
            }
        }
    }

    /// System prompts resolve asynchronously and do not always re-activate
    /// the app; re-read a few times after a request.
    private func scheduleStatusRefresh() {
        for delay in [1.0, 3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.refreshStatus() }
            }
        }
    }
}
