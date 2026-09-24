import SwiftUI

/// Settings → 权限与隐私: every privacy-gated capability on one card, each
/// behind its own switch, with what macOS currently says beside it.
struct PermissionsSection: View {
    @ObservedObject private var center = PermissionCenter.shared
    @ObservedObject private var screenshotHotKey = ScreenshotHotKey.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s10) {
            SectionHeader(icon: "hand.raised", title: "权限与隐私", tint: Theme.claude)
            Text("已开启 \(center.enabledCount) / \(AppPermission.allCases.count) 项 · 打开开关才会向系统请求，关闭后不再调用对应接口。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(AppPermission.allCases) { permission in
                    PermissionCard(permission: permission,
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
    }

    /// Live, per-row context the static purpose text cannot carry.
    private func note(for permission: AppPermission) -> String? {
        let status = center.systemStatus(permission)
        if center.isEnabled(permission), status == .denied {
            return "系统中已拒绝，需在「系统设置 › \(permission.systemCategory)」中允许 ClaudeBar。"
        }
        switch permission {
        case .screenRecording:
            guard center.isEnabled(permission) else { return nil }
            if let error = screenshotHotKey.lastError { return error + "。关闭占用该键的截图软件后重新打开。" }
            return screenshotHotKey.isRegistered ? "热键已注册。" : nil
        case .widgetData:
            return center.isEnabled(permission) ? "每次启动写入时，未签名构建可能仍会被系统询问一次。" : nil
        default:
            return nil
        }
    }
}

private struct PermissionCard: View {
    let permission: AppPermission
    let isOn: Bool
    let status: PermissionStatus
    let note: String?
    let onToggle: (Bool) -> Void
    let openSettings: () -> Void

    @State private var hovered = false

    /// A pill only where it says something: an enabled switch, or a system
    /// decision the user may want to revisit.
    private var showsStatus: Bool {
        isOn || status == .granted || status == .denied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                GlyphWell(name: permission.symbol, tint: isOn ? Theme.claude : Theme.textSecondary,
                          size: 28, engaged: hovered)
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { isOn }, set: onToggle))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(Theme.claude)
            }
            Text(permission.title)
                .font(Theme.Font.chromeEmph)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(permission.purpose)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note {
                Text(note)
                    .font(Theme.Font.caption)
                    .foregroundStyle(status == .denied ? Theme.Ink.error : Theme.Ink.claude)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(permission.systemCategory)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.textTertiary())
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsStatus {
                    StatusPill(label: status.label, tint: status.tint, ink: status.ink)
                }
                if permission.settingsURL != nil, status == .granted || status == .denied {
                    Button(action: openSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .help("打开「系统设置 › \(permission.systemCategory)」")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isOn ? Theme.claude.opacity(hovered ? 0.45 : 0.22) : Theme.hairline, lineWidth: 1)
        )
        .onHover { hovered = $0 }
        .animation(Theme.Motion.state, value: hovered)
        .animation(Theme.Motion.state, value: status)
        .animation(Theme.Motion.state, value: isOn)
    }
}
