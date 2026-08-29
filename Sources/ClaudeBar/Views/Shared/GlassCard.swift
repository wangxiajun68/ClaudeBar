import SwiftUI

// MARK: - Selection tint/// Selected/active Liquid Glass tint: a translucent accent wash behind the
/// content, drawn only when `isActive`. Single source for row selection
/// backgrounds so editors and lists stay visually consistent.
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
