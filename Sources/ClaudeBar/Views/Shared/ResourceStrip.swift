import SwiftUI

/// Host resource cards with live readings and resource-specific detail views.
struct ResourceStrip: View {
    private let sampler = ProcessSampler.shared
    private let fanMonitor = FanMonitor.shared
    private let audioMonitor = AudioAccessoryMonitor.shared
    @State private var showCPU = false
    @State private var showGPU = false
    @State private var showMemory = false
    @State private var showDisk = false

    var body: some View {
        // One shared string for the CPU / GPU / 风扇 tiles. `meter(...)` used to
        // call `helpText()` itself, which built the identical array of shares +
        // host line + `String(format:)` memory labels six times per body pass
        // (2 s, or 1 s while live). 内存 and 硬盘 replace it at their own call
        // sites with a tooltip naming their popover, which is why this is the
        // default rather than "the" tooltip.
        let help = helpText()
        return EqualRowGrid(spacing: Theme.Space.gridGap, minColumnWidth: 0, fixedColumns: 3) {
            meter("CPU",
                  icon: "cpu",
                  hero: String(format: "%.0f%%", sampler.host.cpu),
                  // The hero is a *figure*, so it takes the text variant of the
                  // hue — `chartGreen` is a fill color and measures 1.99:1 on
                  // the ice canvas (see the `Theme.Ink` note in Theme.swift).
                  heroTint: Theme.Ink.success,
                  load: sampler.host.cpu / 100,
                  kind: .cpu,
                  tint: Theme.chartGreen,
                  caption: cpuTempCaption,
                  pill: ("\(sampler.host.coreCount) 核", Theme.textSecondary),
                  help: help,
                  tempColor: cpuTempColor)
            meter("GPU",
                  icon: "square.3.layers.3d",
                  hero: String(format: "%.0f%%", sampler.host.gpu),
                  heroTint: Theme.textPrimary,
                  load: sampler.host.gpu / 100,
                  kind: .gpu,
                  tint: Theme.chartBlue,
                  caption: gpuCaption,
                  pill: ("本机", Theme.textSecondary),
                  help: help,
                  tempColor: gpuTempColor)
            meter("内存",
                  icon: "memorychip",
                  hero: String(format: "%.0f%%", memPercent),
                  heroTint: Theme.textPrimary,
                  load: memPercent / 100,
                  kind: .memory,
                  tint: Theme.chartAmber,
                  caption: "已使用 \(sampler.host.memoryLabel)",
                  pill: memoryPill,
                  help: help)
            meter("硬盘",
                  icon: "internaldrive",
                  hero: String(format: "%.0f%%", sampler.host.diskPercent),
                  heroTint: Theme.textPrimary,
                  load: sampler.host.diskPercent / 100,
                  kind: .disk,
                  tint: Theme.chartPurple,
                  caption: "已使用 \(sampler.host.diskLabel)",
                  pill: diskPill,
                  help: help)
            // Connection status combines network, power and accessory readings.
            LinkCard(host: sampler.host,
                     accessory: audioMonitor.accessories.first,
                     accessoryCount: audioMonitor.accessories.count,
                     unavailableReason: audioMonitor.unavailableReason,
                     dense: false)
            meter("风扇",
                  icon: "fanblades",
                  hero: fanHero,
                  heroTint: Theme.textPrimary,
                  load: 0,
                  kind: .fans,
                  tint: Theme.claude,
                  caption: fanCaption,
                  pill: fanPill,
                  help: help)
        }
        .onAppear {
            fanMonitor.start()
            audioMonitor.start()
        }
        .onDisappear {
            fanMonitor.stop()
            audioMonitor.stop()
        }
    }

    private var fanHero: String {
        guard !fanMonitor.fans.isEmpty else { return "—" }
        let rpms = fanMonitor.fans.prefix(2).map(\.rpm)
        if rpms.count == 2 { return "\(rpms[0]) · \(rpms[1])" }
        return "\(rpms[0])"
    }

