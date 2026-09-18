import SwiftUI

/// Uiverse connected KPI bar — icon + number, 1px gaps, one shared track.
/// Popup machine metrics belong here: four facts, not four cards.
/// Pattern: uiverse.io connected stats / segmented toolbar (gap-px group).
struct MachineKpiStrip: View {
    private let sampler = ProcessSampler.shared
    private let fanMonitor = FanMonitor.shared

    var body: some View {
        HStack(spacing: 1) {
            kpi(icon: "cpu", label: "CPU",
                value: String(format: "%.0f%%", sampler.host.cpu),
                tint: Theme.chartGreen)
            kpi(icon: "square.3.layers.3d", label: "GPU",
                value: String(format: "%.0f%%", sampler.host.gpu),
                tint: Theme.chartBlue)
            kpi(icon: "memorychip", label: "内存",
                value: memShort,
                tint: Theme.chartAmber)
            Button(action: toggleFanMax) {
                kpiLabel(icon: "fanblades", label: "风扇",
                         value: fanShort, tint: Theme.claude)
            }
            .buttonStyle(.uiversePress)
            .help(fansAtMax ? "恢复自动风速" : "最大风速")
        }
        .background(Theme.hairline)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .onAppear {
            ProcessSampler.shared.setScope(.popup, active: true)
            fanMonitor.start()
        }
        .onDisappear {
            ProcessSampler.shared.setScope(.popup, active: false)
            fanMonitor.stop()
        }
    }

    private func kpi(icon: String, label: String, value: String, tint: Color) -> some View {
        kpiLabel(icon: icon, label: label, value: value, tint: tint)
    }

    private func kpiLabel(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.textTertiary())
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardSurface)
        .help(helpText())
    }

    private var memShort: String {
        ProcessSampler.Snapshot(memoryBytes: sampler.host.memoryUsed).memoryLabel
            .replacingOccurrences(of: " GB", with: "G")
            .replacingOccurrences(of: " MB", with: "M")
    }

    private var fanShort: String {
        guard !fanMonitor.fans.isEmpty else { return "—" }
        return "\(fanMonitor.fans.map(\.rpm).reduce(0, +))"
    }

    private var fansAtMax: Bool {
        guard !fanMonitor.fans.isEmpty else { return false }
        return fanMonitor.fans.allSatisfy { !$0.mode.isAutomatic }
    }

    private func toggleFanMax() {
        if fansAtMax {
            fanMonitor.resetAllToAutomatic()
        } else {
            for fan in fanMonitor.fans {
                fanMonitor.setManual(fan.id, rpm: fan.maxRPM)
            }
        }
    }

    private func helpText() -> String {
        var host = "本机  CPU \(Int(sampler.host.cpu.rounded()))%  GPU \(Int(sampler.host.gpu.rounded()))%  \(sampler.host.memoryLabel)"
        if let cpuT = sampler.host.temperatureLabel(celsius: sampler.host.cpuTemperatureCelsius) {
            host += "  CPU \(cpuT)"
        }
        if let gpuT = sampler.host.temperatureLabel(celsius: sampler.host.gpuTemperatureCelsius) {
            host += "  GPU \(gpuT)"
        }
        return host
    }
}

/// 系统资源：标题数字为整机（全核 CPU、IOKit GPU、物理内存、温度）。
/// 色条为 ClaudeBar / CC / Cursor / Codex 占整机的 CPU 与内存比例。
struct ResourceStrip: View {
    private let sampler = ProcessSampler.shared
    private let fanMonitor = FanMonitor.shared
    var dense: Bool = false

