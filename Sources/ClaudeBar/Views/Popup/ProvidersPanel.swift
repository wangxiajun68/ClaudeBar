import SwiftUI

/// Popup model picker + optional current-config strip and feedback toast.
struct ProvidersPanel: View {
    @EnvironmentObject var providerStore: ProviderStore
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    var panel: PanelState
    @Binding var configCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !configCollapsed, let env = providerStore.currentEnv {
                currentConfigView(env)
                HairlineDivider()
            }

            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                SectionHeader(icon: "cpu", title: "模型")
                    .padding(.horizontal, Theme.Space.s16)

                TileGrid(.popupProvider) {
                    ForEach(providerStore.providers) { provider in
                        ForEach(provider.models) { model in
                            PopupModelTile(
                                provider: provider,
                                model: model,
                                isActive: isActiveModel(provider: provider, model: model),
                                onActivate: {
                                    providerStore.activateModel(providerID: provider.id, modelID: model.id)
                                    panel.showFeedback("\(provider.name) / \(model.name)")
                                },
                                onToggleCapture: {
                                    providerStore.setCaptureEnabled(
                                        providerID: provider.id,
                                        enabled: !provider.captureEnabled)
                                },
                                testOutcome: tests.outcome(
                                    ConnectivityTestCenter.vendorModelKey(provider.id, model.id)),
                                onTest: {
                                    tests.testVendor(
                                        id: provider.id,
                                        claude: provider,
                                        model: model,
                                        codex: providerStore.peer?.providers.first { ProviderBridge.matches(provider, $0) })
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.s8)

                FeedbackToast(message: panel.feedbackMessage, tint: Theme.statusBusy)
                    .padding(.vertical, 2)

                HairlineDivider().padding(.top, Theme.Space.s6)
            }
            .padding(.horizontal, Theme.Space.s16).padding(.vertical, Theme.Space.s6)
        }
    }

    private func isActiveModel(provider: Provider, model: ModelConfig) -> Bool {
        guard provider.id == providerStore.activeProviderID else { return false }
        return model.name.caseInsensitiveCompare(providerStore.currentEnv?.ANTHROPIC_MODEL ?? "") == .orderedSame
    }

    // MARK: Current config strip

    private func currentConfigView(_ env: EnvConfig) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack(spacing: Theme.Space.s6) {
                Circle()
                    .fill(providerStore.activeProviderID != nil ? Theme.statusBusy : Theme.statusWarning)
                    .frame(width: 6, height: 6)

                Text(providerStore.activeModel?.name ?? providerStore.activeProvider?.name ?? "未保存的配置")
                    .font(Theme.Font.rowTitle)
                    .foregroundColor(Theme.textPrimary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let provider = providerStore.activeProvider, providerStore.activeModel != nil {
                    Text("/ \(provider.name)")
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            HStack(spacing: Theme.Space.s6) {
                if let host = URL(string: env.ANTHROPIC_BASE_URL)?.host {
                    Text(host)
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
                Spacer()
                if providerStore.balanceLoading {
                    Text("⋯").font(Theme.Font.bodySmall).foregroundColor(Theme.textTertiary())
                } else if let balance = providerStore.balanceText {
                    Text("¥\(balance)")
                        .font(Theme.Font.rowTitle)
                        .foregroundColor(Theme.statusBusy.opacity(0.85))
                }
            }
        }
        .padding(.horizontal, Theme.Space.s16).padding(.vertical, Theme.Space.s8)
    }
}
