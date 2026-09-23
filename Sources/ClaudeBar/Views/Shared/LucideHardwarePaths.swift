import SwiftUI

/// Adapted from Lucide gpu / shield-check (ISC); see Resources/Lucide.txt.
/// Shared 24-point geometry keeps small toolbar and large dashboard marks consistent.
enum LucideHardwarePaths {
    static func drawGPU(in context: inout GraphicsContext, tint: Color, level: Double, detailed: Bool) {
        var board = Path()
        board.move(to: CGPoint(x: 2, y: 17))
        board.addLine(to: CGPoint(x: 20, y: 17))
        board.addQuadCurve(to: CGPoint(x: 22, y: 15), control: CGPoint(x: 22, y: 17))
        board.addLine(to: CGPoint(x: 22, y: 7))
        board.addQuadCurve(to: CGPoint(x: 20, y: 5), control: CGPoint(x: 22, y: 5))
        board.addLine(to: CGPoint(x: 2, y: 5))
        var wash = board
        wash.closeSubpath()
        context.fill(wash, with: .linearGradient(Gradient(colors: [tint.opacity(0.05), tint.opacity(0.18)]), startPoint: CGPoint(x: 2, y: 5), endPoint: CGPoint(x: 22, y: 17)))
        let stroke = StrokeStyle(lineWidth: detailed ? 1 : 1.7, lineCap: .round, lineJoin: .round)
        context.stroke(board, with: .color(tint), style: stroke)
        var bracket = Path()
        bracket.move(to: CGPoint(x: 2, y: 21)); bracket.addLine(to: CGPoint(x: 2, y: 3))
        bracket.move(to: CGPoint(x: 7, y: 17)); bracket.addLine(to: CGPoint(x: 7, y: 20))
        bracket.addQuadCurve(to: CGPoint(x: 8, y: 21), control: CGPoint(x: 7, y: 21))
        bracket.addLine(to: CGPoint(x: 13, y: 21))
        bracket.addQuadCurve(to: CGPoint(x: 14, y: 20), control: CGPoint(x: 14, y: 21))
        bracket.addLine(to: CGPoint(x: 14, y: 17))
        context.stroke(bracket, with: .color(tint), style: stroke)
        for x in [CGFloat(8), 16] {
            let core = Path(ellipseIn: CGRect(x: x - 2, y: 9, width: 4, height: 4))
            context.fill(core, with: .color(tint.opacity(0.12 + min(1, max(0, level)) * 0.35)))
            context.stroke(core, with: .color(tint), style: stroke)
        }
    }

    /// Lucide `shield-check`, with the check replaced by a dash (Lucide
    /// `minus`) when the tunnel is off — the shield alone cannot say whether
    /// anything is running, and the caller passes `active` for that.
    static func drawVPN(in context: inout GraphicsContext, tint: Color, active: Bool = true) {
        var shield = Path()
        shield.move(to: CGPoint(x: 20, y: 13))
        shield.addCurve(to: CGPoint(x: 12, y: 22), control1: CGPoint(x: 20, y: 18), control2: CGPoint(x: 16.2, y: 20.6))
        shield.addCurve(to: CGPoint(x: 4, y: 13), control1: CGPoint(x: 7.8, y: 20.6), control2: CGPoint(x: 4, y: 18))
        shield.addLine(to: CGPoint(x: 4, y: 6))
        shield.addQuadCurve(to: CGPoint(x: 5, y: 5), control: CGPoint(x: 4, y: 5))
        shield.addCurve(to: CGPoint(x: 12, y: 2), control1: CGPoint(x: 7, y: 5), control2: CGPoint(x: 10, y: 3.6))
        shield.addCurve(to: CGPoint(x: 19, y: 5), control1: CGPoint(x: 14, y: 3.6), control2: CGPoint(x: 17, y: 5))
        shield.addQuadCurve(to: CGPoint(x: 20, y: 6), control: CGPoint(x: 20, y: 5))
        shield.closeSubpath()
        context.fill(shield, with: .linearGradient(Gradient(colors: [tint.opacity(0.04), tint.opacity(0.2)]), startPoint: CGPoint(x: 4, y: 2), endPoint: CGPoint(x: 20, y: 22)))
        let stroke = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
        context.stroke(shield, with: .color(tint), style: stroke)
        var glyph = Path()
        if active {
            glyph.move(to: CGPoint(x: 9, y: 12))
            glyph.addLine(to: CGPoint(x: 11, y: 14))
            glyph.addLine(to: CGPoint(x: 15, y: 10))
        } else {
            glyph.move(to: CGPoint(x: 9, y: 12))
            glyph.addLine(to: CGPoint(x: 15, y: 12))
        }
        context.stroke(glyph, with: .color(tint), style: stroke)
    }
}
