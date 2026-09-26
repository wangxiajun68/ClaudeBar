import SwiftUI

/// Bottom confirmation toast: a status dot + message. Lifecycle is owned by
/// the caller (message + token drive a `.task(id:)` auto-dismiss); this view
/// only renders and animates.
struct FeedbackToast: View {
    let message: String?
    var tint: Color = Theme.statusSuccess

    var body: some View {
        HStack(spacing: Theme.Space.s6) {
            // The mark in the shared well, and the surface from the same family
            // as everything else it floats over. The radius was a hard-coded 10
            // — off the token grid, and the one rounded rect in the app that did
            // not use `.continuous`.
            GlyphWell(name: "info.circle.fill", tint: tint, size: 20)
            Text(message ?? "")
                .font(Theme.Font.microMedium)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s6)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(Theme.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            InnerFrameRing(inset: 2, radius: Theme.Radius.sm, tint: tint.opacity(0.3))
        }
        .opacity(message == nil ? 0 : 1)
        .accessibilityHidden(message == nil)
        .animation(Theme.Animation.smooth, value: message)
        .accessibilityLabel(message ?? "")
    }
}
