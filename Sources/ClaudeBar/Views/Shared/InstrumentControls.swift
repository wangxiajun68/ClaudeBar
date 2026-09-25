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
            // One implementation of the well: `InstrumentWell` is the surface
            // both this and a field-shaped control wear.
            .instrumentWell(radius: radius, focused: focused,
                            accent: accent, onCard: onCard)
            .animation(Theme.Motion.state, value: focused)
    }
}

/// The field's *surface* without a field — the well and the rim, for a control
/// that is drawn as a field but is not a `TextField` (an API key's read state, a
/// selector that opens a picker).
///
/// Split from `InstrumentField` so those two call sites can wear the same box as
/// the inputs beside them without pretending to be inputs: the difference
/// between "type here" and "click here" is the content, not the well.
struct InstrumentWell: ViewModifier {
    var radius: CGFloat = Theme.Radius.md
    var focused: Bool = false
    var accent: Color = Theme.Ink.claude
    var onCard: Bool = false

    func body(content: Content) -> some View {
        content
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
                InnerFrameRing(inset: 2, radius: radius,
                               tint: focused ? accent.opacity(0.28) : Theme.innerFrameMuted)
            }
    }
}

extension View {
    func instrumentWell(radius: CGFloat = Theme.Radius.md, focused: Bool = false,
                        accent: Color = Theme.Ink.claude,
                        onCard: Bool = false) -> some View {
        modifier(InstrumentWell(radius: radius, focused: focused,
                                accent: accent, onCard: onCard))
    }
}

// MARK: - Instrument toggle (metanef switch)

/// The app's **one** switch: an inset, engraved track with a plated handle, and
/// a hover where the handle stretches toward the side it would travel to.
///
/// Why this exists at all: the app had **20 raw `Toggle`s** — sixteen
/// `.toggleStyle(.switch).labelsHidden().tint(...)` chains written out by hand,
/// one lone `.checkbox`, and three with no style at all — so "a switch" was a
/// different object in five different files, and none of them belonged to the
/// surface family the tiles are drawn from.
///
/// The reference (`metanef`) is a neumorphic switch whose *track is inset*
/// (`inset 3px 3px 6px` + `inset -3px -3px 6px`) and whose handle changes shape
/// on hover (a bar stretching into a D). Both survive the translation:
///
/// - the track is a recessed fill with an engraved top rule and a lit bottom
///   edge, which is what an inset control looks like on an ice canvas;
/// - the handle is a plated capsule with a lit top edge, and on hover it widens
///   ~30 % toward the direction it will move — a *destination hint*, which is
///   the part worth keeping. The original's stretch is a pure decoration; here
///   it says "this will go right".
///
/// Motion: the handle's travel is a state change on `isOn`; the hover stretch
/// is the same kind. Reduce Motion drops the stretch and keeps the travel
/// (travel is the state itself, not decoration).
struct InstrumentToggleStyle: ToggleStyle {
    var tint: Color = Theme.Ink.claude
    /// The track's own hue when on — the raw shape hue, since it is a fill.
    var faceTint: Color? = nil
    /// Whether the label beside the track is drawn. The tile call sites name the
    /// control in the tile itself and pass `false`; a call site that prints its
    /// own words beside the switch passes `true` (the default).
    var showsLabel: Bool = true

    /// The switch stands alone. Call sites in this app already print the
    /// control's own name in the tile they sit in (`SettingTile`), so a label
    /// beside the track would be the second copy of the same words — which is
    /// exactly what the twenty hand-written `.labelsHidden()` chains were
    /// suppressing one by one. The label is still honoured (and still
    /// clickable) when a call site genuinely passes one, as `Toggle("启用", …)`
    /// does outside a tile.
    func makeBody(configuration: Configuration) -> some View {
        let face = faceTint ?? tint
        return InstrumentToggleTrack(isOn: configuration.isOn, face: face, tint: tint,
                                     hasLabel: showsLabel,
                                     label: { configuration.label }) {
            configuration.isOn.toggle()
        }
    }
}

/// The track itself, split out so the `@State` hover flag lives on a small view
/// (the style's `makeBody` cannot hold one).
private struct InstrumentToggleTrack<Label: View>: View {
    var isOn: Bool
    var face: Color
    var tint: Color
    var hasLabel: Bool
    @ViewBuilder var label: () -> Label
    var action: () -> Void

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let width: CGFloat = 38
    private let height: CGFloat = 22
    private let inset: CGFloat = 3
    private var travel: CGFloat { width - height }

