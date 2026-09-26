import SwiftUI

// Native translations of the *control* language in the Uiverse.io pieces this
// product borrows from — the half the surface file (`UiverseSurfaces.swift`)
// does not cover.
//
// The surfaces file owns what a card *is*; this file owns what a control *does*
// when you touch it. Both files answer to the same two performance rules:
// motion is a one-shot state change or a gated Core Animation layer, and every
// ornament is one `Canvas`/one stroked shape rather than a stack of views.
//
// The reference pieces behind this file:
//
// | Reference | What is borrowed |
// | --- | --- |
// | `metanef` switch | an inset, engraved track with a plated handle — the *recessed* control, not a floating pill |
// | `ultimate-3d-btn` | a conic perimeter that lights the control's own edge (one-shot, hover only) |
// | `mymiamo` glass menu | a milled cradle with an inner top rim and a bottom rule |
// | `om_5409` 3D card | depth behind a selection, never a flat tint |
// | `stat-widget` pill | a conic reading ring around a value, with a real ground shadow |

// MARK: - Instrument field (one field surface for the whole app)

/// The one **field** surface: search boxes, port numbers, provider inputs, the
/// model selector — anything the user types into.
///
/// Before this there were four: `InstrumentSearchField` (radius 9),
/// `ProviderDirectorySearch` (radius 10), `ProviderInputStyle` (radius 10) and
/// `ProviderModelSelector` (radius 10). They agreed on nothing but the idea.
/// This is the single box they should all be, and it carries the two things the
/// reference's controls all have and a stock `TextField` does not:
///
/// 1. **A milled well** — a *recessed* fill (`Theme.cardFill`) rather than a
///    raised white card, so a field reads as "type here" at a glance in a page
///    full of raised tiles. This is the `metanef` switch's `shadow-inset` idea
///    at field scale.
/// 2. **A lit rim on focus** — the accent ring plus the inset frame ring the
///    tiles carry, so a focused field belongs to the same machined family.
///
/// One stroked shape + one inset ring. No blur, no material.
struct InstrumentField<Content: View>: View {
    var radius: CGFloat = Theme.Radius.md
    var focused: Bool = false
    var accent: Color = Theme.Ink.claude
    /// Turn the well's fill up a step — for a field that sits on a card rather
    /// than on the page canvas, where a recessed fill would vanish.
    var onCard: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(onCard ? Theme.cardFill(0.06) : Theme.fieldWell)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(focused ? accent.opacity(0.65) : Theme.hairline,
                                  lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if focused {
                    InnerFrameRing(inset: 2, radius: radius, tint: accent.opacity(0.28))
                }
            }
            .animation(Theme.Motion.state, value: focused)
    }
}