    var body: some View {
        EqualRowGrid(spacing: Theme.Space.gridGap, minColumnWidth: 0, fixedColumns: 3) {
            meter("CPU",
                  icon: "cpu",
                  hero: String(format: "%.0f%%", sampler.host.cpu),
                  heroTint: Theme.chartGreen,
                  unit: nil,
                  secondary: nil,
                  trail: sampler.trail.map(\.cpu),
                  chart: .chip,
                  tint: Theme.chartGreen,
                  shares: cpuSegments,
                  caption: cpuTempCaption,
                  pill: ("\(sampler.host.coreCount) 核", Theme.textSecondary),
                  tempColor: cpuTempColor)
            meter("GPU",
                  icon: "square.3.layers.3d",
                  hero: String(format: "%.0f%%", sampler.host.gpu),
                  heroTint: Theme.textPrimary,
                  unit: nil,
                  secondary: nil,
                  trail: sampler.trail.map(\.gpu),
                  chart: .bars,
                  tint: Theme.chartBlue,
                  shares: gpuSegments,
                  caption: gpuCaption,
                  pill: ("本机", Theme.textSecondary),
                  tempColor: gpuTempColor)
            meter("内存",
                  icon: "memorychip",
                  hero: String(format: "%.0f%%", memPercent),
                  heroTint: Theme.textPrimary,
                  unit: nil,
                  secondary: nil,
                  trail: sampler.trail.map(\.mem),
                  chart: .line,
                  tint: Theme.chartAmber,
                  shares: memSegments,
                  caption: "已使用 \(sampler.host.memoryLabel)",
                  pill: memoryPill)
            meter("硬盘",
                  icon: "internaldrive",
                  hero: String(format: "%.0f%%", sampler.host.diskPercent),
                  heroTint: Theme.textPrimary,
                  unit: nil,
                  secondary: nil,
                  trail: [min(1, sampler.host.diskPercent / 100)],
                  chart: .disk,
                  tint: Theme.chartPurple,
                  shares: [],
                  caption: "已使用 \(sampler.host.diskLabel)",
                  pill: diskPill)
            meter("连接",
                  icon: "antenna.radiowaves.left.and.right",
                  hero: linkHero,
                  heroTint: Theme.textPrimary,
                  unit: nil,
                  secondary: nil,
                  trail: [],
                  chart: .links,
                  tint: Theme.chartBlue,
                  shares: [],
                  caption: linkCaption,
                  pill: linkPill)
            meter("风扇",
                  icon: "fanblades",
                  hero: fanHero,
                  heroTint: Theme.textPrimary,
                  unit: nil,
                  secondary: nil,
                  trail: [],
                  chart: .fans,
                  tint: Theme.claude,
                  shares: [],
                  caption: fanCaption,
                  pill: fanPill)
        }
        .onAppear {
            if dense { ProcessSampler.shared.setScope(.popup, active: true) }
            fanMonitor.start()
        }
        .onDisappear {
            if dense { ProcessSampler.shared.setScope(.popup, active: false) }
            fanMonitor.stop()
        }
    }

    private var fanHero: String {
        guard !fanMonitor.fans.isEmpty else { return "—" }
        let rpms = fanMonitor.fans.prefix(2).map(\.rpm)
        if rpms.count == 2 { return "\(rpms[0]) · \(rpms[1])" }
        return "\(rpms[0])"
    }

    private var fanCaption: String {
        guard !fanMonitor.fans.isEmpty else { return "未检测到风扇" }
        let manual = fanMonitor.fans.filter { !$0.mode.isAutomatic }.count
        if manual > 0 { return "\(manual)/\(fanMonitor.fans.count) 手动" }
        return "自动"
    }

    private var fansAtMax: Bool {
        guard !fanMonitor.fans.isEmpty else { return false }
        return fanMonitor.fans.allSatisfy { !$0.mode.isAutomatic }
    }

    private var memPercent: Double {
        guard sampler.host.memoryTotal > 0 else { return 0 }
        return Double(sampler.host.memoryUsed) / Double(sampler.host.memoryTotal) * 100
    }

    private func temperatureColor(_ celsius: Double?) -> Color? {
        sampler.host.temperatureColor(celsius: celsius)
    }

    private var cpuTempColor: Color? { temperatureColor(sampler.host.cpuTemperatureCelsius) }
    private var gpuTempColor: Color? { temperatureColor(sampler.host.gpuTemperatureCelsius) }

    private var cpuTempCaption: String {
        if let temp = sampler.host.temperatureLabel(celsius: sampler.host.cpuTemperatureCelsius) {
            return "\(cpuCaption) · \(temp)"
        }
        return cpuCaption
    }

    private func loadPill(_ percent: Double) -> (String, Color) {
        if percent >= 90 { return ("高负载", Theme.statusError) }
        if percent >= 70 { return ("偏高", Theme.statusWarning) }
        if percent < 35 { return ("低负载", Theme.statusSuccess) }
        return ("正常", Theme.statusSuccess)
    }

    private var memoryPill: (String, Color) {
        if sampler.host.memoryPressureLevel >= 4 { return ("严重", Theme.statusError) }
        if sampler.host.memoryPressureLevel >= 2 || memPercent >= 75 { return ("偏高", Theme.statusWarning) }
        return ("正常", Theme.statusSuccess)
    }

    private var fanPill: (String, Color) {
        guard !fanMonitor.fans.isEmpty else { return ("未检测", Theme.statusIdle) }
        if fansAtMax { return ("最大", Theme.statusWarning) }
        if fanMonitor.fans.contains(where: { !$0.mode.isAutomatic }) { return ("手动", Theme.statusWarning) }
        return ("自动", Theme.statusSuccess)
    }

