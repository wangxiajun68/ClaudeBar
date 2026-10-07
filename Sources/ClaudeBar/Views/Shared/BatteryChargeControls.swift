import SwiftUI

/// Controls share one app-lifetime controller across the dashboard and popovers.
struct BatteryChargeControls: View {
    @Bindable private var controller = BatteryChargeController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("电池管理").font(Theme.Font.chromeEmph)
                Spacer()
                if controller.pending || controller.probing || controller.authorizingHelper {
                    ProgressView().controlSize(.small)
                }
                Text("目标 \(Int(controller.threshold))%")
                    .font(Theme.Font.bodySmall).monospacedDigit()
            }
            Text(controller.probing ? "正在检测电池控制能力…" : controller.statusText)
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if controller.supported == false || controller.probeError != nil {
                Text(controller.probeError ?? "当前机型不支持电池控制。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Button("重新检测") { controller.probe(retry: true) }
                    .disabled(controller.probing)
            }
            HStack(spacing: 8) {
                ForEach(BatteryChargeController.Mode.displayOrder) { mode in modeButton(mode) }
            }
            limitSlider
            if !controller.notice.isEmpty {
                Text(controller.notice).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            } else if controller.supported == true && !controller.dischargeSupported {
                Text("此机型仅支持限充，无法主动降到目标电量。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            if !controller.measuredText.isEmpty {
                Text(controller.measuredText).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Ink.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { controller.probe() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.mode)
    }

    private var limitSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("20%")
                // Binding handles pointer, keyboard and accessibility changes alike.
                Slider(value: Binding(get: { controller.threshold }, set: { controller.setLimit(Int($0)) }),
                       in: BatteryChargeController.minLimit...100, step: 1)
                    .tint(Theme.chartBlue).controlSize(.small)
                    .accessibilityLabel("管理目标电量")
                    .accessibilityValue("\(Int(controller.threshold))%")
                Text("100%")
            }
            .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary())
            Label(limitCaption, systemImage: controller.limitConfirmed ? "checkmark.circle.fill" : "info.circle")
                .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var limitCaption: String {
        if controller.isRestoring { return "正在还原系统 · 目标仅保存，不会重新启动管理" }
        if controller.pending { return "目标待确认 · 上次生效 \(controller.appliedLimit)%" }
        if controller.managesLimit {
            return controller.limitConfirmed ? "已生效 \(controller.appliedLimit)% · 更改目标自动应用"
                : "目标尚未生效 · 当前上限 \(controller.appliedLimit)%"
        }
        return "目标仅保存 · 点击模式启用管理"
    }

    private func modeButton(_ mode: BatteryChargeController.Mode) -> some View {
        let selected = !controller.pending && !controller.recoveryUnconfirmed && controller.mode == mode
            && (mode != .system || (!controller.processIsRunning && controller.savedMode == .system))
        let blocked = mode == .discharge && !controller.dischargeSupported
        return Button { controller.apply(mode) } label: {
            // One rounded plate, one shape: fill and border share a single
            // `RoundedRectangle` and the radius is the Theme token, not a
            // second hard-coded 12 (finding 543). The face is split out as an
            // Equatable view so a ~2 s controller publish that changes neither
            // `selected` nor `blocked` does not rebuild it.
            ModeButtonFace(mode: mode, selected: selected)
                .equatable()
        }
        .buttonStyle(.plain)
        .disabled(!controller.canApply(mode))
        .opacity(blocked ? 0.4 : 1)
        .help(blocked ? "此机型未检测到主动放电能力，只能限制充电。" : mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

}

/// The mode button's face — glyph, label and the selected plate — comparing
/// only what it draws, so the controller's 2 s status publishes skip it.
private struct ModeButtonFace: View, Equatable {
    let mode: BatteryChargeController.Mode
    let selected: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mode == rhs.mode && lhs.selected == rhs.selected
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: mode.symbol)
                .font(.system(size: 14, weight: .semibold))
            Text(mode.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(selected ? Theme.chartBlue : Theme.textSecondary)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(selected ? Theme.chartBlue.opacity(0.14) : Theme.bgOverlay)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(selected ? Theme.chartBlue.opacity(0.55) : Color.clear, lineWidth: 1)
        )
    }
}

struct CompactBatteryChargeControl: View {
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            IconChip(systemImage: "slider.horizontal.3", tint: Theme.textSecondary)
        }
        .buttonStyle(.pressable)
        .help("充电控制")
        .accessibilityLabel("充电控制")
        .popover(isPresented: $presented) {
            BatteryChargeControls().padding(16).frame(width: 420).background(Theme.cardSurface)
        }
    }
}
