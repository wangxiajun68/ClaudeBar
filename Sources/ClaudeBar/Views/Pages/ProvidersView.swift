import SwiftUI

/// Provider grid. Claude Code and Codex lists are independent — activate
/// one without rewriting the other. The editor still offers an explicit import.
struct ProvidersView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject private var tests = ConnectivityTestCenter.shared
    @State private var showEditor = false
    @State private var editorFocusProviderID: UUID?
    @State private var confirmRestore = false
    @Namespace private var stackNS
    @AppStorage("providersStack") private var stackRaw = "claude"

    private var stack: Stack {
        get { Stack(rawValue: stackRaw) ?? .claude }
        nonmutating set { stackRaw = newValue.rawValue }
    }

    private enum Stack: String, CaseIterable, Identifiable {
        case claude, codex
        var id: String { rawValue }
        var label: String { self == .claude ? "Claude Code" : "Codex" }
        /// Short chip copy — same as cc-switch's header switcher.
        var chipLabel: String { self == .claude ? "Claude" : "Codex" }
        var tint: Color { self == .claude ? Theme.claude : Theme.codex }
        var ink: Color { self == .claude ? Theme.Ink.claude : Theme.Ink.codex }
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
        .background(Theme.bgPrimary)
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
            PageTitle(title: "模型")
            stackSwitch
            Spacer(minLength: Theme.Space.s8)
            Button {
                showEditor = true
            } label: {
                Label("管理", systemImage: "slider.horizontal.3")
                    .font(Theme.Font.bodySmall)
            }
            .adaptiveGlassButton(prominent: true)
            .tint(stack.tint)
            Button {
                confirmRestore = true
            } label: {
                Label("还原官方", systemImage: "arrow.uturn.backward")
                    .font(Theme.Font.bodySmall)
            }
            .adaptiveGlassButton()
            .help(restoreHelp)
            .confirmationDialog(restoreTitle, isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("还原", role: .destructive) { restoreOfficial() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(restoreMessage)
            }
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.vertical, Theme.Space.s16)
    }

    /// cc-switch AppSwitcher: muted well, raised white pill, brand mark + short name.
    private var stackSwitch: some View {
        HStack(spacing: 4) {
            ForEach(Stack.allCases) { s in
                StackChip(
                    stack: s,
                    selected: stack == s,
                    namespace: stackNS
                ) {
                    withAnimation(Theme.Animation.snappy) { stackRaw = s.rawValue }
                }
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.bgOverlay)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("供应商列表")
    }

    private struct StackChip: View {
        let stack: Stack
        let selected: Bool
        let namespace: Namespace.ID
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    StackProductMark(stack: stack)
                        .foregroundColor(selected ? stack.ink : Theme.textTertiary())
                    Text(stack.chipLabel)
                        .font(selected ? Theme.Font.chromeEmph : Theme.Font.chrome)
                        .foregroundColor(selected || hover ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background {
                    ZStack {
                        if hover && !selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.cardSurface.opacity(0.5))
                        }
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.cardSurface)
                                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "stack-pill", in: namespace)
                        }
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(stack.label)
            .help(stack == .claude
                  ? "Claude Code 供应商，写入 ~/.claude/settings.json"
                  : "Codex 供应商，写入 ~/.codex/config.toml")
        }
    }

    /// Distinctive product marks — asterisk vs blossom — so the two chips
    /// don't rely on Theme.codex grey to tell them apart.
    private struct StackProductMark: View {
        let stack: Stack

        var body: some View {
            Group {
                if stack == .claude {
                    ClaudeAsterisk()
                } else {
                    CodexBlossom()
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
        }
    }

    private struct ClaudeAsterisk: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let outer = min(rect.width, rect.height) / 2
            let inner = outer * 0.16
            let halfW = outer * 0.17
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                let dx = cos(a), dy = sin(a)
                let px = -dy, py = dx
                path.move(to: CGPoint(x: c.x + dx * outer, y: c.y + dy * outer))
                path.addLine(to: CGPoint(x: c.x + dx * outer * 0.42 + px * halfW, y: c.y + dy * outer * 0.42 + py * halfW))
                path.addLine(to: CGPoint(x: c.x + dx * inner + px * halfW * 0.25, y: c.y + dy * inner + py * halfW * 0.25))
                path.addLine(to: CGPoint(x: c.x + dx * inner - px * halfW * 0.25, y: c.y + dy * inner - py * halfW * 0.25))
                path.addLine(to: CGPoint(x: c.x + dx * outer * 0.42 - px * halfW, y: c.y + dy * outer * 0.42 - py * halfW))
                path.closeSubpath()
            }
            return path
        }
    }

    private struct CodexBlossom: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = min(rect.width, rect.height) / 2
            let orbit = r * 0.38
            let petal = r * 0.34
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3 - .pi / 2
                let p = CGPoint(x: c.x + cos(a) * orbit, y: c.y + sin(a) * orbit)
                path.addEllipse(in: CGRect(x: p.x - petal, y: p.y - petal, width: petal * 2, height: petal * 2))
            }
            return path
        }
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
                            accent: Theme.claude, accentInk: Theme.Ink.claude
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
                            accent: Theme.codex, accentInk: Theme.Ink.codex
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

    private var restoreTitle: String {
        stack == .claude ? "还原 Claude Code 为官方配置？" : "还原 Codex 为官方配置？"
    }

    private var restoreHelp: String {
        stack == .claude
            ? "从 settings.json 去掉第三方中转，Claude Code 走 Anthropic 官方登录"
            : "去掉第三方供应商，保留已有的 ChatGPT 登录，并用 HTTPS 官方通道避免新会话重连"
    }

    private var restoreMessage: String {
        if stack == .claude {
            return "会从 ~/.claude/settings.json 删除 ANTHROPIC_BASE_URL、令牌和模型覆盖。供应商列表不删，权限等其它字段保留。新开一个 Claude Code 会话后生效。"
        }
        return "会把 ~/.codex/config.toml 指到官方 HTTPS 通道（不再走 WebSocket，新会话不会重连 5 次）。已有的 ChatGPT 登录原样保留，只去掉旁边的第三方 API Key。供应商列表不删。新开一个 Codex 会话后生效。"
    }

    private func restoreOfficial() {
        if stack == .codex {
            codexStore.restoreOfficial()
        } else {
            providerStore.restoreOfficial()
        }
    }
}