    private var diskPill: (String, Color) {
        let p = sampler.host.diskPercent
        if p >= 90 { return ("将满", Theme.statusError) }
        if p >= 75 { return ("偏高", Theme.statusWarning) }
        return ("正常", Theme.statusSuccess)
    }

    private var linkHero: String {
        let host = sampler.host
        if host.wifiOn, !host.wifiName.isEmpty { return host.wifiName }
        if host.wifiOn { return "Wi-Fi" }
        if host.wiredOn { return "有线" }
        if host.bluetoothOn { return "蓝牙" }
        return "离线"
    }

    private var linkCaption: String {
        let host = sampler.host
        var parts: [String] = []
        if host.wifiOn {
            parts.append(host.wifiRSSI < 0 ? "Wi-Fi \(host.wifiRSSI) dBm" : "Wi-Fi 开")
        } else {
            parts.append("Wi-Fi 关")
        }
        parts.append(host.bluetoothOn ? "蓝牙 开" : "蓝牙 关")
        if host.wiredOn { parts.append("有线") }
        return parts.joined(separator: " · ")
    }

    private var linkPill: (String, Color) {
        let host = sampler.host
        if host.wifiOn || host.wiredOn { return ("在线", Theme.statusSuccess) }
        if host.bluetoothOn { return ("本机", Theme.textSecondary) }
        return ("离线", Theme.statusIdle)
    }

    private var cpuSegments: [ShareSegment] {
        sampler.shares.map { ShareSegment(id: $0.id, label: $0.label, ratio: $0.cpuShare, tint: tint(for: $0.id)) }
    }

    private var memSegments: [ShareSegment] {
        sampler.shares.map { ShareSegment(id: $0.id, label: $0.label, ratio: $0.memShare, tint: tint(for: $0.id)) }
    }

    private var gpuSegments: [ShareSegment] {
        [ShareSegment(id: "host", label: "本机",
                      ratio: min(1, sampler.host.gpu / 100), tint: Theme.external)]
    }

    private var cpuCaption: String { familyCaption(kind: .cpu) }
    private var gpuCaption: String {
        var parts = ["本机 \(Int(sampler.host.gpu.rounded()))%"]
        if let temp = sampler.host.temperatureLabel(celsius: sampler.host.gpuTemperatureCelsius) {
            parts.append(temp)
        }
        return parts.joined(separator: " · ")
    }

    private var memCaption: String {
        if sampler.host.memoryPressureLevel >= 4 { return "内存压力 · 严重 · \(sampler.host.memoryLabel)" }
        if sampler.host.memoryPressureLevel >= 2 { return "内存压力 · 偏高 · \(sampler.host.memoryLabel)" }
        return sampler.host.memoryLabel
    }

    private func tint(for id: String) -> Color {
        switch id {
        case "claudeBar": return Theme.textSecondary
        case "cursor": return Theme.cursor
        case "claude": return Theme.claude
        case "codex": return Theme.codex
        default: return Theme.external
        }
    }

    private enum ChartKind { case bars, line, chip, fans, disk, links }

