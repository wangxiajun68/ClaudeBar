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

    /// Reduce Motion drops the ornament outright. It is decoration on top of an
    /// affordance that is already complete without it (the rim and the fill),
    /// which is the test this file's rules set for what may be removed.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fraction of the perimeter the *head* of the arc sits at.
    ///
    /// The overlay is hidden entirely when `phase` is nil, which is the whole
    /// trick: a trim with a negative `to:` does **not** render nothing — it
    /// renders a wrap-around arc, which is how an earlier version of this leaked
    /// a stray circle outside the control it belonged to. So the parked state is
    /// `nil`, never a negative number.
    ///
    /// One piece of state drives both the drawing and the visibility, and the
    /// one-shot is a single `task(id:)`: an earlier version ran the fade on a
    /// timer *and* the travel on a `withAnimation`, which are two clocks that
    /// can disagree about when the sweep is over.
    @State private var phase: Double?
    /// How long the whole one-shot takes. The travel and the fade are the same
    /// clock, so the arc cannot outlive its own visibility.
    private let duration: Double = 0.85

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            let capsule = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let head = phase ?? 0
            ZStack {
                // The head: the bright leading third of the sweep.
                capsule
                    .trim(from: head, to: head + span / 360)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // The tail, so the arc reads as travelling rather than as a
                // blob jumping around the edge.
                capsule
                    .trim(from: head - span / 360 * 0.55, to: head)
                    .stroke(tint.opacity(0.30),
                            style: StrokeStyle(lineWidth: lineWidth * 0.6, lineCap: .round))
            }
            .opacity(phase == nil ? 0 : 1)
        }
        .allowsHitTesting(false)
        // `.task(id:)` is the one-shot: it starts the travel, waits exactly as
        // long as the travel takes, then parks. A second hover while the first
        // sweep is still running restarts it (the id changed), and Reduce Motion
        // simply never starts — the control is complete without the ornament.
        .task(id: active) {
            guard active, !reduceMotion else { phase = nil; return }
            phase = -span / 360
            withAnimation(.easeInOut(duration: duration)) { phase = 1.0 + span / 360 }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            phase = nil
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

/// **The page band's own control** — a capsule *milled into* the band rather
/// than a second white chip laid on it, plus the 3D button reference's
/// **perimeter sweep** — a lit arc that travels the control's own edge once
/// when the pointer arrives and then stops.
///
/// It used to be a flat grey capsule with a grey border and **no hover response
/// at all** (`bgSecondary` fill, `Theme.hairline` stroke) — the single most
/// generic object on a page whose complaint was that it read as plain. Two
/// things fix it, both cheap:
///
/// 1. the well is the *recessed* fill (`Theme.fieldWell`) so the button reads as
///    a control sitting in the band, not another card;
/// 2. the accent rim and the one-shot sweep say "this is a target" before the
///    click. The sweep is one trimmed shape and runs only on hover, never on a
///    loop — a permanent rotating border is chrome that never stops meaning
///    anything, and it is what the reference does that this deliberately does
///    not.
struct HeaderControlModifier: ViewModifier {
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
            // The well and the rim are the control's **whole** surface, so the
            // button must be `.plain`: the default macOS bezel would draw its
            // own grey rounded rect *inside* this capsule, which is the muddy
            // double-grey that made these read as washed-out and disabled.
            // `.plain` also means `isEnabled` no longer dims the label for us,
            // so the disabled state is stated below instead of inherited.
            .background(Theme.fieldWell, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(hovered ? Theme.claude.opacity(0.45) : Theme.hairline,
                                  lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if !reduceMotion {
                    PerimeterSweep(active: hovered, tint: Theme.claude.opacity(0.9), lineWidth: 1.4)
                        .padding(0.5)
                }
            }
            .overlay { GroundShadow(active: hovered).offset(y: 18).opacity(0.5) }
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
            .onHover { if hovered != $0 { hovered = $0 } }
            .animation(Theme.Motion.state, value: hovered)
    }
}

// MARK: - Instrument button (ultimate-3d-btn, quiet)

/// The app's **one** push button, replacing the stock glass / bordered button.
///
/// Quiet is a recessed capsule — the same milled well as a field — so a
/// secondary action reads as a control sitting in the page, not as Aqua chrome.
/// Prominent fills with the shape hue, keeps a lit top edge, and presses *down*
/// (the 3D button's active state). Both light their own perimeter once when the
/// pointer arrives (`PerimeterSweep`); neither spins a border forever, and
/// neither glitches its label. A glitch on a native control reads as a fault.
struct InstrumentButtonStyle: ButtonStyle {
    var prominent = false
    /// Rim and, when prominent, the fill. A shape hue, not ink.
    var tint: Color = Theme.claude
    /// Label color for a quiet button. Prominent always prints white.
    var ink: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        InstrumentButtonBody(configuration: configuration, prominent: prominent,
                             tint: tint, ink: ink)
    }
}

