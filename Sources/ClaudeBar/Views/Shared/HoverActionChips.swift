import SwiftUI

/// Hover-reveal action row: chips slide in and become interactive only while
/// the parent is hovered. Replaces the duplicated
/// `.opacity(isHovered).offset(x:).allowsHitTesting` triple in SessionsView.
struct HoverActionsModifier: ViewModifier {
    @Binding var isHovered: Bool
    var spacing: CGFloat = Theme.Space.s4

    func body(content: Content) -> some View {
        content
            .opacity(isHovered ? 1 : 0)
            .offset(x: isHovered ? 0 : 10)
            .allowsHitTesting(isHovered)
            .animation(Theme.Animation.smooth, value: isHovered)
    }
}

extension View {
    /// Show this view (typically an HStack of ActionChips) only while hovered.
    func hoverActions(when isHovered: Binding<Bool>) -> some View {
        modifier(HoverActionsModifier(isHovered: isHovered))
    }
}
