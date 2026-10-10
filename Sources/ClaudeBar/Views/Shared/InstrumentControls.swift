import SwiftUI

// =============================================================================
// The control language.
//
// One press feel, three shapes, three tones. Every button, chip, icon action
// and switch in the app is one of these; a call site that hand-rolls a capsule
// and a stroke is a call site that will disagree with the next page.
//
// **The press feel** (shared by all four shapes through `ControlPressModifier`):
//
//   rest ──pointer──▶ tinted fill, hairline brightens, ~0.10 s
//        ──press───▶ the *same* tint, one step deeper, ~0.10 s
//        ──release─▶ a 0.97 → 1 spring, Theme.Animation.snappy
//
// Three rules that keep it quiet, and each of them is a thing the app used to
// do and no longer does:
//
// 1. **Nothing grows under the pointer.** The old plate scaled to 1.02 on
//    hover, so a row of buttons reflowed as the pointer crossed it. A control
//    answers the pointer with light, not with size.
// 2. **Nothing loops.** The old primary button ran a Core Animation rim sweep
//    for as long as the pointer stayed on it, and the VPN CTA ran a rotating
//    conic border per frame. Per-frame chrome on the most-repeated component in
//    the app is the one cost this file will not pay; the vocabulary for "the
//    pointer arrived" is the tint, which is free.
// 3. **One shadow, carried by a layer.** `LayerShadow`, not `.shadow(...)`,
//    because the plate is the app's most repeated control (the provider
//    directory alone draws eight per card) and a display-list filter re-runs
//    every display cycle its subtree is visited.
//
// The only motion left is the press spring and the existing one-shot
// `ShineSweep` on a large accent plate, which is a pointer-arrival accent and
// never the affordance itself.
// =============================================================================

// MARK: - Tones

/// What a control *is*, not what it looks like: the shape draws itself from
/// this. Three tones, because a control is either the page's own quiet
/// furniture, the one action the page is about, or the one that destroys
/// something — and a fourth would be a decoration.
///
/// Each tone is a **role**, and the shape decides its own drawing from it:
/// `neutral` is a light fill with a hairline, `accent` is the *same* control
/// tinted, and `destructive` is the only one that fills solid — the one place
/// Apple's own language raises its voice, and the one place this app should.
enum ControlTone {
    /// A light fill, a hairline, and the primary ink — the control that is
    /// visible without being loud.
    ///
    /// `ActionButton`'s default tone, and what every call site that does not
    /// name one gets — also the default for `ActionIcon` and
    /// `ActionPlateButtonStyle`, and the right answer for a call site that
    /// wants a quiet plate on the ice canvas — a dense row of icon actions, or
    /// a button drawn inside a card where a dark pill would punch a hole in
    /// the surface.
    case neutral
    /// The page's one primary action. Not a slab of the hue — a *tinted* fill at
    /// 14 % with the hue's ink as the label, the way macOS tints a secondary
    /// action. Only a keyboard-default action fills solid.
    case accent
    /// The hue and a filled body. Reserved for "this destroys something".
    case destructive
    /// The **dark sparkle plate** — the app's one dark button, ported from a
    /// reference CSS pill (see `SparklePlate`). Unlike the three tones above it
    /// does not tint from the caller's hue: its identity *is* its own dark
    /// surface, so `tint` is ignored except for the label's hover ink.
    case sparkle
}

/// Whether a tone is the page's **default** action — what the platform fills,
/// and therefore the only thing this file fills.
enum ControlEmphasis {
    case standard
    case primary

    var isPrimary: Bool { self == .primary }
}

/// The geometry a control is drawn at. Two sizes, not five: a page band and a
/// dense card row disagree about height, and they are the only two that exist.
///
/// Not named `ControlSize`: SwiftUI already owns that name (`.controlSize(…)`,
/// `.mini` / `.small` / `.regular` / `.large`), and a local type of the same name
/// silently shadows it at every call site in the file.
enum ControlMetrics {
    /// 30pt — page bands, toolbars, forms, card rows.
    case regular
    /// 40pt — a hero action (the VPN 启动 / 停止 plate), alone on its row.
    case large

    var height: CGFloat { self == .large ? 40 : 30 }
    var labelSize: CGFloat { self == .large ? 13.5 : 12.5 }
    var iconSize: CGFloat { self == .large ? 15 : 13 }
    var hPadding: CGFloat { self == .large ? 20 : 13 }
}

// MARK: - The press vocabulary

/// The one press/hover feel. Composed rather than inherited so `ChipButton`,
/// `ActionIcon` and any future shape answer the pointer the same way without
/// each re-deriving a scale and a duration.
private struct ControlPressModifier: ViewModifier {
    @Binding var hovered: Bool
    @Binding var pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion || !pressed ? 1 : 0.97)
            .onHover { if hovered != $0 { hovered = $0 } }
            .animation(reduceMotion ? nil : Theme.Animation.snappy, value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .disabledTreatment()
    }
}

/// The one **disabled look**: 0.34 opacity and a full desaturation, the pair a
/// control fades to when it is not enabled.
///
/// Its own modifier rather than two lines inside `ControlPressModifier`, because
/// the two styles that do not compose the press modifier — the
/// `ActionPlateButtonStyle` body and the page band's `HeaderControlModifier` —
/// wear the same treatment, and a call site documents relying on the number
/// (`ConnectorsView`). Three copies is how a treatment drifts.
private struct DisabledTreatmentModifier: ViewModifier {
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .opacity(enabled ? 1 : 0.34)
            .saturation(enabled ? 1 : 0)
    }
}

private extension View {
    /// The shared disabled look. `isEnabled` is read inside the modifier, so a
    /// call site does not thread a flag into it.
    func disabledTreatment() -> some View {
        modifier(DisabledTreatmentModifier())
    }
}

