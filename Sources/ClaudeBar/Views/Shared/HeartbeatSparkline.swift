import SwiftUI

/// EKG-style busy heartbeat: a Canvas of ticks from the store's poll history.
struct HeartbeatSparkline: View {
    let trail: [Bool]
    var tint: Color = Theme.statusBusy

    /// Tick geometry, shared by the Canvas and the intrinsic frame below so the
    /// drawn pitch and the view's width can never drift apart.
    private static let w: CGFloat = 2
    private static let gap: CGFloat = 1.5
    private static let step: CGFloat = w + gap

    var body: some View {
        Canvas { ctx, size in
            if trail.isEmpty {
                for i in 0..<8 {
                    let x = CGFloat(i) * Self.step
                    let rect = CGRect(x: x, y: (size.height - 4) / 2, width: Self.w, height: 4)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(Theme.cardFill(0.10)))
                }
                return
            }
            for (i, busy) in trail.enumerated() {
                let x = CGFloat(i) * Self.step
                let h: CGFloat = busy ? 9 : 4
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: Self.w, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(busy ? tint.opacity(0.9) : Theme.cardFill(0.14)))
            }
        }
        .frame(width: CGFloat(max(trail.count, 8)) * Self.step, height: 9)
    }
}
