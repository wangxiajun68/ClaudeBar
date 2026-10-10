import Foundation
import CoreGraphics

/// A bounded, view-owned pool lets quick taps overlap without accumulating
/// views or keeping an idle display loop alive.
struct WoodenFishBurstPool {
    static let capacity = 8
    struct Entry: Identifiable {
        let id: UInt
        let feedback: WoodenFishStrikeFeedback
    }
    private(set) var entries: [Entry] = []
    var ids: [UInt] { entries.map(\.id) }
    var celebration: WoodenFishSurprise? { entries.last { $0.feedback.surprise != nil }?.feedback.surprise }

    mutating func emit(_ id: UInt, feedback: WoodenFishStrikeFeedback = .init()) {
        guard !ids.contains(id) else { return }
        entries.append(Entry(id: id, feedback: feedback))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    // SwiftUI can coalesce several events in one frame. Preserve each recent
    // strike's word instead of silently drawing only the last one.
    mutating func emit(from previous: UInt, through id: UInt, feedback: WoodenFishStrikeFeedback) {
        let count = min(id &- previous, UInt(Self.capacity))
        guard count > 0 else { return }
        for step in 0..<count {
            var snapshot = feedback
            snapshot.combo = max(0, feedback.combo - Int(count - step - 1))
            if step != count - 1 { snapshot.surprise = nil }
            emit(id &- (count - step - 1), feedback: snapshot)
        }
    }

    mutating func expire(_ id: UInt) { entries.removeAll { $0.id == id } }

}

enum WoodenFishMotion {
    struct Particle {
        var offset: CGPoint
        var opacity: Double
        var scale: Double
        var angle: Double
    }

    /// Each strike owns a stable, different flight. New strikes never reposition
    /// existing words. Native bounds keep the spray inside the transparent window.
    static func word(progress: Double, id: UInt, reducedMotion: Bool, displayScale: CGFloat = 0.72) -> Particle {
        let p = min(1, max(0, progress))
        let opacity = min(1, p / 0.06) * max(0, min(1, (1 - p) / 0.35))
        guard !reducedMotion else {
            return Particle(offset: .zero, opacity: opacity, scale: 1, angle: 0)
        }
        func variation(_ salt: UInt64) -> Double {
            var value = UInt64(id) &+ salt &+ 0x9E3779B97F4A7C15
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            value ^= value >> 31
            return Double(value >> 11) / 9_007_199_254_740_992
        }
        // Low-discrepancy angles distribute a rapid sequence across the fan;
        // per-strike variation changes origin, reach, curvature and launch speed.
        let phase = Double(id % 65_536) * 0.61803398875 + (variation(1) - 0.5) * 0.12
        let angle = (-160 + 140 * (phase - floor(phase))) * .pi / 180
        let horizontalReach = max(0, 130 * Double(displayScale) - 32)
        let origin = CGPoint(x: (variation(2) - 0.5) * horizontalReach * 1.1,
                             y: -22 + 62 * variation(3))
        let minimumY = 22 - (36 + 91 * Double(displayScale))
        let destination = CGPoint(x: cos(angle) * horizontalReach * (0.72 + 0.24 * variation(4)),
                                  y: max(minimumY, origin.y + sin(angle) * (44 + 44 * variation(5))))
        let travel = 1 - pow(1 - p, 2.8 + 1.4 * variation(6))
        let bend = sin(p * .pi) * (variation(7) - 0.5) * 10
        let bloom = min(1, p / 0.18)
        let scale = 0.76 + 0.24 * (1 - pow(1 - bloom, 3)) + 0.06 * sin(bloom * .pi)
        return Particle(offset: CGPoint(x: origin.x + (destination.x - origin.x) * travel + bend,
                                        y: origin.y + (destination.y - origin.y) * travel),
                        opacity: opacity, scale: scale * (0.94 + 0.06 * variation(8)),
                        angle: (variation(9) - 0.5) * (8 + 20 * travel))
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


struct WoodenFishStrikeFeedback: Equatable {
    var combo = 0
    var surprise: WoodenFishSurprise?
    var isGolden: Bool { combo >= 8 || surprise != nil }
}

enum WoodenFishSurprise: CaseIterable, Hashable {
    case firstOfDay, flow, matrix, cache, peace, hello, innerPeace
    var message: String {
        switch self {
        case .firstOfDay: return "今日开敲"
        case .flow: return "8 连击 · 进入心流"
        case .matrix: return "There is no spoon."
        case .cache: return "烦恼 Cache Miss"
        case .peace: return "108 · 心静如水"
        case .hello: return "1024 · Hello, world."
        case .innerPeace: return "4096 · Inner peace"
        }
    }
}

/// Session-only manual rhythm. It never changes actual token usage, awards
/// extra counts, plays extra sound, or lets the automatic timer farm surprises.
struct WoodenFishRhythm {
    private var previous: Date?
    private var manualDay: Date?
    private var combo = 0
    private var lastShown: [WoodenFishSurprise: Date] = [:]

    mutating func resetChain() { previous = nil; combo = 0 }

    mutating func strike(at now: Date, automatic: Bool, today: Int, total: Int) -> WoodenFishStrikeFeedback {
        guard !automatic else { return .init() }
        let day = Calendar.current.startOfDay(for: now)
        let firstManual = manualDay != day
        manualDay = day
        let gap = previous.map { now.timeIntervalSince($0) }
        combo = gap.map { $0 >= 0 && $0 <= 0.55 } == true ? min(999, combo + 1) : 1
        previous = now
        let candidate: WoodenFishSurprise?
        switch total {
        case 108: candidate = .peace
        case 1024: candidate = .hello
        case 4096: candidate = .innerPeace
        default:
            switch combo {
            case 8: candidate = .flow
            case 16: candidate = .matrix
            case 32: candidate = .cache
            default: candidate = firstManual ? .firstOfDay : nil
            }
        }
        var surprise: WoodenFishSurprise?
        if let candidate {
            let elapsed = lastShown[candidate].map { now.timeIntervalSince($0) }
            if elapsed.map({ $0 >= 8 || $0 < 0 }) ?? true {
                lastShown[candidate] = now
                surprise = candidate
            }
        }
        return WoodenFishStrikeFeedback(combo: combo, surprise: surprise)
    }
}
