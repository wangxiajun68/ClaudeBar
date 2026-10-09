import CoreGraphics

/// One outline drives both vector drawing and desktop mouse capture.
/// Coordinates are in the unscaled 260×270 accessory, measured from its top.
enum WoodenFishGeometry {
    // Foreground widths and their keylines are shared by drawing and capture.
    static let goldenRatio: CGFloat = (1 + sqrt(5)) / 2
    // Visible bounds include the keyline; the Canvas uses a uniform projection.
    static let bodyBounds = CGRect(x: 21, y: 38, width: 178, height: 178 / goldenRatio)
    static let bodyStrokeWidth: CGFloat = 16
    static let baseStrokeWidth: CGFloat = 8
    static let malletStrokeWidth: CGFloat = 10
    static let keylineWidth: CGFloat = 1.8
    static var outlineWidth: CGFloat { bodyStrokeWidth + keylineWidth }
    static var baseWidth: CGFloat { baseStrokeWidth + keylineWidth }
    static var malletWidth: CGFloat { malletStrokeWidth + keylineWidth }

    static func basePath() -> CGPath {
        let width = bodyBounds.width / goldenRatio - baseWidth
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bodyBounds.midX - width / 2, y: 150))
        path.addQuadCurve(to: CGPoint(x: bodyBounds.midX + width / 2, y: 150),
                          control: CGPoint(x: bodyBounds.midX, y: 168))
        return path
    }

    static func eyePath() -> CGPath {
        let center = CGPoint(x: bodyBounds.minX + bodyBounds.width / goldenRatio,
                             y: bodyBounds.minY + bodyBounds.height / (goldenRatio * goldenRatio))
        return CGPath(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10), transform: nil)
    }

    static func malletHeadPath() -> CGPath {
        CGPath(ellipseIn: CGRect(x: 0, y: -0.5, width: 24, height: 24), transform: nil)
    }

    static func malletHandlePath() -> CGPath {
        let height = (24 + malletWidth) / goldenRatio - malletWidth
        return CGPath(roundedRect: CGRect(x: 23, y: 11.5 - height / 2, width: 51, height: height),
                      cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
    }

    static func bodyPath() -> CGPath {
        CGPath(ellipseIn: bodyBounds.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2), transform: nil)
    }

    static func captures(_ point: CGPoint, scale: CGFloat = 1) -> Bool {
        guard scale.isFinite, scale > 0 else { return false }
        // The transparent upper margin keeps native height for word-cloud breathing room.
        let point = CGPoint(x: point.x / scale, y: 36 + (point.y - 36) / scale)
        let art = CGPoint(x: (point.x - 10) * 220 / 240, y: (point.y - 56) * 220 / 240)
        // The solid instrument's enclosed interior remains an easy tap target.
        if bodyPath().contains(art)
            || bodyPath().copy(strokingWithWidth: outlineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(art) { return true }
        if basePath().copy(strokingWithWidth: baseWidth, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(art) { return true }
        // Invert the view's exact 74×23 top-trailing mallet transform:
        // artwork origin (10,56), offset (7,18), rotation −38° about (37,11.5).
        let relative = CGPoint(x: point.x - 10 - 173 - 37, y: point.y - 56 - 18 - 11.5)
        let angle = 38.0 * Double.pi / 180
        let local = CGPoint(x: cos(angle) * relative.x - sin(angle) * relative.y + 37,
                            y: sin(angle) * relative.x + cos(angle) * relative.y + 11.5)
        return malletHandlePath().contains(local) || malletHeadPath().contains(local)
            || malletHandlePath().copy(strokingWithWidth: malletWidth, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(local)
            || malletHeadPath().copy(strokingWithWidth: malletWidth, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(local)
    }
}
