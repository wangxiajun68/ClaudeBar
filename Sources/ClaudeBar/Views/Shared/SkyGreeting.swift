import SwiftUI

/// A handwritten salutation beside a condensed signature. Both are installed
/// macOS faces; the fallback keeps every machine legible without font downloads.
struct SkyGreeting: View {
    let name: String
    let palette: SkyPalette
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened = false

    private var script: String {
        NSFont(name: "SnellRoundhand-Bold", size: 100) == nil ? "HelveticaNeue-LightItalic" : "SnellRoundhand-Bold"
    }
    private var signature: String {
        NSFont(name: "AvenirNextCondensed-DemiBold", size: 72) == nil ? "HelveticaNeue-CondensedBold" : "AvenirNextCondensed-DemiBold"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            phrase(hello: 106, name: 76)
            phrase(hello: 82, name: 58)
            phrase(hello: 64, name: 44)
        }
        .foregroundStyle(palette.ink)
        .shadow(color: palette.isLightGround ? .clear : .black.opacity(0.12), radius: 12, x: 0, y: 4)
        .onAppear { opened = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hello，\(name)")
    }

    private func phrase(hello: CGFloat, name size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("Hello")
                .font(.custom(script, size: hello))
                .tracking(-2)
                .rotationEffect(.degrees(-5), anchor: .bottomLeading)
                .offset(y: opened || reduceMotion || !animated ? 0 : 12)
                .animation(reduceMotion || !animated ? nil : .spring(response: 1.1, dampingFraction: 0.8), value: opened)
            Text(name)
                .font(.custom(signature, size: size))
                .tracking(opened || reduceMotion || !animated ? -1.8 : -4)
                .animation(reduceMotion || !animated ? nil : .spring(response: 1.2, dampingFraction: 0.9).delay(0.08), value: opened)
        }
        .fixedSize()
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
}
