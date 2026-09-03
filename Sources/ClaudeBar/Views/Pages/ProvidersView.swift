import SwiftUI

/// Unified provider grid. One list writes Claude Code (`settings.json`) and
/// Codex (`config.toml` + catalog) together. Full editor replaces the grid
/// in-place — no separate floating editor window.
struct ProvidersView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    @State private var showEditor = false
    @State private var editorFocusProviderID: UUID?

    var body: some View {
        Group {
            if showEditor {
                ProviderEditorView(
                    providerStore: providerStore,
                    focusProviderID: $editorFocusProviderID,
                    embedded: true,
                    onBack: { showEditor = false }
                )
            } else {
                gridPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.base0.opacity(0.35))
        .onReceive(NotificationCenter.default.publisher(for: .openProvidersEditor)) { _ in
            showEditor = true
        }
    }

    private var gridPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            gridHeader
            HairlineDivider()
            grid
        }
    }

    private var gridHeader: some View {
        HStack(alignment: .center, spacing: Theme.Space.s12) {
            Text("模型")
                .font(Theme.Font.titleLarge)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            Text("Claude Code 与 Codex 同步")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
            Spacer(minLength: Theme.Space.s8)
            Button {
                showEditor = true
            } label: {
                Label("管理", systemImage: "slider.horizontal.3")
                    .font(Theme.Font.bodySmall)
            }
            .adaptiveGlassButton(prominent: true)
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
            Text("暂无模型")
                .font(Theme.Font.body)
                .foregroundColor(Theme.textTertiary())
            Text("选择预设快速开始，或进入管理自定义。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: Theme.Space.s8)], spacing: Theme.Space.s8) {
                    ForEach(CodexPreset.all.filter { !$0.provider.baseURL.isEmpty }, id: \.label) { preset in
                        Button {
                            providerStore.addFromCodexPreset(preset.provider)
                        } label: {
                            VStack(spacing: 2) {
                                Text(preset.label)
                                    .font(Theme.Font.bodySmall)
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(preset.provider.wireAPI == "chat" ? "Chat" : "Responses")
                                    .font(Theme.Font.caption)
                                    .foregroundColor(Theme.textTertiary())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, Theme.Space.s12)
                            .padding(.vertical, Theme.Space.s8)
                        }
                        .adaptiveGlassButton()
                        .help(preset.provider.baseURL)
                    }
                }
                .padding(.horizontal, Theme.Space.s24)
            }
            .frame(maxHeight: 220)
            Button {
                showEditor = true
            } label: {
                Label("进入管理", systemImage: "slider.horizontal.3")
                    .font(Theme.Font.bodySmall)
            }
            .adaptiveGlassButton()
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
