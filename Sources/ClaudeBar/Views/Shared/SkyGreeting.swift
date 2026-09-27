import SwiftUI

/// A handwritten salutation beside a condensed signature. Both are installed
/// macOS faces; the fallback keeps every machine legible without font downloads.
///
/// **What** the salutation says is `GreetingPhrase`'s decision, not this view's:
/// the script word and its optional aside are handed in already chosen, so this
/// view never reads a clock and the wording can be tested on its own. It used to
/// be the literal `"Hello"` at every hour of every day — see `GreetingPhrase`
/// for why the card says "Still up" at 23:28 instead of a bright greeting.
///
/// The entrance is the card's own and is unchanged: the script word rises
/// 12pt into place on one spring while the signature tightens its tracking from
/// -4 to -1.8 on a slower one, 80ms behind. What changed is only *when* it
/// runs. It used to be a `onAppear`-only latch — one entry per view lifetime —
/// and an entrance you can only ever see once is a fact about the view, not
/// about the greeting. The greeting is also re-armed when the pointer arrives,
/// so pointing at the name replays the same entrance, and leaving eases it back
/// out through the *same two springs*, in reverse.
///
/// Leaving is the same animation, not a second one: every animated property
/// reads `presented`, so the pointer leaving is just that value going back to
/// its start. Nothing here opens a separate transaction — an earlier version
/// wrapped the re-arm in its own `.easeOut`, which put a visible hitch in front
/// of the entrance and made the hover replay look nothing like the card's own.
///
/// Reduce Motion keeps every end position and drops the travel, exactly as it
/// did before: the type is still there, it just arrives rather than moves in.
/// The hover target is the *drawn* greeting plus a little breathing room, not
/// the full width of the card, so the animation does not fire from the pointer
/// crossing the clock or the weather beside it.
struct SkyGreeting: View {
    let name: String
    let palette: SkyPalette
    /// The salutation to draw. Defaulted to the plain daytime greeting so the
    /// preview fixture and any other caller that has no clock keeps working;
    /// the card passes the time-aware phrase.
    var phrase: GreetingPhrase.Phrase = GreetingPhrase.forDate(Date())
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceIsVisible) private var surfaceVisible
    /// Pointer is on the greeting.
    @State private var hovering = false
    /// The greeting is drawn in its arrived position — the state the card opens
    /// into, and the state a hover returns it to. This is the old `opened`
    /// latch; the only thing that differs is what sets it back to `false`.
    @State private var presented = false

    private var script: String {
        NSFont(name: "SnellRoundhand-Bold", size: 100) == nil ? "HelveticaNeue-LightItalic" : "SnellRoundhand-Bold"
    }
    private var signature: String {
        NSFont(name: "AvenirNextCondensed-DemiBold", size: 72) == nil ? "HelveticaNeue-CondensedBold" : "AvenirNextCondensed-DemiBold"
    }

    var body: some View {
        // The aside is its own row under the type, and `ViewThatFits` has to see
        // it to decide the script size — a long festival word beside a long
        // machine name is the one case that needs the smaller step. So the
        // fitted unit is the whole greeting, not just the name line.
        ViewThatFits(in: .horizontal) {
            greetingLine(script: 106, name: 76)
            greetingLine(script: 82, name: 58)
            greetingLine(script: 64, name: 44)
        }
        .foregroundStyle(palette.ink)
        .shadow(color: palette.isLightGround ? .clear : .black.opacity(0.12), radius: 12, x: 0, y: 4)
        // Two triggers, one entrance: the card opening, and the pointer
        // arriving on the name.
        .onAppear { presented = true }
        .onHover { inside in
            guard surfaceVisible else { return }
            guard hovering != inside else { return }
            hovering = inside
            // Leaving hands the same springs their start value back; no
            // transaction is opened here, so the retreat*is* the entrance run
            // backwards.
            presented = inside
            // The pointer can arrive while the entrance is still in flight, so
            // the re-arm is deferred to the next frame. A press inside the same
            // transaction as the rewind would be coalesced into it and the
            // replay would start from wherever the entrance had got to.
            if inside { rearmNextFrame() }
        }
        .accessibilityElement(children: .ignore)
        // English punctuation: the label is read by VoiceOver, which announces
        // a CJK comma as a pause if at all. The aside is a separate clause, so
        // it takes a period and a space rather than being comma-spliced on.
        .accessibilityLabel(phrase.aside.map { "\(phrase.script). \($0). \(name)" }
                            ?? "\(phrase.script), \(name)")
    }

    /// Put the value back to `true` one frame after the pointer landed, so the
    /// springs have a start position to travel from.
    private func rearmNextFrame() {
        Task { @MainActor in
            await Task.yield()
            presented = true
        }
    }

    private func greetingLine(script scriptSize: CGFloat, name size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(phrase.script)
                    .font(.custom(script, size: scriptSize))
                    .tracking(-2)
                    .rotationEffect(.degrees(-5), anchor: .bottomLeading)
                    .offset(y: presented || reduceMotion || !animated ? 0 : 12)
                    .animation(reduceMotion || !animated ? nil : .spring(response: 1.1, dampingFraction: 0.8), value: presented)
                Text(name)
                    .font(.custom(signature, size: size))
                    .tracking(presented || reduceMotion || !animated ? -1.8 : -4)
                    .animation(reduceMotion || !animated ? nil : .spring(response: 1.2, dampingFraction: 0.9).delay(0.08), value: presented)
            }
            .fixedSize()
            // The aside rides the same spring as the word above it, so the
            // greeting arrives as one gesture and its quiet second line does
            // not fade in on a different beat.
            if let aside = phrase.aside {
                Text(aside)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(palette.inkSoft)
                    .padding(.leading, 4)
                    .offset(y: presented || reduceMotion || !animated ? 0 : 8)
                    .animation(reduceMotion || !animated ? nil : .spring(response: 1.1, dampingFraction: 0.85).delay(0.06), value: presented)
            }
        }
        .fixedSize()
        .padding(.top, 6)
        .padding(.bottom, 12)
        // The hit shape is the greeting itself, sized by the drawn type — the
        // whole card is a button and must not become the greeting's hover
        // region, or the animation would fire from anywhere on the surface.
        .contentShape(Rectangle().inset(by: -10))
    }
}
