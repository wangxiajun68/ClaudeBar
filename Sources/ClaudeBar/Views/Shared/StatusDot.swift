import SwiftUI

/// Semantic status dot: hue carries the meaning, pulse when busy. The single
/// 6px `Circle().fill(...)` that used to be hand-rolled in SessionCardView,
/// MenuBarView, and DashboardView.
struct StatusDot: View {
    var isBusy: Bool
    var color: Color = Theme.statusBusy
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(isBusy ? color : Theme.statusIdle.opacity(0.5))
            .frame(width: size, height: size)
            .symbolEffect(.pulse, options: .repeating, isActive: isBusy)
    }
}
