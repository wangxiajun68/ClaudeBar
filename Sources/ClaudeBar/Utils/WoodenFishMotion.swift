import Foundation
import CoreGraphics

/// A bounded, view-owned pool lets quick taps overlap without accumulating
/// views or keeping an idle display loop alive.
struct WoodenFishBurstPool {
    static let capacity = 8
    private(set) var ids: [UInt] = []

    mutating func emit(_ id: UInt) {
        guard !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > Self.capacity { ids.removeFirst(ids.count - Self.capacity) }
    }

    mutating func expire(_ id: UInt) { ids.removeAll { $0 == id } }
}

enum WoodenFishMotion {
    struct Particle {
        var offset: CGPoint
        var opacity: Double
        var scale: Double
        var angle: Double
    }

    /// Coordinates fit the existing transparent canvas; particles never
    /// enlarge the window or its mouse-capture outline.
    static func particle(progress: Double, lane: Int, reducedMotion: Bool) -> Particle {
        let p = min(1, max(0, progress))
        let targets: [CGPoint] = [CGPoint(x: -76, y: -65), CGPoint(x: 2, y: -95),
                                 CGPoint(x: 72, y: -56), CGPoint(x: -89, y: -38),
                                 CGPoint(x: -40, y: -92), CGPoint(x: 47, y: -86),
                                 CGPoint(x: 96, y: -29)]
        let target = targets[min(targets.count - 1, max(0, lane))]
        let opacity = min(1, p / 0.09) * max(0, min(1, (1 - p) / 0.42))
        return Particle(offset: reducedMotion ? .zero : CGPoint(x: target.x * p, y: target.y * p),
                        opacity: opacity, scale: reducedMotion ? 1 : 0.7 + 0.3 * min(1, p / 0.2),
                        angle: reducedMotion ? 0 : Double(lane - 1) * 5 * p)
    }
}
