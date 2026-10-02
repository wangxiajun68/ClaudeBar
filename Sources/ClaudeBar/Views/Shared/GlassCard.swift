import SwiftUI

// MARK: - Selection tint

/// Selected/active tint: a translucent accent wash behind a selected row,
/// drawn only when `isActive`.
struct SelectionTintModifier: ViewModifier {
    var isActive: Bool
    var color: Color
    var corner: CGFloat

    func body(content: Content) -> some View {
        content.background {
            if isActive {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(color.opacity(0.16))
            }
        }
    }
}

extension View {
    func selectionTint(
        _ isActive: Bool,
        color: Color = Theme.accent,
        corner: CGFloat = Theme.Radius.sm
    ) -> some View {
        modifier(SelectionTintModifier(isActive: isActive, color: color, corner: corner))
    }
}
