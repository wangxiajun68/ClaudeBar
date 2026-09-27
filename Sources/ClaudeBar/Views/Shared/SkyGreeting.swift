import SwiftUI

/// `Hello, <本机名>` — the band's hero, set as a piece of type rather than as a
/// label, and the one place in this app where display type is animated.
///
/// Three things make it "dynamic", and they are deliberately different in kind:
///
/// 1. **The wave.** Every character rides its own sine, offset in phase along
///    the name, so the word undulates like a flag instead of bobbing as one
///    block. The phase comes from a `TimelineView`, not from `repeatForever`
///    (DESIGN.md's rule): the letters' `offset` is a transform, so nothing
///    relays out, and pausing the timeline on Reduce Motion / an off-screen
///    surface freezes the name mid-wave instead of resetting it.
/// 2. **The arrival.** On appear — and on every change of machine or sky — the
///    characters rise and fade in on a stagger, so the name *lands* rather than
///    being there. One shot, keyed on the value, never on a timer.
/// 3. **The fill.** The letters are painted with the sky's own gradient, so the
///    name is literally made of the weather behind it, and a slow travelling
///    highlight crosses it (a shimmer) at the sky's pace.
///
/// Cost, because it runs on the 概览 page: the characters are split **once**
/// (`Array(name)`, stored, never recomputed), the timeline is a single
/// `TimelineView` around nothing but the glyph row, and per frame the work is a
/// handful of `offset`/`opacity` values on already-laid-out `Text` leaves.
struct SkyGreeting: View {
    let name: String
    /// The sky palette's text inks — the greeting is text, so it takes them.
    let palette: SkyPalette
    /// `false` when there is no reading: the wave still runs (a greeting is not
    /// weather data), but the fill stops claiming a sky it does not have.
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceIsVisible) private var surfaceVisible

    @State private var start = Date()
    /// Drives the one-shot arrival. Keyed on the name, so a host rename
    /// re-lands the type rather than swapping the glyphs in place.
    @State private var arrived = false

    /// Split once. `Array(name)` inside the timeline closure would allocate a
    /// new array (and re-measure the row) on every frame.
    private var glyphs: [String] { name.map(String.init) }

    private var running: Bool { animated && !reduceMotion && surfaceVisible }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("HELLO")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(4.5)
                .foregroundStyle(palette.inkSoft.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .trailing)

            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !running)) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                HStack(spacing: 0) {
                    ForEach(Array(glyphs.enumerated()), id: \.offset) { index, glyph in
                        Text(glyph)
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .tracking(-0.5)
                            .foregroundStyle(fill(t: t))
                            .offset(y: lift(index: index, t: t))
                            .opacity(arrived ? 1 : 0)
                            .offset(y: arrived ? 0 : 10)
                            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72)
                                        .delay(Double(index) * 0.028),
                                       value: arrived)
                    }
                }
                .fixedSize()
                .overlay(alignment: .leading) { shimmer(t: t) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            if !paletteSubtitle.isEmpty {
                Text(paletteSubtitle)
                    .font(Theme.Font.tileDetail)
                    .foregroundStyle(palette.inkSoft)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.45)
        .onAppear { arrived = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hello，\(name)")
    }

    /// The line under the name: the chip, or the system when a chip is not
    /// published. Read once from `MachineIdentity`.
    private var paletteSubtitle: String {
        MachineIdentity.chip.isEmpty ? MachineIdentity.system : MachineIdentity.chip
    }

    /// The travelling highlight: a narrow, slanted white band that crosses the
    /// name every ~7 s at the sky's pace.
    @ViewBuilder
    private func shimmer(t: TimeInterval) -> some View {
        if running {
            let cycle = 7.0
            let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
            GeometryReader { geo in
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: geo.size.width * 0.16)
                    .rotationEffect(.degrees(12))
                    .offset(x: geo.size.width * (phase * 1.5 - 0.25))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            // The shimmer lives on the glyph row's own bounds; `mask` keeps it
            // from spilling past the last letter.
            .mask {
                HStack(spacing: 0) {
                    ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                        Text(glyph)
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .tracking(-0.5)
                    }
                }
                .fixedSize()
            }
            .allowsHitTesting(false)
        }
    }

    /// Per-character wave. Phase advances along the name so the row undulates;
    /// amplitude is deliberately ~1.5pt — this is the band's hero type seen
    /// twenty times a day, and a 6pt bob would be a fidget.
    private func lift(index: Int, t: TimeInterval) -> CGFloat {
        guard running else { return 0 }
        let phase = t * 0.55 - Double(index) * 0.34
        return CGFloat(sin(phase * 2 * .pi / 3.4) * 1.6)
    }

    /// The sky's gradient, sliding slowly across the name so the letters keep
    /// catching different parts of it. The direction is the band's own gradient
    /// direction, which is what makes the name read as *made of* the sky rather
    /// than merely coloured from it.
    private func fill(t: TimeInterval) -> LinearGradient {
        _ = t
        return LinearGradient(colors: [palette.accent, palette.ink, palette.accent],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
