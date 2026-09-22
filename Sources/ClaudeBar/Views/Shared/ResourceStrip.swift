import SwiftUI

/// Connected KPI bar — label above value, equal columns, one shared track.
/// Equal-width columns keep every metric legible when headphones connect.
/// Pattern: uiverse.io connected stats / segmented toolbar (gap-px group).
struct MachineKpiStrip: View {
    private let sampler = ProcessSampler.shared
    private let fanMonitor = FanMonitor.shared
    private let audioMonitor = AudioAccessoryMonitor.shared

    var body: some View {
        EqualRowGrid(spacing: 1, minColumnWidth: 0, fixedColumns: hasHeadset ? 5 : 4) {
            kpi(icon: "cpu", label: "CPU",
                value: String(format: "%.0f%%", sampler.host.cpu),
                tint: Theme.chartGreen)
            kpi(icon: "square.3.layers.3d", label: "GPU",
                value: String(format: "%.0f%%", sampler.host.gpu),
                tint: Theme.chartBlue)
            kpi(icon: "memorychip", label: "内存",
                value: memShort,
                tint: Theme.chartAmber)
            // The headphone cell exists only while a headset is actually in
            // use. Nearby / charging-in-the-case readings stay in the 连接
            // tooltip, they do not steal a column here.
            if let accessory = audioMonitor.accessories.first,
               accessory.connection == .inUse {
                audioKpi
            }
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
            audioMonitor.start()
        }
        .onDisappear {
            ProcessSampler.shared.setScope(.popup, active: false)
            fanMonitor.stop()
            audioMonitor.stop()
        }
    }

    private func kpi(icon: String, label: String, value: String, tint: Color,
                     help: String? = nil) -> some View {
        kpiLabel(icon: icon, label: label, value: value, tint: tint, help: help)
    }

