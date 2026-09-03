import SwiftUI

/// Popup panel header: brand mark + refresh.
struct PanelHeader: View {
    @EnvironmentObject var providerStore: ProviderStore
    var onFeedback: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            BrandMark(size: 20)
            Text("ClaudeBar")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button(action: {
                providerStore.refresh()
                onFeedback()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(Theme.textSecondary)
            }
            .adaptiveGlassButton()
            .sensoryFeedback(.selection, trigger: providerStore.sessions.map(\.pid))
            .help("刷新")
        }
        .padding(.horizontal, Theme.Space.s16).padding(.vertical, Theme.Space.s12)
    }
}
