import SwiftUI

/// Telemetry-driven power distribution. Only sensor updates redraw the paths;
/// there is no animation timer, subprocess, or per-frame sampling.
struct PowerFlowCard: View {
    private let sampler = ProcessSampler.shared

    var body: some View {
        let host = sampler.host
        if host.batteryInstalled {
            let supplementing = host.batteryExternalPower && (host.powerBatteryWatts ?? 0) < 0
            let charging = host.batteryExternalPower && !supplementing
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    GlyphWell(name: "power", tint: Theme.Ink.warning, size: 26)
                    Text("电力流向").font(Theme.Font.chromeEmph)
                    Spacer()
                    Text(host.powerIsEstimated ? "电池功率为估算" : "实时功率")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
                HStack(spacing: 6) {
                    VStack(spacing: 8) {
                        endpoint(host.batteryExternalPower ? "电源输入" : "电池供电",
                                 symbol: host.batteryExternalPower ? "powerplug.fill" : "battery.100",
                                 watts: host.batteryExternalPower ? host.powerInputWatts : host.powerBatteryWatts.map { abs($0) },
                                 tint: Theme.Ink.warning)
                        if supplementing {
                            endpoint("电池补充", symbol: "battery.100",
                                     watts: host.powerBatteryWatts.map { abs($0) }, tint: Theme.Ink.cursor)
                        }
                    }.frame(width: 108)
                    PowerFlowBands(split: charging, merging: supplementing,
                                   battery: host.powerBatteryWatts, system: host.powerSystemWatts)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        if charging {
                            endpoint("电池充电", symbol: "battery.100.bolt",
                                     watts: host.powerBatteryWatts, tint: Theme.Ink.success)
                        }
                        endpoint("整机消耗", symbol: "laptopcomputer",
                                 watts: host.powerSystemWatts, tint: Theme.Ink.claude)
                    }.frame(width: 120)
                }
                .frame(height: 150)
                Text(footnote(host))
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            .padding(16)
            .panelCard()
        }
    }

    private func endpoint(_ label: String, symbol: String, watts: Double?, tint: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundColor(tint)
            Text(watts.map { String(format: "%.2f W", $0) } ?? "暂无读数")
                .font(Theme.Font.tileValueSmall).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cardFill(0.035), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func footnote(_ host: ProcessSampler.HostStats) -> String {
        if host.powerSystemWatts == nil || (host.batteryExternalPower && host.powerInputWatts == nil) {
            return "部分遥测不可用，流带仅示意方向；未用充电器额定功率替代实测值。"
        }
        return host.powerIsEstimated
            ? "输入与整机功率来自系统遥测；电池功率由电流 × 电压估算。"
            : "输入、电池与整机功率来自同一组系统遥测；流带示意供电方向。"
    }
}

private struct PowerFlowBands: View {
    let split: Bool
    let merging: Bool
    let battery: Double?
    let system: Double?

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 8
            let middle = size.height / 2
            func band(_ startTop: CGFloat, _ startBottom: CGFloat,
                      _ endTop: CGFloat, _ endBottom: CGFloat, _ tint: Color) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: startTop))
                path.addCurve(to: CGPoint(x: size.width, y: endTop),
                              control1: CGPoint(x: size.width * 0.4, y: startTop),
                              control2: CGPoint(x: size.width * 0.6, y: endTop))
                path.addLine(to: CGPoint(x: size.width, y: endBottom))
                path.addCurve(to: CGPoint(x: 0, y: startBottom),
                              control1: CGPoint(x: size.width * 0.6, y: endBottom),
                              control2: CGPoint(x: size.width * 0.4, y: startBottom))
                path.closeSubpath()
                context.fill(path, with: .linearGradient(
                    Gradient(colors: [Theme.chartAmber.opacity(0.55), tint.opacity(0.18)]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            }
            if split {
                let fraction = CGFloat(max(0.08, min(0.8, (battery ?? 0) / max(1, (battery ?? 0) + (system ?? 0)))))
                let splitY = size.height * fraction
                band(0, splitY - gap / 2, 0, middle - gap / 2, Theme.chartGreen)
                band(splitY + gap / 2, size.height, middle + gap / 2, size.height, Theme.chartBlue)
            } else if merging {
                band(0, middle - gap / 2, 0, middle - gap / 2, Theme.chartBlue)
                band(middle + gap / 2, size.height, middle + gap / 2, size.height, Theme.chartPurple)
            } else {
                band(0, size.height, 0, size.height, Theme.chartBlue)
            }
        }
    }
}
