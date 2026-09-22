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
/// No scaleEffect — scale reflows neighbors and is what made the 测速
/// button jump in a row of variable-width chips.
struct UiversePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 1 : 0)
            .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.08),
                    radius: configuration.isPressed ? 0 : 2, y: configuration.isPressed ? 0 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == UiversePressStyle {
    static var uiversePress: UiversePressStyle { UiversePressStyle() }
}

/// One-shot lift on appear. Delay is staggered so stacked popup sections
/// cascade without animating every inner cell (that would hitch scroll).
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
            hover = hovering
        }
        .help(help)
        // `.help` renders a tooltip only; VoiceOver needs the label.
        .accessibilityLabel(help)
    }
}

// MARK: - Icon chip

/// A compact rounded icon tile with a hover lift + highlight, backed by
/// Liquid Glass so each icon carries a specular surface. Used for the
/// menu-bar popup's action bar and small icon buttons.
struct IconChip: View {
    let systemImage: String
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 12
    var tile: CGFloat = 24
    var corner: CGFloat = Theme.Radius.sm
    @State private var hover = false

    var body: some View {
        SignatureGlyph(name: systemImage, tint: hover ? tint : tint.opacity(0.85),
                       size: size + 4, engaged: hover)
            .frame(width: tile, height: tile)
            .background {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(tint.opacity(hover ? 0.16 : 0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(tint.opacity(hover ? 0.3 : 0.12), lineWidth: 0.75)
            }
            .onHover { hover = $0 }
    }
}
