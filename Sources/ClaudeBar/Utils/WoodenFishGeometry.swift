import CoreGraphics

/// One outline drives both vector drawing and desktop mouse capture.
/// Coordinates are in the unscaled 260×270 accessory, measured from its top.
enum WoodenFishGeometry {
    static func cushionPath() -> CGPath {
        CGPath(ellipseIn: CGRect(x: 38, y: 126, width: 153, height: 22), transform: nil)
    }

    static func cushionRimPath() -> CGPath {
        CGPath(ellipseIn: CGRect(x: 43, y: 127, width: 142, height: 13), transform: nil)
    }

    static func malletHeadPath() -> CGPath {
        CGPath(ellipseIn: CGRect(x: 0, y: 0.5, width: 24, height: 22), transform: nil)
    }

    static func malletHandlePath() -> CGPath {
        CGPath(roundedRect: CGRect(x: 12, y: 8, width: 62, height: 7), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
    }

    static func bodyPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 36, y: 83))
        path.addCurve(to: CGPoint(x: 113, y: 40), control1: CGPoint(x: 41, y: 52), control2: CGPoint(x: 81, y: 34))
        path.addCurve(to: CGPoint(x: 181, y: 65), control1: CGPoint(x: 145, y: 42), control2: CGPoint(x: 165, y: 47))
        path.addCurve(to: CGPoint(x: 198, y: 91), control1: CGPoint(x: 207, y: 66), control2: CGPoint(x: 211, y: 80))
        path.addCurve(to: CGPoint(x: 164, y: 127), control1: CGPoint(x: 192, y: 114), control2: CGPoint(x: 184, y: 122))
        path.addCurve(to: CGPoint(x: 56, y: 126), control1: CGPoint(x: 137, y: 142), control2: CGPoint(x: 84, y: 144))
        path.addCurve(to: CGPoint(x: 36, y: 83), control1: CGPoint(x: 40, y: 116), control2: CGPoint(x: 29, y: 100))
        path.closeSubpath()
        return path
    }

    static func captures(_ point: CGPoint, showsTools: Bool, scale: CGFloat = 1) -> Bool {
        guard scale.isFinite, scale > 0 else { return false }
        if showsTools {
            // Separate circular buttons; gaps remain click-through.
            for offset in [-60.0, -30.0, 0.0, 30.0, 60.0] {
                if hypot(point.x - (130 * scale + offset), point.y - 18) <= 13 { return true }
            }
        }
        // Header tools keep native dimensions; only the instrument scales.
        let point = CGPoint(x: point.x / scale, y: 36 + (point.y - 36) / scale)
        let art = CGPoint(x: (point.x - 10) * 220 / 240, y: (point.y - 56) * 172 / 180)
        if bodyPath().contains(art) { return true }
        if cushionPath().contains(art) { return true }
        if cushionRimPath().copy(strokingWithWidth: 0.65, lineCap: .butt, lineJoin: .miter, miterLimit: 10).contains(art) { return true }
        // Invert the view's exact 74×23 top-trailing mallet transform:
        // artwork origin (10,56), offset (7,18), rotation −38° about (37,11.5).
        let relative = CGPoint(x: point.x - 10 - 173 - 37, y: point.y - 56 - 18 - 11.5)
        let angle = 38.0 * Double.pi / 180
        let local = CGPoint(x: cos(angle) * relative.x - sin(angle) * relative.y + 37,
                            y: sin(angle) * relative.x + cos(angle) * relative.y + 11.5)
        return malletHandlePath().contains(local) || malletHeadPath().contains(local)
            || malletHeadPath().copy(strokingWithWidth: 0.65, lineCap: .butt, lineJoin: .miter, miterLimit: 10).contains(local)
    }
}
