import SwiftUI

/// Live Axon + agent CPU / GPU / memory meters. Each meter is a stacked
/// share of the processes we can attribute, plus a 1 Hz ribbon.
struct ResourceStrip: View {
    @ObservedObject var sampler = ProcessSampler.shared
    var dense: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 6 : 10) {
            if !dense {
                HStack(alignment: .firstTextBaseline) {
                    Text("本机负载")
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
                meter("CPU", value: cpuValue, trail: sampler.trail.map(\.cpu),
                      tint: Theme.claude, shares: cpuSegments)
                meter("GPU", value: String(format: "%.0f%%", sampler.systemGPU),
                      trail: sampler.trail.map(\.gpu), tint: Theme.external,
                      shares: gpuSegments, footnote: gpuFootnote)
                meter("内存", value: memValue, trail: sampler.trail.map(\.mem),
                      tint: Theme.cursor, shares: memSegments)
            }
        }
    }

    private var cpuValue: String {
        let total = sampler.shares.reduce(0) { $0 + $1.cpu }
        return String(format: "%.0f%%", total)
    }

    private var memValue: String {
        let bytes = sampler.shares.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }
        return ProcessSampler.Snapshot(memoryBytes: bytes).memoryLabel
    }

    private var topCaption: String {
        let named = sampler.shares.prefix(4).map { share in
            "\(share.label) \(Int((share.cpuShare * 100).rounded()))%"
        }
        if named.isEmpty { return "仅 Axon" }
        return named.joined(separator: " · ")
    }

    private var cpuSegments: [ShareSegment] {
        sampler.shares.map { ShareSegment(id: $0.id, label: $0.label, ratio: $0.cpuShare, tint: tint(for: $0.id)) }
    }

    private var memSegments: [ShareSegment] {
        sampler.shares.map { ShareSegment(id: $0.id, label: $0.label, ratio: $0.memShare, tint: tint(for: $0.id)) }
    }

    private var gpuSegments: [ShareSegment] {
        let attributed = sampler.shares.filter { $0.gpuShare > 0.02 }
        if attributed.isEmpty {
            return [ShareSegment(id: "sys", label: "本机", ratio: min(1, sampler.systemGPU / 100), tint: Theme.external)]
        }
        return attributed.map { ShareSegment(id: $0.id, label: $0.label, ratio: $0.gpuShare, tint: tint(for: $0.id)) }
    }

    private var gpuFootnote: String? {
        sampler.shares.contains(where: { $0.gpuShare > 0.02 }) ? nil : "整机占用，会话无法拆分"
    }

    private func tint(for id: String) -> Color {
        if id == "axon" { return Theme.textSecondary }
        if id == "cursor" { return Theme.cursor }
        if id.hasPrefix("c-") { return Theme.claude }
        if id.hasPrefix("x-") { return Theme.external }
        return Theme.codex
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
                    .contentTransition(.numericText())
            }
            ZStack(alignment: .leading) {
                HistoryRibbon(values: trail, tint: tint)
                    .opacity(0.35)
                ShareStack(segments: shares, height: dense ? 3 : 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: dense ? 18 : 28)
            if !dense {
                Text(shareCaption(shares, fallback: footnote))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(shareHelp(shares, footnote: footnote))
    }

    private func shareCaption(_ shares: [ShareSegment], fallback: String?) -> String {
        let named = shares.filter { $0.ratio >= 0.04 }.prefix(3).map {
            "\($0.label) \(Int(($0.ratio * 100).rounded()))%"
        }
        if named.isEmpty { return fallback ?? "—" }
        return named.joined(separator: " · ")
    }

    private func shareHelp(_ shares: [ShareSegment], footnote: String?) -> String {
        var lines = shares.filter { $0.ratio > 0.005 }.map {
            "\($0.label)  \(Int(($0.ratio * 100).rounded()))%"
        }
        if let footnote { lines.append(footnote) }
        return lines.isEmpty ? "暂无进程" : lines.joined(separator: "\n")
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
                ForEach(segments.filter { $0.ratio > 0.008 }) { seg in
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
            .contentTransition(.numericText())
            .lineLimit(1)
            .help(shared
                  ? "整个 Cursor 进程的 CPU / 内存（会话没有独立进程）"
                  : "该会话进程的 CPU / 内存。跨进程 GPU 需要 task_for_pid，多数代理会显示为 —")
    }
}
