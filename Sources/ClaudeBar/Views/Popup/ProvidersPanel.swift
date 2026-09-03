import SwiftUI

/// Popup model picker + optional current-config strip and feedback toast.
struct ProvidersPanel: View {
    @EnvironmentObject var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    var panel: PanelState
    @Binding var configCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !configCollapsed, providerStore.currentEnv != nil || codexStore.activeProvider != nil {
                currentConfigView
                HairlineDivider()
            }

            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                SectionHeader(icon: "cpu", title: "Claude Code")
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
                                    panel.showFeedback("CC · \(provider.name) / \(model.name)")
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
                                        codex: nil)
                                },
                                accent: Theme.claude
                            )
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.s8)

                if !codexStore.providers.isEmpty {
                    SectionHeader(icon: "chevron.left.forwardslash.chevron.right", title: "Codex")
                        .padding(.horizontal, Theme.Space.s16)
                        .padding(.top, Theme.Space.s8)

                    TileGrid(.popupProvider) {
                        ForEach(codexStore.providers) { provider in
                            ForEach(provider.models) { model in
                                PopupModelTile(
                                    provider: provider.asDisplayProvider,
                                    model: ModelConfig(id: model.id, name: model.name),
                                    isActive: provider.id == codexStore.activeProviderID
                                        && (provider.activeModelID == model.id
                                            || (provider.activeModelID == nil && model.id == provider.models.first?.id)),
                                    onActivate: {
                                        codexStore.activate(providerID: provider.id, modelID: model.id)
                                        panel.showFeedback("Codex · \(provider.name) / \(model.name)")
                                    },
                                    onToggleCapture: {
                                        codexStore.setCaptureEnabled(
                                            providerID: provider.id,
                                            enabled: !provider.captureEnabled)
                                    },
                                    testOutcome: tests.outcome(
                                        ConnectivityTestCenter.vendorModelKey(provider.id, model.id)),
                                    onTest: {
                                        tests.testVendor(
                                            id: provider.id,
                                            claude: provider.asDisplayProvider,
                                            model: ModelConfig(id: model.id, name: model.name),
                                            codex: provider)
                                    },
                                    accent: Theme.codex
                                )
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.s8)
                }

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

    private var currentConfigView: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            if let env = providerStore.currentEnv {
                configLine(
                    active: providerStore.activeProviderID != nil,
                    title: providerStore.activeModel?.name
                        ?? providerStore.activeProvider?.name
                        ?? "未保存的配置",
                    subtitle: providerStore.activeProvider.map { "/ \($0.name)" },
                    host: URL(string: env.ANTHROPIC_BASE_URL)?.host,
                    trailing: {
                        if providerStore.balanceLoading {
                            Text("⋯").font(Theme.Font.bodySmall).foregroundColor(Theme.textTertiary())
                        } else if let balance = providerStore.balanceText {
                            Text("¥\(balance)")
                                .font(Theme.Font.rowTitle)
                                .foregroundColor(Theme.statusBusy.opacity(0.85))
                        }
                    })
            }
            if let p = codexStore.activeProvider {
                configLine(
                    active: true,
                    title: p.activeModel?.name ?? p.name,
                    subtitle: "/ \(p.name)",
                    host: URL(string: p.baseURL)?.host,
                    trailing: { EmptyView() })
            }
        }
        .padding(.horizontal, Theme.Space.s16).padding(.vertical, Theme.Space.s8)
    }

    private func configLine<Trailing: View>(
        active: Bool,
        title: String,
        subtitle: String?,
        host: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack(spacing: Theme.Space.s6) {
                Circle()
                    .fill(active ? Theme.statusBusy : Theme.statusWarning)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(Theme.Font.rowTitle)
                    .foregroundColor(Theme.textPrimary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            HStack(spacing: Theme.Space.s6) {
                if let host {
                    Text(host)
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
                Spacer()
                trailing()
            }
        }
    }
}