    /// Label then track, **hugging** — deliberately no spacer between them.
    ///
    /// The stock SwiftUI toggle behaves this way, and the call sites depend on
    /// it: several are already inside an `HStack` that puts its own `Spacer()`
    /// before the toggle so the control lands on the row's trailing edge. A
    /// spacer inside the style as well would pin the *switch* to the far right
    /// while leaving its label behind at the left, splitting the two halves of
    /// one control. So the pair stays together and the row decides where the
    /// pair goes.
    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            // A bare switch takes no label column *and* no stack spacing, so it
            // sits centred in a tile cell rather than 8pt off it.
            if hasLabel {
                label()
                    .font(Theme.Font.chrome)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .onTapGesture(perform: action)
            }
            Button(action: action) {
                ZStack(alignment: .leading) {
                    track
                    handle
                }
                .frame(width: width, height: height)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .onHover { if hovered != $0 { hovered = $0 } }
        .animation(Theme.Animation.snappy, value: isOn)
        .animation(Theme.Motion.state, value: hovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// The recessed channel: a milled well whose top edge is engraved (dark) and
    /// whose bottom edge is lit — the inverse of the raised tiles' rim, which is
    /// exactly what makes it read as a hole rather than a chip.
    private var track: some View {
        Capsule()
            .fill(isOn ? face.opacity(Theme.isDark ? 0.34 : 0.24) : Theme.fieldWell)
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Theme.isDark ? Color.black.opacity(0.30) : Color.black.opacity(0.10),
                                Color.white.opacity(Theme.isDark ? 0.06 : 0.55)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                // The accent, once on: a lit perimeter on the filled track.
                if isOn {
                    Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 1)
                }
            }
    }

    /// The plated handle. On hover it widens toward its destination and squares
    /// off on that leading edge (the reference's D-shape), which is the
    /// direction hint.
    private var handle: some View {
        let stretched = hovered && !reduceMotion
        let handleWidth = height - inset * 2 + (stretched ? 7 : 0)
        return Capsule()
            .fill(Theme.cardSurface)
            .overlay {
                Capsule().strokeBorder(Theme.isDark
                                       ? Color.white.opacity(0.10)
                                       : Color.black.opacity(0.06),
                                       lineWidth: 1)
            }
            .overlay {
                // The reference's lit top edge on the plate (`inset 0 2px 2px`).
                Capsule()
                    .fill(
                        LinearGradient(colors: [.white.opacity(Theme.isDark ? 0.14 : 0.9), .clear],
                                       startPoint: .top, endPoint: .center)
                    )
                    .allowsHitTesting(false)
            }
            .frame(width: handleWidth, height: height - inset * 2)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .offset(x: isOn ? travel - (handleWidth - (height - inset * 2)) : inset)
    }
}

extension ToggleStyle where Self == InstrumentToggleStyle {
    /// `Toggle(…).instrumentToggle()` — the app's switch.
    static var instrument: InstrumentToggleStyle { InstrumentToggleStyle() }
}

// MARK: - Perimeter sweep (ultimate-3d-btn::before)

/// A lit arc travelling the control's *own* perimeter — the `ultimate-3d-btn`'s
/// spinning conic gradient, which is the piece's signature.
///
/// The original spins it forever. Here it is **one shot**, and only while the
/// pointer is on the control: a permanent rotating border on a page of cards is
/// per-frame chrome, and an ornament that never stops stops meaning anything.
/// The arc is drawn as a single trimmed stroke, so one control is one layer.
struct PerimeterSweep: View {
    var active: Bool
    var tint: Color = .white
    var lineWidth: CGFloat = 1.5
    /// How much of the perimeter the lit arc covers, in degrees.
    var span: Double = 130

    /// Fraction of the perimeter the *head* of the arc sits at. Negative while
    /// the sweep is parked, and the whole overlay is hidden then — a negative
    /// `to:` on a trim does not render nothing, it renders a wrap-around arc,
    /// which is how an earlier version leaked a stray circle outside its button.
    @State private var phase: Double = 0
    @State private var running = false

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            let capsule = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                // The head: the bright leading third of the sweep.
                capsule
                    .trim(from: phase, to: phase + span / 360)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // The tail, so the arc reads as travelling rather than as a
                // blob jumping around the edge.
                capsule
                    .trim(from: phase - span / 360 * 0.55, to: phase)
                    .stroke(tint.opacity(0.30),
                            style: StrokeStyle(lineWidth: lineWidth * 0.6, lineCap: .round))
            }
            .opacity(running ? 1 : 0)
        }
        .allowsHitTesting(false)
        .onChange(of: active) { _, on in
            guard on else { return }
            // Start just off the leading edge and run past the end, so the arc
            // enters and leaves rather than appearing in place. 0…1 covers the
            // whole perimeter; the span overshoot parks it fully off.
            phase = -span / 360
            running = true
            withAnimation(.easeInOut(duration: 0.85)) { phase = 1 }
        }
        .onChange(of: running) { _, _ in }
        .task(id: active) {
            guard active else { running = false; return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            running = false
        }
    }
}

// MARK: - Ground shadow (stat-widget `.ground-shadow`)

/// The soft ellipse under a floating control — the `stat-widget`'s ground
/// shadow, which is what makes its pill read as *above* the surface rather than
/// painted on it.
///
/// A hover ornament, deliberately: at rest the control sits on its surface; the
/// shadow appears with the lift, so the pair says "picked up". Reduce Motion
/// keeps the shadow static (it is depth, not motion) but drops nothing else.
struct GroundShadow: View {
    var active: Bool
    var width: CGFloat? = nil

    var body: some View {
        Capsule()
            .fill(
                LinearGradient(colors: [.black.opacity(0.26), .black.opacity(0.14)],
                               startPoint: .top, endPoint: .bottom)
            )
            .frame(width: width, height: 7)
            .blur(radius: 7)
            .opacity(active ? 0.9 : 0.35)
            .animation(Theme.Motion.state, value: active)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
