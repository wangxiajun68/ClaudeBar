import SwiftUI

/// Providers page: embeds the existing `ProviderEditorView` (master-detail
/// editor) inside the Dispatch console. Provider activation here flows
/// through the shared `ProviderStore`, updating both the popup and Dashboard.
struct ProvidersView: View {
    @EnvironmentObject var providerStore: ProviderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("供应商")
                    .font(Theme.Font.titleLarge)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.s24)
            .padding(.top, Theme.Space.s24)
            .padding(.bottom, Theme.Space.s12)

            ProviderEditorView(providerStore: providerStore)
                .background(Theme.base0.opacity(0.35))
        }
        .background(Theme.base0.opacity(0.35))
    }
}
