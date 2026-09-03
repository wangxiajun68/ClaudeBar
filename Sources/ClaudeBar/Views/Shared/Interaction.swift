import SwiftUI

// MARK: - PressableStyle

/// A button style that scales the content down slightly on press, then
/// springs back on release. The tactile foundation for chips, icon buttons,
/// and cards — the small 0.96 scale keeps the press subtle.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.Animation.bouncy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
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
                if isHovered != hovering {
                    withAnimation(Theme.Animation.bouncy) { isHovered = hovering }
                }
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
struct ActionChip: View {
    let systemImage: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Theme.Font.bodySmall.weight(.semibold))
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
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Animation.bouncy) { hover = hovering }
        }
        .help(help)
    }
}

// MARK: - Icon chip

/// A compact rounded icon tile with a hover lift + highlight, backed by
/// Liquid Glass so each icon carries a specular surface. Used for the
/// menu-bar popup's action bar and small icon buttons.
struct IconChip: View {
    let systemImage: String
    var tint: Color = .white
    var size: CGFloat = 12
    var tile: CGFloat = 24
    var corner: CGFloat = 5
    @State private var hover = false

    var body: some View {
        Image(systemName: systemImage)
            .font(Theme.Font.systemIcon(size))
            .foregroundColor(hover ? tint : tint.opacity(0.85))
            .frame(width: tile, height: tile)
            .background {
                RoundedRectangle(cornerRadius: corner)
                    .fill(tint.opacity(hover ? 0.22 : 0.06))
            }
            .scaleEffect(hover ? 1.08 : 1)
            .onHover { hovering in
                withAnimation(Theme.Animation.bouncy) { hover = hovering }
            }
    }
}