    private func meter(
        _ label: String,
        icon: String,
        hero: String,
        heroTint: Color,
        unit: String?,
        secondary: String?,
        trail: [Double],
        chart: ChartKind,
        tint: Color,
        shares: [ShareSegment],
        caption: String,
        pill: (String, Color),
        iconAction: (() -> Void)? = nil,
        iconActive: Bool? = nil,
        iconHelp: String? = nil,
        tempColor: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                GlyphWell(name: icon, tint: Theme.textSecondary, size: 22)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 4)
                StatusPill(label: pill.0, tint: pill.1)
                if let iconAction {
                    Button(action: iconAction) {
                        Image(systemName: "snowflake")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(iconActive == true ? Theme.chartBlue : Theme.textTertiary())
                    }
                    .buttonStyle(.plain)
                    .help(iconHelp ?? "")
                }
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(hero)
                            .font(Theme.Font.displayMetric)
                            .monospacedDigit()
                            .foregroundColor(tempColor ?? heroTint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let unit {
                            Text(unit)
                                .font(Theme.Font.tileLabel)
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundColor(tempColor ?? Theme.textTertiary())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Group {
                    switch chart {
                    case .bars:
                        EqualizerBars(values: trail, tint: tint)
                    case .line:
                        WaveTank(progress: trail.last ?? 0, tint: tint, phase: trail.count)
                    case .chip:
                        CPUChip(load: (trail.last ?? 0), tint: tint)
                    case .fans:
                        CompactFanPair(fans: fanMonitor.fans, onToggle: toggleFan)
                    case .disk:
                        WaveTank(progress: trail.last ?? 0, tint: tint, phase: trail.count)
                    case .links:
                        LinkLamps(
                            wifiOn: sampler.host.wifiOn,
                            bluetoothOn: sampler.host.bluetoothOn,
                            wiredOn: sampler.host.wiredOn)
                    }
                }
                .frame(width: dense ? 72 : 88, height: dense ? 52 : 56)
                .clipped()
                .transaction { tx in
                    if chart != .fans { tx.animation = nil }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: dense ? 112 : 124, maxHeight: .infinity, alignment: .topLeading)
        .tile(dense: dense)
        .help(helpText())
    }

    private func toggleFan(_ fan: FanInfo) {
        if fan.mode.isAutomatic {
            fanMonitor.setMaxSpeed(fan.id)
        } else {
            fanMonitor.setAutomatic(fan.id)
        }
    }

    private enum CaptionKind { case cpu, mem }

    private func familyCaption(kind: CaptionKind) -> String {
        let parts: [String] = sampler.shares.compactMap { share in
            switch kind {
            case .cpu:
                let pct = share.cpuShare * 100
                guard pct >= 0.4 else { return nil }
                return "\(share.label) \(Int(pct.rounded()))%"
            case .mem:
                guard share.memoryBytes > 4 * 1024 * 1024 else { return nil }
                return "\(share.label) \(ProcessSampler.Snapshot(memoryBytes: share.memoryBytes).memoryLabel)"
            }
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func helpText() -> String {
        var lines = sampler.shares.map { share -> String in
            let cpu = Int((share.cpuShare * 100).rounded())
            let mem = ProcessSampler.Snapshot(memoryBytes: share.memoryBytes).memoryLabel
            return "\(share.label)  CPU \(cpu)%  \(mem)"
        }
        var hostLine = "本机  CPU \(Int(sampler.host.cpu.rounded()))%  GPU \(Int(sampler.host.gpu.rounded()))%  \(sampler.host.memoryLabel)"
        if let cpuT = sampler.host.temperatureLabel(celsius: sampler.host.cpuTemperatureCelsius) {
            hostLine += "  CPU \(cpuT)"
        }
        if let gpuT = sampler.host.temperatureLabel(celsius: sampler.host.gpuTemperatureCelsius) {
            hostLine += "  GPU \(gpuT)"
        }
        lines.insert(hostLine, at: 0)
        return lines.joined(separator: "\n")
    }
}

/// 风扇转速只读条：实时跟随轮询刷新（概括处展示用，调速在设置界面）。
private struct FanTachometer: View {
    let monitor: FanMonitor
    var tint: Color

    var body: some View {
        let rpm = monitor.fans.map(\.rpm).reduce(0, +)
        let maxRPM = max(monitor.fans.map(\.maxRPM).reduce(0, +), 1)
        ArcGauge(progress: min(1, Double(rpm) / Double(maxRPM)), tint: tint, ticks: true)
    }
}

private struct ShareSegment: Identifiable {
    var id: String
    var label: String
    var ratio: Double
    var tint: Color
}

/// Uiverse-style circular progress: 240° arc, round cap, optional ticks.
private struct ArcGauge: View {
    var progress: Double
    var tint: Color
    var ticks: Bool = false

    var body: some View {
        Canvas { ctx, size in
            let clamped = min(max(progress, 0), 1)
            let inset: CGFloat = 6
            let r = min(size.width, size.height) / 2 - inset
            let c = CGPoint(x: size.width / 2, y: size.height / 2 + 4)
            let startDeg: Double = -210
            let sweepDeg: Double = 240
            let start = Angle.degrees(startDeg)
            let end = Angle.degrees(startDeg + sweepDeg * clamped)
            let full = Angle.degrees(startDeg + sweepDeg)

            if ticks {
                for i in 0...8 {
                    let a = Angle.degrees(startDeg + sweepDeg * Double(i) / 8)
                    let rad = CGFloat(a.radians)
                    var tick = Path()
                    tick.move(to: CGPoint(x: c.x + cos(rad) * (r - 5), y: c.y + sin(rad) * (r - 5)))
                    tick.addLine(to: CGPoint(x: c.x + cos(rad) * (r + 1), y: c.y + sin(rad) * (r + 1)))
                    ctx.stroke(tick, with: .color(Theme.cardFill(0.18)), lineWidth: 1)
                }
            }

            var track = Path()
            track.addArc(center: c, radius: r, startAngle: start, endAngle: full, clockwise: false)
            ctx.stroke(track, with: .color(Theme.cardFill(0.12)),
                       style: StrokeStyle(lineWidth: 7, lineCap: .round))

            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
            ctx.stroke(arc, with: .color(tint),
                       style: StrokeStyle(lineWidth: 7, lineCap: .round))

            let rad = CGFloat(end.radians)
            let cap = CGRect(x: c.x + cos(rad) * r - 3.5, y: c.y + sin(rad) * r - 3.5, width: 7, height: 7)
            ctx.fill(Path(ellipseIn: cap), with: .color(tint))
        }
    }
}

/// Signal / equalizer bars — interpolated from the trail so GPU looks alive
/// without a 60fps TimelineView.
private struct EqualizerBars: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            let n = 18
            let gap: CGFloat = 2
            let w = max(2, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            for i in 0..<n {
                let t = Double(i) / Double(max(n - 1, 1))
                var v = interpolate(values, t: t)
                v = min(1, max(0.08, v + 0.06 * sin(t * 9 + v * 6)))
                let h = max(4, size.height * CGFloat(v))
                let x = CGFloat(i) * (w + gap)
                let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2, style: .continuous),
                         with: .color(tint.opacity(0.40 + 0.60 * v)))
            }
        }
    }
}

