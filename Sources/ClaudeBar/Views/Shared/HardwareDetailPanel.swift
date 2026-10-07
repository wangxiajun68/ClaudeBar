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
    /// Apple's raw names read "Apple M4 Pro"; the captions want the chip alone.
    /// One transform, so the CPU and GPU captions cannot drift apart.
    private static func short(_ full: String) -> String { full.replacingOccurrences(of: "Apple ", with: "") }
    static var shortName: String { short(name) }
    static var shortGPUName: String { short(gpuName) }
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
    /// drawing fills whatever box it is handed, scaled from Lucide's 24pt grid.
    var markHeight: CGFloat = 76
    var body: some View {
        VStack(spacing: 3) {
            HardwareIllustration(kind: gpu ? .gpu : .cpu, load: load, tint: tint, cells: cells)
                .frame(height: markHeight)
            Text(gpu ? HardwareIdentity.shortGPUName : HardwareIdentity.shortName).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
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
            let units = sampler.cells.gpuRenderers.count
            return units > 0
                ? "每一格是一组图形子单元，按各自的实时占用点亮。"
                : "芯片亮度表示整体负载。"
        }
        let cores = sampler.cells.cores.count
        return cores > 0
            ? "每一个方块是一个逻辑核心（共 \(cores) 个），按各自的实时占用点亮。"
            : "芯片亮度表示整体负载。"
    }

    var body: some View {
        let load = gpu ? sampler.host.gpu : sampler.host.cpu
        let values = sampler.trail.map { gpu ? $0.gpu : $0.cpu }
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                SiliconCells(gpu: gpu, load: load / 100, tint: tint, markHeight: 62)
                    .frame(width: 104)
                VStack(alignment: .leading, spacing: 4) {
                    Text(gpu ? HardwareIdentity.gpuName : HardwareIdentity.name).font(Theme.Font.chromeEmph)
                    Text(gpu ? "图形处理器 · 整体负载" : "\(sampler.host.coreCount) 个逻辑核心 · 整体负载").rollingNumber(gpu ? "图形处理器 · 整体负载" : "\(sampler.host.coreCount) 个逻辑核心 · 整体负载").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    RollingNumberText(String(format: "%.1f%%", load)).font(Theme.Font.displayMetric).monospacedDigit()
                }
                Spacer()
            }
            LoadHistoryChart(values: values, tint: tint)
            HStack {
                Label(sampler.host.temperatureLabel(celsius: gpu ? sampler.host.gpuTemperatureCelsius : sampler.host.cpuTemperatureCelsius) ?? "温度暂无读数", systemImage: "thermometer.medium")
                Spacer()
                Text("峰值 \(Int((values.max() ?? 0) * 100))%").rollingNumber("峰值 \(Int((values.max() ?? 0) * 100))%")
            }.font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            Text(caption)
                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }.padding(22).frame(width: 420).background(Theme.cardSurface)
    }
}

/// Connection inspector: signal first, local service second, nearby devices last.
/// The signal scale is a measurement, never a throughput animation. A listener
/// and an attached network do not establish internet reachability or routing.
struct ConnectionDetailPanel: View {
    private let sampler = ProcessSampler.shared
    private let audio = AudioAccessoryMonitor.shared
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var codexStore: CodexProviderStore
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var airDropFailed = false

