import SwiftUI

// MARK: - PressableStyle

/// A button style that scales the content down slightly on press, then
/// springs back on release. The tactile foundation for chips, icon buttons,
/// and cards — the small 0.96 scale keeps the press subtle.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

/// Uiverse 3D press: translate down 1pt, collapse the drop shadow.
/// Translation preserves the visual size of compact, variable-width controls.
struct UiversePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.08),
                    radius: configuration.isPressed ? 0 : 2, y: configuration.isPressed ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == UiversePressStyle {
    static var uiversePress: UiversePressStyle { UiversePressStyle() }
}

/// One-shot lift on appear. Delay is staggered so stacked popup sections
/// cascade without animating every inner cell (that would hitch scroll).
///
/// **Currently no call site.** It used to stagger the popup's sections on open;
/// those `.appearLift(...)` calls were removed, and DESIGN.md's "popup sections
/// lift in once" now describes nothing in the code. Kept because the stagger
/// *shape* — a one-shot per section, never per inner cell — is the right one
/// for a surface that wants it, and the `onAppear`-guarded `@State` is the
/// non-obvious half of getting it right.
struct AppearLift: ViewModifier {
    var delay: Double = 0
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? nil : Theme.Animation.smooth.delay(delay)) { shown = true }
            }
    }
}

extension View {
    func appearLift(delay: Double = 0) -> some View {
        modifier(AppearLift(delay: delay))
    }
}

// MARK: - Adaptive glass buttons

extension View {
    /// macOS 26+: native Liquid Glass. Earlier: bordered fallback with the same API surface.
    @ViewBuilder
    func adaptiveGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// MARK: - HoverState

/// Tracks pointer-in / pointer-out for a view, wrapped into a bindable
/// `@State` so hover-driven UI can be read declaratively.
struct HoverState: ViewModifier {
    @Binding var isHovered: Bool

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if isHovered != hovering { isHovered = hovering }
            }
    }
}

extension View {
    /// Drive `isHovered` from pointer movement, animated with the theme spring.
    func hoverState(_ isHovered: Binding<Bool>) -> some View {
        modifier(HoverState(isHovered: isHovered))
    }
}

// MARK: - Action chip

/// A compact circular icon button used as the hover-revealed action on rows.
/// Carries its own hover highlight so it feels like a distinct target rather
/// than part of the card surface.
///
/// `.plain` alone gives the button no hit shape: the tappable area is the
/// *rendered glyph* (icon strokes plus the 26×26 background), so clicks land
/// on the transparent corners and fall through to whatever is behind. Wrapping
/// the label in a `contentShape` makes the whole tile a target.
struct ActionChip: View {
    let systemImage: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            AppGlyph(name: systemImage, size: 12, box: 16)
                .foregroundColor(tint)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(tint.opacity(hover ? 0.22 : 0.10))
                )
                .overlay(
                    Circle()
                        .strokeBorder(tint.opacity(hover ? 0.5 : 0.25), lineWidth: 1)
                )
            .scaleEffect(hover ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hover != hovering { hover = hovering }
        }
        .help(help)
        // `.help` renders a tooltip only; VoiceOver needs the label.
        .accessibilityLabel(help)
    }
}

// MARK: - Icon chip

/// One item in an icon row — the menu-bar popup's action bar, the battery
/// popover's button, the main window's trailing controls.
///
/// Drawn from the `mymiamo` glass menu's *item*: a rounded tile that stays
/// quiet at rest and, on hover, takes a lit fill plus the same inset rim the
/// menu group wears (`inset 2px 2px 5px -2px` top-left, `inset -2px -2px`
/// bottom-right). A row of ten identical flat squares was the plainest thing in
/// the highest-frequency surface in the app; the reference's answer is not more
/// decoration per item but a *shared* well the items sit in, which is
/// `IconChipRow` below.
struct IconChip: View {
    let systemImage: String
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 12
    var tile: CGFloat = 26
    var corner: CGFloat = Theme.Radius.sm
    @State private var hover = false

