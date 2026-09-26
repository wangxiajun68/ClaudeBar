import SwiftUI
import Darwin
import Metal

/// Machine identity is immutable for this process; never launch a profiler from a view body.
enum HardwareIdentity {
    static let gpuName = MTLCreateSystemDefaultDevice()?.name ?? "GPU"
    static let name: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }()
    static var shortName: String { name.replacingOccurrences(of: "Apple ", with: "") }
}

struct HardwareSiliconMark: View {
    var gpu = false
    var load: Double
    var tint: Color
    /// The mark's per-unit reading, straight from the sampler: one cell per
    /// logical core, or one per GPU sub-unit. The mark is the same drawing
    /// everywhere it appears, so the breakdown is handed in rather than looked
    /// up — a caller with only a single number still draws the single die.
    var cells: [Double] = []
    /// The size the tile gives the mark. Passed in so the popover's hero copy and
    /// the tile's copy are the *same drawing at the same proportions* — the
    /// drawing fills whatever box it is handed on its own 120×92 grid.
    var markHeight: CGFloat = 76
    var body: some View {
        VStack(spacing: 3) {
            HardwareIllustration(kind: gpu ? .gpu : .cpu, load: load, tint: tint, cells: cells)
                .frame(height: markHeight)
            Text(gpu ? HardwareIdentity.gpuName.replacingOccurrences(of: "Apple ", with: "") : HardwareIdentity.shortName).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 2)
        .accessibilityLabel("\(gpu ? HardwareIdentity.gpuName : HardwareIdentity.name) · \(gpu ? "GPU" : "CPU") 总负载 \(Int(min(1, max(0, load.isFinite ? load : 0)) * 100))%")
    }
}

struct LoadHistoryChart: View {
    let values: [Double]
    let tint: Color
    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                for step in 0...4 {
                    let y = size.height * CGFloat(step) / 4
                    var grid = Path(); grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(grid, with: .color(Theme.hairline), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                    context.draw(Text("\(100 - step * 25)").font(.system(size: 9)).foregroundColor(Theme.textSecondary), at: CGPoint(x: 2, y: y + 6), anchor: .leading)
                }
                guard values.count > 1 else { return }
                var line = Path()
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: 28 + (size.width - 28) * CGFloat(index) / CGFloat(values.count - 1),
                                        y: size.height * (1 - CGFloat(min(1, max(0, value)))))
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 28, y: size.height)); area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.28), tint.opacity(0.015)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }.frame(height: 140)
            HStack { Text("较早采样"); Spacer(); Text("当前 · %") }.font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }
        .accessibilityLabel("最近 \(values.count) 次采样，当前 \(Int((values.last ?? 0) * 100))%")
    }
}

struct HardwareDetailPanel: View {
    let gpu: Bool
    private let sampler = ProcessSampler.shared
    private var tint: Color { gpu ? Theme.chartBlue : Theme.chartGreen }

    /// What the mark is actually showing. The previous copy promised the
    /// opposite ("不代表单个核心的独立读数") of what the drawing now does, which
    /// is exactly the kind of caption that turns a measurement back into an
    /// ornament.
    private var caption: String {
        if gpu {
            let units = sampler.host.gpuRenderers.count
            return units > 0
                ? "每一格是一组图形子单元，按各自的实时占用点亮。"
                : "芯片亮度表示整体负载。"
        }
        let cores = sampler.host.coreLoad.count
        return cores > 0
            ? "每一个方块是一个逻辑核心（共 \(cores) 个），按各自的实时占用点亮。"
            : "芯片亮度表示整体负载。"
    }

