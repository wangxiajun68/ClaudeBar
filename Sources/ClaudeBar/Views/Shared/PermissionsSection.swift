import SwiftUI

/// Privacy controls stay explicit and opt-in, grouped by what they enable.
struct PermissionsSection: View {
    @ObservedObject private var center = PermissionCenter.shared
    @ObservedObject private var screenshotHotKey = ScreenshotHotKey.shared
    @Bindable private var batteryController = BatteryChargeController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("仅在开启后访问对应数据或请求系统授权。关闭开关即可停止使用该功能。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            permissionGroup("会话与通知", permissions: [.cursorData, .notifications, .automation])
            permissionGroup("系统功能", permissions: [.widgetData, .screenRecording, .bluetooth])
            permissionGroup("位置", permissions: [.currentLocation, .location])

            SettingsGroup(title: "电池充电控制") {
                SettingsRow(title: "辅助工具", caption: batteryController.lastError ?? "需要一次管理员授权，充电模式在概览的电池面板中调整。") {
                    if batteryController.helperInstalled {
                        Label("已授权", systemImage: "checkmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ActionButton(batteryController.authorizingHelper ? "授权中…" : "授权", tone: .neutral) {
                            batteryController.authorizeHelper()
                        }
                        .disabled(batteryController.authorizingHelper || batteryController.pending || batteryController.processIsRunning)
                    }
                }
            }
        }
        .task { await batteryController.refreshHelperAuthorization() }
    }

    private func permissionGroup(_ title: String, permissions: [AppPermission]) -> some View {
        SettingsGroup(title: title) {
            ForEach(permissions) { permission in
                if permission != permissions.first { SettingsDivider() }
                PermissionSettingsRow(permission: permission,
                                      isOn: center.isEnabled(permission),
                                      status: center.systemStatus(permission),
                                      note: note(for: permission)) { on in
                    center.setEnabled(permission, on)
                } openSettings: {
                    center.openSystemSettings(for: permission)
                }
            }
        }
    }

    private func note(for permission: AppPermission) -> String? {
        if center.isEnabled(permission), center.systemStatus(permission) == .denied {
            return "请在系统设置的「\(permission.systemCategory)」中允许 ClaudeBar。"
        }
        if permission == .screenRecording, center.isEnabled(permission), let error = screenshotHotKey.lastError {
            return error + "。请关闭占用该快捷键的软件后重试。"
        }
        return nil
    }
}

private struct PermissionSettingsRow: View {
    let permission: AppPermission
    let isOn: Bool
    let status: PermissionStatus
    let note: String?
    let onToggle: (Bool) -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: permission.title, caption: purpose) {
                HStack(spacing: 12) {
                    if status == .denied || (isOn && status != .notRequired) {
                        Text(status.label)
                            .font(.system(size: 11))
                            .foregroundStyle(status == .denied ? Theme.Ink.error : Theme.textSecondary)
                    }
                    if permission.settingsURL != nil, status == .granted || status == .denied {
                        Button(action: openSettings) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 13))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("打开\(permission.systemCategory)系统设置")
                        .help("打开系统设置 · \(permission.systemCategory)")
                    }
                    Toggle(permission.title, isOn: Binding(get: { isOn }, set: onToggle))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.claude)
                        .accessibilityLabel(permission.title)
                        .accessibilityValue(isOn ? "已开启，\(status.label)" : "已关闭")
                }
            }
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 15)
            }
        }
    }

    private var purpose: String {
        switch permission {
        case .cursorData: return "只读访问 Cursor 本机数据，显示会话与用量。"
        case .notifications: return "会话完成后发送 macOS 通知。"
        case .automation: return "在 Warp 或终端中自动执行继续命令；Otty 无需此权限。"
        case .widgetData: return "将用量与会话同步到桌面小组件。"
        case .screenRecording: return "使用 ⌘⇧A 框选截图并复制到剪贴板。"
        case .bluetooth: return "显示蓝牙状态与耳机电量。"
        case .currentLocation: return "按当前位置获取天气，关闭后使用手动城市。"
        case .location: return "显示 Wi-Fi 名称与信号，不读取坐标。"
        }
    }
}
