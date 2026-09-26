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
                    Text(gpu ? "图形处理器 · 整体负载" : "\(sampler.host.coreCount) 个逻辑核心 · 整体负载").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    RollingNumberText(String(format: "%.1f%%", load)).font(Theme.Font.displayMetric).monospacedDigit()
                }
                Spacer()
            }
            LoadHistoryChart(values: values, tint: tint)
            HStack {
                Label(sampler.host.temperatureLabel(celsius: gpu ? sampler.host.gpuTemperatureCelsius : sampler.host.cpuTemperatureCelsius) ?? "温度暂无读数", systemImage: "thermometer.medium")
                Spacer()
                Text("峰值 \(Int((values.max() ?? 0) * 100))%")
            }.font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            Text(caption)
                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }.padding(22).frame(width: 420).background(Theme.cardSurface)
    }
}

struct ConnectionDetailPanel: View {
    private let sampler = ProcessSampler.shared
    private let audio = AudioAccessoryMonitor.shared
    var body: some View {
        let host = sampler.host
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("连接地图").font(Theme.Font.displayHero); Spacer(); Button("刷新") { audio.refreshNow() } }
            HStack(spacing: 0) {
                node("Wi-Fi", detail: host.wifiOn ? (host.wifiName.isEmpty ? "已开启" : host.wifiName) : "未开启", symbol: "wifi", active: host.wifiOn)
                Rectangle().fill(Theme.chartBlue.opacity(0.4)).frame(height: 2)
                node(HardwareIdentity.shortName, detail: "本机", symbol: "laptopcomputer", active: true)
                Rectangle().fill(Theme.chartPurple.opacity(0.4)).frame(height: 2)
                node("蓝牙", detail: host.bluetoothOn ? "已开启" : "未开启", symbol: "antenna.radiowaves.left.and.right", active: host.bluetoothOn)
            }.frame(height: 110)
            if host.wifiOn && host.wifiRSSI < 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("信号强度"); Spacer(); RollingNumberText("\(host.wifiRSSI) dBm").monospacedDigit() }
                    GeometryReader { proxy in
                        Capsule().fill(Theme.hairline)
                        Capsule().fill(LinearGradient(colors: [Theme.chartBlue, Theme.chartGreen], startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * CGFloat(min(1, max(0, Double(host.wifiRSSI + 100) / 60))))
                    }.frame(height: 8)
                    HStack { Text("弱 · −100"); Spacer(); Text("强 · −40") }.font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                }
            }
            HStack(spacing: 24) { WiFiConnectionMark(host: host); AirDropConnectionMark() }
            if host.wiredOn { Label("以太网已接入", systemImage: "network").font(Theme.Font.chrome) }
            if audio.accessories.isEmpty {
                Text("尚未检测到耳机。连接后自动更新，电量以设备报告为准。").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 14) {
                        ForEach(audio.accessories) { accessory in
                            VStack(spacing: 7) {
                                ZStack {
                                    Circle().stroke(Theme.hairline, lineWidth: 5)
                                    Circle().trim(from: 0, to: CGFloat(accessory.headline ?? 0) / 100)
                                        .stroke(Theme.chartPurple, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                                    Text(accessory.headline.map { "\($0)%" } ?? "未知").font(Theme.Font.chromeEmph)
                                }.frame(width: 62, height: 62)
                                Text(accessory.name).lineLimit(2)
                                Text(accessory.connection.label).foregroundColor(Theme.textSecondary)
                            }.font(Theme.Font.caption).padding(8)
                        }
                    }
                }.frame(maxHeight: 160)
            }
        }.padding(22).frame(width: 440).background(Theme.cardSurface)
    }
    private func node(_ title: String, detail: String, symbol: String, active: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundColor(active ? Theme.chartBlue : Theme.textSecondary)
            Text(title).font(Theme.Font.chromeEmph)
            Text(detail).font(Theme.Font.caption).foregroundColor(Theme.textSecondary).lineLimit(2)
        }.frame(width: 110)
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
