import SwiftUI

/// Provider grid. Claude Code and Codex lists are independent — activate
/// one without rewriting the other. The editor still offers an explicit import.
struct ProvidersView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    @State private var showEditor = false
    @State private var editorFocusProviderID: UUID?
    @AppStorage("providersStack") private var stackRaw = "claude"

    private var stack: Stack {
        get { Stack(rawValue: stackRaw) ?? .claude }
        nonmutating set { stackRaw = newValue.rawValue }
    }

    private enum Stack: String, CaseIterable, Identifiable {
        case claude, codex
        var id: String { rawValue }
        var label: String { self == .claude ? "Claude Code" : "Codex" }
        var tint: Color { self == .claude ? Theme.claude : Theme.codex }
    }

    var body: some View {
        Group {
            if showEditor {
                if stack == .codex {
                    CodexProviderEditorView(
                        codexStore: codexStore,
                        embedded: true,
                        onBack: { showEditor = false }
                    )
                } else {
                    ProviderEditorView(
                        providerStore: providerStore,
                        focusProviderID: $editorFocusProviderID,
                        embedded: true,
                        onBack: { showEditor = false }
                    )
                }
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
            HStack(spacing: Theme.Space.s4) {
                ForEach(Stack.allCases) { s in
                    let on = stack == s
                    Button(s.label) { stackRaw = s.rawValue }
                        .font(Theme.Font.caption)
                        .foregroundColor(on ? .white : Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(on ? s.tint.opacity(0.45) : Theme.cardFill(0.08)))
                        .buttonStyle(.plain)
                }
            }
            Text("各自独立选择，互不同步")
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
            .tint(stack.tint)
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.vertical, Theme.Space.s16)
    }

    @ViewBuilder private var grid: some View {
        if stack == .claude {
            claudeGrid
        } else {
            codexGrid
        }
    }

    @ViewBuilder private var claudeGrid: some View {
        if providerStore.providers.isEmpty {
            emptyState(stack: .claude)
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
                                    codex: nil)
                            },
                            accent: Theme.claude
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

    @ViewBuilder private var codexGrid: some View {
        if codexStore.providers.isEmpty {
            emptyState(stack: .codex)
        } else {
            ScrollView {
                TileGrid(.pageProvider) {
                    ForEach(codexStore.providers) { provider in
                        ProviderTile(
                            provider: provider.asDisplayProvider,
                            isActive: provider.id == codexStore.activeProviderID,
                            currentModelName: provider.activeModel?.name,
                            onActivateModel: { modelID in
                                codexStore.activate(providerID: provider.id, modelID: modelID)
                            },
                            onToggleCapture: {
                                codexStore.setCaptureEnabled(
                                    providerID: provider.id,
                                    enabled: !provider.captureEnabled)
                            },
                            testOutcome: tests.outcome(ConnectivityTestCenter.vendorKey(provider.id)),
                            onTest: {
                                tests.testVendor(
                                    id: provider.id,
                                    claude: provider.asDisplayProvider,
                                    model: provider.activeModel.map {
                                        ModelConfig(id: $0.id, name: $0.name)
                                    },
                                    codex: provider)
                            },
                            accent: Theme.codex
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

    private func emptyState(stack: Stack) -> some View {
        VStack(spacing: Theme.Space.s16) {
            Spacer()
            Text(stack == .claude ? "暂无 Claude Code 供应商" : "暂无 Codex 供应商")
                .font(Theme.Font.body)
                .foregroundColor(Theme.textTertiary())
            Text("选择预设快速开始，或进入管理自定义。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: Theme.Space.s8)], spacing: Theme.Space.s8) {
                    ForEach(CodexPreset.all.filter { !$0.provider.baseURL.isEmpty }, id: \.label) { preset in
                        Button {
                            if stack == .codex {
                                codexStore.addFromPreset(preset.provider)
                            } else {
                                providerStore.addFromCodexPreset(preset.provider)
                            }
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
            .tint(stack.tint)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Space.s24)
    }

    static func modelToTest(_ provider: Provider, envModel: String?) -> ModelConfig? {
        provider.models.first {
            $0.name.caseInsensitiveCompare(envModel ?? "") == .orderedSame
        } ?? provider.activeModel ?? provider.models.first
    }
}
