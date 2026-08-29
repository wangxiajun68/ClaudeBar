import SwiftUI

/// Pulsing status dot used across session cards. When `isOn` the dot is filled
/// with `color` and surrounded by a slow pulsing ring; otherwise it is a muted
/// gray dot. Extracted from the repeated `Circle().fill().overlay().animation()`
/// pattern in the menu-bar popup.
struct StatusBadge: View {
    let isOn: Bool
    let color: Color
    var big: Bool = false

    var body: some View {
        Circle()
            .fill(isOn ? color : Theme.statusIdle.opacity(0.55))
            .frame(width: big ? 8 : 6, height: big ? 8 : 6)
            .overlay(
                Circle().strokeBorder(isOn ? color.opacity(0.4) : Color.clear, lineWidth: big ? 4 : 3)
                    .scaleEffect(isOn ? 1.7 : 1)
                    .opacity(isOn ? 0.5 : 0)
                    .animation(Theme.Animation.pulse.repeatForever(autoreverses: true),
                               value: isOn)
            )
    }
}
