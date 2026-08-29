import SwiftUI

/// The session's current activity, e.g. "Bash · build.sh", with a small pulsing
/// dot indicating whether the session is busy. Extracted from
/// `MenuBarView.activityLine`.
struct ActivityLine: View {
    let activity: String
    let isBusy: Bool
    var color: Color = Theme.statusBusy

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isBusy ? color : Theme.statusIdle.opacity(0.5))
                .frame(width: 4, height: 4)
                .overlay(
                    Circle().strokeBorder(isBusy ? color.opacity(0.4) : Color.clear, lineWidth: 2)
                        .scaleEffect(isBusy ? 1.8 : 1)
                        .opacity(isBusy ? 0.5 : 0)
                        .animation(Theme.Animation.pulse.repeatForever(autoreverses: true),
                                   value: isBusy)
                )
            Text(activity)
                .font(Theme.Font.captionMono)
                .foregroundColor(isBusy ? .white.opacity(0.7) : .white.opacity(0.4))
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 2)
    }
}
