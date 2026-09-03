import SwiftUI

/// Popup panel header: brand mark + collapse toggle + refresh.
struct PanelHeader: View {
    @EnvironmentObject var providerStore: ProviderStore
    @Binding var configCollapsed: Bool
    var onFeedback: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            BrandMark(size: 20)
            Text("ClaudeBar")
                .font(Theme.Font.titleSmall)
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button(action: {
                withAnimation(Theme.Animation.smooth) { configCollapsed.toggle() }
            }) {
                Image(systemName: configCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    .font(Theme.Font.bodySmall)
                    .foregroundColor(Theme.textSecondary)
            }
            .adaptiveGlassButton()
            .help(configCollapsed ? "展开配置与模型" : "折叠配置与模型")
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
