import SwiftUI

/// Context-health progress bar; the fill color tracks
/// `Theme.contextColor(ratio)` (calm → warning → critical).
struct ContextBar: View {
    let ratio: Double
    var height: CGFloat = 4
    /// Override the customary ratio-derived hue. `nil` (the default) keeps the
    /// context tinting; a caller that is reading something other than context
    /// fill — an allowance that is *consumed* rather than *remaining* — passes
    /// its own so the bar does not borrow the wrong meaning.
    var tint: Color? = nil

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(ratio, 0), 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(Theme.cardFill(0.08))
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(tint ?? Theme.contextColor(ratio))
                    // The `max(height, …)` floor keeps a small but non-zero
                    // fill round-cornered instead of a degenerate sliver —
                    // but it must not apply to an empty bar, where a
                    // height-wide pill reads as "some fill" (finding 561).
                    .frame(width: clamped <= 0 ? 0 : max(height, geo.size.width * clamped))
            }
        }
        .frame(height: height)
    }
}
