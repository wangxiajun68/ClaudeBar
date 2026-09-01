import SwiftUI

/// EKG-style busy heartbeat: a Canvas of ticks from the store's poll history.
struct HeartbeatSparkline: View {
    let trail: [Bool]
    var tint: Color = Theme.statusBusy

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 1.5
            let w: CGFloat = 2
            let step = w + gap
            if trail.isEmpty {
                for i in 0..<8 {
                    let x = CGFloat(i) * step
                    let rect = CGRect(x: x, y: (size.height - 4) / 2, width: w, height: 4)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(Color.white.opacity(0.08)))
                }
                return
            }
            for (i, busy) in trail.enumerated() {
                let x = CGFloat(i) * step
                let h: CGFloat = busy ? 9 : 4
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(busy ? tint.opacity(0.9) : Color.white.opacity(0.14)))
            }
        }
        .frame(width: CGFloat(max(trail.count, 8)) * 3.5, height: 9)
    }
}