    var body: some View {
        SignatureGlyph(name: systemImage, tint: hover ? tint : tint.opacity(0.85),
                       size: size + 4, engaged: hover)
            .frame(width: tile, height: tile)
            .background {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(tint.opacity(hover ? 0.15 : 0))
            }
            .overlay {
                // The lit rim appears with the fill, so the tile reads as a
                // glass item lighting up rather than as a square that changed
                // colour.
                if hover {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(tint.opacity(0.30), lineWidth: 0.75)
                }
            }
            .overlay {
                if hover {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(Theme.isDark ? 0.10 : 0.75),
                                         .clear,
                                         Color.white.opacity(Theme.isDark ? 0.05 : 0.35)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            }
            .onHover { if hover != $0 { hover = $0 } }
            .animation(Theme.Motion.state, value: hover)
    }
}

/// The milled well an icon row sits in — the `mymiamo` menu's own glass track.
///
/// This is the half of the reference that fixes a ten-chip row: the items share
/// one translucent capsule with a lit top rim and a soft bottom rule, so the bar
/// reads as a single control strip rather than as ten unrelated squares on the
/// canvas. The row's own items (`IconChip`) then only need a hover highlight,
/// which is why they could give up their resting fill entirely.
///
/// One shape, one gradient overlay, drawn once for the whole row — no per-item
/// layer, so a bar of ten chips is two layers, not twenty.
struct IconChipRow<Content: View>: View {
    var spacing: CGFloat = Theme.Space.s4
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: spacing) { content() }
            .padding(.horizontal, Theme.Space.s6)
            .padding(.vertical, Theme.Space.s4)
            .background {
                Capsule()
                    .fill(Theme.cardFill(0.06))
                    .overlay {
                        Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
                    }
            }
            .overlay {
                // The lit rim: bright along the top edge, fading before it
                // reaches the bottom — the same top-lit convention the tiles and
                // the segmented cradle use.
                Capsule()
                    .strokeBorder(
                        LinearGradient(colors: [Theme.innerFrameMuted, .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                    .padding(1.5)
                    .allowsHitTesting(false)
            }
    }
}

/// The island's per-digit roll, shared by the island, the menu-bar popup and
/// the main window. Only the glyphs move; the view's frame stays put.
///
/// **`.numericText` only — no implicit `.animation(value:)`.** A previous
/// version also carried `.animation(.snappy(duration: 0.38), value: value)`,
/// which made this the app's worst idle cost. Every instance is driven by a
/// value the sampler updates once a second (a hero percentage, a session
/// count, a context label), so the modifier opened a *fresh* animated
/// transaction on every tick, and an in-flight transaction makes the display
/// cycle run the whole hosting view's layout + display list. The `sample`
/// signature moved cleanly: `+[NSAnimationContext runAnimationGroup:]` inside
/// `NSHostingView.layout()` fell from 31 % of main-thread samples to 13 %, and
/// `stepIdle` (the display-cycle observer re-laying out the window every
/// frame) from 56 % to 3 %. `.numericText` already animates the digits, so
/// removing the modifier costs the roll nothing: the transition *is* the
/// animation.
///
/// The `ps -p PID -o time=` delta on the dashboard is a *noisy* metric on this
/// machine (a Chrome renderer holds half a core, and the app's own idle figure
/// swings 10-27 % between 20 s windows with no interaction). Treat the sample
/// attribution above as the evidence and the CPU delta as corroboration only.
///
/// The rule is the one `UiverseSurfaces.swift` states for repeating motion,
/// applied to *implicit* motion: on a hot surface, a modifier keyed to a
/// per-second value is not free even when the value rarely changes.
/// `Tests/inflight-animation-regressions.py` holds this and
/// `SectionHeader.trailingView` to it.
struct RollingNumberText: View {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ value: String) { self.value = value }

    var body: some View {
        Text(value)
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
    }
}
