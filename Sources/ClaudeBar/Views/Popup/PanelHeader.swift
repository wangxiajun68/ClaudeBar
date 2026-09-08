import SwiftUI

/// Popup panel header: brand mark + VPN chrome + refresh.
struct PanelHeader: View {
    @EnvironmentObject var providerStore: ProviderStore
    var onFeedback: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            BrandMark(size: 20)
            Text("ClaudeBar")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
            VpnChromeCluster()
            Button(action: {
                providerStore.refresh()
                onFeedback()
            }) {
                AppGlyph(name: "arrow.clockwise", size: 12)
                    .foregroundColor(Theme.textSecondary)
            }
            .adaptiveGlassButton()
            .sensoryFeedback(.selection, trigger: providerStore.sessions.map(\.pid))
            .help("刷新")
        }
        .padding(.horizontal, Theme.Space.s16).padding(.vertical, Theme.Space.s12)
    }
}
