import Foundation
import CoreGraphics

/// A bounded, view-owned pool lets quick taps overlap without accumulating
/// views or keeping an idle display loop alive.
struct WoodenFishBurstPool {
    static let capacity = 2
    // Enough fading tails for two coalesced visible strikes per 60Hz frame.
    static let retiringCapacity = 24
    static let fadeDuration = 0.18
    struct Entry: Identifiable {
        let id: UInt
        let createdAt: Date
        let feedback: WoodenFishStrikeFeedback
        var retiredAt: Date?

        func opacity(at now: Date, reducedMotion: Bool) -> Double {
            let progress = max(0, now.timeIntervalSince(createdAt)) / 1.35
            let natural = reducedMotion ? max(0, min(1, (1 - progress) / 0.35)) :
                min(1, progress / 0.06) * max(0, min(1, (1 - progress) / 0.35))
            return natural * retirementOpacity(at: now)
        }

        func retirementOpacity(at now: Date) -> Double {
            guard let retiredAt else { return 1 }
            let p = min(1, max(0, now.timeIntervalSince(retiredAt) / WoodenFishBurstPool.fadeDuration))
            return 1 - p * p * (3 - 2 * p)
        }

        func isFinished(at now: Date) -> Bool {
            if now.timeIntervalSince(createdAt) >= 1.42 { return true }
            guard let retiredAt else { return false }
            // Keep the resonator impulse until it has also settled.
            return now.timeIntervalSince(retiredAt) >= WoodenFishBurstPool.fadeDuration
                && now.timeIntervalSince(createdAt) >= 0.4
        }
    }
    private(set) var active: [Entry] = []
    private(set) var retiring: [Entry] = []
    var entries: [Entry] { retiring + active }
    var ids: [UInt] { entries.map(\.id) }
    var celebration: WoodenFishSurprise? { entries.last { $0.feedback.surprise != nil }?.feedback.surprise }

    mutating func emit(_ id: UInt, feedback: WoodenFishStrikeFeedback = .init(),
                       at now: Date = Date(), reducedMotion: Bool = false) {
        prune(at: now)
        guard !ids.contains(id) else { return }
        active.append(Entry(id: id, createdAt: now, feedback: feedback))
        let limit = reducedMotion ? 1 : Self.capacity
        while active.count > limit {
            var entry = active.removeFirst()
            entry.retiredAt = now
            retiring.append(entry)
        }
        if retiring.count > Self.retiringCapacity {
            retiring.removeFirst(retiring.count - Self.retiringCapacity)
        }
    }

    // Only the newest two events in one display transaction could be visible.
    // Previously displayed entries retain their own clock and fade-out state.
    mutating func emit(from previous: UInt, through id: UInt, feedback: WoodenFishStrikeFeedback,
                       at now: Date = Date(), reducedMotion: Bool = false) {
        let count = min(id &- previous, UInt(reducedMotion ? 1 : Self.capacity))
        guard count > 0 else { return }
        for step in 0..<count {
            var snapshot = feedback
            snapshot.combo = max(0, feedback.combo - Int(count - step - 1))
            if step != count - 1 { snapshot.surprise = nil }
            emit(id &- (count - step - 1), feedback: snapshot, at: now, reducedMotion: reducedMotion)
        }
    }

    mutating func prune(at now: Date) {
        active.removeAll { $0.isFinished(at: now) }
        retiring.removeAll { $0.isFinished(at: now) }
    }

    mutating func expire(_ id: UInt) {
        active.removeAll { $0.id == id }
        retiring.removeAll { $0.id == id }
    }
}

enum WoodenFishMotion {
    static func press(from: Double, to: Double, age: Double) -> Double {
        let p = min(1, max(0, age / 0.08))
        return from + (to - from) * (1 - pow(1 - p, 3))
    }

    /// New impulses start at zero, so rapid taps add to the existing rebound
    /// rather than snapping the instrument back to its resting transform.
    static func impact(age: Double) -> Double {
        guard age >= 0, age < 0.4 else { return 0 }
        if age < 0.045 { return age / 0.045 }
        let tail = min(1, max(0, (0.4 - age) / 0.1))
        return exp(-(age - 0.045) * 14) * cos((age - 0.045) * 23)
            * tail * tail * (3 - 2 * tail)
    }

    struct Particle {
        var offset: CGPoint
        var opacity: Double
        var scale: Double
        var angle: Double
    }

    /// Each strike owns a stable, different flight. New strikes never reposition
    /// existing words. Native bounds keep the spray inside the transparent window.
    static func word(progress: Double, id: UInt, reducedMotion: Bool, displayScale: CGFloat = 0.46) -> Particle {
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
        // Both native-size reward lines share this envelope, even at the
        // smallest artwork scale. Leave six points above the count footer.
        let horizontalReach = max(0, 130 * Double(displayScale) - 36)
        let maximumY = 109 * Double(displayScale) - 29
        let origin = CGPoint(x: (variation(2) - 0.5) * horizontalReach * 1.1,
                             y: min(maximumY, -22 + 62 * variation(3)))
        let minimumY = 24 - (36 + 91 * Double(displayScale))
        let destination = CGPoint(x: cos(angle) * horizontalReach * (0.72 + 0.24 * variation(4)),
                                  y: max(minimumY, origin.y + sin(angle) * (44 + 44 * variation(5))))
        let travel = 1 - pow(1 - p, 2.8 + 1.4 * variation(6))
        let bend = sin(p * .pi) * (variation(7) - 0.5) * 10
        let bloom = min(1, p / 0.18)
        let scale = 0.76 + 0.24 * (1 - pow(1 - bloom, 3)) + 0.06 * sin(bloom * .pi)
        return Particle(offset: CGPoint(x: min(horizontalReach, max(-horizontalReach,
                                                origin.x + (destination.x - origin.x) * travel + bend)),
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
