import SwiftUI

/// Section heading: tinted glyph well + title, optional live count.
///
/// `tint` is a *shape* hue (glyph well, dot). The count pill renders as text,
/// so it uses `ink` when one is supplied — the raw signal hues are 1.8–3.4:1
/// on the light canvas.
struct SectionHeader: View {
    let icon: String
    let title: String
    /// Accent used for the icon well.
    var tint: Color = Theme.textSecondary
    /// Readable counterpart of `tint` for the count pill. Defaults to `tint`
    /// so a call site that already picked an ink color keeps working.
    var ink: Color? = nil
    var count: Int? = nil
    /// Second component of the count, e.g. busy/active split ("● 1B · 2I").
    var activeCount: Int? = nil
    var activeSymbol: String = "B"
    /// Shown instead of a count when `count` is zero.
    var emptyLabel: String = "无"

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            GlyphWell(name: icon, tint: tint, size: 18)
            Text(title)
                .font(Theme.Font.section)
                .foregroundColor(Theme.textPrimary)
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
                StatusPill(
                    label: "\(activeCount)\(activeSymbol) · \(count - activeCount)I",
                    tint: activeCount > 0 ? tint : Theme.textSecondary,
                    ink: activeCount > 0 ? (ink ?? tint) : Theme.textSecondary
                )
                .contentTransition(.numericText())
                .animation(Theme.Animation.smooth, value: activeCount)
                .animation(Theme.Animation.smooth, value: count)
            } else {
                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(Theme.textSecondary)
                    .contentTransition(.numericText())
                    .animation(Theme.Animation.smooth, value: count)
            }
        }
    }
}
