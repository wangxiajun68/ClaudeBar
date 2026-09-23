import SwiftUI

/// Vector hardware silhouettes. Load affects the die illumination, not fictitious per-core readings.
struct HardwareIllustration: View {
    enum Kind { case cpu, gpu, memory }
    let kind: Kind
    let load: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 100, size.height / 76)
            context.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 76 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let level = min(1, max(0, load.isFinite ? load : 0))
            func line(_ points: [CGPoint], color: Color, width: CGFloat = 1.5) {
                guard let first = points.first else { return }
                var path = Path(); path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            func plate(_ rect: CGRect, radius: CGFloat, opacity: Double) {
                let path = Path(roundedRect: rect, cornerRadius: radius)
                context.fill(path, with: .linearGradient(Gradient(colors: [tint.opacity(opacity), tint.opacity(opacity * 0.25)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                context.stroke(path, with: .color(tint.opacity(0.65)), lineWidth: 1.2)
            }
            switch kind {
            case .cpu:
                // Four-sided leads, stacked package and a luminous central die.
                for index in 0..<6 {
                    let p = CGFloat(30 + index * 8)
                    line([CGPoint(x: p, y: 6), CGPoint(x: p, y: 14)], color: tint.opacity(0.55), width: 2.5)
                    line([CGPoint(x: p, y: 62), CGPoint(x: p, y: 70)], color: tint.opacity(0.55), width: 2.5)
                    let y = CGFloat(18 + index * 8)
                    line([CGPoint(x: 16, y: y), CGPoint(x: 24, y: y)], color: tint.opacity(0.55), width: 2.5)
                    line([CGPoint(x: 76, y: y), CGPoint(x: 84, y: y)], color: tint.opacity(0.55), width: 2.5)
                }
                plate(CGRect(x: 24, y: 14, width: 52, height: 50), radius: 10, opacity: 0.2)
                plate(CGRect(x: 29, y: 18, width: 42, height: 40), radius: 7, opacity: 0.16)
                plate(CGRect(x: 35, y: 24, width: 30, height: 28), radius: 5, opacity: 0.25 + level * 0.55)
                context.draw(Text("CPU").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundColor(tint), at: CGPoint(x: 50, y: 38))
                context.fill(Path(ellipseIn: CGRect(x: 29, y: 56, width: 3, height: 3)), with: .color(tint))
            case .gpu:
                var graphics = context
                graphics.translateBy(x: 12, y: 0)
                graphics.scaleBy(x: 3.16, y: 3.16)
                LucideHardwarePaths.drawGPU(in: &graphics, tint: tint, level: level, detailed: true)
            case .memory:
                // Horizontal memory module, keyed edge connector and two IC packages.
                plate(CGRect(x: 9, y: 19, width: 82, height: 38), radius: 6, opacity: 0.15)
                for index in 0..<12 where index != 7 {
                    let x = CGFloat(15 + index * 6)
                    line([CGPoint(x: x, y: 57), CGPoint(x: x, y: 64)], color: tint.opacity(0.75), width: 3)
                }
                for x in [CGFloat(22), 53] {
                    plate(CGRect(x: x, y: 27, width: 25, height: 21), radius: 3, opacity: 0.18 + level * 0.42)
                    for offset in [CGFloat(5), 12, 19] {
                        line([CGPoint(x: x + offset, y: 24), CGPoint(x: x + offset, y: 27)], color: tint.opacity(0.6), width: 1)
                    }
                }
                line([CGPoint(x: 16, y: 52), CGPoint(x: 84, y: 52)], color: tint.opacity(0.18), width: 2)
                if level > 0 { line([CGPoint(x: 16, y: 52), CGPoint(x: 16 + 68 * level, y: 52)], color: tint, width: 2) }
                for x in [CGFloat(14), 84] {
                    context.stroke(Path(ellipseIn: CGRect(x: x, y: 23, width: 3, height: 3)), with: .color(tint.opacity(0.6)), lineWidth: 1)
                }
            }
        }.accessibilityHidden(true)
    }
}