/// The plate: Apple's control material, drawn from one tone and one emphasis.
///
/// The reference is macOS 26's own buttons, and the two things that make them
/// read as *designed* rather than as rectangles of paint:
///
/// 1. **The fill is a tint, not the hue.** A standard control is the surface
///    lifted a few percent — grey on grey — with the accent living in the label
///    and the stroke. Only a `primary` control fills solid, which is why a page
///    with one primary action and six ordinary ones has a hierarchy instead of
///    seven blue pills.
/// 2. **The stroke is a hairline that follows the fill**, brightening with the
///    pointer. It is not a second colour; it is the edge of the same material.
///
/// Continuous corners (`RoundedRectangle(style: .continuous)` / `Capsule`)
/// throughout, because a squircle is what the rest of this UI is built from and
/// a circular arc beside it reads as a different, older control.
///
/// **No gradients.** One flat fill, one 1pt stroke. The plate this replaces had
/// a light-top/dark-bottom gradient plus a second gradient on its top edge,
/// which at 30pt is a glossy blob rather than a control.
private struct ControlPlate<S: InsettableShape>: View {
    let tone: ControlTone
    let tint: Color
    let emphasis: ControlEmphasis
    let shape: S
    let hovered: Bool
    let pressed: Bool
    /// Only `.sparkle` reads this — it scales the glow. The tinted tones draw
    /// from `shape`'s own geometry and have no use for a metric.
    var metrics: ControlMetrics = .regular
    var enabled = true

    private var solid: Bool { emphasis.isPrimary || tone == .destructive }

    /// How far the pointer and the press take the fill. One step each, in the
    /// same direction, so the control deepens rather than flattens — the old
    /// plate multiplied its whole fill by 0.92, which *washed the accent out*
    /// at the exact moment the pointer asked it to respond.
    private func step(_ rest: Double, _ hover: Double, _ down: Double) -> Double {
        pressed ? down : (hovered ? hover : rest)
    }

    private var fill: Color {
        if solid {
            return tint.opacity(step(1.0, 1.0, 0.82))
        }
        switch tone {
        case .neutral:
            return Theme.isDark
                ? Color.white.opacity(step(0.06, 0.10, 0.14))
                : Color.black.opacity(step(0.035, 0.06, 0.10))
        case .accent:
            return tint.opacity(step(0.13, 0.20, 0.26))
        case .destructive:
            return tint.opacity(step(0.13, 0.20, 0.26))
        case .sparkle:
            // Unreachable: `body` delegates before either is read. Stated so the
            // switch stays exhaustive and a future tone cannot silently fall
            // through to this one's fill.
            return SparklePlate.restFill
        }
    }

    /// The edge is the fill's own ink: almost nothing at rest, the tone under
    /// the pointer, and the tone on press.
    private var edge: Color {
        if solid { return .white.opacity(step(0.14, 0.26, 0.40)) }
        switch tone {
        case .neutral:
            return pressed ? (Theme.isDark ? .white.opacity(0.26) : .black.opacity(0.20))
                : (hovered ? Theme.textSecondary.opacity(0.55) : Theme.hairline)
        case .accent, .destructive:
            return tint.opacity(step(0.34, 0.62, 0.85))
        case .sparkle:
            return Color.white.opacity(step(0.10, 0.40, 0.40))
        }
    }

    var body: some View {
        // `.sparkle` is not a tint of the caller's hue — it is its own material,
        // so it does not go through `fill`/`edge` at all and delegates to the
        // ported recipe. Branching here (rather than teaching `fill` a dark case)
        // keeps that recipe in one readable place instead of spread across two
        // computed properties that also have to serve the three tinted tones.
        if tone == .sparkle {
            SparklePlate(height: metrics.height, hovered: hovered,
                         pressed: pressed, enabled: enabled)
        } else {
            shape
                .fill(fill)
                .overlay {
                    shape.strokeBorder(edge, lineWidth: 1).allowsHitTesting(false)
                }
        }
    }
}

// MARK: - Sparkle plate (the reference's `.btn`)

/// The app's **dark sparkle plate**, ported from a reference CSS button.
///
/// This is the one button in the app that is a *dark* pill on the ice canvas.
/// The design brief asked for every ordinary (non-switch) button to take it, so
/// it is modelled as a `ControlTone` — `.sparkle` — rather than as a parallel
/// style: a tone is what `ControlPlate`, `ActionButton` and the four style shims
/// already branch on, so one new case switches every labelled action in the app
/// without touching a call site.
///
/// The CSS, and what each declaration became:
///
/// | CSS | here |
/// | --- | --- |
/// | `background: #1C1A1C` | `restFill` |
/// | `border-radius: 3em` on `height: 5em` | `Capsule()` |
/// | `hover background: linear-gradient(0deg,#A47CF3,#683FEA)` | `hoverGradient` |
/// | `inset 0 1px 0 rgba(255,255,255,.4)` | the inset top highlight |
/// | `inset 0 -4px 0 rgba(0,0,0,.2)` | the inset bottom shade |
/// | `0 0 0 4px rgba(255,255,255,.2)` | the 4pt white ring |
/// | `0 0 180px 0 #9917FF` | the outer glow (`LayerShadow`, tinted) |
/// | `transform: translateY(-2px)` | the 2pt hover lift |
/// | `transition: all 450ms ease-in-out` | `Theme.Animation.sparkle` |
/// | `.text { color: #AAAAAA }` → `white` | `labelColor` |
///
/// **Two things the CSS does that this app will not, and why:**
///
/// 1. **No `translateY` on the plate itself.** The brief asks for the reference's
///    motion, and the lift is kept — but applied as a `.offset(y:)` on the label
///    rather than by moving the hit shape. Moving a control's own frame on hover
///    is the exact oscillation documented on `ControlPressModifier`: the pointer
///    parked on the bottom edge is carried out of the button and back, once per
///    frame. Offsetting the drawn content keeps the silhouette the pointer is
///    actually over.
/// 2. **The glow is a layer, not `.shadow`.** A 180pt blur is the single most
///    expensive thing in the CSS; on the app's most-repeated control a
///    display-list filter would re-run every display cycle. `LayerShadow` is the
///    same rasterisation path the rest of the file already uses, and the glow is
///    scaled to the control's height so a 30pt button does not carry a 180pt
///    bloom.
///
/// The glow and gradient are **hover-only**, exactly as in the CSS: at rest this
/// is a flat dark pill, which is what keeps a page of them from reading as a
/// row of lights.
struct SparklePlate: View {
    /// The control's height, used to scale every shadow so the same recipe works
    /// at 30pt and at 40pt.
    let height: CGFloat
    let hovered: Bool
    let pressed: Bool
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `#1C1A1C` — the reference's rest fill.
    static let restFill = Color(hex: 0x1C1A1C)
    /// `#A47CF3` → `#683FEA`, bottom to top (the CSS is `0deg`).
    static let hoverTop = Color(hex: 0x683FEA)
    static let hoverBottom = Color(hex: 0xA47CF3)
    /// `#9917FF` — the glow.
    static let glowBase = Color(hex: 0x9917FF)

