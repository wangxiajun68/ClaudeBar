import SwiftUI

/// 系统资源：标题数字为整机（全核 CPU、IOKit GPU、物理内存、温度）。
/// 色条为 ClaudeBar / CC / Cursor / Codex 占整机的 CPU 与内存比例。
struct ResourceStrip: View {
    @ObservedObject var sampler = ProcessSampler.shared
    @ObservedObject private var fanMonitor = FanMonitor.shared
    var dense: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 6 : 10) {
            if !dense {
                HStack(alignment: .firstTextBaseline) {
                    Text("系统资源")
                        .font(Theme.Font.titleSmall)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text(topCaption)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
            }
            HStack(spacing: dense ? 10 : 16) {
                meter("CPU",
                      value: cpuValue,
                      trail: sampler.trail.map(\.cpu),
                      tint: Theme.claude,
                      shares: cpuSegments,
                      caption: cpuCaption,
                      tempColor: cpuTempColor)
                meter("GPU",
                      value: gpuValue,
                      trail: sampler.trail.map(\.gpu),
                      tint: Theme.external,
                      shares: gpuSegments,
                      caption: gpuCaption,
                      tempColor: gpuTempColor)
                meter("内存",
                      value: sampler.host.memoryLabel,
                      trail: sampler.trail.map(\.mem),
                      tint: Theme.cursor,
                      shares: memSegments,
                      caption: memCaption)
                meter("风扇",
                      value: fanValue,
                      trail: [],
                      tint: Theme.claude,
                      shares: [],
                      caption: fanCaption,
                      icon: "snowflake",
                      iconAction: toggleFanMax,
                      iconActive: fansAtMax,
                      iconHelp: fansAtMax ? "恢复自动风速" : "最大风速",
                      iconHelpDefault: "")
            }
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

    private var fanValue: String {
        guard !fanMonitor.fans.isEmpty else { return "—" }
        let rpm = fanMonitor.fans.map(\.rpm).reduce(0, +)
        return "\(rpm) RPM"
    }

    private var fanCaption: String {
        guard !fanMonitor.fans.isEmpty else { return "未检测到风扇" }
        let manual = fanMonitor.fans.filter { !$0.mode.isAutomatic }.count
        if manual > 0 { return "\(manual)/\(fanMonitor.fans.count) 手动" }
        return fanMonitor.fans.map { "\($0.rpm)" }.joined(separator: " / ") + " rpm"
    }

    /// 雪花按钮：点击 = 全部风扇手动最大转速；再次点击 = 恢复自动。
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

    private var cpuValue: String {
        valueWithTemperature(
            percent: sampler.host.cpu,
            celsius: sampler.host.cpuTemperatureCelsius)
    }

    private var gpuValue: String {
        valueWithTemperature(
            percent: sampler.host.gpu,
            celsius: sampler.host.gpuTemperatureCelsius)
    }

    private func valueWithTemperature(percent: Double, celsius: Double?) -> String {
        let base = String(format: "%.0f%%", percent)
        guard let temp = sampler.host.temperatureLabel(celsius: celsius) else { return base }
        return "\(base) · \(temp)"
    }

    /// 温度文字颜色：正常无色，≥75° amber，≥85° 红。
    private func temperatureColor(_ celsius: Double?) -> Color? {
        sampler.host.temperatureColor(celsius: celsius)
    }

    private var cpuTempColor: Color? { temperatureColor(sampler.host.cpuTemperatureCelsius) }
    private var gpuTempColor: Color? { temperatureColor(sampler.host.gpuTemperatureCelsius) }

    private var topCaption: String { familyCaption(kind: .cpu) }

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
        if let temp = sampler.host.temperatureLabel(celsius: sampler.host.gpuTemperatureCelsius) {
            return "本机 \(Int(sampler.host.gpu.rounded()))% · \(temp)"
        }
        return "本机 \(Int(sampler.host.gpu.rounded()))%"
    }

    private var memCaption: String {
        if sampler.host.memoryPressureLevel >= 4 { return "内存压力 · 严重" }
        if sampler.host.memoryPressureLevel >= 2 { return "内存压力 · 偏高" }
        return familyCaption(kind: .mem)
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

    private func meter(
        _ label: String,
        value: String,
        trail: [Double],
        tint: Color,
        shares: [ShareSegment],
        caption: String,
        icon: String? = nil,
        iconAction: (() -> Void)? = nil,
        iconActive: Bool? = nil,
        iconHelp: String? = nil,
        iconHelpDefault: String = "",
        tempColor: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: dense ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(spacing: 3) {
                    if let icon {
                        Button(action: iconAction ?? {}) {
                            Image(systemName: icon)
                                .font(.system(size: dense ? 11 : 14, weight: .medium))
                                .foregroundColor(iconActive == true ? Theme.claude : Theme.textTertiary(0.5))
                        }
                        .buttonStyle(.plain)
                        .help(iconHelp ?? iconHelpDefault)
                    }
                    Text(label)
                        .font(Theme.Font.tileLabel)
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                Text(value)
                    .font(dense ? Theme.Font.captionMono : Theme.Font.tileMicroValue)
                    .monospacedDigit()
                    // 值内含温度（"42% · 78°C"）；高温时整段变 amber/红。
                    .foregroundColor(tempColor ?? Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            ZStack(alignment: .leading) {
                if label == "风扇" {
                    // 概括处只读展示：实时转速条（不可拖），调速在设置界面。
                    FanMiniBars(monitor: fanMonitor)
                } else {
                    HistoryRibbon(values: trail, tint: tint)
                        .opacity(0.35)
                    ShareStack(segments: shares, height: dense ? 3 : 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(height: dense ? 18 : 28)
            if !dense {
                Text(caption)
                    .font(Theme.Font.caption)
                    .foregroundColor(label == "GPU" && tempColor != nil ? tempColor : Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText())
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
private struct FanMiniBars: View {
    @ObservedObject var monitor: FanMonitor
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            ForEach(monitor.fans) { fan in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.textTertiary().opacity(0.25))
                        Capsule()
                            .fill(Theme.claude)
                            .frame(width: max(2, geo.size.width * barRatio(fan)))
                    }
                }
                .frame(height: compact ? 4 : 5)
            }
        }
    }

    private func barRatio(_ fan: FanInfo) -> Double {
        let span = max(1, fan.maxRPM - fan.minRPM)
        return min(1, max(0.02, Double(fan.rpm - fan.minRPM) / Double(span)))
    }
}

private struct ShareSegment: Identifiable {
    var id: String
    var label: String
    var ratio: Double
    var tint: Color
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

private struct HistoryRibbon: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            var path = Path()
            let n = values.count
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(n - 1)
                let y = size.height * (1 - CGFloat(min(max(v, 0), 1)))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            ctx.fill(path, with: .color(tint.opacity(0.35)))
        }
    }
}

/// One-line CPU / memory for a tracked session or app family.
struct SessionLoadChip: View {
    @ObservedObject private var sampler = ProcessSampler.shared
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
