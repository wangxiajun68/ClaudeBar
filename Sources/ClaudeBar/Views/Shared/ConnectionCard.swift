import SwiftUI

/// Network, power and accessory status, with a connection-details popover.
struct LinkCard: View {
    @State private var showConnections = false
    var host: ProcessSampler.HostStats
    var accessory: AudioAccessoryMonitor.Accessory?
    var accessoryCount: Int
    var unavailableReason: String?
    var dense: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: dense ? 8 : 12)
            ConnectLaneRow(host: host,
                           accessory: accessory,
                           count: accessoryCount,
                           density: dense ? .popup : .page)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: dense ? 112 : 124, maxHeight: .infinity, alignment: .topLeading)
        .tile(dense: dense)
        .help(helpText())
        .contentShape(Rectangle())
        .accessibilityAction(named: "查看连接地图") { showConnections = true }
        .popover(isPresented: $showConnections) { ConnectionDetailPanel() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            InstrumentBadge(kind: .link)
            Button { showConnections = true } label: { Label("连接", systemImage: "arrow.up.right") }
                .buttonStyle(.plain)
                .font(Theme.Font.chrome)
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 4)
            StatusPill(label: linkState.0, tint: linkState.1)
        }
    }

    /// Whole-card state: is this Mac on a network at all? Independent of the
    /// headset, which is a mark with its own state.
    private var linkState: (String, Color) {
        if host.wiredOn || !host.wifiName.isEmpty || host.wifiRSSI < 0 { return ("已连接", Theme.Ink.success) }
        if host.wifiOn { return ("Wi-Fi 已开启", Theme.textSecondary) }
        if host.bluetoothOn { return ("本机", Theme.textSecondary) }
        return ("离线", Theme.Ink.idle)
    }

    private func helpText() -> String {
        var lines: [String] = []
        lines.append(host.wifiOn ? "Wi-Fi 开" : "Wi-Fi 关")
        if !host.wifiName.isEmpty { lines.append(host.wifiName) }
        if host.wifiOn, host.wifiRSSI < 0 { lines.append("\(host.wifiRSSI) dBm \(WiFiBars.label(for: host.wifiRSSI) ?? "")") }
        if host.wiredOn { lines.append("以太网 已接入") }
        if host.batteryInstalled {
            var battery = "电池 \(host.batteryPercent)%"
            if host.batteryCharging { battery += " 充电中" }
            else if host.batteryExternalPower { battery += " 已接通电源" }
            lines.append(battery)
        } else {
            lines.append("电源 交流电")
        }
        if let accessory {
            lines.append("\(accessory.name) \(accessoryValue(accessory, count: accessoryCount)) · \(accessory.connection.label)")
        } else if let unavailableReason {
            lines.append(unavailableReason)
        }
        return lines.joined(separator: "  ·  ")
    }
}

/// Shared glyph and text bands keep connection marks aligned across densities.
fileprivate struct ConnectMetrics {
    var dial: CGFloat
    var caption: CGFloat
    var markBox: CGFloat
    var gap: CGFloat
    /// Height of the band under the glyph row that every mark's percentage (or
    /// caption) sits in. Reserved on every mark, headset or not — a
    /// conditional band was how the row lost its baseline.
    var labelBand: CGFloat
    var symbolSize: CGFloat {
        markBox * 0.74
    }

    /// Size each headset symbol by its visible bounds while preserving a common baseline.
    func partSymbolSize(for symbol: String) -> CGFloat {
        // Ink height / em for each mark, measured from `NSImage` at a fixed
        // point size. Rounded to two places; they are ratios, not absolutes.
        let inkHeightRatio: CGFloat = symbol.contains("case") ? 0.875 : 0.80
        return (dial * 0.46) / inkHeightRatio * 0.80
    }

    /// The buds are drawn from their ink width too, so the *pair* stays
    /// symmetric: `earbud.left` and `earbud.right` are mirror images and must be
    /// scaled identically or the pair reads lopsided.
    var budSymbolSize: CGFloat { partSymbolSize(for: "earbud.left") }
    var caseSymbolSize: CGFloat { partSymbolSize(for: "airpods.chargingcase") }

    /// Both rows are `glyphRow + labelBand + statusBand` tall, and every mark
    /// draws into exactly those bands, so a 32pt ring and a 28pt arc share one
    /// centre line.
    var statusBand: CGFloat { 14 }

    static func resolve(_ density: ConnectDensity, extraMarks: Int) -> ConnectMetrics {
        let crowded = extraMarks > 0
        switch density {
        case .page:
            return ConnectMetrics(dial: 32, caption: 10.5, markBox: 38,
                                  gap: crowded ? 11 : 20,
                                  labelBand: 17)
        case .popup:
            return ConnectMetrics(dial: 30, caption: 10, markBox: 36,
                                  gap: crowded ? 9 : 18,
                                  labelBand: 16)
        }
    }
}