    /// How far the label rides up on hover. The CSS's 2px, scaled with the
    /// control.
    static func lift(for height: CGFloat) -> CGFloat { height >= 40 ? 2 : 1.5 }

    private var active: Bool { hovered && enabled }

    var body: some View {
        Capsule(style: .continuous)
            .fill(active
                  ? AnyShapeStyle(LinearGradient(colors: [Self.hoverBottom, Self.hoverTop],
                                                 startPoint: .bottom, endPoint: .top))
                  : AnyShapeStyle(Self.restFill))
            // inset 0 1px 0 rgba(255,255,255,.4)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(active ? 0.4 : 0.10), lineWidth: 1)
                    .mask(LinearGradient(colors: [.white, .white.opacity(0)],
                                         startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            }
            // inset 0 -4px 0 rgba(0,0,0,.2)
            .overlay {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [.clear, Color.black.opacity(active ? 0.20 : 0.16)],
                                         startPoint: .center, endPoint: .bottom))
                    .allowsHitTesting(false)
            }
            // 0 0 0 4px rgba(255,255,255,.2) — a white ring *outside* the pill,
            // drawn as an overlay stroke on an expanded shape so it reads as a
            // halo rather than as a second border.
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(active ? 0.20 : 0), lineWidth: 4)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
            // 0 0 180px 0 #9917FF, scaled to the control.
            .background {
                LayerShadow(radius: height * (active ? 2.6 : 0.6),
                            y: active ? 0 : 1,
                            opacity: active ? 0.55 : 0.22,
                            cornerRadius: height / 2,
                            surface: .clear,
                            color: active ? Self.glowBase : .black)
            }
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : Theme.Animation.sparkle, value: active)
            .animation(reduceMotion ? nil : Theme.Animation.snappy, value: pressed)
    }
}
// MARK: - ActionButton