private struct InstrumentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    var prominent: Bool
    var tint: Color
    var ink: Color?
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = configuration.isPressed && enabled && !reduceMotion
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(prominent ? Color.white : (ink ?? (hovered ? Theme.textPrimary : Theme.textSecondary)))
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background { plate }
            .overlay { rim }
            .overlay {
                if !reduceMotion {
                    PerimeterSweep(active: hovered && enabled,
                                   tint: prominent ? Color.white.opacity(0.95) : tint.opacity(0.9),
                                   lineWidth: 1.4)
                        .padding(1)
                        .clipShape(Capsule())
                        .allowsHitTesting(false)
                }
            }
            .background(alignment: .bottom) {
                GroundShadow(active: hovered && enabled && !pressed)
                    .padding(.horizontal, 8)
                    .offset(y: 9)
            }
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.42)
            // Press travels down. The hit shape is declared before the offset,
            // so a 2pt press cannot carry the pointer out of the control.
            .offset(y: pressed ? (prominent ? 2 : 1) : 0)
            .onHover { if hovered != $0 { hovered = $0 } }
            .animation(reduceMotion ? nil : Theme.Motion.state, value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private var plate: some View {
        Capsule()
            .fill(prominent ? tint : Theme.fieldWell)
            .overlay {
                if prominent {
                    // Pulls a bright shape hue down so white 12pt type clears
                    // the body-text contrast floor without inventing a second red.
                    Capsule().fill(Color.black.opacity(0.22)).allowsHitTesting(false)
                }
            }
            .overlay {
                if prominent {
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(Theme.isDark ? 0.22 : 0.34), .clear],
                                             startPoint: .top, endPoint: .center))
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(prominent ? (hovered ? 0.16 : 0.08) : 0),
                    radius: prominent ? (hovered ? 8 : 3) : 0,
                    y: prominent ? (hovered ? 4 : 1) : 0)
    }

    private var rim: some View {
        Capsule()
            .strokeBorder(hovered ? tint.opacity(prominent ? 0.0 : 0.55) : Theme.hairline, lineWidth: 1)
            .overlay {
                InnerFrameRing(inset: 2, radius: 14,
                               tint: hovered ? tint.opacity(0.30) : Theme.innerFrameMuted)
            }
            .allowsHitTesting(false)
    }
}

/// A menu shown as the same recessed capsule as a field, with a chevron.
/// Native `.pickerStyle(.menu)` is Aqua chrome inside a machined tile.
struct InstrumentMenuLabel: View {
    var title: String
    var tint: Color = Theme.claude
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textTertiary())
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 28)
        .frame(maxWidth: 168)
        .instrumentWell(radius: 14, focused: hovered, accent: tint, onCard: true)
        .overlay {
            if !reduceMotion {
                PerimeterSweep(active: hovered, tint: tint.opacity(0.9), lineWidth: 1.2)
                    .padding(1)
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
            }
        }
        .onHover { if hovered != $0 { hovered = $0 } }
        .animation(Theme.Motion.state, value: hovered)
    }
}

extension View {
    /// The one control shape a page band's buttons take.
    ///
    /// Shared by 连接器's 刷新 / 选择项目 and 模型's 自定义: a page band's
    /// controls are the band's own affordances, so two bands that are meant to
    /// read as the same object must not dress their buttons differently.
    func headerControl() -> some View { modifier(HeaderControlModifier()) }
}