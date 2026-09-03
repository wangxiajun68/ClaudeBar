import SwiftUI

/// 系统资源：标题数字为整机（全核 CPU、IOKit GPU、物理内存）。说明与色条为
/// Axon / CC / Cursor / Codex 占整机的比例，剩余为其他进程。
struct ResourceStrip: View {
    @ObservedObject var sampler = ProcessSampler.shared
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
                      value: String(format: "%.0f%%", sampler.host.cpu),
                      trail: sampler.trail.map(\.cpu),
                      tint: Theme.claude,
                      shares: cpuSegments)
                meter("GPU",
                      value: String(format: "%.0f%%", sampler.host.gpu),
                      trail: sampler.trail.map(\.gpu),
                      tint: Theme.external,
                      shares: gpuSegments,
                      footnote: gpuFootnote)
                meter("内存",
                      value: sampler.host.memoryLabel,
                      trail: sampler.trail.map(\.mem),
                      tint: Theme.cursor,
                      shares: memSegments)
            }
        }
    }

    private var topCaption: String {
        familyCaption(kind: .cpu)
    }

    private var cpuSegments: [ShareSegment] {
        sampler.shares.map { ShareSegment(id: $0.id, label: $0.label, ratio: $0.cpuShare, tint: tint(for: $0.id)) }
    }

    private var memSegments: [ShareSegment] {
        sampler.shares.map { ShareSegment(id: $0.id, label: $0.label, ratio: $0.memShare, tint: tint(for: $0.id)) }
    }

    private var gpuSegments: [ShareSegment] {
        let attributed = sampler.shares.filter { $0.gpuShare > 0.005 }
        if attributed.isEmpty {
            return [ShareSegment(id: "host", label: "本机",
                                 ratio: min(1, sampler.host.gpu / 100), tint: Theme.external)]
        }
        return attributed.map { ShareSegment(id: $0.id, label: $0.label, ratio: $0.gpuShare, tint: tint(for: $0.id)) }
    }

    private var gpuFootnote: String? {
        sampler.shares.contains(where: { $0.gpuShare > 0.005 })
            ? nil
            : "无法按进程拆分 GPU：跨进程统计需要 task_for_pid 权限"
    }

    private func tint(for id: String) -> Color {
        switch id {
        case "axon": return Theme.textSecondary
        case "cursor": return Theme.cursor
        case "claude": return Theme.claude
        case "codex": return Theme.codex
        default: return Theme.external
        }
    }

    private func meter(_ label: String, value: String, trail: [Double], tint: Color,
                       shares: [ShareSegment], footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: dense ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(Theme.Font.tileLabel)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 4)
                Text(value)
                    .font(dense ? Theme.Font.captionMono : Theme.Font.tileMicroValue)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
            }
            ZStack(alignment: .leading) {
                HistoryRibbon(values: trail, tint: tint)
                    .opacity(0.35)
                ShareStack(segments: shares, height: dense ? 3 : 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: dense ? 18 : 28)
            if !dense {
                Text(caption(for: label, fallback: footnote))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText(footnote: footnote))
    }

    private enum CaptionKind { case cpu, gpu, mem }

    private func caption(for meter: String, fallback: String?) -> String {
        switch meter {
        case "CPU": return familyCaption(kind: .cpu)
        case "GPU":
            let named = familyCaption(kind: .gpu)
            return named == "—" ? (fallback ?? "—") : named
        default: return familyCaption(kind: .mem)
        }
    }

    private func familyCaption(kind: CaptionKind) -> String {
        let parts: [String] = sampler.shares.compactMap { share in
            switch kind {
            case .cpu:
                let pct = share.cpuShare * 100
                guard pct >= 0.4 else { return nil }
                return "\(share.label) \(Int(pct.rounded()))%"
            case .gpu:
                let pct = share.gpuShare * 100
                guard pct >= 0.4 else { return nil }
                return "\(share.label) \(Int(pct.rounded()))%"
            case .mem:
                guard share.memoryBytes > 4 * 1024 * 1024 else { return nil }
                return "\(share.label) \(ProcessSampler.Snapshot(memoryBytes: share.memoryBytes).memoryLabel)"
            }
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func helpText(footnote: String?) -> String {
        var lines = sampler.shares.map { share -> String in
            let cpu = Int((share.cpuShare * 100).rounded())
            let mem = ProcessSampler.Snapshot(memoryBytes: share.memoryBytes).memoryLabel
            return "\(share.label)  CPU \(cpu)%  \(mem)"
        }
        lines.insert("本机  CPU \(Int(sampler.host.cpu.rounded()))%  GPU \(Int(sampler.host.gpu.rounded()))%  \(sampler.host.memoryLabel)", at: 0)
        if let footnote { lines.append(footnote) }
        return lines.joined(separator: "\n")
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

/// Filled area of the last N normalized samples (0...1).
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

/// One-line CPU / memory (and GPU when the kernel gives us a task port).
/// Observes the sampler itself so the parent tile doesn't redraw at 1 Hz.
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
                  : "该会话进程的 CPU 与内存。跨进程 GPU 需要 task_for_pid 权限，多数代理无法显示。")
    }
}
