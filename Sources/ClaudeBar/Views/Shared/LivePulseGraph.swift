import SwiftUI

// MARK: - Live pulse graph

/// A flowing, GPU-rendered activity waveform — the Dashboard's "heartbeat".
/// Built from `Canvas` + `TimelineView(.animation)`: every frame the curve is
/// redrawn from a time-based function whose amplitude is driven by the live
/// busy-session count, so the graph genuinely *reacts* to how much Claude is
/// running right now (more activity → taller waves). A scan line rides the
/// pointer's x position and reads off the current value.
///
/// Refined render layers, bottom → top:
/// 1. A faint horizontal baseline grid so the wave has a "rest position" to
///    read against — turns free-floating curves into an oscilloscope.
/// 2. The filled area under the curve, fading down.
/// 3. A mirrored, fainter wave for parallax depth.
/// 4. The main stroke, drawn as a gradient (brighter at the leading edge).
/// 5. A glowing leading-edge dot that traces the wave's rightmost point —
///    the "live signal" that the data is moving in real time.
/// 6. The pointer scan line + readout dot.
struct LivePulseGraph: View {
    /// Live activity level 0...1 (e.g. busy sessions / some max). Drives wave
    /// amplitude and tint.
    var level: Double
    /// Optional throughput label shown at the scan line.
    var label: String? = nil

    @State private var scanX: CGFloat? = nil
    @State private var size: CGSize = .zero

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { gctx, size in
                drawWaves(gctx: gctx, size: size, t: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(height: 92)
        .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { newSize in
            if size != newSize { size = newSize }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                scanX = point.x
            case .ended:
                withAnimation(Theme.Animation.smooth) { scanX = nil }
            @unknown default: break
            }
        }
    }

    // MARK: Drawing

    private func drawWaves(gctx: GraphicsContext, size: CGSize, t: Double) {
        guard size.width > 0, size.height > 0 else { return }
        let mid = size.height * 0.6
        let amp = (8 + level * 22)                // taller waves when busier
        let tint = self.tint

        // Build the main flowing curve as a series of points, scrolling left.
        let steps = max(48, Int(size.width / 6))
        var points: [CGPoint] = []
        points.reserveCapacity(steps)
        for i in 0...steps {
            let x = CGFloat(i) / CGFloat(steps) * size.width
            // Layered sines at different frequencies + speeds → organic flow.
            let phase = t * 0.9
            let y = mid
                + sin(phase + Double(i) * 0.18) * amp
                + sin(phase * 1.7 + Double(i) * 0.07) * amp * 0.45
                + sin(phase * 0.5 + Double(i) * 0.31) * amp * 0.25
            points.append(CGPoint(x: x, y: y))
        }

        // 1. Baseline grid — two faint rules marking the rest line and a lower
        //    reference, so the wave reads against a scale, not floating.
        gctx.stroke(
            Path(CGRect(x: 0, y: mid, width: size.width, height: 0.5)),
            with: .color(tint.opacity(0.10)), lineWidth: 0.5
        )
        gctx.stroke(
            Path(CGRect(x: 0, y: mid + amp * 0.6, width: size.width, height: 0.5)),
            with: .color(tint.opacity(0.05)), lineWidth: 0.5
        )

        // 2. Filled area under the curve (fading down).
        var fillPath = Path()
        fillPath.addLines(points)
        fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
        fillPath.addLine(to: CGPoint(x: 0, y: size.height))
        fillPath.closeSubpath()
        gctx.fill(fillPath, with: .linearGradient(
            Gradient(colors: [tint.opacity(0.32), tint.opacity(0)]),
            startPoint: .init(x: 0, y: mid - amp),
            endPoint: .init(x: 0, y: size.height)
        ))

        // 3. Secondary mirrored, fainter wave for depth.
        var mirror = Path()
        for (i, p) in points.enumerated() {
            let mp = CGPoint(x: p.x, y: 2 * mid - p.y + 4)
            if i == 0 { mirror.move(to: mp) } else { mirror.addLine(to: mp) }
        }
        gctx.stroke(mirror, with: .color(tint.opacity(0.16)), lineWidth: 1)

        // 4. The main stroke — a horizontal gradient so the leading (right)
        //    edge glows brighter, reading as the newest data.
        var linePath = Path()
        linePath.addLines(points)
        gctx.stroke(linePath, with: .linearGradient(
            Gradient(colors: [tint.opacity(0.5), tint]),
            startPoint: .init(x: 0, y: 0),
            endPoint: .init(x: size.width, y: 0)
        ), lineWidth: 1.6)

        // 5. Glowing leading-edge dot: traces the wave's rightmost point with
        //    a soft halo, the "live signal arriving" affordance.
        if let last = points.last {
            gctx.fill(
                Path(ellipseIn: CGRect(x: last.x - 7, y: last.y - 7, width: 14, height: 14)),
                with: .color(tint.opacity(0.18))
            )
            gctx.fill(
                Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)),
                with: .color(tint)
            )
        }

        // 6. Scan line: rides the pointer x, reads the current y value and
        //    draws a vertical rule + dot — the "I'm inspecting this moment"
        //    affordance.
        if let sx = scanX, sx >= 0, sx <= size.width {
            let idx = Int((sx / size.width) * CGFloat(steps))
            let clamped = min(max(0, idx), points.count - 1)
            let pt = points[clamped]
            gctx.stroke(
                Path(CGRect(x: sx, y: 0, width: 0.5, height: size.height)),
                with: .color(tint.opacity(0.5)), lineWidth: 1
            )
            gctx.fill(
                Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)),
                with: .color(tint)
            )
            if let label {
                let text = gctx.resolve(Text(label).font(Theme.Font.captionMono).foregroundColor(tint))
                let textWidth = text.measure(in: size).width
                let tx = min(max(4, sx + 8), size.width - textWidth - 4)
                gctx.draw(text, at: CGPoint(x: tx + textWidth / 2, y: 12))
            }
        }
    }

    /// Amber when busy, dim slate when idle — the signal's mood follows load.
    private var tint: Color {
        level > 0.05 ? Theme.claude : Theme.statusIdle.opacity(0.75)
    }
}
