import SwiftUI

/// Popup model picker — Claude Code and Codex in two fixed-height scroll columns.
struct ProvidersPanel: View {
    @EnvironmentObject var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    var panel: PanelState

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s8) {
            stackColumn(title: "Claude Code", icon: "cpu", tint: Theme.claude) {
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

            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
                .padding(.vertical, Theme.Space.s4)

            stackColumn(title: "Codex", icon: "chevron.left.forwardslash.chevron.right", tint: Theme.codex) {
                if codexStore.providers.isEmpty {
                    Text("未配置")
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Space.s8)
                        .padding(.vertical, Theme.Space.s4)
                } else {
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
            }
        }
        .padding(.horizontal, Theme.Space.s8)
        .padding(.vertical, Theme.Space.s6)
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                FeedbackToast(message: panel.feedbackMessage, tint: Theme.statusBusy)
                    .padding(.bottom, 2)
                HairlineDivider()
            }
        }
    }

    private func stackColumn<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            SectionHeader(icon: icon, title: title, tint: tint)
                .padding(.horizontal, Theme.Space.s8)

            ScrollView {
                VStack(spacing: Theme.Space.s4) {
                    content()
                }
                .padding(.horizontal, Theme.Space.s4)
                .padding(.bottom, Theme.Space.s4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func isActiveModel(provider: Provider, model: ModelConfig) -> Bool {
        guard provider.id == providerStore.activeProviderID else { return false }
        return model.name.caseInsensitiveCompare(providerStore.currentEnv?.ANTHROPIC_MODEL ?? "") == .orderedSame
    }
}