    private var status: ConnectionStatus { ConnectionStatus(host: sampler.host) }
    private var outcome: ConnectivityOutcome { tests.outcome(ConnectivityTestCenter.proxyKey) }
    private var connected: [AudioAccessoryMonitor.Accessory] {
        audio.accessories.filter { $0.connection == .inUse }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("连接详情").font(Theme.Font.chromeEmph)
                Spacer()
                Text("本机状态").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    network
                    HairlineDivider()
                    proxy
                    HairlineDivider()
                    devices
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
            }
            HairlineDivider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 460, height: 590)
        .background(Theme.cardSurface)
        .foregroundColor(Theme.textPrimary)
        .alert("无法打开隔空投送", isPresented: $airDropFailed) {
            Button("好", role: .cancel) { }
        } message: { Text("请从 Finder 的“前往”菜单打开“隔空投送”。") }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            copied = false
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: status.symbol)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundColor(status.attached ? Theme.chartBlue : Theme.textSecondary)
                    .frame(width: 40, height: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(status.title)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .lineLimit(2).textSelection(.enabled)
                    Text(status.subtitle).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                StatusPill(label: status.attached ? "已接入" : "未接入",
                           tint: status.attached ? Theme.Ink.success : Theme.Ink.idle)
            }
            if sampler.host.wifiOn {
                HStack(alignment: .firstTextBaseline) {
                    Text(sampler.host.wiredOn ? "Wi-Fi 信号 · 同时开启" : "Wi-Fi 信号")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    Spacer()
                    if let rssi = status.rssi {
                        Text(WiFiBars.label(for: rssi)).font(Theme.Font.chromeEmph)
                        RollingNumberText("\(rssi)")
                            .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("dBm").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    } else {
                        Text("暂无读数").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    }
                }
                ConnectionSignalScale(rssi: status.rssi)
                if sampler.host.wifiName.isEmpty {
                    Button("授权读取 Wi-Fi 名称", systemImage: "location") {
                        NotificationCenter.default.post(.showMainWindow(page: .settings))
                    }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundColor(Theme.Ink.claude)
                    .help("在应用设置中开启定位权限，以读取 Wi-Fi 名称")
                }
            } else {
                Label(sampler.host.wiredOn ? "通过有线接口接入网络" : "连接 Wi-Fi 或以太网后显示网络信息",
                      systemImage: sampler.host.wiredOn ? "cable.connector" : "wifi.slash")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            Text("网络接入状态不代表互联网可用性。")
                .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
        }
    }

    private var proxy: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").foregroundColor(Theme.chartPurple)
                Text("本机代理").font(Theme.Font.chromeEmph)
                Spacer()
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(codexStore.proxyRunning ? Theme.chartGreen : Theme.textSecondary)
                        DecorativeMotion(kind: .pulse, tint: Theme.chartGreen,
                                         active: codexStore.proxyRunning && !reduceMotion)
                    }.frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(codexStore.proxyRunning ? "监听中" : "未运行")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
            }
            HStack {
                Text("127.0.0.1:\(prefs.codexProxyPort)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    tests.testProxy(port: prefs.codexProxyPort, running: codexStore.proxyRunning)
                } label: {
                    Label(outcome.state == .running ? "检测中…" : "检测代理",
                          systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.plain).font(Theme.Font.caption).foregroundColor(Theme.Ink.claude)
                .disabled(outcome.state == .running)
            }
            if outcome.state != .idle {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: outcome.state == .passed ? "checkmark.circle" :
                                (outcome.state == .failed ? "exclamationmark.circle" : "ellipsis.circle"))
                        Text(outcome.state == .passed ? "本机代理检测通过" :
                             (outcome.state == .failed ? "本机代理检测失败" : "正在检测本机代理"))
                        Spacer()
                        if let latency = outcome.latencyMS {
                            Text("\(latency) ms").monospacedDigit()
                        }
                    }
                    .foregroundColor(outcome.state == .failed ? Theme.Ink.error : Theme.textPrimary)
                    Text(outcome.detail).foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .font(Theme.Font.caption)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fieldWell, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("检测本机服务是否响应；不代表上游模型可用。")
                    .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("附近与设备").font(Theme.Font.chromeEmph)
                Spacer()
                Button("蓝牙设置", systemImage: "arrow.up.right") {
                    openSettings("com.apple.BluetoothSettings")
                }
                .buttonStyle(.plain).font(Theme.Font.caption).foregroundColor(Theme.Ink.claude)
            }
            HStack(spacing: 10) {
                Image(systemName: "headphones").foregroundColor(Theme.chartPurple).frame(width: 24)
                Text(sampler.host.bluetoothOn ? "蓝牙已开启" : "蓝牙已关闭")
                    .font(Theme.Font.caption)
                Spacer()
                Text("\(connected.count) 台音频设备已连接")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            if connected.isEmpty {
                Text(audio.unavailableReason ?? (sampler.host.bluetoothOn ? "未检测到已连接的音频设备" : "开启蓝牙以连接无线设备"))
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(connected) { device in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(device.name).font(Theme.Font.caption).lineLimit(2)
                        Text(device.isStale ? "电量读数已过期" : accessoryValue(device, count: 1))
                            .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button {
                let url = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
                airDropFailed = !NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "airdrop").font(.system(size: 19)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("隔空投送").foregroundColor(Theme.textPrimary)
                        Text("在 Finder 中查看接收范围与附近设备")
                            .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(Theme.Font.caption).foregroundColor(Theme.Ink.claude)
                .padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button(action: copyDiagnostics) {
                Label(copied ? "已复制" : "复制诊断", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel(copied ? "连接诊断已复制" : "复制连接诊断")
            Spacer(minLength: 0)
            Button("代理流量") { NotificationCenter.default.post(.showMainWindow(page: .traffic)) }
            Button("网络设置") { openSettings("com.apple.Network-Settings.extension") }
        }
        .buttonStyle(.plain).font(Theme.Font.caption).foregroundColor(Theme.Ink.claude)
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { openURL(url) }
    }

    private func copyDiagnostics() {
        var lines = ["ClaudeBar 连接诊断", "网络：\(status.title)", "状态：\(status.subtitle)"]
        if let rssi = status.rssi { lines.append("Wi-Fi 信号：\(rssi) dBm") }
        lines.append("互联网可用性：未检测")
        lines.append("本机代理：\(codexStore.proxyRunning ? "监听中" : "未运行") · 127.0.0.1:\(prefs.codexProxyPort)")
        if outcome.state != .idle { lines.append("最近代理检测：\(outcome.detail)") }
        lines.append("蓝牙：\(sampler.host.bluetoothOn ? "开启" : "关闭")")
        if let reason = audio.unavailableReason { lines.append("音频设备：\(reason)") }
        for device in audio.accessories {
            lines.append("设备：\(device.name) · \(accessoryValue(device, count: 1))\(device.isStale ? " · 电量读数已过期" : "")")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
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
            Text(ProcessSampler.Snapshot.byteLabel(bytes))
                .rollingNumber(ProcessSampler.Snapshot.byteLabel(bytes))
                .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(Theme.textSecondary)
        }
        .accessibilityLabel("\(disk ? "硬盘" : "内存")容量 \(ProcessSampler.Snapshot.byteLabel(bytes))")
    }
}

/// A calibrated RSSI ruler. Its ticks are signal levels, not time buckets.
///
/// It moved here from `ConnectionCard.swift` when the tile stopped drawing the
/// wide ruler: the tile's reading is a *mark* in the mark slot every sibling
/// reserves (`ConnectInterfaceMark`), and the only reader of the full-width row
/// is this panel's 网络 section. The two surfaces must still measure one reading
/// one way — the tile's mark uses the same −100…−40 dBm fraction — but only one
/// of them draws the ruler, so only one of them declares it.
///
/// There is no compact form: nothing in the app ever passed `compact: true`,
/// so the 9pt row it gated — a second drawing with its own radius, height and
/// padding — was unreachable; deleted rather than kept as a knob no caller can
/// turn.
///
/// Only new measurements animate; no polling or decorative frame loop.
struct ConnectionSignalScale: View {
    let rssi: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var position: Double? { rssi.map { min(1, max(0, Double($0 + 100) / 60)) } }

    /// Thirty cells, matching the reference: each step is one grade of RSSI
    /// across the −100…−40 dBm ruler, so 27 filled reads as "one notch under
    /// full" rather than as a percentage.
    static let cellCount = 30

    /// An empty cell. A solid muted fill rather than the hairline — see the
    /// note in `body`: at hairline weight the tail of a nearly-full row
    /// disappeared.
    static var emptyCell: Color { Theme.cardFill(0.18) }

    var body: some View {
        VStack(spacing: 6) {
            // Thirty **equal** rounded squares — not a ramp. The cells used to
            // grow by 0.7pt per index, which drew a staircase and made the
            // signal read as a bar chart whose right-hand cells were "taller"
            // than its left. The reference is a row of squares: the count of
            // filled cells *is* the reading, so the squares must not also encode
            // one. Empty cells take a solid muted fill (`Theme.cardFill`), not
            // the hairline: at a hairline weight the remaining three cells of a
            // 27/30 reading vanished and the row looked like it simply stopped.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<Self.cellCount, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(geometry.size.width > 0
                                      && position.map { Double(index) / Double(Self.cellCount - 1) <= $0 } == true
                                      ? Theme.chartBlue : Self.emptyCell)
                                .frame(maxWidth: .infinity)
                                .frame(height: 20)
                                .padding(.horizontal, 3)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    if let position {
                        Circle().fill(Theme.chartBlue).frame(width: 6, height: 6)
                            .offset(x: max(0, min(geometry.size.width - 6, (geometry.size.width - 6) * position)), y: -24)
                    }
                }
            }
            .frame(height: 40)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: rssi)
            HStack {
                Text("−100 · 弱")
                Spacer()
                Text("−70")
                Spacer()
                Text("−40 · 强")
            }.font(Theme.Font.micro).foregroundColor(Theme.textSecondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rssi.map { "Wi-Fi 信号 \($0) dBm，刻度负 100 至负 40 dBm" } ?? "Wi-Fi 信号暂无读数")
    }
}
