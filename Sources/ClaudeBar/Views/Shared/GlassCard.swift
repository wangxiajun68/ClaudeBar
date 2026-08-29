import SwiftUI

// MARK: - Selection tint (Liquid Glass, unified)

/// Selected/active Liquid Glass tint — the single home for the
/// `.glassEffect(.regular.tint(accent…))` selection background that used to
/// be hand-rolled in ProviderRow (×3), ProviderEditorView, MainWindowView,
/// and SessionCardView's busy treatment.
struct SelectionTintModifier: ViewModifier {
    var isActive: Bool
    var color: Color
    var corner: CGFloat
    /// Extra opacity for the "active and emphasized" case (busy rows).
    var opacity: Double = 0.16

    func body(content: Content) -> some View {
        content.background {
            if isActive {
                RoundedRectangle(cornerRadius: corner)
                    .fill(Color.clear)
                    .glassEffect(
                        .regular.tint(color.opacity(opacity)),
                        in: RoundedRectangle(cornerRadius: corner)
                    )
            }
        }
    }
}

extension View {
    func selectionTint(
        _ isActive: Bool,
        color: Color = Theme.accent,
        corner: CGFloat = Theme.Radius.sm,
        opacity: Double = 0.16
    ) -> some View {
        modifier(SelectionTintModifier(isActive: isActive, color: color, corner: corner, opacity: opacity))
    }
}

// MARK: - Glass card

/// Data-as-ornament glass card: quiet by default (no shadow), hover lift via
/// fill brightening. Optional emphasis tint (e.g. busy sessions). Shadows —
/// when enabled — carry offset + blur per craft-floor (never a flat halo).
struct GlassCard<Content: View>: View {
    var isActive: Bool = false
    var tint: Color = Theme.accent
    var corner: CGFloat = Theme.Radius.md
    var hoverFill: Bool = true
    var shadow: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        content()
            .glassEffect(
                .regular.tint(
                    isActive ? tint.opacity(0.12) : Color.white.opacity(isHovered ? 0.09 : 0.05)
                ),
                in: RoundedRectangle(cornerRadius: corner)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(isActive ? tint.opacity(0.35) : Theme.hairline, lineWidth: 1)
            )
            .modifier(CardShadow(enabled: shadow))
            .scaleEffect(isHovered && hoverFill ? 1.01 : 1)
            .hoverState($isHovered)
            .animation(Theme.Animation.smooth, value: isHovered)
            .animation(Theme.Animation.smooth, value: isActive)
    }
}

private struct CardShadow: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.shadowCard()
        } else {
            content
        }
    }
}
