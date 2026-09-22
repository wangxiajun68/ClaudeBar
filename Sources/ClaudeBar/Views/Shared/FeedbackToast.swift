import SwiftUI

/// Bottom confirmation toast: a status dot + message. Lifecycle is owned by
/// the caller (message + token drive a `.task(id:)` auto-dismiss); this view
/// only renders and animates.
struct FeedbackToast: View {
    let message: String?
    var tint: Color = Theme.statusSuccess

    var body: some View {
        HStack(spacing: Theme.Space.s6) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(tint)
                .accessibilityHidden(true)
            Text(message ?? "")
                .font(Theme.Font.microMedium)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s16)
        .padding(.vertical, Theme.Space.s8)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .opacity(message == nil ? 0 : 1)
        .accessibilityHidden(message == nil)
        .animation(Theme.Animation.smooth, value: message)
        .accessibilityLabel(message ?? "")
    }
}