/// Memory as a liquid tank: fill + a data-driven sine surface.
private struct WaveTank: View {
    var progress: Double
    var tint: Color
    var phase: Int

    var body: some View {
        Canvas { ctx, size in
            let p = min(max(progress, 0), 1)
            let rect = CGRect(origin: .zero, size: size)
            let tank = Path(roundedRect: rect, cornerRadius: 8, style: .continuous)
            ctx.fill(tank, with: .color(Theme.cardFill(0.08)))
            ctx.clip(to: tank)

            let base = size.height * (1 - CGFloat(p))
            let amp: CGFloat = 3.5
            let phi = CGFloat(phase) * 0.55
            var wave = Path()
            wave.move(to: CGPoint(x: 0, y: size.height))
            wave.addLine(to: CGPoint(x: 0, y: base))
            var x: CGFloat = 0
            while x <= size.width {
                let y = base + sin(x / 9 + phi) * amp
                wave.addLine(to: CGPoint(x: x, y: y))
                x += 2
            }
            wave.addLine(to: CGPoint(x: size.width, y: size.height))
            wave.closeSubpath()
            ctx.fill(wave, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.55), tint.opacity(0.22)]),
                startPoint: CGPoint(x: 0, y: base),
                endPoint: CGPoint(x: 0, y: size.height)))
        }
    }
}

private func interpolate(_ values: [Double], t: Double) -> Double {
    guard !values.isEmpty else { return 0.12 }
    if values.count == 1 { return values[0] }
    let f = min(max(t, 0), 1) * Double(values.count - 1)
    let i = Int(f)
    let n = min(i + 1, values.count - 1)
    let frac = f - Double(i)
    return values[i] * (1 - frac) + values[n] * frac
}

private struct ShareStack: View {
    let segments: [ShareSegment]
    var height: CGFloat

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments.filter { $0.ratio > 0.004 }) { seg in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(seg.tint)
                        .frame(width: max(2, geo.size.width * seg.ratio), height: height)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// One-line CPU / memory for a tracked session or app family.
struct SessionLoadChip: View {
    private let sampler = ProcessSampler.shared
    let key: ProcessSampler.Key
    var compact: Bool = false
    var shared: Bool = false

    var body: some View {
        let snap = sampler.byKey[key]
        Text(snap?.loadLabel ?? "—")
            .font(compact ? Theme.Font.microMono : Theme.Font.captionMono)
            .monospacedDigit()
            .foregroundColor(snap == nil ? Theme.textTertiary(0.45) : Theme.textSecondary)
            .lineLimit(1)
            .help(shared
                  ? "Cursor 为共享进程，显示整个应用的 CPU 与内存"
                  : "该会话进程的 CPU 与内存")
    }
}

/// Dashboard / sessions pages need attribution sampling while visible.
struct ResourceMonitorScope: ViewModifier {
    let scope: ProcessSampler.MonitorScope

    func body(content: Content) -> some View {
        content
            .onAppear { ProcessSampler.shared.setScope(scope, active: true) }
            .onDisappear { ProcessSampler.shared.setScope(scope, active: false) }
    }
}

extension View {
    func resourceMonitorScope(_ scope: ProcessSampler.MonitorScope) -> some View {
        modifier(ResourceMonitorScope(scope: scope))
    }
}
