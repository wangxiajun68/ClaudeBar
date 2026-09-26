import SwiftUI

/// Connected KPI bar — label above value, equal columns, one shared track.
/// Equal-width columns keep every metric legible when headphones connect.
/// Pattern: uiverse.io connected stats / segmented toolbar (gap-px group).
struct MachineKpiStrip: View {
    private let sampler = ProcessSampler.shared
    private let fanMonitor = FanMonitor.shared
    private let audioMonitor = AudioAccessoryMonitor.shared

    var body: some View {
        // One tooltip for the four machine cells. `kpiLabel` used to fall back
        // to `helpText()`, so CPU / GPU / memory / fan each rebuilt the same
        // host string (two `String(format:)` temperature labels included) on
        // every body pass.
        let help = helpText()
        return EqualRowGrid(spacing: 1, minColumnWidth: 0, fixedColumns: hasHeadset ? 5 : 4) {
            MachineKpiButton(kind: .cpu, value: String(format: "%.0f%%", sampler.host.cpu),
                             load: sampler.host.cpu / 100, help: help)
            MachineKpiButton(kind: .gpu, value: String(format: "%.0f%%", sampler.host.gpu),
                             load: sampler.host.gpu / 100, help: help)
            MachineKpiButton(kind: .memory, value: memShort,
                             load: memPercent / 100, help: help)
            // The headphone cell exists only while a headset is actually in
            // use. Nearby / charging-in-the-case readings stay in the 连接
            // tooltip, they do not steal a column here.
            if let accessory = audioMonitor.accessories.first,
               accessory.connection == .inUse {
                audioKpi
            }
            Button(action: toggleFanMax) {
                kpiLabel(icon: "fanblades", label: "风扇",
                         value: fanShort, tint: Theme.claude,
                         help: fansAtMax ? "恢复自动风速" : "最大风速")
            }
            .buttonStyle(.uiversePress)
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

    private func kpiLabel(icon: String, label: String, value: String, tint: Color,
                          help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                SignatureGlyph(name: icon, tint: tint, size: 15)
                Text(label)
                    .font(Theme.Font.kpi)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            RollingNumberText(value)
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
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private var hasHeadset: Bool {
        audioMonitor.accessories.first?.connection == .inUse
    }

    // MARK: - 耳机 (popup)

    /// The popup's one-line headphone readout: the product glyph, the worse
    /// bud's percentage, and nothing else. The per-bud / case breakdown stays in
    /// the tooltip — this cell was added *as* a fifth column (`hasHeadset`
    /// drives `fixedColumns`), so what it deliberately does not do is spend a
    /// second column on those numbers.
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

    /// Compact headset status; component battery levels remain available in the tooltip.
    private var audioKpi: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                // No ring, for the same reason the CPU / GPU / 内存 cells
                // beside it dropped theirs: a ~96° arc at 20pt reads as a
                // *spinner*, and "waiting" is never what this cell means. The
                // battery it used to encode as a rate is already the badge's own
                // dial — a percentage, which is the honest shape for it — and
                // the tooltip still carries the bytes.
                //
                // The badge's dial is trimmed to the *battery level*, so it
                // stops short of a full circle and reads as a gauge. A headset
                // at 100 % is the one case where the trim is the whole ring, and
                // "a closed ring at 20pt" is precisely the ornament this row was
                // told to give up. Past 90 % the dial therefore recedes and the
                // glyph carries the state on its own; the level is still the
                // figure under the label and the bytes are still in the tooltip.
                HeadsetBadge(accessory: audioMonitor.accessories.first,
                             charging: audioCharging, level: audioLevel)
                    .frame(width: 20, height: 20)
                Text("耳机")
                    .font(Theme.Font.kpi)
                    .foregroundColor(Theme.textSecondary)
            }
            RollingNumberText(audioShort)
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

    /// Share of physical memory in use, 0…1 — the popup keeps the three-column
    /// form ("12.4G") but the mark needs the *fraction*, or the arc would spin
    /// at full rate on a machine with 128 GB of which 12 GB are used.
    private var memPercent: Double {
        guard sampler.host.memoryTotal > 0 else { return 0 }
        return Double(sampler.host.memoryUsed) / Double(sampler.host.memoryTotal)
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

private struct HeadsetBadge: View {
    var accessory: AudioAccessoryMonitor.Accessory?
    var charging: Bool
    var level: Double?

    private var inUse: Bool { accessory?.connection == .inUse }

    /// `tint` is the ink mix — it colours the 9pt glyph and the dial. An ink
    /// hue is the right choice here; the raw signal hues are for shapes, which
    /// is the whole reason `Theme.Ink` and `Theme.chart*` are separate.
    private var tint: Color {
        guard inUse else { return Theme.Ink.idle }
        return charging ? Theme.Ink.success : Theme.chartPurple
    }

    /// Where the dial stops chasing a full circle.
    ///
    /// A 2.5pt ring at 20pt reads as a circle whether its trim is 40 % or 100 %,
    /// and the whole cell is one of four identical marks in a row that were
    /// explicitly told to stop looking like rings — the same objection that
    /// removed `LoadRing` from this row. So the dial is a *gauge* again above
    /// this value: it fades out and the glyph carries the state alone (colour
    /// for charging, brightness for idle). Below it the trim is short enough to
    /// be unmistakably a reading, and the ring is what makes "how full" legible
    /// at a glance — which is the one thing a percentage at 9pt cannot do.
    private static let dialCeiling = 0.90

    var body: some View {
        ZStack {
            Circle().stroke(Theme.cardFill(0.18), lineWidth: 2.5)
            if let level, level < Self.dialCeiling {
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

/// The mark in one menu-bar KPI cell.
///
/// It draws Lucide's own geometry (`HardwareIllustration`), the same mark the
/// 概览 tile for that reading draws, at the cell's own size — so CPU is a
/// processor, GPU a card, 内存 a DIMM, and none of them is a closed ring. The
/// label and the figure beside it stay SF-adjacent and unchanged: this swap is
/// about the four marks that were reading as circles, not about the typography.
///
/// No reading lane. The `HardwareIllustration` this draws from is the *tile's*
/// mark, and it reserves a lane under the icon for one bar per unit; a 15pt
/// glyph has nowhere to put 12 of them, and the cell already prints the figure
/// under the label. It hands in a plain view of the geometry instead.
private struct HardwareKpiGlyph: View {
    let kind: MachineKpiButton.Kind
    var size: CGFloat = 15

    var body: some View {
        let mark = HardwareIllustration.mark(for: kind.glyphKind)
        Canvas { context, canvas in
            guard let mark else { return }
            let outline = LucideHardwareGeometry.path(for: HardwareIllustration.outline(for: mark))
            let scale = min(canvas.width, canvas.height) / LucideHardwareGeometry.grid
            var c = context
            c.translateBy(x: (canvas.width - LucideHardwareGeometry.grid * scale) / 2,
                          y: (canvas.height - LucideHardwareGeometry.grid * scale) / 2)
            c.scaleBy(x: scale, y: scale)
            c.stroke(outline,
                     with: .color(kind.tint),
                     style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct MachineKpiButton: View {
    enum Kind {
        case cpu, gpu, memory

        var label: String {
            switch self {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .memory: return "内存"
            }
        }

        var tint: Color {
            switch self {
            case .cpu: return Theme.chartGreen
            case .gpu: return Theme.chartBlue
            case .memory: return Theme.chartAmber
            }
        }

        /// Which entry of the one symbol table this cell's mark stands for. The
        /// cell's own three cases are `private`, while the table is the app's
        /// shared vocabulary, so the mapping is stated here rather than by
        /// re-spelling `"cpu"` / `"memorychip"` at the call site.
        var glyphKind: InstrumentGlyph.Kind {
            switch self {
            case .cpu: return .cpu
            case .gpu: return .gpu
            case .memory: return .memory
            }
        }
    }

    let kind: Kind
    let value: String
    /// 0…1 — the same reading the strip prints, handed to the mark so its lit
    /// arc travels at a rate proportional to it. Passed in rather than derived
    /// here: the strip already holds the sampler and has already formatted the
    /// figure, and two places computing "the load" is how a label and its
    /// ornament end up disagreeing.
    var load: Double = 0
    /// The host tooltip, built once by the strip and shared by its cells.
    var help: String = ""
    @State private var open = false
    @State private var hovered = false
    var body: some View {
        Button { open = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    // No ring behind the glyph — and the glyph is not a ring
                    // either. The popup is 424pt wide and four to five cells
                    // share it, so an ornament here is the most expensive thing
                    // a cell can carry; every one of them said "waiting" (a
                    // spinner) about a machine that was working, while repeating
                    // the figure printed directly below it.
                    //
                    // `kind.icon` is the *overview* icon set (`cpu`,
                    // `square.3.layers.3d`, `memorychip`), which
                    // `InstrumentGlyph` draws as a rectangle with pins, three
                    // stacked slabs and a ring-outlined chip — the last two are
                    // closed rings and read as the circles this cell was
                    // supposed to have given up. The 概览 tiles already settled
                    // this; the popup is the same four readings and now uses the
                    // same four marks, through the same one symbol table.
                    HardwareKpiGlyph(kind: kind, size: 15)
                    Text(kind.label).font(Theme.Font.kpi).foregroundColor(Theme.textSecondary)
                }
                RollingNumberText(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            }.padding(.horizontal, 9).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 62, maxHeight: .infinity, alignment: .leading)
                .background(Theme.cardSurface)
                // A quiet accent rule under the cell's own reading, in the
                // cell's hue, and — the `stat-widget` detail — a ground shadow
                // that appears with the hover lift, so the cell reads as picked
                // up rather than as a rectangle that changed shade.
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(kind.tint.opacity(0.55))
                            .frame(width: max(3, geo.size.width * min(1, max(0, load))), height: 2)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 9)
                    .allowsHitTesting(false)
                }
        }
        .buttonStyle(.pressable)
        .overlay { if hovered { GroundShadow(active: true).offset(y: 30) } }
        .hoverState($hovered)
        .help(help)
        .popover(isPresented: $open) {
            if kind == .memory { MemoryDetailPanel() }
            else { HardwareDetailPanel(gpu: kind == .gpu) }
        }
    }
}