    private var fanCaption: String {
        // A refused write is the one thing this tile has to say out loud: the
        // readout is SMC truth, so a failed toggle leaves the number simply
        // refusing to move, with nothing on screen explaining why. The helper
        // returns real sentences ("辅助工具不可用，请重新安装。" / "风扇调整失败（退出码 n）")
        // and they had no reader anywhere in the app.
        if let error = fanMonitor.lastError { return error }
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

    /// The temperature-to-color rule returns raw signal hues, which is right
    /// for the mark and wrong for the two places this file applies it: the hero
    /// figure and the caption under it are *text*. `Theme.swift` documents those
    /// hues at 1.8–3.4:1 on the ice canvas and reserves `Theme.Ink.*` for
    /// anything read as text — the same rule the pills in this file already
    /// follow. A 28pt hero in raw amber at 1.84:1 was the least legible number
    /// on the page, at exactly the temperature where it matters most.
    private func temperatureInk(_ celsius: Double?) -> Color? {
        guard let celsius, celsius > 0 else { return nil }
        if celsius >= 85 { return Theme.Ink.error }
        if celsius >= 75 { return Theme.Ink.warning }
        return nil
    }

    private var cpuTempColor: Color? { temperatureInk(sampler.host.cpuTemperatureCelsius) }
    private var gpuTempColor: Color? { temperatureInk(sampler.host.gpuTemperatureCelsius) }

    private var cpuTempCaption: String {
        if let temp = sampler.host.temperatureLabel(celsius: sampler.host.cpuTemperatureCelsius) {
            return "\(cpuCaption) · \(temp)"
        }
        return cpuCaption
    }

    // These tuples land in `StatusPill`, i.e. they render as *text*, so they
    // carry `Theme.Ink` rather than the raw signal hues (the latter measure
    // 1.8–3.4:1 on the ice canvas — an amber "偏高" was barely legible).

    private var memoryPill: (String, Color) {
        if sampler.host.memoryPressureLevel >= 4 { return ("严重", Theme.Ink.error) }
        if sampler.host.memoryPressureLevel >= 2 || memPercent >= 75 { return ("偏高", Theme.Ink.warning) }
        return ("正常", Theme.Ink.success)
    }

    private var fanPill: (String, Color) {
        // Text, so `Theme.Ink` — the same rule as the pills below.
        if fanMonitor.lastError != nil { return ("失败", Theme.Ink.error) }
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

    private var cpuCaption: String { cpuAttributionCaption() }
    private var gpuCaption: String {
        var parts = ["本机 \(Int(sampler.host.gpu.rounded()))%"]
        if let temp = sampler.host.temperatureLabel(celsius: sampler.host.gpuTemperatureCelsius) {
            parts.append(temp)
        }
        return parts.joined(separator: " · ")
    }

    private enum ResourceKind {
        case cpu, gpu, memory, fans, disk
    }

    private func meter(
        _ label: String,
        icon: String,
        hero: String,
        heroTint: Color,
        load: Double,
        kind: ResourceKind,
        tint: Color,
        caption: String,
        pill: (String, Color),
        help: String,
        tempColor: Color? = nil
    ) -> some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // No ring here.
                //
                // Each tile's header used to wrap its glyph in a `LoadRing`: a
                // ~96° arc travelling at a rate proportional to the tile's own
                // reading. It read as a **spinner**, which is a lie — a spinner
                // means "waiting", and nothing on this strip is ever waiting for
                // the machine. It also duplicated the figure printed three
                // lines under it, at a smaller size and a lower contrast.
                //
                // The live reading belongs to the big mark on the right, where
                // it is drawn in the shape of the hardware it describes: twelve
                // cells for twelve cores, one column per GPU sub-unit. That
                // mark states the reading; this one only names the tile.
                InstrumentBadge(kind: InstrumentGlyph.kind(for: icon) ?? .link, tint: tint)
                    .frame(width: 28, height: 28)
                Text(label)
                    .font(Theme.Font.chrome)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 4)
                StatusPill(label: pill.0, tint: pill.1)
                if kind != .fans {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    RollingNumberText(hero)
                            .font(Theme.Font.displayMetric)
                            .monospacedDigit()
                            .foregroundColor(tempColor ?? heroTint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    // The caption shares the row with the mark, and the mark is
                    // deliberately large; so the caption scales down before it
                    // truncates. "已使用 375.3 GB / 460.4…" loses the number that
                    // matters, which is worse than slightly smaller type.
                    Text(caption)
                        .font(Theme.Font.tileLabel)
                        .foregroundColor(tempColor ?? Theme.textTertiary())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
                Spacer(minLength: 4)
                Group {
                    switch kind {
                    case .gpu:
                        // One cell per graphics sub-unit the driver publishes,
                        // not one bar for the whole card: the tile's own figure
                        // is already the aggregate, and a mark that only repeats
                        // it is the decoration this whole strip exists to avoid.
                        HardwareSiliconMark(gpu: true, load: load, tint: tint,
                                            cells: sampler.host.gpuRenderers.map { $0 / 100 })
                    case .memory:
                        CapacityHardwareMark(disk: false, load: load,
                                             bytes: sampler.host.memoryTotal, tint: tint,
                                             wells: sampler.host.memoryWells)
                    case .cpu:
                        // Twelve cores, twelve cells — each lit by that core's
                        // own busy fraction. Empty until the sampler's second
                        // tick establishes the baseline, and the mark falls back
                        // to a single lit die until then rather than inventing
                        // per-core numbers.
                        HardwareSiliconMark(load: load, tint: tint, cells: sampler.host.coreLoad)
                    case .fans:
                        CompactFanPair(fans: fanMonitor.fans, onToggle: toggleFan)
                    case .disk:
                        CapacityHardwareMark(disk: true, load: load,
                                             bytes: sampler.host.diskTotal, tint: tint,
                                             wells: sampler.host.diskWells)
                    }
                }
                // The tile's mark slot. Large on purpose: the mark *is* the
                // reading, so it gets the room that says so. The slot is taller
                // than it is wide because the mark is two stacked lanes — a
                // Lucide icon on top and the reading bar underneath — and
                // squeezing them into a short box is what made an earlier attempt
                // illegible.
                .frame(width: 128, height: 104)
                // No `.transaction { animation = nil }` here any more. It existed
                // to stop a sampler tick from interpolating the *old* static
                // marks; the marks are now driven by `TimelineView`, and
                // suppressing animation on this subtree would freeze exactly the
                // motion that is the point.
                .clipped()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity, alignment: .topLeading)
        // The meter carries its own hue into the tile surface: the accent wash
        // is what the inner frame ring sits on, and the hover edge then agrees
        // with the hero number's tint. No lens here — the tile's mark occupies
        // the trailing cell, and rings anchored to a corner would sit behind
        // the readout instead of behind the mark.
        //
        // Hover is owned by the surface, not by this meter: `content` is used
        // twice (bare, and wrapped in a popover button) and nothing in it reads
        // the flag.
        .hoverTile(tint: tint, dense: false)
        .help(help)
        return Group {
            if kind == .cpu {
                Button { showCPU = true } label: { content }
                    .buttonStyle(.pressable)
                    .popover(isPresented: $showCPU) { HardwareDetailPanel(gpu: false) }
            } else if kind == .gpu {
                Button { showGPU = true } label: { content }
                    .buttonStyle(.pressable)
                    .popover(isPresented: $showGPU) { HardwareDetailPanel(gpu: true) }
            } else if kind == .memory {
                Button { showMemory = true } label: { content }
                    .buttonStyle(.pressable)
                    .help("查看各进程的内存占用")
                    .popover(isPresented: $showMemory) { MemoryDetailPanel() }
            } else if kind == .disk {
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

    private func cpuAttributionCaption() -> String {
        let parts: [String] = sampler.shares.compactMap { share in
            let percent = share.cpuShare * 100
            guard percent >= 0.4 else { return nil }
            return "\(share.label) \(Int(percent.rounded()))%"
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

/// One-line CPU / memory for a tracked session or app family.
struct SessionLoadChip: View {
    private let sampler = ProcessSampler.shared
    let key: ProcessSampler.Key
    var compact: Bool = false
    var shared: Bool = false

    var body: some View {
        let snap = sampler.byKey[key]
        RollingNumberText(snap?.loadLabel ?? "—")
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
