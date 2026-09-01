import SwiftUI

/// Providers page: the 宫格 of provider tiles (activate a model with one tap,
/// expand models in-tile), plus a link into the full editor as the detail
/// layer. Activation flows through the shared `ProviderStore`, updating both
/// the popup and Dashboard.
struct ProvidersView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @State private var segment = 0 // 0 = Claude, 1 = Codex
    @State private var showEditor = false
    @State private var showCodexEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            HStack {
                Text("供应商")
                    .font(Theme.Font.titleLarge)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Picker("", selection: $segment) {
                    Text("Claude").tag(0)
                    Text("Codex").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: segment) { _, newValue in
                    // Switching target collapses the other editor so the
                    // page never shows two editors stacked.
                    if newValue == 0 { showCodexEditor = false } else { showEditor = false }
                }
                Button(action: {
                    if segment == 0 { showEditor.toggle() } else { showCodexEditor.toggle() }
                }) {
                    Label(
                        (segment == 0 ? showEditor : showCodexEditor) ? "收起编辑器" : "编辑供应商…",
                        systemImage: "slider.horizontal.3")
                        .font(Theme.Font.bodySmall)
                }
                .buttonStyle(.glass)
                .tint(segment == 0 ? Theme.claude : Theme.codex)
            }
            .padding(.horizontal, Theme.Space.s24)
            .padding(.top, Theme.Space.s24)

            if segment == 0 {
                claudeSection
            } else {
                codexSection
            }

            if showEditor && segment == 0 {
                ProviderEditorView(providerStore: providerStore)
                    .background(Theme.base0.opacity(0.35))
            }
            if showCodexEditor && segment == 1 {
                CodexProviderEditorView(codexStore: codexStore)
                    .background(Theme.base0.opacity(0.35))
            }
        }
        .background(Theme.base0.opacity(0.35))
    }

    // MARK: - Claude section (original grid)

    @ViewBuilder private var claudeSection: some View {
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
    }

    // MARK: - Codex section

    @ViewBuilder private var codexSection: some View {
        if codexStore.providers.isEmpty {
            // Empty state doubles as the preset entry point — no need to
            // open the editor first to discover presets.
            VStack(spacing: Theme.Space.s12) {
                Text("暂无 Codex 供应商配置 — 从预设一键添加：")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textTertiary())
                HStack(spacing: Theme.Space.s8) {
                    ForEach(CodexPreset.all, id: \.label) { preset in
                        Button {
                            var p = preset.provider
                            p.id = UUID()
                            p.activeModelID = p.models.first?.id
                            codexStore.addProvider(p)
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
                        .tint(Theme.codex)
                        .help(preset.provider.baseURL)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        } else {
            ScrollView {
                TileGrid(.pageProvider) {
                    ForEach(codexStore.providers) { provider in
                        CodexProviderTile(
                            provider: provider,
                            isActive: provider.id == codexStore.activeProviderID,
                            activeModelID: provider.activeModelID,
                            onActivateModel: { modelID in
                                codexStore.activate(providerID: provider.id, modelID: modelID)
                            }
                        )
                    }
                }
                .padding(.horizontal, Theme.Space.s24)
                .padding(.bottom, Theme.Space.s16)
            }
            .frame(maxHeight: .infinity)
        }
    }
}
