import CoreGraphics

/// One outline drives both vector drawing and desktop mouse capture.
/// Coordinates are in the unscaled 260×270 accessory, measured from its top.
enum WoodenFishGeometry {
    // Foreground widths and their keylines are shared by drawing and capture.
    static let goldenRatio: CGFloat = (1 + sqrt(5)) / 2
    // Visible bounds include the keyline; the Canvas uses a uniform projection.
    static let bodyBounds = CGRect(x: 21, y: 38, width: 178, height: 178 / goldenRatio)
    static let bodyStrokeWidth: CGFloat = 6
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
        let r = bodyBounds.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)
        }
        let path = CGMutablePath()
        path.move(to: p(0, 0.55))
        path.addCurve(to: p(0.43, 0), control1: p(0, 0.24), control2: p(0.19, 0))
        path.addCurve(to: p(1, 0.52), control1: p(0.75, 0), control2: p(1, 0.20))
        path.addCurve(to: p(0.51, 1), control1: p(1, 0.83), control2: p(0.78, 1))
        path.addCurve(to: p(0, 0.55), control1: p(0.20, 1), control2: p(0, 0.86))
        path.closeSubpath()
        return path
    }

    // Immutable outlines are prepared once, never allocated on each mouse move.
    private static let captureBody = bodyPath()
    private static let captureBodyEdge = bodyPath().copy(strokingWithWidth: outlineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    private static let captureBase = basePath().copy(strokingWithWidth: baseWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    private static let captureHandle = malletHandlePath()
    private static let captureHead = malletHeadPath()
    private static let captureHandleEdge = malletHandlePath().copy(strokingWithWidth: malletWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    private static let captureHeadEdge = malletHeadPath().copy(strokingWithWidth: malletWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)

    static func captures(_ point: CGPoint, scale: CGFloat = 1) -> Bool {
        guard scale.isFinite, scale > 0 else { return false }
        // The transparent upper margin keeps native height for word-cloud breathing room.
        let point = CGPoint(x: point.x / scale, y: 36 + (point.y - 36) / scale)
        let art = CGPoint(x: (point.x - 10) * 220 / 240, y: (point.y - 56) * 220 / 240)
        // The solid instrument's enclosed interior remains an easy tap target.
        if captureBody.contains(art) || captureBodyEdge.contains(art) || captureBase.contains(art) { return true }
        // Invert the view's exact 74×23 top-trailing mallet transform:
        // artwork origin (10,56), offset (7,18), rotation −38° about (37,11.5).
        let relative = CGPoint(x: point.x - 10 - 173 - 37, y: point.y - 56 - 18 - 11.5)
        let angle = 38.0 * Double.pi / 180
        let local = CGPoint(x: cos(angle) * relative.x - sin(angle) * relative.y + 37,
                            y: sin(angle) * relative.x + cos(angle) * relative.y + 11.5)
        return captureHandle.contains(local) || captureHead.contains(local)
            || captureHandleEdge.contains(local) || captureHeadEdge.contains(local)
    }
}

/// Native-point slop distinguishes a relaxed click from repositioning at every size.
struct WoodenFishPointerGesture {
    private var origin: CGPoint?
    var isTracking: Bool { origin != nil }
    mutating func begin(at point: CGPoint) { origin = point }
    func shouldDrag(to point: CGPoint) -> Bool {
        guard let origin else { return false }
        return hypot(point.x - origin.x, point.y - origin.y) >= 5
    }
    mutating func end(at point: CGPoint) -> Bool {
        let strike = isTracking && !shouldDrag(to: point)
        cancel()
        return strike
    }
    mutating func cancel() { origin = nil }
}
