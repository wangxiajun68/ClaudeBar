import SwiftUI

/// One telemetry-driven Sankey diagram shared by the dashboard and menu popup.
struct PowerFlowCard: View {
    var compact = false
    private let sampler = ProcessSampler.shared

    var body: some View {
        let host = sampler.host
        if host.batteryInstalled {
            VStack(alignment: .leading, spacing: compact ? 7 : 14) {
                HStack {
                    Image(systemName: "bolt.fill").foregroundColor(Theme.Ink.warning)
                    Text("能源流向").font(Theme.Font.chromeEmph)
                    Spacer()
                    Text(host.powerIsEstimated ? "电池侧估算" : "实时功率")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
                EnergySankey(host: host, compact: compact)
                    .frame(height: compact ? 94 : 180)
                if !compact {
                    Text("电源输入 → 整机消耗 / 电池充电 · 电池放电时汇入整机。微小功率以细线表示。")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
            }
            .padding(compact ? 10 : 18)
            .panelCard()
        }
    }
}

private struct EnergySankey: View {
    let host: ProcessSampler.HostStats
    let compact: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appActive = NSApplication.shared.isActive
    @State private var visible = false
    @State private var windowVisible = UIWakePolicy.hasVisibleWindow

    private var flowing: Bool { visible && windowVisible && appActive && !reduceMotion }
    private var batteryBranch: Bool { battery.map { $0 >= 0.005 } ?? false }

    private var splitting: Bool {
        host.batteryExternalPower && batteryBranch && (host.powerBatteryWatts.map { $0 > 0 } ?? host.batteryCharging)
    }
    private var battery: Double? { host.powerBatteryWatts.map { abs($0) } }
    private var supply: Double? { host.batteryExternalPower ? host.powerInputWatts : battery }
    private var fraction: CGFloat {
        let amount = battery ?? 0
        let total = splitting ? amount + (host.powerSystemWatts ?? 0) : amount + (supply ?? 0)
        guard total > 0 else { return 0 }
        return CGFloat(min(0.85, max(0, amount / total)))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let node: CGFloat = compact ? 44 : 76
            let gap: CGFloat = compact ? 5 : 8
            let start = node + gap
            let end = size.width - node - gap
            let width = max(1, end - start)
            let height = size.height
            // Labels need a readable destination even when the actual branch is tiny.
            let splitHeight = height * min(0.42, max(0.28, fraction))
            let mainHeight = host.batteryExternalPower && batteryBranch && !splitting ? height * 0.76 : height
            let batteryY = height * 0.92

            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !flowing)) { timeline in
                    Canvas { context, _ in
                        let time = flowing ? timeline.date.timeIntervalSinceReferenceDate : 0
                        func ribbon(_ leftTop: CGFloat, _ leftBottom: CGFloat,
                                    _ rightTop: CGFloat, _ rightBottom: CGFloat, color: Color) {
                            var path = Path()
                            path.move(to: CGPoint(x: start, y: leftTop))
                            path.addCurve(to: CGPoint(x: end, y: rightTop),
                                control1: CGPoint(x: start + width * 0.42, y: leftTop),
                                control2: CGPoint(x: start + width * 0.58, y: rightTop))
                            path.addLine(to: CGPoint(x: end, y: rightBottom))
                            path.addCurve(to: CGPoint(x: start, y: leftBottom),
                                control1: CGPoint(x: start + width * 0.58, y: rightBottom),
                                control2: CGPoint(x: start + width * 0.42, y: leftBottom))
                            path.closeSubpath()
                            let intensity = scheme == .dark ? 0.78 : 0.48
                            context.fill(path, with: .linearGradient(
                                Gradient(stops: [
                                    .init(color: color.opacity(0.08), location: 0),
                                    .init(color: color.opacity(0.2), location: 0.5),
                                    .init(color: color.opacity(intensity), location: 0.96),
                                    .init(color: color.opacity(0.35), location: 1)
                                ]), startPoint: CGPoint(x: start, y: 0), endPoint: CGPoint(x: end, y: 0)))
                            context.stroke(path, with: .color(color.opacity(0.16)), lineWidth: 0.7)
                            // Isolate frame updates to the water, leaving labels at telemetry cadence.
                            if flowing {
                                var water = context
                                water.clip(to: path)
                                let travel = CGFloat((time / 3.2).truncatingRemainder(dividingBy: 1))
                                for index in -1...1 {
                                    let x = start + (travel + CGFloat(index)) * width * 1.25
                                    water.fill(Path(CGRect(x: x - width * 0.28, y: 0, width: width * 0.56, height: height)),
                                        with: .linearGradient(Gradient(colors: [.clear, color.opacity(0.28), .white.opacity(0.28), .clear]),
                                            startPoint: CGPoint(x: x - width * 0.28, y: 0),
                                            endPoint: CGPoint(x: x + width * 0.28, y: height * 0.3)))
                                }
                                for lane in 1...5 {
                                    let ratio = CGFloat(lane) / 6
                                    var ripple = Path()
                                    for step in 0...24 {
                                        let t = CGFloat(step) / 24
                                        let blend = t * t * (3 - 2 * t)
                                        let top = leftTop + (rightTop - leftTop) * blend
                                        let bottom = leftBottom + (rightBottom - leftBottom) * blend
                                        let wave = sin(t * 15 - CGFloat(time) * 2.8 + CGFloat(lane))
                                        let point = CGPoint(x: start + width * t,
                                            y: top + (bottom - top) * ratio + wave * min(3, (bottom - top) * 0.045))
                                        if step == 0 { ripple.move(to: point) } else { ripple.addLine(to: point) }
                                    }
                                    water.stroke(ripple, with: .color(color.opacity(0.14)), lineWidth: 0.8)
                                }
                            }
                        }
                        if splitting {
                            let boundary = height * min(0.85, max(0.01, fraction))
                            ribbon(0, max(1, boundary - 1), 0, splitHeight - gap / 2, color: Theme.chartGreen)
                            ribbon(boundary + 1, height, splitHeight + gap / 2, height, color: Theme.chartBlue)
                        } else if host.batteryExternalPower && batteryBranch {
                            let branch = max(0.7, height * min(0.65, fraction))
                            ribbon(0, mainHeight, height * 0.09, height * 0.87 - branch, color: Theme.chartBlue)
                            ribbon(batteryY, min(height * 0.98, batteryY + max(0.7, branch * 0.18)),
                                   height * 0.87 - branch + 1, height * 0.87 + 1, color: Theme.chartAmber)
                        } else {
                            ribbon(0, height, height * 0.08, height * 0.92, color: Theme.chartBlue)
                        }
                    }
                }.accessibilityHidden(true)

                endpoint(host.batteryExternalPower ? "电源" : "电池",
                         symbol: host.batteryExternalPower ? "powerplug.fill" : "battery.100",
                         watts: splitting ? supply : nil)
                    .frame(width: node, height: mainHeight)
                    .position(x: node / 2, y: mainHeight / 2)

                if splitting {
                    endpoint("充电", symbol: "battery.100.bolt", watts: nil)
                        .frame(width: node, height: splitHeight - gap / 2)
                        .position(x: size.width - node / 2, y: (splitHeight - gap / 2) / 2)
                    endpoint("整机", symbol: "laptopcomputer", watts: nil)
                        .frame(width: node, height: height - splitHeight - gap / 2)
                        .position(x: size.width - node / 2, y: (height + splitHeight + gap / 2) / 2)
                    reading(battery).position(x: start + width * 0.57, y: splitHeight / 2)
                    reading(host.powerSystemWatts).position(x: start + width * 0.57, y: (height + splitHeight) / 2)
                } else {
                    endpoint("整机", symbol: "laptopcomputer", watts: host.powerSystemWatts)
                        .frame(width: node, height: height * 0.79)
                        .position(x: size.width - node / 2, y: height * 0.485)
                    reading(supply).position(x: start + width * 0.52, y: mainHeight * 0.54)
                    if host.batteryExternalPower && batteryBranch {
                        Image(systemName: "battery.100")
                            .font(.system(size: compact ? 14 : 20)).foregroundColor(Theme.textSecondary)
                            .position(x: node / 2, y: batteryY)
                        reading(battery).position(x: start + width * 0.54, y: batteryY)
                    }
                }
            }
        }
        .onAppear { visible = true; appActive = NSApplication.shared.isActive; windowVisible = UIWakePolicy.hasVisibleWindow }
        .onDisappear { visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
        .onReceive(UIWakePolicy.changes) { windowVisible = UIWakePolicy.hasVisibleWindow }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("电源输入 \(watts(host.powerInputWatts))，整机消耗 \(watts(host.powerSystemWatts))，电池\(splitting ? "充电" : "供电") \(watts(battery))")
    }

    private func watts(_ value: Double?) -> String {
        value.map { String(format: "%.2f W", $0) } ?? "暂无读数"
    }

    private func reading(_ value: Double?) -> some View {
        Text(watts(value))
            .font(.system(size: compact ? 13 : 22, weight: .bold, design: .rounded))
            .monospacedDigit().foregroundColor(Theme.textPrimary)
            .fixedSize()
    }

    private func endpoint(_ name: String, symbol: String, watts value: Double?) -> some View {
        VStack(spacing: compact ? 4 : 7) {
            Image(systemName: symbol).font(.system(size: compact ? 15 : 23, weight: .medium))
            if let value {
                Text(String(format: "%.0f W", value))
                    .font(.system(size: compact ? 11 : 17, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            } else if !compact {
                Text(name).font(Theme.Font.caption)
            }
        }
        .foregroundColor(Theme.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cardFill(scheme == .dark ? 0.1 : 0.055), in: RoundedRectangle(cornerRadius: compact ? 14 : 24))
    }
}