    private func kpiLabel(icon: String, label: String, value: String, tint: Color,
                          help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                SignatureGlyph(name: icon, tint: tint, size: 15)
                Text(label)
                    .font(Theme.Font.kpi)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: .infinity, alignment: .leading)
        .background(Theme.cardSurface)
        .help(help ?? helpText())
        .accessibilityElement(children: .combine)
    }

    private var hasHeadset: Bool {
        audioMonitor.accessories.first?.connection == .inUse
    }

    // MARK: - 耳机 (popup)

    /// The popup's one-line headphone readout: the product glyph, the worse
    /// bud's percentage, and nothing else. The popup already spends its width
    /// on four machine facts; the L/R/case breakdown lives in the tooltip
    /// rather than as a fifth column of numbers.
    private var audioShort: String {
        guard let accessory = audioMonitor.accessories.first, let low = accessory.headline else {
            return "—"
        }
        return "\(low)%"
    }

    /// The popup cell draws the same combined glyph as the 连接 meter (ring =
    /// battery, arc = Wi-Fi, dots = lanes), so the two surfaces read as one
    /// design rather than a symbol here and a gauge there.
    private var audioLevel: Double? {
        audioMonitor.accessories.first?.headline.map { Double($0) / 100 }
    }

    private var audioCharging: Bool {
        audioMonitor.accessories.first?.isCharging == true
    }

    private var audioHelp: String {
        guard let accessory = audioMonitor.accessories.first else {
            return audioMonitor.unavailableReason ?? "未连接耳机"
        }
        var parts: [String] = [accessory.name]
        if let left = accessory.left?.percent { parts.append("左 \(left)%") }
        if let right = accessory.right?.percent { parts.append("右 \(right)%") }
        if let level = accessory.caseLevel?.percent { parts.append("充电盒 \(level)%") }
        if parts.count == 1, let combined = accessory.combined?.percent { parts.append("\(combined)%") }
        if accessory.isCharging == true { parts.append("充电中") }
        // State the connection explicitly: the whole point of the three-state
        // model is that "has a reading" and "is connected" are different facts,
        // and the help text is where a user goes to resolve the ambiguity.
        parts.append(accessory.connection.label)
        if accessory.isStale { parts.append("读数已过期") }
        return parts.joined(separator: "  ")
    }

    /// The headphone cell.
    ///
    /// The mark here is the *product*, not a gauge: the popup's other cells are
    /// text-first, so this one carries the real shape a user recognises. It is
    /// deliberately not the 连接 card's six-mark row — the popup has four machine
    /// facts in this strip and no room for a second dashboard, so the L/R/case
    /// breakdown stays in the tooltip and only the worse bud's level is printed.
    private var audioKpi: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                HeadsetBadge(accessory: audioMonitor.accessories.first,
                             charging: audioCharging, level: audioLevel)
                    .frame(width: 13, height: 13)
                Text("耳机")
                    .font(Theme.Font.kpi)
                    .foregroundColor(Theme.textSecondary)
            }
            Text(audioShort)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: .infinity, alignment: .leading)
        .background(Theme.cardSurface)
        .help(audioHelp)
        .accessibilityElement(children: .combine)
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
    private let audioMonitor = AudioAccessoryMonitor.shared
    var dense: Bool = false
    @State private var showMemory = false
    @State private var showDisk = false

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
            // 连接 is not a single metric and must not be drawn as one. It is
            // the set of things this Mac is linked to right now — Wi-Fi, this
            // Mac's own power, Ethernet if a cable is live, and a headset only
            // while it is actually in use. The generic `meter` shape (one hero
            // number, one caption) forced a choice of which fact to lead with,
            // and the headset won that choice simply because it arrives first,
            // so the card spent its headline on 100% while the Wi-Fi network
            // name — the thing the card is named for — was nowhere on screen.
            LinkCard(host: sampler.host,
                     accessory: audioMonitor.accessories.first,
                     accessoryCount: audioMonitor.accessories.count,
                     unavailableReason: audioMonitor.unavailableReason,
                     dense: dense)
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
            audioMonitor.start()
        }
        .onDisappear {
            if dense { ProcessSampler.shared.setScope(.popup, active: false) }
            fanMonitor.stop()
            audioMonitor.stop()
        }
    }

    // MARK: - 耳机

    /// One number: the lower bud, because that is the one that runs out first.
    private var audioHero: String {
        guard let accessory = audioMonitor.accessories.first, let low = accessory.headline else {
            return "—"
        }
        return "\(low)%"
    }

    /// The full picture in one line, which is where a three-source reading
    /// earns its keep: L/R/Case only ever all arrive together from the logs.
    private var audioCaption: String {
        guard let accessory = audioMonitor.accessories.first else {
            return audioMonitor.unavailableReason ?? "未连接"
        }
        var parts: [String] = []
        if let left = accessory.left?.percent { parts.append("左 \(left)%") }
        if let right = accessory.right?.percent { parts.append("右 \(right)%") }
        if let level = accessory.caseLevel?.percent { parts.append("盒 \(level)%") }
        if parts.isEmpty, let combined = accessory.combined?.percent { parts.append("\(combined)%") }
        let extra = audioMonitor.accessories.count > 1 ? " · 等 \(audioMonitor.accessories.count) 台" : ""
        return parts.isEmpty ? accessory.name : parts.joined(separator: " ") + extra
    }

    private var audioPill: (String, Color) {
        guard let accessory = audioMonitor.accessories.first else {
            return ("未连接", Theme.Ink.idle)
        }
        // Same policy as `linkPill`, and stated once here so the two meters
        // cannot drift apart: green means the headset is *in use*; a case
        // charging on the desk reports its level but stays grey.
        switch accessory.connection {
        case .inUse:
            if accessory.isCharging == true { return ("充电中", Theme.Ink.success) }
            if accessory.isStale { return ("已过期", Theme.Ink.warning) }
            return ("已连接", Theme.Ink.success)
        case .nearby:
            if accessory.isCharging == true { return ("充电中", Theme.textSecondary) }
            if accessory.isStale { return ("已过期", Theme.Ink.warning) }
            return ("未连接", Theme.textSecondary)
        case .absent:
            return ("已离开", Theme.Ink.idle)
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

    // These tuples land in `StatusPill`, i.e. they render as *text*, so they
    // carry `Theme.Ink` rather than the raw signal hues (the latter measure
    // 1.8–3.4:1 on the ice canvas — an amber "偏高" was barely legible).

    private func loadPill(_ percent: Double) -> (String, Color) {
        if percent >= 90 { return ("高负载", Theme.Ink.error) }
        if percent >= 70 { return ("偏高", Theme.Ink.warning) }
        if percent < 35 { return ("低负载", Theme.Ink.success) }
        return ("正常", Theme.Ink.success)
    }

    private var memoryPill: (String, Color) {
        if sampler.host.memoryPressureLevel >= 4 { return ("严重", Theme.Ink.error) }
        if sampler.host.memoryPressureLevel >= 2 || memPercent >= 75 { return ("偏高", Theme.Ink.warning) }
        return ("正常", Theme.Ink.success)
    }

    private var fanPill: (String, Color) {
        guard !fanMonitor.fans.isEmpty else { return ("未检测", Theme.Ink.idle) }
        if fansAtMax { return ("最大", Theme.Ink.warning) }
        if fanMonitor.fans.contains(where: { !$0.mode.isAutomatic }) { return ("手动", Theme.Ink.warning) }
        return ("自动", Theme.Ink.success)
    }

    private var diskPill: (String, Color) {
        let p = sampler.host.diskPercent
        if p >= 90 { return ("将满", Theme.Ink.error) }
        if p >= 75 { return ("偏高", Theme.Ink.warning) }
        return ("正常", Theme.Ink.success)
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

    private enum ChartKind {
        case bars, line, chip, fans, disk
    }

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
        let content = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                InstrumentBadge(kind: InstrumentGlyph.kind(for: icon) ?? .link)
                Text(label)
                    .font(Theme.Font.chrome)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 4)
                StatusPill(label: pill.0, tint: pill.1)
                if label == "内存" || label == "硬盘" {
                    Image(systemName: label == "内存" ? "list.bullet" : "chart.pie")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
                if let iconAction {
                    Button(action: iconAction) {
                        Image(systemName: "snowflake")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(iconActive == true ? Theme.Ink.claude : Theme.textTertiary())
                    }
                    .buttonStyle(.plain)
                    .help(iconHelp ?? "")
                    .accessibilityLabel(iconHelp ?? icon)
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
                        .font(Theme.Font.tileLabel)
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
                        InstrumentGlyph(kind: .memory, tint: tint, level: trail.last ?? 0, detailed: true)
                    case .chip:
                        CPUChip(load: (trail.last ?? 0), tint: tint)
                    case .fans:
                        CompactFanPair(fans: fanMonitor.fans, onToggle: toggleFan)
                    case .disk:
                        InstrumentGlyph(kind: .disk, tint: tint, level: trail.last ?? 0, detailed: true)
                    }
                }
                // The tile's mark slot: the mini charts are ornaments sized to
                // the slot by design.
                .frame(width: dense ? 88 : 112, height: dense ? 68 : 80)
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
        return Group {
            if label == "内存" {
                Button { showMemory = true } label: { content }
                    .buttonStyle(.pressable)
                    .help("查看各进程的内存占用")
                    .popover(isPresented: $showMemory) { MemoryDetailPanel() }
            } else if label == "硬盘" {
                Button { showDisk = true } label: { content }
                    .buttonStyle(.pressable)
                    .help("查看启动磁盘占用图表")
                    .popover(isPresented: $showDisk) { DiskUsagePanel() }
            } else {
                content
            }
        }
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

/// The 连接 card: what this Mac is attached to, drawn as one tidy row of large
/// marks rather than a paragraph with figures beside it.
///
/// The card answers one question — *what am I linked to right now* — and every
/// answer is a **state an icon can carry on its own**. Two marks are always
/// present because the questions they answer always have an answer: Wi-Fi
/// (up / down / how strong) and this Mac's own power. Everything else is
/// hardware that comes and goes — Ethernet only with a live cable, a headset
/// only while it is actually in use — so those marks are *absent* when the
/// hardware is, rather than drawn dim and asking to be decoded. A Bluetooth
/// radio toggle is not a link in this sense (it does not say what is attached),
/// so it is not a mark; the headset *is* the Bluetooth fact worth showing.
///
/// The row is `ConnectLaneRow`: marks packed at natural widths with equal
/// gaps, each a centred glyph over a short caption.
private struct LinkCard: View {
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
    }

    private var header: some View {
        HStack(spacing: 6) {
            InstrumentBadge(kind: .link)
            Text("连接")
                .font(Theme.Font.chrome)
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 4)
            StatusPill(label: linkState.0, tint: linkState.1)
        }
    }

    /// Whole-card state: is this Mac on a network at all? Independent of the
    /// headset, which is a mark with its own state.
    private var linkState: (String, Color) {
        if host.wifiOn || host.wiredOn { return ("在线", Theme.Ink.success) }
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

/// Sizes for the 连接 row.
///
/// `markBox` and `gap` are the layout's two dials. `markBox` is the width every
/// mark is *drawn* into — not the same as its ink width, which is what matters:
/// see `LinkMark`. `gap` is the whitespace between neighbouring marks, and it is
/// what makes the row read as a row rather than as a pile of glyphs.
///
/// The marks are deliberately **not** given equal slots. Equal slots look tidy
/// as a silhouette but land the ink on a ragged grid, because the marks are not
/// equal: `wifi` inks 37pt, `network` 28, `battery.100` 32, and a
/// three-part headset 110. Centring those in identical boxes spreads their
/// centres by the very differences that make them unequal. The row packs at
/// natural widths and holds the *gaps* equal instead, which is the alignment the
/// eye actually reads.
fileprivate struct ConnectMetrics {
    var dial: CGFloat
    var caption: CGFloat
    var markBox: CGFloat
    var gap: CGFloat
    var rowHeight: CGFloat
    /// Height of the band under the glyph row that every mark's percentage (or
    /// caption) sits in. Reserved on every mark, headset or not — a
    /// conditional band was how the row lost its baseline.
    var labelBand: CGFloat
    var symbolSize: CGFloat {
        markBox * 0.74
    }

    /// Headset glyphs are sized from their **ink**, not from a shared point size.
    ///
    /// SF Symbols have wildly different internal padding, so equal point sizes
    /// do not produce equal-looking marks. Measured at a fixed size, `earbud.*`
    /// inks 25×38 while `airpods.chargingcase` inks 34×42 — the case is 36 %
    /// wider and 11 % taller, which is why an equal-point-size row looked like
    /// two hairline buds next to a slab. Each glyph is therefore scaled by its
    /// own ink box to a common target height, so the three parts read as one
    /// family.
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
                                  gap: crowded ? 11 : 20, rowHeight: 92,
                                  labelBand: 17)
        case .popup:
            return ConnectMetrics(dial: 30, caption: 10, markBox: 36,
                                  gap: crowded ? 9 : 18, rowHeight: 86,
                                  labelBand: 16)
        }
    }
}