/// The app's push button: 刷新 / 清空 / 启用 / 移除 / 打开 — every labelled
/// action in the app, whatever page it is on.
///
/// The two controls this replaces are the ones the design review opened with:
/// 刷新 (`.adaptiveGlassButton(prominent: true, tint: Theme.claude)`) and 清空
/// (`.adaptiveGlassButton(tint: Theme.statusError, ink: .white, filled: true)`).
/// They were already the same style at two settings, which is why unifying the
/// *style* alone would not have fixed anything — what was missing was the rule
/// that says which setting a given button should be, and that rule is `tone`.
///
/// A call site that says nothing about its tone gets `.neutral`; the dark
/// `.sparkle` pill is opt-in. `.destructive` and a page's single `.accent`
/// primary are the other two meanings a call site has to name.
struct ActionButton<Label: View>: View {
    /// The memberwise default, and the tone the two title convenience inits
    /// below carry too — so a call site that says nothing about its tone gets
    /// the milled `neutral` well, which is what every one of the ~19 bare
    /// `ActionButton("刷新")` sites in the app renders. `.sparkle` is the dark
    /// reference plate, reached only by asking for it by name (`tone: .sparkle`),
    /// and `.destructive` / the one `.accent` primary per page carry the two
    /// meanings the plate cannot: "this destroys something" and "this is the
    /// action the page is about". The three defaults were out of step once —
    /// this one said `.sparkle` while the inits said `.neutral`, which made the
    /// documented default unreachable; they are kept equal on purpose.
    var tone: ControlTone = .neutral
    var tint: Color = Theme.claude
    var metrics: ControlMetrics = .regular
    /// The page's default action. A primary control fills solid; every other one
    /// is the tinted standard plate. One per page, at most — that is what makes
    /// it read as *the* action rather than as the loudest of several.
    var emphasis: ControlEmphasis = .standard
    /// Named `perform` rather than `action`: a stored `action` shadows
    /// `Button(action:)` inside this very body, and Swift resolves the inner
    /// `Button` against the property instead of the initialiser.
    var perform: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // `label:` is spelled out: this type stores a `label` closure of its own,
        // and the trailing-closure form makes Swift resolve the inner `Button`
        // against that property rather than against `Button.init(label:)`.
        Button(action: perform, label: {
            HStack(spacing: 6) { label() }
                .font(.system(size: metrics.labelSize, weight: .semibold, design: .rounded))
                .foregroundStyle(labelColor)
                .padding(.horizontal, metrics.hPadding)
                .frame(height: metrics.height)
                // The reference lifts its label on hover (`translateY(-2px)`).
                // It is applied here, to the drawn content, and *not* to the
                // Button's own frame: moving the frame is the oscillation the
                // press modifier documents — a pointer parked on the bottom edge
                // is carried out of the control and back, once per frame.
                .offset(y: tone == .sparkle && hovered ? -SparklePlate.lift(for: metrics.height) : 0)
                .background {
                    ControlPlate(tone: tone, tint: tint, emphasis: emphasis,
                                 shape: Capsule(), hovered: hovered, pressed: pressed,
                                 metrics: metrics)
                }
                .background {
                    // A standard control is drawn *in* the surface, so it carries
                    // no lift — the hairline is what says it is a control. Only
                    // the filled plate sits above the page, and only barely.
                    // `.sparkle` carries its own glow inside `SparklePlate`, so
                    // this layer stays off for it.
                    // Only a destructive control lifts; every other tone's
                    // shadow was drawn at opacity 0, which still cost a hosted
                    // `NSView` and two `CALayer`s per button. Not mounted at all
                    // is the same picture.
                    if tone == .destructive {
                        DestructivePlateShadow(hovered: hovered, pressed: pressed,
                                               height: metrics.height)
                    }
                }
                .contentShape(Capsule())
                .modifier(ControlPressModifier(hovered: $hovered, pressed: $pressed))
        })
        .buttonStyle(PressReportingStyle(pressed: $pressed))
        // The sparkle plate's four hover changes ride one slower clock; every
        // other tone keeps the 140 ms it has always had.
        .animation(reduceMotion ? nil : (tone == .sparkle ? Theme.Animation.sparkle
                                                          : .easeOut(duration: 0.14)),
                   value: hovered)
    }

    /// The label carries the tone's **ink**, the way macOS tints an action —
    /// never white on a tinted fill, which is unreadable on the ice canvas. Only
    /// the solid plates (a primary accent, a destructive) take a white label,
    /// because only those have a dark enough body to carry it.
    private var labelColor: Color {
        if tone == .destructive || (emphasis.isPrimary && tone == .accent) { return .white }
        switch tone {
        case .neutral: return Theme.textPrimary
        case .accent: return Theme.isDark ? Theme.claudeHi : Theme.Ink.claude
        case .destructive: return .white
        // The reference's `#AAAAAA` at rest, `white` under the pointer. The
        // label is read against a *dark* plate, so both ends are lighter than
        // any other tone's ink — `Theme.textSecondary` here would be the
        // canvas's grey on a near-black fill.
        case .sparkle: return hovered ? .white : Color(hex: 0xAAAAAA)
        }
    }
}

extension ActionButton where Label == Text {
    init(_ title: String, tone: ControlTone = .neutral, tint: Color = Theme.claude,
         size: ControlMetrics = .regular, emphasis: ControlEmphasis = .standard,
         action: @escaping () -> Void) {
        self.init(tone: tone, tint: tint, metrics: size, emphasis: emphasis, perform: action) {
            Text(title)
        }
    }
}

extension ActionButton where Label == AnyView {
    /// A button with an instrument mark before its label. `symbol` is a
    /// `SignatureGlyph` name, so an action's mark is the app's own drawing
    /// rather than a second icon language.
    init(_ title: String, symbol: String, tone: ControlTone = .neutral,
         tint: Color = Theme.claude, size: ControlMetrics = .regular,
         emphasis: ControlEmphasis = .standard,
         action: @escaping () -> Void) {
        self.init(tone: tone, tint: tint, metrics: size, emphasis: emphasis, perform: action) {
            AnyView(
                HStack(spacing: 6) {
                    SignatureGlyph(name: symbol,
                                   tint: tone == .destructive ? .white
                                        : (tone == .accent ? Theme.Ink.claude : Theme.textSecondary),
                                   size: size.iconSize)
                        .frame(width: size.iconSize, height: size.iconSize)
                    Text(title)
                }
            )
        }
    }
}

/// Reads `isPressed` out of the button's own configuration into a binding, so
/// the plate and the shape can be drawn by the label while the press state
/// still comes from AppKit's real tracking (a `DragGesture` would lose the
/// keyboard's space/Return and the system's press-then-drag-out cancel).
struct PressReportingStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, down in
                if pressed != down { pressed = down }
            }
    }
}

// MARK: - ChipButton

/// A compact selectable chip: the VPN flag row, the connector scope filters,
/// the 已配置 filter — anything that is a *state you can flip* rather than an
/// action you fire.
///
/// Radius 8, not a capsule: a chip is a small square-ish control that sits in a
/// row of its own kind, where a capsule reads as a button and a button in a
/// filter row reads as "this will do something".
struct ChipButton<Label: View>: View {
    var on: Bool
    var tint: Color = Theme.claude
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var hovered = false
    @State private var pressed = false

