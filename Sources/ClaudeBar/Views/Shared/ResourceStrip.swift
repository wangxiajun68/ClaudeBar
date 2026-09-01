import SwiftUI

/// Live Axon + agent CPU / GPU / memory meters with a faint history ribbon.
/// One Canvas per meter — cheap to redraw at 1 Hz, no per-sample views.
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
                    Text(agentCaption)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textTertiary())
                }
            }
            HStack(spacing: dense ? 10 : 16) {
                meter("CPU", value: sampler.axon.cpuLabel, ratio: min(1, sampler.axon.cpu / 100),
                      trail: sampler.trail.map(\.cpu), tint: Theme.claude)
                meter("GPU", value: sampler.axon.gpuLabel, ratio: min(1, sampler.axon.gpu / 100),
                      trail: sampler.trail.map(\.gpu), tint: Theme.external)
                meter("内存", value: sampler.axon.memoryLabel, ratio: memRatio,
                      trail: sampler.trail.map(\.mem), tint: Theme.cursor)
            }
        }
    }

    private var memRatio: Double {
        min(1, Double(sampler.axon.memoryBytes) / (512 * 1024 * 1024))
    }

    private var agentCaption: String {
        let a = sampler.agents
        if a.memoryBytes == 0 && a.cpu < 0.5 { return "仅 Axon" }
        return "Claude 代理 \(a.cpuLabel) · \(a.memoryLabel)"
    }

    private func meter(_ label: String, value: String, ratio: Double, trail: [Double], tint: Color) -> some View {
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
                    .opacity(0.45)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint)
                        .frame(width: max(2, geo.size.width * ratio), height: dense ? 3 : 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(height: dense ? 18 : 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