    var body: some View {
        let load = gpu ? sampler.host.gpu : sampler.host.cpu
        let values = sampler.trail.map { gpu ? $0.gpu : $0.cpu }
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                HardwareSiliconMark(gpu: gpu, load: load / 100, tint: tint,
                                    cells: gpu ? sampler.host.gpuRenderers.map { $0 / 100 }
                                               : sampler.host.coreLoad,
                                    markHeight: 62)
                    .frame(width: 104)
                VStack(alignment: .leading, spacing: 4) {
                    Text(gpu ? HardwareIdentity.gpuName : HardwareIdentity.name).font(Theme.Font.chromeEmph)
                    Text(gpu ? "图形处理器 · 整体负载" : "\(sampler.host.coreCount) 个逻辑核心 · 整体负载").rollingNumber().font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    RollingNumberText(String(format: "%.1f%%", load)).font(Theme.Font.displayMetric).monospacedDigit()
                }
                Spacer()
            }
            LoadHistoryChart(values: values, tint: tint)
            HStack {
                Label(sampler.host.temperatureLabel(celsius: gpu ? sampler.host.gpuTemperatureCelsius : sampler.host.cpuTemperatureCelsius) ?? "温度暂无读数", systemImage: "thermometer.medium")
                Spacer()
                Text("峰值 \(Int((values.max() ?? 0) * 100))%").rollingNumber()
            }.font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            Text(caption)
                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }.padding(22).frame(width: 420).background(Theme.cardSurface)
    }
}

/// The connection tile's popover.
///
/// **What a connection card's click should open**, decided here because the card
/// is four different claims in one tile (Wi-Fi, AirDrop, Ethernet, a headset) and
/// "show me more" has to mean one thing for all of them:
///
/// 1. **The route this Mac's traffic takes.** The tile shows the *radio*; this
///    shows where the radio goes — Wi-Fi and Ethernet on the left, the machine in
///    the middle, Bluetooth and its accessories on the right, which is the answer
///    to "why is Claude Code talking to the proxy this slowly". The 流量 page
///    carries the throughput; this carries the topology.
/// 2. **The link quality.** Signal is a number before it is a *feeling*: an RSSI
///    bar with the weak/strong ends named, so a report of "network is bad" has
///    something to point at.
/// 3. **The proxy hop.** The local endpoint the provider traffic actually
///    passes through, and whether it is listening — the one connection in this
///    machine the app itself owns. It is the same reading the 设置 page shows,
///    surfaced where the connection question is asked.
/// 4. **The accessories.** Each headset's battery and how it is attached. Absent
///    hardware is not a failure, so that block states the reason instead.
///
/// The 网络 pane and `ControlCenter` are the honest answer to "the rest of it",
/// hence the one button at the bottom rather than a fifth block of system facts
/// this app would be re-deriving.
struct ConnectionDetailPanel: View {
    private let sampler = ProcessSampler.shared
    private let audio = AudioAccessoryMonitor.shared
    @ObservedObject private var prefs = AppPreferences.shared
    /// Injected, not a singleton: this panel is presented from the 概览 strip,
    /// and the window already owns the one `CodexProviderStore` it hands to
    /// every page through the environment. Reaching for a `shared` here would
    /// mean the popup and the 设置 page could hold two stores describing one
    /// listener.
    @EnvironmentObject private var codexStore: CodexProviderStore
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    @Environment(\.openURL) private var openURL

    /// Wide enough for the route diagram to stay a *diagram*: 440 put the three
    /// nodes and two links within a few points of each other, so the topology
    /// read as one dense row instead of three stops on a line.
    private let panelWidth: CGFloat = 480

    var body: some View {
        let host = sampler.host
        VStack(alignment: .leading, spacing: 18) {
            header(host)
            route(host)
            if host.wifiOn, host.wifiRSSI < 0 {
                signal(host)
            }
            proxyHop
            accessories
            bottomBar
        }
        .padding(22)
        .frame(width: panelWidth)
        .background(Theme.cardSurface)
    }

    // MARK: Header