    private let radius: CGFloat = 8

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { label() }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(on ? tint : Theme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background {
                    shape
                        .fill(on ? tint.opacity(hovered || pressed ? 0.20 : 0.14)
                                 : Theme.cardFill(hovered || pressed ? 0.10 : 0.05))
                }
                .overlay {
                    shape.strokeBorder(on ? tint.opacity(hovered ? 0.52 : 0.38)
                                          : (hovered ? Theme.hairline.opacity(1.6) : Theme.hairline),
                                      lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .modifier(ControlPressModifier(hovered: $hovered, pressed: $pressed))
        }
        .buttonStyle(PressReportingStyle(pressed: $pressed))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

extension ChipButton where Label == AnyView {
    init(_ title: String, symbol: String? = nil, on: Bool,
         tint: Color = Theme.claude, action: @escaping () -> Void) {
        self.init(on: on, tint: tint, action: action) {
            AnyView(
                HStack(spacing: 5) {
                    if let symbol {
                        SignatureGlyph(name: symbol,
                                       tint: on ? tint : Theme.textSecondary, size: 11)
                            .frame(width: 11, height: 11)
                    }
                    Text(title)
                }
            )
        }
    }
}

// MARK: - ActionIcon

/// A square icon-only action: a settings gear, an eye that reveals a key, a
/// trash. Radius 8 — the same corner as `ChipButton`, because both are small
/// targets that sit in rows and neither is a pill.
struct ActionIcon: View {
    let symbol: String
    var tone: ControlTone = .neutral
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 26
    var action: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    private var destructive: Bool { tone == .destructive }

    var body: some View {
        Button(action: action) {
            SignatureGlyph(name: symbol,
                           tint: destructive ? .white
                               : (hovered ? tint : tint.opacity(0.85)),
                           size: size * 0.5, engaged: hovered)
                .frame(width: size, height: size)
                .background {
                    if destructive {
                        ControlPlate(tone: .destructive, tint: Theme.statusError,
                                     emphasis: .standard, shape: shape,
                                     hovered: hovered, pressed: pressed)
                    } else {
                        // An icon-only control has no label to say it is a
                        // control, so its tint is *the* affordance rather than a
                        // hint: the wash appears on hover, and it is the same 6 %
                        // → 10 % step an `ActionButton` takes, so a row of
                        // gear / eye / trash reads as one family.
                        shape.fill(tint.opacity(pressed ? 0.14 : (hovered ? 0.10 : 0)))
                    }
                }
                .overlay {
                    if !destructive {
                        shape.strokeBorder(tint.opacity(hovered ? 0.28 : 0), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(shape)
                .modifier(ControlPressModifier(hovered: $hovered, pressed: $pressed))
        }
        .buttonStyle(PressReportingStyle(pressed: $pressed))
    }
}

/// The one drop shadow the app's push button draws, shared by the two bodies
/// that can be destructive (`ActionButton` and `ActionPlateButtonStyle`).
///
/// It used to be six identical lines in each, which is how a pair of twins
/// drifts; `Tools/render-mainwindow-preview.py` also has to find and neutralise
/// this exact layer for a still render, and it only has to know one shape now.
/// Only a destructive tone mounts it — every other tone's shadow was drawn at
/// opacity 0, which still cost a hosted `NSView` and two `CALayer`s per button.
struct DestructivePlateShadow: View {
    var hovered: Bool
    var pressed: Bool
    var height: CGFloat

    var body: some View {
        LayerShadow(radius: pressed ? 1 : (hovered ? 6 : 3),
                    y: pressed ? 0 : (hovered ? 3 : 1.5),
                    opacity: hovered ? 0.20 : 0.13,
                    cornerRadius: height / 2,
                    surface: .clear,
                    color: .black)
    }
}

/// `ActionButton`'s plate, as a `ButtonStyle`.
///
/// Kept as a style (rather than folded into `ActionButton`) because a call site
/// whose label it does not own — a `ProgressView`, a rolling figure — still
/// needs the plate applied to a `Button` it built itself, and because the two
/// historical names `ProviderActionStyle` / `ConnectorUtilityButtonStyle`
/// forward here with positional arguments. It is a `ButtonStyle` and not a
/// `ViewModifier` because the press state lives in the configuration, and the
/// plate has to answer it.
struct ActionPlateButtonStyle: ButtonStyle {
    var tone: ControlTone
    var tint: Color
    var ink: Color?
    var metrics: ControlMetrics
    var emphasis: ControlEmphasis = .standard
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let down = pressed && !reduceMotion
        return configuration.label
            .font(.system(size: metrics.labelSize, weight: .semibold, design: .rounded))
            .foregroundStyle(ink ?? sparkleLabelColor)
            .offset(y: tone == .sparkle && hovered ? -SparklePlate.lift(for: metrics.height) : 0)
            .padding(.horizontal, metrics.hPadding)
            .frame(height: metrics.height)
            .background {
                ControlPlate(tone: tone, tint: tint, emphasis: emphasis, shape: Capsule(),
                             hovered: hovered, pressed: pressed, metrics: metrics)
            }
            .background {
                // Destructive only: any other tone drew this at opacity 0.
                if tone == .destructive {
                    DestructivePlateShadow(hovered: hovered, pressed: pressed,
                                           height: metrics.height)
                }
            }
            .contentShape(Capsule())
            .scaleEffect(down ? 0.97 : 1)
            .onHover { if hovered != $0 { hovered = $0 } }
            .animation(reduceMotion ? nil : Theme.Animation.snappy, value: pressed)
            .animation(reduceMotion ? nil : (tone == .sparkle ? Theme.Animation.sparkle
                                                              : .easeOut(duration: 0.14)),
                       value: hovered)
            .disabledTreatment()
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Same rule as `ActionButton.labelColor`, kept here because a style's body
    /// cannot call into the other type. `.sparkle` is the one tone whose resting
    /// ink is a *light* grey rather than the canvas's text colour, because the
    /// plate under it is near-black.
    private var sparkleLabelColor: Color {
        switch tone {
        case .neutral: return Theme.textPrimary
        case .accent: return (emphasis.isPrimary ? .white
                             : (Theme.isDark ? Theme.claudeHi : Theme.Ink.claude))
        case .destructive: return .white
        case .sparkle: return hovered ? .white : Color(hex: 0xAAAAAA)
        }
    }
}

// MARK: - Controls borrowed from Uiverse.io

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


// MARK: - The switch

/// The app's **one** switch, ported 1:1 from a reference toggle.
///
/// The reference is a soft "hardware" pill: a vertical surface gradient, a
/// hairline rim, an outer lift, an inset top highlight and an inset bottom
/// shade; a large knob with its own rim, inset highlight, inset shade and lift;
/// and — the part that makes it recognisable — a **ring indicator** on the far
/// side of the knob, red when off and green when on.
///
/// Geometry is measured from the reference's two state images (222 × 84 track,
/// 82 knob, 48 ring on the same artwork), not from the CSS numbers in the brief:
/// the two disagree, and the images are the design. The CSS's own
/// `115 × 55 / knob 42 / padding 6` gives a longer, flatter pill with a smaller
/// knob than either image shows.
///
/// | measured | value |
/// | --- | --- |
/// | track h/w | 0.378 |
/// | knob / track height | 0.976 |
/// | knob centre, off → on | 53 / 169 px |
/// | ring / track height | 0.571 |
/// | ring centre, off → on | 169 / 53 px |
///
/// **The ring does not travel.** That is the one structural thing the first
/// attempt here got wrong. It reads as if the indicator slides across, but in
/// both images the ring is on the side the knob is *not*: off → knob left, ring
/// right; on → knob right, ring left. Two ways to draw that with one moving
/// part are (a) move the ring and keep the knob still, or (b) move the knob and
/// put the ring at the opposite end. The reference animates the *ring's* colour
/// and the knob's position, and the ring's 74 % / 16 % are simply "the far side"
/// of wherever the knob is — so this draws the ring at the opposite end from the
/// knob and lets it stay put, which is one moving part instead of two.
///
/// The colour is the reference's own: `#EC6766` off, `#65C466` on. It is the one
/// place in this app a control's state is carried by red/green rather than by
/// the caller's hue, and it is deliberate — the reference's whole idea is that
/// the ring *is* the readout, and the 16 CTAs that use this style would lose it
/// if each repainted the ring in its own colour.
struct InstrumentToggleStyle: ToggleStyle {
    /// Ink for the label and the hover rim.
    var tint: Color = Theme.Ink.claude
    /// `false` drops the label column, for a bare switch in a tile cell.
    var showsLabel = true
    /// Overall width. The reference artwork is 222 wide; this default is about a
    /// third of that, because most call sites here sit in a caption row.
    var width: CGFloat = 62

    /// The reference's proportions, as ratios of `width`.
    ///
    /// Measured from the **on** state image, whose left end is unobstructed and
    /// therefore gives a clean pill width; the off image agrees on every ratio
    /// (track 222 × 84, knob 82, ring 48) once the knob's own shadow is excluded
    /// from the track's bounding box — reading that box naively adds ~13pt of
    /// shadow to the left edge and makes the knob look oversize.
    ///
    /// | | px | ratio |
    /// | --- | --- | --- |
    /// | track | 222 × 84 | h/w **0.378** |
    /// | knob | 82 | **0.976** of height |
    /// | ring | 48 | **0.571** of height |
    /// | knob centre, off / on | 53 / 169 | **0.24 / 0.76** of width |
    /// | ring centre, off / on | 169 / 53 | **0.76 / 0.23** |
    /// | end gap, off-left / on-right | 11 / 12 | — |
    ///
    /// One struct so track, knob, ring and travel cannot drift apart: the travel
    /// is "knob centre off to knob centre on", and deriving it from independent
    /// ratios is how a knob ends up 1pt off centre on the state that ships.
    ///
    /// The knob is very nearly the full track height (0.976), which is what makes
    /// the control read as a *milled* pill with a plunger in it rather than as a
    /// rail with a bead — the 2pt of play is a hairline, not a channel.
    struct Metrics {
        /// 84 / 222.
        var heightRatio: CGFloat = 84.0 / 222.0
        /// 82 / 84 — the knob fills the track's height bar a hairline.
        ///
        /// The measured 82 is the knob *including its rim and its shadow's
        /// footprint*. The drawn disc is pulled in by a couple of points so the
        /// track's own edge stays visible to the knob's left in the off state,
        /// which is how the reference reads: a milled channel with a plunger in
        /// it, not a disc flush to the wall.
        var knobRatio: CGFloat = 80.0 / 84.0
        /// 48 / 84 — the ring's outer diameter.
        var ringRatio: CGFloat = 48.0 / 84.0
        /// Ring stroke, as a share of the ring's *outer* diameter.
        ///
        /// **6 / 48 = 0.125.** The CSS says `border: 3px solid`, but the images
        /// measure 6px — the stroke is 12.5 % of the ring, which is what makes
        /// the indicator read as a drawn ring rather than a hairline circle.
        /// (The CSS's 3px on its own 24px ring is 12.5 % too, so the two agree
        /// on the *ratio* and the brief's `24px` was the stale number: the real
        /// ring is 48 with a 6 stroke.)
        var ringStrokeRatio: CGFloat = 6.0 / 48.0
        /// Knob centre when off, and when on (mirrored).
        ///
        /// The measured stops are 53 / 169 px, i.e. 0.24 / 0.76 of the width.
        /// The drawn ones sit a touch further in — 0.265 / 0.735, the stop the
        /// control has shipped — and, unlike `knobRatio` above, that is not a
        /// shadow-footprint correction. At the 62pt default the two differ by
        /// under 2pt, so re-deriving them would move every toggle in the app
        /// for no visible gain.
        var knobOffCentre: CGFloat = 0.265
        var knobOnCentre: CGFloat = 0.735

        /// The ring's own two stops, measured rather than mirrored: 75.5 % and
        /// 22.7 % of the width. They are *near* the knob's mirror (73.5 / 26.5)
        /// but not equal to it — the reference's ring sits a touch further out
        /// than the knob does, which is what keeps the two from reading as a
        /// symmetric pair and makes the indicator feel like a separate gauge
        /// beside a plunger rather than the plunger's reflection.
        var ringOffCentre: CGFloat = 0.755
        var ringOnCentre: CGFloat = 0.227

        func height(for width: CGFloat) -> CGFloat { (width * heightRatio).rounded() }
        func knob(for width: CGFloat) -> CGFloat { (height(for: width) * knobRatio).rounded() }
        func ring(for width: CGFloat) -> CGFloat { (height(for: width) * ringRatio).rounded() }
        func ringStroke(for width: CGFloat) -> CGFloat { max(1.5, (ring(for: width) * ringStrokeRatio).rounded()) }

        /// Knob origin from the track's leading edge. The stop is a *centre*, so
        /// the drawn origin is centre − radius.
        func knobOffset(for width: CGFloat, isOn: Bool) -> CGFloat {
            width * (isOn ? knobOnCentre : knobOffCentre) - knob(for: width) / 2
        }

        /// Ring origin — the mirrored stop. It is the far side from the knob in
        /// both states, so the two never overlap.
        func ringOffset(for width: CGFloat, isOn: Bool) -> CGFloat {
            width * (isOn ? ringOnCentre : ringOffCentre) - ring(for: width) / 2
        }
    }

    var metrics = Metrics()

    @MainActor
    func makeBody(configuration: Configuration) -> some View {
        InstrumentToggleBody(configuration: configuration, style: self)
    }
}

extension ToggleStyle where Self == InstrumentToggleStyle {
    /// The app's switch, in two spellings for two kinds of call site: `.instrument`
    /// where the style is chosen inline, `instrumentToggle()` where a labelled
    /// switch is being chained at the end of a longer expression.
    static var instrument: InstrumentToggleStyle { InstrumentToggleStyle() }
}

extension Toggle {
    func instrumentToggle(tint: Color = Theme.Ink.claude,
                          showsLabel: Bool = true) -> some View {
        toggleStyle(InstrumentToggleStyle(tint: tint, showsLabel: showsLabel))
    }
}

/// The switch's own colours, in one place so the light and dark recipes cannot
/// drift.
private enum SwitchPalette {
    /// The reference's track: white at the top easing to a very light grey at
    /// the bottom. Both images sit on a `#E8E8E8` page, so these are the
    /// measured values, not a guess at a gradient.
    static var trackTop: Color { Theme.isDark ? Color(hex: 0x3C444E) : Color(hex: 0xFFFFFF) }
    static var trackBottom: Color { Theme.isDark ? Color(hex: 0x272E36) : Color(hex: 0xEAEBED) }

    /// The hairline rim — `rgba(0,0,0,.1)` in the reference, lit in dark mode so
    /// the edge still reads.
    static var rim: Color { Theme.isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.10) }

    /// The knob's disc: white, lit from the upper left.
    static var knobCenter: Color { Color.white }
    static var knobMid: Color { Theme.isDark ? Color(hex: 0xEFF1F4) : Color(hex: 0xFBFBFC) }
    static var knobEdge: Color { Theme.isDark ? Color(hex: 0xD4D9E0) : Color(hex: 0xEFEFF1) }
    static var knobRim: Color { Theme.isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.06) }

    /// The ring indicator — the reference's own two colours.
    static var ringOff: Color { Color(hex: 0xEC6766) }
    static var ringOn: Color { Color(hex: 0x65C466) }
}

private struct InstrumentToggleBody: View {
    let configuration: ToggleStyle.Configuration
    let style: InstrumentToggleStyle

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOn: Bool { configuration.isOn }
    private var metrics: InstrumentToggleStyle.Metrics { style.metrics }
    private var height: CGFloat { metrics.height(for: style.width) }
    private var knob: CGFloat { metrics.knob(for: style.width) }
    private var ring: CGFloat { metrics.ring(for: style.width) }
    private var ringStroke: CGFloat { metrics.ringStroke(for: style.width) }

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            if style.showsLabel {
                configuration.label
                    .font(Theme.Font.chrome)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .onTapGesture { configuration.isOn.toggle() }
            }
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: .leading) {
                    track
                    ringView
                    knobView
                }
                .frame(width: style.width, height: height)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .onHover { if hovered != $0 { hovered = $0 } }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: isOn)
        .animation(Theme.Motion.state, value: hovered)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// The pill: surface gradient, hairline rim, outer lift, inset highlight
    /// along the top edge and inset shade along the bottom.
    private var track: some View {
        Capsule(style: .continuous)
            .fill(LinearGradient(
                colors: [SwitchPalette.trackTop, SwitchPalette.trackBottom],
                startPoint: .top, endPoint: .bottom))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(SwitchPalette.rim, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            // Inset top highlight: the reference's `inset 0 2px 2px #fff`.
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(Theme.isDark ? 0.20 : 0.95), lineWidth: 1.5)
                    .mask(LinearGradient(colors: [.white, .white.opacity(0)],
                                         startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            }
            // Inset bottom shade: `inset 0 -5px 10px rgba(0,0,0,.06)`.
            .overlay {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [.clear, Color.black.opacity(Theme.isDark ? 0.22 : 0.06)],
                                         startPoint: .center, endPoint: .bottom))
                    .allowsHitTesting(false)
            }
            // Outer lift: `0 10px 22px` + `0 2px 6px`, scaled with the control
            // so a 27pt pill does not wear a 55pt pill's detached shadow.
            .shadow(color: .black.opacity(0.10), radius: height * 0.34, y: height * 0.16)
            .shadow(color: .black.opacity(0.08), radius: height * 0.09, y: height * 0.03)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(hovered ? style.tint.opacity(0.55) : Color.clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    /// The ring indicator: a stroked circle on the side the knob is not, red when
    /// off and green when on.
    ///
    /// It does **not** animate its position — see the note on
    /// `InstrumentToggleStyle`. Only the colour changes, and the knob is what
    /// moves; giving the ring a travel of its own would be a second moving part
    /// saying what the knob already says.
    private var ringView: some View {
        Circle()
            .strokeBorder(isOn ? SwitchPalette.ringOn : SwitchPalette.ringOff,
                          lineWidth: ringStroke)
            .frame(width: ring, height: ring)
            .offset(x: metrics.ringOffset(for: style.width, isOn: isOn))
            .animation(reduceMotion ? nil : Theme.Motion.state, value: isOn)
    }

    /// The knob: a large disc lit from the upper left, with its own rim, inset
    /// highlight, inset shade and lift.
    private var knobView: some View {
        Circle()
            .fill(RadialGradient(
                colors: [SwitchPalette.knobCenter, SwitchPalette.knobMid, SwitchPalette.knobEdge],
                center: UnitPoint(x: 0.34, y: 0.28),
                startRadius: 0,
                endRadius: knob * 0.80))
            .overlay {
                Circle().strokeBorder(SwitchPalette.knobRim, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(Theme.isDark ? 0.26 : 0.95), lineWidth: 1.5)
                    .mask(LinearGradient(colors: [.white, .white.opacity(0)],
                                         startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            }
            .overlay {
                Circle()
                    .fill(LinearGradient(colors: [.clear, Color.black.opacity(0.06)],
                                         startPoint: .center, endPoint: .bottom))
                    .allowsHitTesting(false)
            }
            .frame(width: knob, height: knob)
            // Lift: `0 10px 18px rgba(0,0,0,.16)` + `0 2px 5px rgba(0,0,0,.12)`.
            .shadow(color: .black.opacity(0.16), radius: knob * 0.20, y: knob * 0.10)
            .shadow(color: .black.opacity(0.10), radius: knob * 0.06, y: knob * 0.03)
            .offset(x: metrics.knobOffset(for: style.width, isOn: isOn))
    }
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

    var body: some View {
        Capsule()
            .fill(
                LinearGradient(colors: [.black.opacity(0.26), .black.opacity(0.14)],
                               startPoint: .top, endPoint: .bottom)
            )
            .frame(height: 7)
            .blur(radius: 7)
            .opacity(active ? 0.9 : 0.35)
            .animation(Theme.Motion.state, value: active)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}



// MARK: - The page band's own control
/// The control a page band (连接器 / 模型) puts in its header: the same push
/// button as everywhere else, at the band's own proportions, in the quiet tone.
///
/// It used to be its own recipe — a milled capsule with a bottom rule and a
/// `GroundShadow` — which is exactly the kind of "one more button" this
/// unification removes. A band's control is not a different object from the
/// dashboard's 刷新; it is the same object on a different surface.
extension View {
    func headerControl() -> some View {
        modifier(HeaderControlModifier())
    }
}

private struct HeaderControlModifier: ViewModifier {
    /// The band's control is the regular plate at the band's own proportions:
    /// the font, padding and height are read from `ControlMetrics.regular`
    /// rather than re-typed, so retuning the regular plate carries to the band.
    private let metrics: ControlMetrics = .regular

    func body(content: Content) -> some View {
        content
            .font(.system(size: metrics.labelSize, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, metrics.hPadding)
            .frame(height: metrics.height)
            .background {
                ControlPlate(tone: .neutral, tint: Theme.claude, emphasis: .standard,
                             shape: Capsule(), hovered: false, pressed: false)
            }
            .background {
                LayerShadow(radius: 3, y: 1.5, opacity: 0.09,
                            cornerRadius: 15, surface: .clear, color: .black)
            }
            .contentShape(Capsule())
            .disabledTreatment()
    }
}

// MARK: - The menu label

/// A `Menu` shown as the same recessed capsule as a field, with a chevron.
/// Native `.pickerStyle(.menu)` is Aqua chrome inside a machined tile, which is
/// why every menu in the app draws its own label through this.
///
/// It is a *label*, not a control: the `Menu` around it owns the button, the
/// click and the focus ring. So this draws the well, the hover rim and the
/// chevron, and nothing else — a second press state here would fight the one
/// AppKit is already tracking on the `Menu` itself.
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
        // On a card, not on the page canvas: a recessed well would vanish
        // against a raised tile, so the well steps up instead.
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

/// A native popover retains our shared field surface; macOS Menu can replace
/// an authored label with its own borderless title. Short option sets keep
/// normal focusable buttons and an explicit current selection.
struct InstrumentChoiceControl<Value: Hashable>: View {
    var label: String
    var items: [Value]
    var selection: Value
    var title: (Value) -> String
    var tint: Color = Theme.Ink.cursor
    var onSelect: (Value) -> Void
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            InstrumentMenuLabel(title: title(selection), tint: tint)
        }.buttonStyle(.plain).accessibilityLabel(label)
            .accessibilityValue(title(selection))
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(label).font(Theme.Font.chromeEmph).foregroundStyle(Theme.textPrimary)
                        .padding(.bottom, 4)
                    ForEach(items, id: \.self) { item in
                        Button { presented = false; onSelect(item) } label: {
                            HStack(spacing: 12) {
                                Text(title(item)).font(Theme.Font.bodySmall).foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 8)
                                AppGlyph(name: "checkmark", size: 12).foregroundStyle(tint)
                                    .opacity(item == selection ? 1 : 0).accessibilityHidden(true)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(item == selection ? tint.opacity(0.08) : Theme.fieldWell,
                                            in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        }.buttonStyle(.plain).accessibilityAddTraits(item == selection ? [.isSelected] : [])
                    }
                }.padding(16).frame(width: 240).background(Theme.bgPrimary)
            }
    }
}
