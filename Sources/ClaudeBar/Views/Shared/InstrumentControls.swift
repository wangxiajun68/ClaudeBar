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

    func makeBody(configuration: Configuration) -> some View {
        let face = faceTint ?? tint
        return HStack(spacing: Theme.Space.s8) {
            configuration.label
                .font(Theme.Font.chrome)
                .foregroundStyle(Theme.textPrimary)
                .onTapGesture { configuration.isOn.toggle() }
            Spacer(minLength: Theme.Space.s8)
            track(configuration, face: face, tint: tint)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func track(_ configuration: Configuration, face: Color, tint: Color) -> some View {
        InstrumentToggleTrack(isOn: configuration.isOn, face: face, tint: tint) {
            configuration.isOn.toggle()
        }
    }
}

/// The track itself, split out so the `@State` hover flag lives on a small view
/// (the style's `makeBody` cannot hold one).
private struct InstrumentToggleTrack: View {
    var isOn: Bool
    var face: Color
    var tint: Color
    var action: () -> Void

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let width: CGFloat = 38
    private let height: CGFloat = 22
    private let inset: CGFloat = 3
    private var travel: CGFloat { width - height }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                track
                handle
            }
            .frame(width: width, height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { if hovered != $0 { hovered = $0 } }
        .animation(Theme.Animation.snappy, value: isOn)
        .animation(Theme.Motion.state, value: hovered)
        .accessibilityRepresentation {
            Toggle(isOn: .constant(isOn), label: { EmptyView() })
        }
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

    @State private var phase: Double = -1

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            let capsule = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                capsule
                    .trim(from: max(0, phase), to: min(1, phase + span / 360))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                capsule
                    .trim(from: max(0, phase - 0.08), to: max(0, min(1, phase)))
                    .stroke(tint.opacity(0.35), style: StrokeStyle(lineWidth: lineWidth * 0.6, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
        .onChange(of: active) { _, on in
            guard on else { phase = -1; return }
            phase = -1
            withAnimation(.easeInOut(duration: 0.9)) { phase = 1 }
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
