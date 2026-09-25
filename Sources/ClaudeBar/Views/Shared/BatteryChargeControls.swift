import SwiftUI

/// Controls share one app-lifetime controller across the dashboard and popovers.
struct BatteryChargeControls: View {
    @Bindable private var controller = BatteryChargeController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("充电控制").font(Theme.Font.chromeEmph)
                Spacer(minLength: 8)
                if controller.pending { ProgressView().controlSize(.small) }
                Text(controller.supported == false ? "不可用" : controller.statusText)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                RollingNumberText("\(Int(controller.threshold))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }
            if controller.supported == false {
                Text("当前机型或系统暂不支持充电控制。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(BatteryChargeController.Mode.allCases) { mode in
                        modeButton(mode)
                    }
                }
                limitSlider
            }
            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Ink.warning)
                    .lineLimit(2)
            }
        }
        .onAppear { controller.probe() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.mode)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.pending)
    }

    /// The charge limit as a continuous control.
    ///
    /// Drags apply on release, but only once charge management is running: the
    /// helper is what owns a limit, and starting it is the explicit "启动管理"
    /// action. With management off a drag just remembers the preference, and
    /// the caption says so — silently launching a privileged process from a
    /// slider would be a surprise.
    ///
    /// The range is 20–100, not 0–100: `policy.h` rejects a limit below 20, so
    /// a slider that could reach it would offer states the helper refuses.
    @ViewBuilder private var limitSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("\(Int(BatteryChargeController.minLimit))%")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.textTertiary())
                Slider(value: $controller.threshold,
                       in: BatteryChargeController.minLimit...100,
                       step: 1) { editing in
                    // `false` is the release. Apply only then, so a drag does
                    // not queue a dozen commands behind the helper's revision
                    // check.
                    if !editing { controller.setLimit(Int(controller.threshold)) }
                }
                .tint(Theme.chartBlue)
                .controlSize(.small)
                Text("100%")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.textTertiary())
            }
            HStack(spacing: 6) {
                Image(systemName: controller.managesLimit ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(controller.managesLimit ? Theme.chartBlue : Theme.textTertiary())
                Text(limitCaption)
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.textTertiary())
                    .lineLimit(1)
            }
        }
    }

    private var limitCaption: String {
        if controller.managesLimit {
            return "松手即生效 · 当前上限 \(controller.appliedLimit)%"
        }
        if controller.mode == .system && controller.processIsRunning == false {
            return "尚未启动充电管理 · 此为保存值，点「启动管理」后才生效"
        }
        return "点「启动管理」后，拖动即生效"
    }

    private func modeButton(_ mode: BatteryChargeController.Mode) -> some View {
        let selected = controller.mode == mode
        let blocked = mode == .discharge && !controller.dischargeSupported
        return Button { controller.apply(mode) } label: {
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.chartBlue.opacity(0.14) : Theme.bgOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.chartBlue.opacity(0.55) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(blocked || controller.pending || controller.supported == nil)
        .opacity(blocked ? 0.4 : 1)
        .help(mode == .discharge
              ? "连接电源时使用电池，降到上限后自动停止；合盖会结束放电。"
              : mode.title + "。首次启用需管理员授权；退出后由系统管理，下次启动会恢复这次的模式。")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
