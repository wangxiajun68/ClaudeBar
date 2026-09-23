import SwiftUI

/// Resolution-independent product marks, drawn locally without image decoding.
struct ProductBrandMark: View {
    let codex: Bool

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            context.scaleBy(x: side / 100, y: side / 100)
            if codex {
                // Scalloped Codex silhouette with its terminal chevron and cursor.
                var outline = Path()
                outline.move(to: CGPoint(x: 21, y: 25))
                outline.addCurve(to: CGPoint(x: 51, y: 12), control1: CGPoint(x: 20, y: 7), control2: CGPoint(x: 42, y: 2))
                outline.addCurve(to: CGPoint(x: 79, y: 27), control1: CGPoint(x: 69, y: 4), control2: CGPoint(x: 85, y: 13))
                outline.addCurve(to: CGPoint(x: 89, y: 54), control1: CGPoint(x: 99, y: 31), control2: CGPoint(x: 99, y: 47))
                outline.addCurve(to: CGPoint(x: 70, y: 84), control1: CGPoint(x: 98, y: 72), control2: CGPoint(x: 84, y: 89))
                outline.addCurve(to: CGPoint(x: 40, y: 89), control1: CGPoint(x: 64, y: 100), control2: CGPoint(x: 47, y: 99))
                outline.addCurve(to: CGPoint(x: 14, y: 71), control1: CGPoint(x: 20, y: 98), control2: CGPoint(x: 8, y: 86))
                outline.addCurve(to: CGPoint(x: 12, y: 43), control1: CGPoint(x: 0, y: 64), control2: CGPoint(x: 1, y: 49))
                outline.addCurve(to: CGPoint(x: 21, y: 25), control1: CGPoint(x: 5, y: 30), control2: CGPoint(x: 11, y: 23))
                outline.closeSubpath()
                context.fill(outline, with: .linearGradient(Gradient(colors: [Color(red: 0.62, green: 0.54, blue: 1), Color(red: 0.24, green: 0.32, blue: 0.95)]), startPoint: CGPoint(x: 30, y: 8), endPoint: CGPoint(x: 65, y: 95)))
                var terminal = Path()
                terminal.move(to: CGPoint(x: 29, y: 36))
                terminal.addLine(to: CGPoint(x: 40, y: 51))
                terminal.addLine(to: CGPoint(x: 29, y: 66))
                terminal.move(to: CGPoint(x: 51, y: 67))
                terminal.addLine(to: CGPoint(x: 72, y: 67))
                context.stroke(terminal, with: .color(.white), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            } else {
                // Claude's irregular radial asterisk; each tapered ray has its own length.
                let radii: [CGFloat] = [43, 37, 44, 36, 42, 40, 44, 35, 43, 39, 45, 36]
                var star = Path()
                for (index, radius) in radii.enumerated() {
                    let angle = CGFloat(index) * .pi / 6 - .pi / 2
                    let direction = CGPoint(x: cos(angle), y: sin(angle))
                    let normal = CGPoint(x: -direction.y, y: direction.x)
                    let width: CGFloat = index.isMultiple(of: 3) ? 4 : 3
                    star.move(to: CGPoint(x: 50 + direction.x * 8 + normal.x * 4, y: 50 + direction.y * 8 + normal.y * 4))
                    star.addLine(to: CGPoint(x: 50 + direction.x * radius + normal.x * width, y: 50 + direction.y * radius + normal.y * width))
                    star.addLine(to: CGPoint(x: 50 + direction.x * radius - normal.x * width, y: 50 + direction.y * radius - normal.y * width))
                    star.addLine(to: CGPoint(x: 50 + direction.x * 8 - normal.x * 4, y: 50 + direction.y * 8 - normal.y * 4))
                    star.closeSubpath()
                }
                star.addEllipse(in: CGRect(x: 39, y: 39, width: 22, height: 22))
                context.fill(star, with: .color(Color(red: 0.82, green: 0.43, blue: 0.31)))
            }
        }.accessibilityLabel(codex ? "Codex" : "Claude Code")
    }
}
