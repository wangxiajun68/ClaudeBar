import SwiftUI

/// A tiny live equalizer — a few bars that dance while a session is busy and
/// collapse to a dim rest state when idle. Conveys "this agent is working" at
/// a glance without a moving dot or a spinner. Driven by TimelineView so the
/// motion is smooth and GPU-cheap; collapses to static under reduced motion.
struct SignalTrace: View {
    var isActive: Bool
    var color: Color
    var bars: Int = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isActive && !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<bars, id: \.self) { i in
                            Capsule()
                                .fill(color.opacity(0.9))
                                .frame(width: 2, height: barHeight(i, t: t))
                        }
                    }
                    .frame(height: 10)
                }
            } else {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<bars, id: \.self) { _ in
                        Capsule()
                            .fill(color.opacity(0.25))
                            .frame(width: 2, height: 3)
                    }
                }
                .frame(height: 10)
            }
        }
        .accessibilityHidden(true)
    }

    /// Offset sine per bar so the trace ripples rather than pulses in unison.
    private func barHeight(_ i: Int, t: Double) -> CGFloat {
        let phase = t * 3.2 + Double(i) * 0.85
        return 3 + (sin(phase) * 0.5 + 0.5) * 6.5
    }
}
