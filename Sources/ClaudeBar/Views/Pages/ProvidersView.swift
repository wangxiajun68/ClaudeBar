import SwiftUI

/// Unified provider grid. One list writes Claude Code (`settings.json`) and
/// Codex (`config.toml` + catalog) together. The editor is a detail layer
/// that replaces the grid so the page never stacks two competing layouts.
struct ProvidersView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HairlineDivider()
            if showEditor {
                ProviderEditorView(providerStore: providerStore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
        }
        .background(Theme.base0.opacity(0.35))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.s12) {
            Text("供应商")
                .font(Theme.Font.titleLarge)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            Text("Claude Code 与 Codex 同步")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
            Spacer(minLength: Theme.Space.s8)
            Button(action: { showEditor.toggle() }) {
                Label(showEditor ? "返回列表" : "编辑供应商",
                      systemImage: showEditor ? "square.grid.2x2" : "slider.horizontal.3")
                    .font(Theme.Font.bodySmall)
            }
            .buttonStyle(.glass)
            .tint(Theme.claude)
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.vertical, Theme.Space.s16)
    }

    @ViewBuilder private var grid: some View {
        if providerStore.providers.isEmpty {
            emptyState
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
                            },
                            onToggleCapture: {
                                providerStore.setCaptureEnabled(
                                    providerID: provider.id,
                                    enabled: !provider.captureEnabled)
                            },
                            testOutcome: tests.outcome(ConnectivityTestCenter.vendorKey(provider.id)),
                            onTest: {
                                tests.testVendor(
                                    id: provider.id,
                                    claude: provider,
                                    model: Self.modelToTest(provider, envModel: providerStore.currentEnv?.ANTHROPIC_MODEL),
                                    codex: providerStore.peer?.providers.first { ProviderBridge.matches(provider, $0) })
                            }
                        )
                    }
                }
                .padding(.horizontal, Theme.Space.s24)
                .padding(.bottom, Theme.Space.s16)
                .padding(.top, Theme.Space.s16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.s16) {
            Spacer()
            Text("暂无供应商")
                .font(Theme.Font.body)
                .foregroundColor(Theme.textTertiary())
            Text("选择预设后，将同时写入 Claude Code 与 Codex。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
            HStack(spacing: Theme.Space.s8) {
                ForEach(CodexPreset.all, id: \.label) { preset in
                    Button {
                        providerStore.addFromCodexPreset(preset.provider)
                    } label: {
                        VStack(spacing: 2) {
                            Text(preset.label)
                                .font(Theme.Font.bodySmall)
                                .foregroundColor(Theme.textPrimary)
                            Text(preset.provider.wireAPI == "chat" ? "Chat" : "Responses")
                                .font(Theme.Font.caption)
                                .foregroundColor(Theme.textTertiary())
                        }
                        .padding(.horizontal, Theme.Space.s12)
                        .padding(.vertical, Theme.Space.s8)
                    }
                    .buttonStyle(.glass)
                    .help(preset.provider.baseURL)
                }
            }
            Button {
                showEditor = true
            } label: {
                Label("自定义", systemImage: "plus")
                    .font(Theme.Font.bodySmall)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.claude)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Space.s24)
    }

    /// Prefer the env-selected model when this tile is the live vendor.
    static func modelToTest(_ provider: Provider, envModel: String?) -> ModelConfig? {
        provider.models.first {
            $0.name.caseInsensitiveCompare(envModel ?? "") == .orderedSame
        } ?? provider.activeModel ?? provider.models.first
    }
}
