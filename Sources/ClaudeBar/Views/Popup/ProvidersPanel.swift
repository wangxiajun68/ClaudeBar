import SwiftUI

/// Popup providers + current-config area: active config strip, provider rows,
/// and the feedback toast inline slot.
struct ProvidersPanel: View {
    @EnvironmentObject var providerStore: ProviderStore
    var panel: PanelState
    @Binding var configCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !configCollapsed, let env = providerStore.currentEnv {
                currentConfigView(env)
                HairlineDivider()
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("PROVIDERS")
                    .font(Theme.Font.microSemibold)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Theme.Space.s16 + Theme.Space.s6).padding(.bottom, Theme.Space.s4)

                VStack(spacing: 2) {
                    ForEach(providerStore.providers) { provider in
                        ProviderRow(
                            provider: provider,
                            isActive: provider.id == providerStore.activeProviderID,
                            isExpanded: !providerStore.collapsedProviderIDs.contains(provider.id),
                            currentModelName: providerStore.currentEnv?.ANTHROPIC_MODEL,
                            onToggleExpand: {
                                if providerStore.collapsedProviderIDs.contains(provider.id) {
                                    providerStore.collapsedProviderIDs.remove(provider.id)
                                } else {
                                    providerStore.collapsedProviderIDs.insert(provider.id)
                                }
                            },
                            onActivateModel: { modelID in
                                providerStore.activateModel(providerID: provider.id, modelID: modelID)
                                if let m = provider.models.first(where: { $0.id == modelID }) {
                                    panel.showFeedback("\(provider.name) / \(m.name)")
                                }
                            }
                        )
                    }
                }

                // Feedback toast (render-only; lifecycle lives in the shell).
                FeedbackToast(message: panel.feedbackMessage, tint: Theme.statusBusy)
                    .padding(.vertical, 2)

                HairlineDivider().padding(.top, Theme.Space.s6)
            }
            .padding(.horizontal, Theme.Space.s6).padding(.vertical, Theme.Space.s6)
        }
    }

    // MARK: Current config strip

    private func currentConfigView(_ env: EnvConfig) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack(spacing: Theme.Space.s6) {
                Circle()
                    .fill(providerStore.activeProviderID != nil ? Theme.statusBusy : Theme.statusWarning)
                    .frame(width: 6, height: 6)

                Text(providerStore.activeProvider?.name ?? "Unsaved Config")
                    .font(Theme.Font.rowTitle)
                    .foregroundColor(Theme.textPrimary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let model = providerStore.activeModel {
                    Text("/ \(model.name)")
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                        .truncationMode(.middle)
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
        .padding(.horizontal, Theme.Space.s16 - 2).padding(.vertical, Theme.Space.s8)
    }
}