fileprivate enum ConnectDensity { case page, popup }

/// The row of link marks: Wi-Fi and 电量 first (always), then Ethernet and
/// the headset only when those attachments actually exist.
///
/// One `HStack` of equal gaps. The headset contributes its parts *as marks in
/// this row* rather than as a separate cluster, so left bud / right bud / case
/// sit on the same footing as Wi-Fi. Bluetooth radio power is not a mark —
/// "is the radio on" is not "what is attached" — and a USB-plug glyph is not
/// Ethernet, which is why the old `cable.connector` lane is gone.
fileprivate struct ConnectLaneRow: View {
    var host: ProcessSampler.HostStats
    var accessory: AudioAccessoryMonitor.Accessory?
    var count: Int
    var density: ConnectDensity

    /// In use, with a number. Nearby AirPods still announce a percentage over
    /// BLE with the lid open; drawing that as a mark would look connected when
    /// the user is not wearing them. The 连接 row only shows what is attached
    /// *to this Mac right now*.
    private var headset: AudioAccessoryMonitor.Accessory? {
        guard let accessory,
              accessory.connection == .inUse,
              accessory.headline != nil else { return nil }
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
        HStack(spacing: m.gap) {
            wifi
            // Permanent: "how is this Mac powered" always has an answer.
            // Sitting next to Wi-Fi — not after the optional lanes — is what
            // keeps it from being the first thing clipped when the row fills.
            BatteryMark(host: host, metrics: m)
                .layoutPriority(1)
            if host.wiredOn {
                EthernetMark(metrics: m)
                    .transition(.scale(scale: 0.75, anchor: .center).combined(with: .opacity))
            }
            if let headset {
                HeadsetMarks(accessory: headset, count: count, metrics: m)
                    .transition(.scale(scale: 0.75, anchor: .center).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: m.rowHeight)
        .animation(Theme.Animation.snappy, value: host.wiredOn)
        .animation(Theme.Animation.snappy, value: host.batteryPercent)
        .animation(Theme.Animation.snappy, value: host.batteryCharging)
        .animation(Theme.Animation.snappy, value: headset?.id)
        .animation(Theme.Animation.snappy, value: headset?.left?.percent)
        .animation(Theme.Animation.snappy, value: headset?.right?.percent)
        .animation(Theme.Animation.snappy, value: headset?.caseLevel?.percent)
        .animation(Theme.Animation.snappy, value: headset?.isCharging)
    }

    private var wifi: some View {
        LinkMark(symbol: host.wifiOn ? WiFiBars.symbol(for: host.wifiRSSI) : "wifi.slash",
                 tint: Theme.chartBlue,
                 on: host.wifiOn,
                 metrics: metrics,
                 // The word under the mark says how good the signal is, so an
                 // off Wi-Fi gets the lane's own name instead of a blank line —
                 // a reserved-but-empty caption was how the lit marks ended up
                 // floating above the dimmed ones.
                 caption: host.wifiOn ? (WiFiBars.label(for: host.wifiRSSI) ?? "Wi-Fi") : "Wi-Fi",
                 captionDim: !host.wifiOn,
                 help: wifiHelp)
    }

    private var wifiHelp: String {
        guard host.wifiOn else { return "Wi-Fi 已关闭" }
        var text = "Wi-Fi"
        if !host.wifiName.isEmpty { text += " \(host.wifiName)" }
        if host.wifiRSSI < 0 { text += " \(host.wifiRSSI) dBm" }
        return text
    }
}

/// Segmented power cell with exact percentage and explicit charging state below.
/// Machines without an internal battery retain the AC plug affordance.
private struct BatteryMark: View {
    var host: ProcessSampler.HostStats
    var metrics: ConnectMetrics
    @State private var showPowerFlow = false

    /// **The mark is permanent, so "no pack" has to be a state it can draw.**
    ///
    /// It is one of two marks that never come and go (Wi-Fi is the other):
    /// Ethernet and the headset appear with the hardware behind them, but 电量
    /// is always there, because "how is this Mac powered" is always a question
    /// with an answer. A desktop answers it with 交流电 rather than by hiding —
    /// an absent mark would read as a failed reading, and it would also make the
    /// row's width jump between machines for no visible reason.
    private var installed: Bool { host.batteryInstalled }

    /// Nearest 25 % step, which is the resolution the SF Symbols battery family
    /// actually has. There is no continuous battery glyph, and faking one with a
    /// rectangle would be a drawing the rest of the row does not share. A Mac
    /// with no pack gets the outlet glyph instead of a battery at all — drawing
    /// `battery.0` there would be a flat-battery alarm about a machine that
    /// cannot go flat.
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

/// The headset's parts, contributed to the row as three ordinary marks.
///
/// Each part is a ring with its own glyph and percentage, and each is drawn into
/// the same `markBox` as a network lane — so the row has a constant rhythm and
/// the headset is no longer a shape that happens to be wider than its
/// neighbours. Only the *status word* (`已连接` / `充电中` / `未连接`) is shared,
/// and it is drawn once beneath the group's centre rather than repeated three
/// times.
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
            // The status word belongs to the device rather than to any one part,
            // so it is printed once under the middle of the group — and it is a
            // *row*, not an `overlay`. An overlay is sized by the view it covers,
            // so it landed inside the ring row and printed on top of `76%`; a
            // real row of `statusBand` height is the only arrangement that
            // guarantees the two lines cannot collide.
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

/// One part of the headset: product glyph inside a charge ring, percentage
/// beneath.
///
/// The glyphs are Apple's own hardware marks — `earbud.left`, `earbud.right`,
/// `airpods.chargingcase` — rather than the letters L/R/C. The letters needed a
/// legend and read as English initials in a Chinese UI; the product shapes carry
/// the meaning directly, and the two buds are mirror images so left stays
/// visually distinct from right.
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

    /// **Charging is a per-part fact, so it is a per-part colour.** An earlier
    /// version tinted green only when the *whole* headset was in use, which drew
    /// a charging case — a green fact about a part — in the same grey as a
    /// disconnected one, next to two purple buds that were neither. Three parts
    /// of one device cannot use two different rules; the colour order here is
    /// charge, then connection, then the default signal hue.
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

/// Maps RSSI onto Wi-Fi marks.
///
/// SF Symbols has no graded Wi-Fi family (`wifi` is one fixed 3-arc glyph), so
/// the *shape* cannot carry the grade — only the presence/absence of the slash
/// can. The grade is therefore carried by the caption under the mark, and this
/// type owns that mapping in one place so the icon and its caption cannot
/// disagree about what counts as "good".
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

/// The popup's headset mark: a battery ring around the headset's own glyph.
///
/// Sized to the popup's 9pt label / 13pt value rhythm rather than to the 连接
/// card's row, because it sits inside a text cell — a ring tall enough to match
/// the card would push the cell's baseline off the three KPIs beside it.
private struct HeadsetBadge: View {
    var accessory: AudioAccessoryMonitor.Accessory?
    var charging: Bool
    var level: Double?

    private var inUse: Bool { accessory?.connection == .inUse }

    private var tint: Color {
        guard inUse else { return Theme.Ink.idle }
        return charging ? Theme.Ink.success : Theme.chartPurple
    }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.cardFill(0.18), lineWidth: 2.5)
            if let level {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, level)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: "earbud.left")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(tint)
        }
        .padding(2.5)
        .accessibilityHidden(true)
    }
}
