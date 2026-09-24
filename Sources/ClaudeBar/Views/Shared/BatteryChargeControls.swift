import SwiftUI

/// Controls share one app-lifetime controller across the dashboard and popovers.
struct BatteryChargeControls: View {
    @Bindable private var controller = BatteryChargeController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let presets = [60, 80, 100]
    private var limitDirty: Bool {
        controller.mode != .system && Int(controller.threshold) != controller.appliedLimit
    }

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
                Text("\(Int(controller.threshold))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }
            if controller.supported == false {
                Text("当前机型或系统暂不支持充电控制。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            } else {
                HStack(spacing: 8) {
                    modeButton(.limit, detail: "充到上限")
                    modeButton(.hold, detail: "暂停")
                    modeButton(.discharge, detail: "放电")
                    modeButton(.system, detail: "系统")
                }
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { presetChip($0) }
                    if limitDirty {
                        Button { controller.apply(controller.mode) } label: {
                            Text("应用")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(Theme.chartBlue, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
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

    private func modeButton(_ mode: BatteryChargeController.Mode, detail: String) -> some View {
        let selected = controller.mode == mode
        let blocked = mode == .discharge && !controller.dischargeSupported
        return Button { controller.apply(mode) } label: {
            VStack(spacing: 4) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
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
              : mode.title + "。首次启用需管理员授权；退出应用后恢复系统管理。")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func presetChip(_ value: Int) -> some View {
        let selected = Int(controller.threshold) == value
        return Button { controller.threshold = Double(value) } label: {
            Text("\(value)%")
                .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(selected ? Theme.chartBlue : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Theme.chartBlue.opacity(0.14) : Theme.bgOverlay)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Theme.chartBlue.opacity(0.45) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

}

struct CompactBatteryChargeControl: View {
    @State private var presented = false
    private var controller = BatteryChargeController.shared
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("充电控制")
                Spacer()
                Text(controller.mode == .system ? "系统管理" : "上限 \(controller.appliedLimit)%")
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $presented) {
            BatteryChargeControls().padding(16).frame(width: 420).background(Theme.cardSurface)
        }
    }
}
