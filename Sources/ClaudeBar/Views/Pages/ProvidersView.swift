import SwiftUI

/// Providers page: the 宫格 of provider tiles (activate a model with one tap,
/// expand models in-tile), plus a link into the full editor as the detail
/// layer. Activation flows through the shared `ProviderStore`, updating both
/// the popup and Dashboard.
struct ProvidersView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            HStack {
                Text("供应商")
                    .font(Theme.Font.titleLarge)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Button(action: { showEditor.toggle() }) {
                    Label(showEditor ? "收起编辑器" : "编辑供应商…", systemImage: "slider.horizontal.3")
                        .font(Theme.Font.bodySmall)
                }
                .buttonStyle(.glass)
                .tint(Theme.claude)
            }
            .padding(.horizontal, Theme.Space.s24)
            .padding(.top, Theme.Space.s24)

            if providerStore.providers.isEmpty {
                Text("暂无供应商配置")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textTertiary())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                ScrollView {
                    TileGrid(.pageProvider) {
                        ForEach(providerStore.providers) { provider in
                            ProviderTile(
                                provider: provider,
                                isActive: provider.id == providerStore.activeProviderID,
                                currentModelName: providerStore.currentEnv?.ANTHROPIC_MODEL,
                                onActivateModel: { modelID in
                                    providerStore.activateModel(providerID: provider.id, modelID: modelID)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, Theme.Space.s24)
                    .padding(.bottom, Theme.Space.s16)
                }
            }

            if showEditor {
                ProviderEditorView(providerStore: providerStore)
                    .background(Theme.base0.opacity(0.35))
            }
        }
        .background(Theme.base0.opacity(0.35))
    }
}