fileprivate enum ConnectDensity { case page, popup }

/// Wi-Fi and power are always present; Ethernet and headsets appear when connected.
fileprivate struct ConnectLaneRow: View {
    var host: ProcessSampler.HostStats
    var accessory: AudioAccessoryMonitor.Accessory?
    var count: Int
    var density: ConnectDensity

    /// Show attached headsets even before their first battery report arrives.
    /// Nearby BLE advertisements alone do not establish a connection to this Mac.
    private var headset: AudioAccessoryMonitor.Accessory? {
        guard let accessory,
              accessory.connection == .inUse else { return nil }
        return accessory
    }

    private var extraMarks: Int {
        (host.wiredOn ? 1 : 0) + (headset == nil ? 0 : 1)
    }

    private var metrics: ConnectMetrics {
        ConnectMetrics.resolve(density, extraMarks: extraMarks)
    }

    var body: some View {
        let m = metrics
        ViewThatFits(in: .horizontal) {
            HStack(spacing: m.gap) {
                wifi
                BatteryMark(host: host, metrics: m)
                AirDropConnectionMark(dial: m.dial, labelHeight: m.labelBand)
                accessoryMarks
            }
            VStack(spacing: 10) {
                HStack(spacing: m.gap) {
                    wifi
                    BatteryMark(host: host, metrics: m)
                    AirDropConnectionMark(dial: m.dial, labelHeight: m.labelBand)
                }
                if host.wiredOn || headset != nil {
                    HStack(spacing: m.gap) { accessoryMarks }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    @ViewBuilder private var accessoryMarks: some View {
        if host.wiredOn { EthernetMark(metrics: metrics) }
        if let headset { HeadsetMarks(accessory: headset, count: count, metrics: metrics) }
    }

    private var wifi: some View {
        WiFiConnectionMark(host: host, dial: metrics.dial, labelHeight: metrics.labelBand)
    }


}

/// Segmented power cell with exact percentage and explicit charging state below.
/// Machines without an internal battery retain the AC plug affordance.
private struct BatteryMark: View {
    var host: ProcessSampler.HostStats
    var metrics: ConnectMetrics
    @State private var showPowerFlow = false

    /// Desktop Macs retain an AC-power mark when no battery is installed.
    private var installed: Bool { host.batteryInstalled }

    /// Choose the closest available SF Symbols battery state.
    private var symbol: String {
        guard installed else { return "powerplug" }
        let step = Int((Double(host.batteryPercent) / 25).rounded()) * 25
        let clamped = max(0, min(100, step))
        return host.batteryCharging ? "battery.\(clamped).bolt" : "battery.\(clamped)"
    }

    /// Amber below 20 %, red below 10 % — and never while on external power,
    /// where a low number is already being handled.
    private var tint: Color {
        if host.batteryCharging { return Theme.Ink.success }
        guard installed else { return Theme.textSecondary }
        if !host.batteryExternalPower {
            if host.batteryPercent <= 10 { return Theme.Ink.error }
            if host.batteryPercent <= 20 { return Theme.Ink.warning }
        }
        return Theme.textSecondary
    }

    /// Charging and *plugged in* are different claims, and a Mac holding at
    /// 100 % on a charger is the second without the first — so it says 已接通
    /// rather than 充电中, the same distinction the headset parts make.
    private var stateWord: String {
        guard installed else { return "交流电" }
        if let watts = host.powerBatteryWatts {
            if watts > 0 { return String(format: "充电 %.1f W", watts) }
            if watts < 0 { return String(format: "放电 %.1f W", abs(watts)) }
        }
        if host.batteryCharging { return "充电中 · 功率未知" }
        return host.batteryExternalPower ? "已接通" : "电池"
    }

    /// The reading line. A Mac with no pack has no percentage to print, so the
    /// line states the source instead — the band is never left blank, which is
    /// what would make this mark look broken next to the lanes.
    private var reading: String {
        installed ? "\(host.batteryPercent)%" : "电源"
    }

    var body: some View {
        let content = VStack(spacing: 0) {
            Group {
                if installed {
                    InstrumentGlyph(kind: .battery, tint: tint, level: Double(host.batteryPercent) / 100)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: metrics.symbolSize, weight: .semibold))
                        .foregroundColor(tint)
                }
            }
                .frame(width: metrics.markBox, height: metrics.dial)
            Text(reading)
                .font(.system(size: metrics.caption, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(installed ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .frame(height: metrics.labelBand)
            Text(stateWord)
                .font(.system(size: metrics.caption, weight: .medium, design: .rounded))
                .foregroundColor(host.batteryCharging ? Theme.Ink.success : Theme.textTertiary())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: metrics.markBox, height: metrics.statusBand)
        }
        .frame(width: metrics.markBox)
        .help(batteryHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(batteryHelp)

        return Button { showPowerFlow = true } label: { content }
            .buttonStyle(.pressable)
            .disabled(!installed)
            .accessibilityHint("点击查看电源、电池与整机的实时功率")
            .popover(isPresented: $showPowerFlow) {
                PowerFlowCard().frame(width: 560).padding(12).background(Theme.bgPrimary)
            }
    }

    private var batteryHelp: String {
        guard installed else { return "Mac 电源 · 交流电 · 无内置电池" }
        var text = "Mac 电池 \(host.batteryPercent)% · \(stateWord)"
        if host.batteryExternalPower { text += " · 已接电源" }
        if host.batteryCharging {
            text += host.batteryChargingWatts == nil
                ? " · 充电功率暂无读数"
                : (host.powerIsEstimated ? " · 电池侧估算功率" : " · 电池实时功率")
        }
        return text
    }
}

/// Live Ethernet. Absent when there is no carrier — a dim USB-plug glyph is
/// how this used to be read as "charging", which it is not.
fileprivate struct EthernetMark: View {
    var metrics: ConnectMetrics

    var body: some View {
        LinkMark(symbol: "network",
                 tint: Theme.external,
                 on: true,
                 metrics: metrics,
                 caption: "以太网",
                 help: "以太网已接入")
    }
}

/// Battery rings for the headset components, followed by one shared connection label.
fileprivate struct HeadsetMarks: View {
    var accessory: AudioAccessoryMonitor.Accessory
    var count: Int
    var metrics: ConnectMetrics

    /// The case is optional hardware: a headset that never reports one gets two
    /// marks, not a dashed third.
    private var showsCase: Bool { accessory.caseLevel != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: metrics.gap) {
                HeadsetPart(percent: accessory.left?.percent,
                            symbol: "earbud.left",
                            charging: accessory.left?.charging == true,
                            accessory: accessory,
                            metrics: metrics)
                HeadsetPart(percent: accessory.right?.percent,
                            symbol: "earbud.right",
                            charging: accessory.right?.charging == true,
                            accessory: accessory,
                            metrics: metrics)
                if showsCase {
                    HeadsetPart(percent: accessory.caseLevel?.percent,
                                // The outlined case, not the filled one: the
                                // filled mark is a slab that outweighs the
                                // hairline bud glyphs beside it.
                                symbol: "airpods.chargingcase",
                                charging: accessory.caseLevel?.charging == true,
                                accessory: accessory,
                                metrics: metrics)
                }
            }
            // Reserve a separate text band so connection state cannot overlap charge labels.
            Text(stateWord)
                .font(.system(size: metrics.caption, weight: .medium, design: .rounded))
                .foregroundColor(inUse ? Theme.Ink.success : Theme.textTertiary())
                .lineLimit(1)
                .fixedSize()
                .frame(height: metrics.statusBand)
        }
        .help("\(accessory.name) \(accessoryValue(accessory, count: count)) · \(accessory.connection.label)")
    }

    private var inUse: Bool { accessory.connection == .inUse }

    /// Connection decides the word, charge only refines it — the same order the
    /// card's help text uses, so the two cannot disagree about one headset.
    /// `充电中` is never read as `已连接` because only a connected headset gets
    /// the green word.
    private var stateWord: String {
        if inUse, accessory.isCharging == true { return "充电中" }
        return inUse ? "已连接" : "未连接"
    }
}

/// One headset component: charge ring, product glyph and percentage.
fileprivate struct HeadsetPart: View {
    var percent: Int?
    var symbol: String
    var charging: Bool
    var accessory: AudioAccessoryMonitor.Accessory
    var metrics: ConnectMetrics

    private var inUse: Bool { accessory.connection == .inUse }

    private var symbolSize: CGFloat {
        symbol.contains("case") ? metrics.caseSymbolSize : metrics.budSymbolSize
    }

    /// Charging state is per component and takes precedence over connection tint.
    private var tint: Color {
        if charging { return Theme.Ink.success }
        return inUse ? Theme.chartPurple : Theme.Ink.idle
    }

    /// Low-battery colours are connection-independent on purpose: 15 % is 15 %
    /// whether or not the headset is on your head. A part that is charging is
    /// exempt — the level it is sitting at is being topped up, so warning about
    /// it would be warning about the one case that is already handled.
    private var ringTint: Color {
        guard let percent, !charging else { return tint }
        if percent <= 15 { return Theme.Ink.error }
        if percent <= 35 { return Theme.Ink.warning }
        return tint
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .stroke(Theme.cardFill(0.16), lineWidth: metrics.dial * 0.085)
                if let percent {
                    Circle()
                        .trim(from: 0, to: CGFloat(percent) / 100)
                        .stroke(ringTint, style: StrokeStyle(lineWidth: metrics.dial * 0.085, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                // `.minimumScaleFactor` is not available on `Image`, so the
                // glyph is given a hard frame the ring cannot clip: the mark's
                // own box is wider than its ink, and a frame smaller than the
                // box is what cut the buds' stems off in the first render.
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundColor(percent == nil ? Theme.textTertiary() : Theme.textPrimary)
                    .frame(width: metrics.dial * 0.92, height: metrics.dial * 0.92)
            }
            .frame(width: metrics.dial, height: metrics.dial)
            .overlay(alignment: .topTrailing) {
                // Filled while in use, hollow while merely nearby: the ring
                // carries the level, this dot carries "with you or not".
                Group {
                    if inUse {
                        Circle().fill(Theme.Ink.success)
                    } else {
                        Circle().stroke(Theme.Ink.idle, lineWidth: 1.5)
                    }
                }
                .frame(width: 6, height: 6)
                .offset(x: 2, y: -2)
            }

            Text(percent.map { "\($0)%" } ?? "—")
                .font(.system(size: metrics.caption, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(percent == nil ? Theme.textTertiary() : Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .frame(height: metrics.labelBand)
        }
        // Exactly the box a network lane occupies: same glyph band, same label
        // band. The mark is centred in the band rather than in the box, which is
        // why a 32pt ring and a 28pt arc share one centre line.
        .frame(width: metrics.markBox)
        .accessibilityLabel("\(partName) \(percent.map { "\($0)%" } ?? "无读数")")
    }

    private var partName: String {
        if symbol.contains(".right") { return "右耳" }
        if symbol.contains("case") { return "充电盒" }
        if symbol.contains("earbud") { return "左耳" }
        return "部件"
    }
}

/// Bespoke radio / Ethernet marks share a fixed glyph band and caption baseline.
/// The original state labels and accessibility descriptions remain authoritative.
fileprivate struct LinkMark: View {
    var symbol: String
    var tint: Color
    var on: Bool
    var metrics: ConnectMetrics
    /// Always non-empty: Wi-Fi carries its grade when up, and its own name
    /// when down, so an off lane is not dressed as one that is on.
    var caption: String
    /// Forces the neutral caption ink for a caption that is a *name* rather
    /// than a reading (an off Wi-Fi reads `弱`/`好`/… when up, `Wi-Fi` when
    /// down), so a lane that is off is not dressed as one that is on.
    var captionDim: Bool = false
    var help: String

    private var effectiveTint: Color { on ? tint : Theme.textTertiary(0.32) }

    var body: some View {
        VStack(spacing: 0) {
            // The glyph band is the *ring's* diameter on every mark, so a 28pt
            // arc and a 32pt ring are centred on the same horizontal line.
            InstrumentGlyph(kind: symbol == "network" ? .ethernet : .link, tint: effectiveTint, active: on)
                .frame(width: metrics.markBox, height: metrics.dial)
            Text(caption)
                .font(.system(size: metrics.caption, weight: .medium, design: .rounded))
                .foregroundColor(on && !captionDim ? Theme.textSecondary : Theme.textTertiary())
                .lineLimit(1)
                .fixedSize()
                .frame(height: metrics.labelBand)
            // The headset prints a status line under its percentages; Wi-Fi
            // and Ethernet reserve the same band and leave it empty, which is
            // what keeps every mark on one baseline.
            Color.clear.frame(height: metrics.statusBand)
        }
        .frame(width: metrics.markBox)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(help)
    }
}

/// RSSI is represented by a textual grade beside the connection glyph.
private enum WiFiBars {
    static func symbol(for rssi: Int) -> String {
        rssi < -80 ? "wifi.exclamationmark" : "wifi"
    }

    static func label(for rssi: Int) -> String? {
        switch rssi {
        case ..<(-75): return "弱"
        case ..<(-62): return "一般"
        case ..<(-50): return "好"
        default: return "很强"
        }
    }
}

/// Charge and connection are separate claims; both are stated when both are
/// true, so 充电中 is never read as 已连接. Shared by the card's help text and
/// the headset cell so the two cannot describe the same headset differently.
private func accessoryValue(_ accessory: AudioAccessoryMonitor.Accessory, count: Int) -> String {
    var parts: [String] = []
    if let left = accessory.left?.percent { parts.append("左 \(left)%") }
    if let right = accessory.right?.percent { parts.append("右 \(right)%") }
    if let level = accessory.caseLevel?.percent { parts.append("盒 \(level)%") }
    if parts.isEmpty, let combined = accessory.combined?.percent { parts.append("\(combined)%") }
    if count > 1 { parts.append("等 \(count) 台") }
    let level = parts.isEmpty ? "—" : parts.joined(separator: " ")
    switch accessory.connection {
    case .inUse: return accessory.isCharging == true ? "\(level) · 充电中" : "\(level) · 已连接"
    case .nearby: return accessory.isCharging == true ? "\(level) · 充电中" : "\(level) · 未连接"
    case .absent: return "\(level) · 已离开"
    }
}

/// SSID belongs beneath its radio glyph; only the signal strength occupies the secondary line.
struct WiFiConnectionMark: View {
    let host: ProcessSampler.HostStats
    var dial: CGFloat = 32
    var labelHeight: CGFloat = 17
    @ObservedObject private var permission = WiFiNameAuthorization.shared

    private var name: String {
        if !host.wifiOn { return "Wi-Fi 已关闭" }
        if !host.wifiName.isEmpty { return host.wifiName }
        if permission.requesting { return "等待授权…" }
        return permission.authorized ? "检查定位权限" : "授权显示名称"
    }

    var body: some View {
        Button { permission.request() } label: {
            VStack(spacing: 0) {
                Image(systemName: host.wifiOn ? "wifi" : "wifi.slash")
                    .font(.system(size: dial * 0.75, weight: .medium))
                    .foregroundColor(host.wifiOn ? Theme.chartBlue : Theme.textSecondary)
                    .frame(height: dial)
                Text(name).font(Theme.Font.caption).lineLimit(1).truncationMode(.middle)
                    .frame(height: labelHeight)
                Text(host.wifiOn && host.wifiRSSI < 0 ? "\(host.wifiRSSI) dBm" : "Wi-Fi")
                    .font(.system(size: 9)).foregroundColor(Theme.textSecondary).frame(height: 14)
            }
            .frame(width: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!host.wifiOn || !host.wifiName.isEmpty || permission.requesting)
        .foregroundColor(Theme.textPrimary)
        .help(host.wifiName.isEmpty ? "macOS 读取 Wi-Fi 名称需要定位授权；不会采集地理位置。" : host.wifiName)
        .alert("尚未获得 Wi-Fi 名称读取权限", isPresented: $permission.showSettingsHelp) {
            Button("打开定位设置") { permission.openSettings() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("请在“隐私与安全性 → 定位服务”中开启定位服务，并允许 ClaudeBar。若系统授权窗口已出现，可先在其中完成授权。")
        }
    }
}

struct AirDropConnectionMark: View {
    var dial: CGFloat = 32
    var labelHeight: CGFloat = 17
    @State private var openFailed = false

    var body: some View {
        Button {
            let app = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
            openFailed = !NSWorkspace.shared.open(app)
        } label: {
            VStack(spacing: 0) {
                AirDropGlyph(tint: Theme.chartBlue)
                    .frame(width: dial, height: dial)
                Text("隔空投送").font(Theme.Font.caption).frame(height: labelHeight)
                Text("打开").font(.system(size: 9)).foregroundColor(Theme.textSecondary).frame(height: 14)
            }
            .frame(width: 58).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundColor(Theme.textPrimary)
        .help("打开隔空投送，查看接收范围与附近设备")
        .alert("无法打开隔空投送", isPresented: $openFailed) {
            Button("好", role: .cancel) { }
        } message: { Text("请从 Finder 的“前往”菜单打开“隔空投送”。") }
    }
}


/// Concentric broadcast arcs and a receiving pointer, independent of SF Symbols availability.
private struct AirDropGlyph: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            for radius in [CGFloat(4), 7, 10] {
                var arc = Path()
                arc.addArc(center: CGPoint(x: 12, y: 11), radius: radius,
                           startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
                context.stroke(arc, with: .color(tint), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            }
            var receiver = Path()
            receiver.move(to: CGPoint(x: 12, y: 12))
            receiver.addLine(to: CGPoint(x: 7.5, y: 22))
            receiver.addQuadCurve(to: CGPoint(x: 16.5, y: 22), control: CGPoint(x: 12, y: 24))
            receiver.closeSubpath()
            context.fill(receiver, with: .color(tint))
        }
        .accessibilityHidden(true)
    }
}
