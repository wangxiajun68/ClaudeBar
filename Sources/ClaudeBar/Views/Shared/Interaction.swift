import SwiftUI

// MARK: - PressableStyle

/// A button style that scales the content down slightly on press and lifts the
/// shadow, then springs back on release. This is the "tactile" foundation for
/// every tappable chip, icon button, and card — flat buttons that don't react
/// to the press read as dead. The scale is small (0.96) so it stays classy.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var lift: CGFloat = 1.5

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Theme.Animation.bouncy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - HoverState

/// Tracks pointer-in / pointer-out for a view. SwiftUI's `.onHover` fires on
/// both enter and leave, which makes building "hover-only" UI awkward; this
/// wraps it into a bindable `@State` you can read declaratively.
struct HoverState: ViewModifier {
    @Binding var isHovered: Bool
    var shape: any Shape = RoundedRectangle(cornerRadius: Theme.Radius.md)

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
                .font(.system(size: 11, weight: .semibold))
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

/// A compact rounded icon tile with its own hover lift + highlight — the
/// building block for the menu-bar popup's action bar and any small icon
/// button. Now backed by native Liquid Glass so every icon button across
/// the app automatically carries a real specular glass surface. The fill
/// brightens (via glass tint) and the tile scales up slightly on hover so
/// each icon reads as a live target.
struct IconChip: View {
    let systemImage: String
    var tint: Color = .white
    var size: CGFloat = 12
    var tile: CGFloat = 24
    var corner: CGFloat = 5
    @State private var hover = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size))
            .foregroundColor(hover ? tint : tint.opacity(0.85))
            .frame(width: tile, height: tile)
            .glassEffect(
                .regular.tint(tint.opacity(hover ? 0.22 : 0)),
                in: RoundedRectangle(cornerRadius: corner)
            )
            .scaleEffect(hover ? 1.08 : 1)
            .onHover { hovering in
                withAnimation(Theme.Animation.bouncy) { hover = hovering }
            }
    }
}
