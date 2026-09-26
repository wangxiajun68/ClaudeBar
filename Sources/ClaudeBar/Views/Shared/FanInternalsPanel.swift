import SwiftUI

/// Detailed illustrated hardware overview with independently animated turbines.
/// Component placement is illustrative, never a host-specific board map.
struct FanInternalsPanel: View {
    private let fanMonitor = FanMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("散热系统").font(.system(size: 22, weight: .semibold))
                    Text("机内一览 · 实时风扇状态")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Label("\(fanMonitor.fans.count) 个风扇", systemImage: "fanblades")
                    .rollingNumber()
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            internalsIllustration
            if fanMonitor.fans.isEmpty {
                Label("未检测到风扇，或辅助工具尚未安装。", systemImage: "fan.slash")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(fanMonitor.fans.enumerated()), id: \.element.id) { index, fan in
                        fanControl(fan, index: index)
                    }
                }
            }
            if let error = fanMonitor.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption).foregroundColor(Theme.Ink.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("概念结构插画 · 实际布局因机型而异")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.cardSurface)
    }

    private var internalsIllustration: some View {
        GeometryReader { proxy in
            if let image = FanArtwork.image {
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    illustratedFan(at: 0, width: proxy.size.width)
                        .position(x: proxy.size.width * 300 / 1536, y: proxy.size.height * 315 / 1024)
                    illustratedFan(at: 1, width: proxy.size.width)
                        .position(x: proxy.size.width * 1237 / 1536, y: proxy.size.height * 315 / 1024)
                }
            } else {
                Image(systemName: "laptopcomputer")
                    .resizable().scaledToFit().foregroundStyle(.secondary).padding(30)
            }
        }
        .aspectRatio(1.5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("笔记本内部结构插画：双风扇、散热管、主板电路与电池；实际布局因机型而异")
    }

    @ViewBuilder private func illustratedFan(at index: Int, width: CGFloat) -> some View {
        let fan = fanMonitor.fans.indices.contains(index) ? fanMonitor.fans[index] : nil
        LucideRotor(rpm: fan?.rpm ?? 0, maxRPM: fan?.maxRPM ?? 1,
                    tint: Theme.textSecondary, forced: false,
                    size: width * 216 / 1536, showsHousing: false,
                    artwork: index == 0 ? FanArtwork.leftRotor : FanArtwork.rightRotor)
    }

    private func fanControl(_ fan: FanInfo, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LucideRotor(rpm: fan.rpm, maxRPM: fan.maxRPM,
                            tint: fan.mode.isAutomatic ? Theme.textSecondary : Theme.chartAmber,
                            forced: !fan.mode.isAutomatic, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name(fan, index: index)).font(.system(size: 11, weight: .semibold))
                    Text(fan.mode.isAutomatic ? "系统自动" : "手动控制")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(fan.rpm)")
                    .rollingNumber()
                    .font(.system(size: 25, weight: .medium, design: .rounded))
                Text("RPM").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            Text("上限 \(fan.maxRPM.formatted()) rpm")
                .rollingNumber()
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Button {
                if fan.mode.isAutomatic { fanMonitor.setMaxSpeed(fan.id) }
                else { fanMonitor.setAutomatic(fan.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: fan.mode.isAutomatic ? "wind" : "arrow.uturn.backward")
                    Text(fan.mode.isAutomatic ? "切换最大转速" : "恢复系统自动")
                }
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("\(name(fan, index: index))：\(fan.mode.isAutomatic ? "切换最大转速" : "恢复系统自动")")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func name(_ fan: FanInfo, index: Int) -> String {
        if fan.name.localizedCaseInsensitiveContains("left") || fan.name.contains("左") { return "左侧风扇" }
        if fan.name.localizedCaseInsensitiveContains("right") || fan.name.contains("右") { return "右侧风扇" }
        return fanMonitor.fans.count == 1 ? "风扇" : "风扇 \(index + 1)"
    }
}
