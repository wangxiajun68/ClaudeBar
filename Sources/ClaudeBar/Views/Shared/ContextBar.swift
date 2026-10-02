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
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(Theme.cardFill(0.08))
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(tint ?? Theme.contextColor(ratio))
                    .frame(width: max(height, geo.size.width * min(max(ratio, 0), 1.0)))
            }
        }
        .frame(height: height)
    }
}
