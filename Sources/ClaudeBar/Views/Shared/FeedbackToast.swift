import SwiftUI

/// Bottom confirmation toast: a status dot + message. Lifecycle is owned by
/// the caller (message + token drive a `.task(id:)` auto-dismiss); this view
/// only renders and animates.
struct FeedbackToast: View {
    let message: String?
    var tint: Color = Theme.statusSuccess

    var body: some View {
        HStack(spacing: Theme.Space.s6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(message ?? "")
                .font(Theme.Font.microMedium)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s16)
        .padding(.vertical, Theme.Space.s8)
        .opacity(message == nil ? 0 : 1)
        .animation(Theme.Animation.smooth, value: message)
        .accessibilityLabel(message ?? "")
    }
}
