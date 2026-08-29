import SwiftUI

/// EKG-style busy heartbeat: a row of thin ticks, one per poll sample —
/// colored while the session was busy, dim gray while idle. Renders the
/// store's existing polling history, adding no polling of its own.
struct HeartbeatSparkline: View {
    /// Oldest → newest busy samples. Empty = no history yet.
    let trail: [Bool]
    /// Hue for busy ticks.
    var tint: Color = Theme.statusBusy

    var body: some View {
        if trail.isEmpty {
            // No history yet — a quiet dotted baseline so layout is stable.
            HStack(spacing: 1.5) {
                ForEach(0..<8, id: \.self) { _ in
                    Capsule().fill(Color.white.opacity(0.08)).frame(width: 2, height: 4)
                }
            }
        } else {
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(trail.indices, id: \.self) { i in
                    let busy = trail[i]
                    Capsule()
                        .fill(busy ? tint.opacity(0.9) : Color.white.opacity(0.14))
                        .frame(width: 2, height: busy ? 9 : 4)
                }
            }
            .animation(Theme.Animation.smooth, value: trail)
        }
    }
}