    private func header(_ host: ProcessSampler.HostStats) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("连接").font(Theme.Font.displayHero)
            Spacer()
            Text(headline(host))
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
        }
    }

    /// One sentence for the whole card: what the machine is on. Deliberately the
    /// *link*, not the count of accessories — an earbud connected does not change
    /// how this Mac reaches the network, and the tile already said both.
    private func headline(_ host: ProcessSampler.HostStats) -> String {
        if host.wiredOn, !host.wifiName.isEmpty { return "以太网 · Wi-Fi \(host.wifiName)" }
        if host.wiredOn { return "以太网" }
        if !host.wifiName.isEmpty { return host.wifiName }
        if host.wifiOn { return "Wi-Fi 已开启" }
        if host.bluetoothOn { return "仅蓝牙" }
        return "离线"
    }

    // MARK: Route

    /// The topology the tile cannot show: radio → machine → accessories.
    private func route(_ host: ProcessSampler.HostStats) -> some View {
        HStack(spacing: 0) {
            node(host.wiredOn ? "以太网" : "Wi-Fi",
                 detail: host.wiredOn ? "已接入"
                       : (host.wifiName.isEmpty ? (host.wifiOn ? "已开启" : "未开启") : host.wifiName),
                 symbol: host.wiredOn ? "network" : "wifi",
                 active: host.wiredOn || host.wifiOn)
            Link(kind: .uplink, tint: Theme.chartBlue)
            node(HardwareIdentity.shortName, detail: "本机", symbol: "laptopcomputer", active: true)
            Link(kind: .downlink, tint: Theme.chartPurple)
            node("蓝牙",
                 detail: audio.accessories.isEmpty
                       ? (host.bluetoothOn ? "已开启" : "未开启")
                       : "\(audio.accessories.count) 个设备",
                 symbol: "antenna.radiowaves.left.and.right",
                 active: host.bluetoothOn)
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardFill(0.4))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    /// The connector between two nodes. A lit hairline when the hop is live, a
    /// dashed grey one when it is not — the same distinction the marks make, so
    /// "off" is drawn rather than merely dimmer.
    private struct Link: View {
        enum Kind { case uplink, downlink }

        var kind: Kind
        var tint: Color

        var body: some View {
            VStack(spacing: 6) {
                Text(kind == .uplink ? "上行" : "下行")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.textTertiary())
                Rectangle()
                    .fill(tint.opacity(0.45))
                    .frame(width: 44, height: 2)
            }
        }
    }

    private func node(_ title: String, detail: String, symbol: String, active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(active ? Theme.chartBlue : Theme.textTertiary(0.5))
            Text(title)
                .font(Theme.Font.chromeEmph)
                .lineLimit(1)
            Text(detail)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 104)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(detail)")
    }

    // MARK: Signal

    private func signal(_ host: ProcessSampler.HostStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("信号强度").font(Theme.Font.chromeEmph)
                Spacer()
                if let grade = WiFiBars.label(for: host.wifiRSSI) {
                    StatusPill(label: grade, tint: Theme.chartBlue)
                }
                RollingNumberText("\(host.wifiRSSI) dBm")
                    .font(Theme.Font.captionMono)
                    .monospacedDigit()
            }
            // −100…−40 is the range macOS itself treats as "usable". Drawn as a
            // bare track with one marker rather than a filled bar: the reading is
            // a position on a scale, and a bar that fills would read as a ratio.
            GeometryReader { proxy in
                let position = min(1, max(0, Double(host.wifiRSSI + 100) / 60))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.chartBlue, Theme.chartGreen],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * CGFloat(position))
                }
            }
            .frame(height: 8)
            HStack {
                Text("弱 · −100").font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
                Spacer()
                Text("强 · −40").font(Theme.Font.caption).foregroundColor(Theme.textTertiary())
            }
        }
    }

    // MARK: Proxy hop

    /// The one connection this app owns. Same readout as 设置 → 本地代理, surfaced
    /// where the question is actually asked, plus the test button that already
    /// knows how to answer it.
    private var proxyHop: some View {
        let outcome = tests.outcome(ConnectivityTestCenter.proxyKey)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("本地代理").font(Theme.Font.chromeEmph)
                Spacer()
                StatusPill(label: codexStore.proxyRunning ? "监听中" : "未监听",
                           tint: codexStore.proxyRunning ? Theme.chartGreen : Theme.textSecondary,
                           ink: codexStore.proxyRunning ? Theme.Ink.success : Theme.textSecondary)
            }
            Text(LocalProxyAddress.openaiRoot)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textSecondary)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                ConnectivityTileButton(outcome: outcome, helpIdle: "检测本机代理") {
                    tests.testProxy(port: prefs.codexProxyPort, running: codexStore.proxyRunning)
                }
                Text(outcome.state == .idle ? "尚未检测" : outcome.detail)
                    .font(Theme.Font.caption)
                    .foregroundColor(outcome.state == .failed ? Theme.Ink.error : Theme.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.cardFill(0.4))
        }
    }

    // MARK: Accessories

    @ViewBuilder private var accessories: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("蓝牙设备").font(Theme.Font.chromeEmph)
                Spacer()
                Button("刷新") { audio.refreshNow() }
                    .buttonStyle(.plain)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Ink.claude)
            }
            if audio.accessories.isEmpty {
                Text(audio.unavailableReason
                     ?? "尚未检测到耳机。连接后自动更新，电量以设备报告为准。")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(3)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 14) {
                        ForEach(audio.accessories) { accessory in
                            accessoryCell(accessory)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private func accessoryCell(_ accessory: AudioAccessoryMonitor.Accessory) -> some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().stroke(Theme.cardFill(0.35), lineWidth: 5)
                if let level = accessory.headline {
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, Double(level) / 100)))
                        .stroke(accessoryTint(accessory), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(accessory.headline.map { "\($0)%" } ?? "未知")
                    .rollingNumber()
                    .font(Theme.Font.chromeEmph)
            }
            .frame(width: 56, height: 56)
            Text(accessory.name).lineLimit(2).multilineTextAlignment(.center)
            Text(accessoryValue(accessory, count: audio.accessories.count))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .font(Theme.Font.caption)
        .frame(maxWidth: .infinity)
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(accessory.name) \(accessoryValue(accessory, count: audio.accessories.count))")
    }

    private func accessoryTint(_ accessory: AudioAccessoryMonitor.Accessory) -> Color {
        switch accessory.connection {
        case .inUse: return accessory.isCharging == true ? Theme.chartGreen : Theme.chartPurple
        default: return Theme.textTertiary(0.55)
        }
    }

    // MARK: Footer

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text("更详细的路由与吞吐在 流量 页；系统级的接口列表在 macOS 的网络设置里。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("流量明细") {
                NotificationCenter.default.post(.showMainWindow(page: .traffic))
            }
            .buttonStyle(.plain)
            .font(Theme.Font.caption)
            .foregroundColor(Theme.Ink.claude)
            Button("打开网络设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                    openURL(url)
                }
            }
            .buttonStyle(.plain)
            .font(Theme.Font.caption)
            .foregroundColor(Theme.textSecondary)
        }
    }
}

struct CapacityHardwareMark: View {
    var disk: Bool
    var load: Double
    var bytes: UInt64
    var tint: Color
    /// The mark's own reading, one entry per area. Empty falls back to the single
    /// `load` figure, which is what a caller without the breakdown gets.
    var wells: [Double] = []
    /// The size the tile gives the mark, so the byte label stays inside the slot.
    var markHeight: CGFloat = 76
    var body: some View {
        VStack(spacing: 0) {
            // Two different Lucide icons for two different things: 内存 is the
            // DIMM (`memory-stick`), 硬盘 the drive bay (`hard-drive`). Sharing
            // one drawing made the disk read as a second stick of memory, which
            // is the one thing a hardware mark must not do.
            HardwareIllustration(kind: disk ? .disk : .memory, load: load, tint: tint,
                                 wells: wells)
                .frame(height: markHeight - 12)
            Text(ProcessSampler.Snapshot(memoryBytes: bytes).memoryLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(Theme.textSecondary)
        }
        .accessibilityLabel("\(disk ? "硬盘" : "内存")容量 \(ProcessSampler.Snapshot(memoryBytes: bytes).memoryLabel)")
    }
}
