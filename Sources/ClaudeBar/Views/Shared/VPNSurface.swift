import SwiftUI

/// VPN uses quiet, stationary surfaces: controls and scrolling never lift a panel.
extension View {
    func vpnSurface() -> some View {
        background(Theme.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
