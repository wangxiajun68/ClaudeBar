import SwiftUI

/// De-emphasized eyebrow section header: small icon + uppercase micro label,
/// with an optional live count on the right. Counts roll via
/// `contentTransition(.numericText())`; the eyebrow stays quiet — the data
/// carries the weight.
struct SectionHeader: View {
    let icon: String
    let title: String
    /// Accent used for the icon's pulsing state.
    var tint: Color = Theme.claude
    var count: Int? = nil
    /// Second component of the count, e.g. busy/active split ("● 1B · 2I").
    var activeCount: Int? = nil
    var activeSymbol: String = "B"
    /// Shown instead of a count when `count` is zero.
    var emptyLabel: String = "none"

    var body: some View {
        HStack(spacing: Theme.Space.s6) {
            Image(systemName: icon)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textSecondary)
            Text(title)
                .font(Theme.Font.microSemibold)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            trailingView
        }
    }

    @ViewBuilder private var trailingView: some View {
        if let count {
            if count == 0 {
                Text(emptyLabel)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            } else if let activeCount {
                Text("● \(activeCount)\(activeSymbol) · \(count - activeCount)I")
                    .font(Theme.Font.microMedium)
                    .monospacedDigit()
                    .foregroundColor(Theme.textSecondary)
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: activeCount)
                    .animation(Theme.Animation.smooth, value: count)
            } else {
                Text("\(count)")
                    .font(Theme.Font.microMedium)
                    .monospacedDigit()
                    .foregroundColor(Theme.textSecondary)
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: count)
            }
        }
    }
}
