import SwiftUI

/// Context-health progress bar; the fill color tracks
/// `Theme.contextColor(ratio)` (calm → warning → critical).
struct ContextBar: View {
    let ratio: Double
    var height: CGFloat = 4
    var trackOpacity: Double = 0.08

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Theme.cardFill(trackOpacity))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Theme.contextColor(ratio))
                    .frame(width: max(height, geo.size.width * min(max(ratio, 0), 1.0)))
            }
        }
        .frame(height: height)
    }
}