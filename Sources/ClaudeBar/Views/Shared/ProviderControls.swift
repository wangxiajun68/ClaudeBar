import SwiftUI

/// Configuration and activation are separate facts; incomplete records are never ready.
enum ProviderCardState: Equatable {
    case unconfigured, incomplete, ready, active

    static func isReady(_ provider: Provider) -> Bool {
        !provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !provider.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        provider.models.contains { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static func model(_ provider: Provider) -> ModelConfig? {
        if let model = provider.activeModel, !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return model }
        return provider.models.first { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var title: String {
        switch self {
        case .unconfigured: return "未配置"
        case .incomplete: return "待完善"
        case .ready: return "已配置 · 未激活"
        case .active: return "已激活"
        }
    }
    var color: Color {
        switch self {
        case .unconfigured: return Theme.textSecondary
        case .incomplete: return Theme.isDark ? Color(hex: 0xFFC76A) : Color(hex: 0x936000)
        case .ready: return Theme.isDark ? Color(hex: 0x8FAFFF) : Color(hex: 0x3657C8)
        case .active: return Theme.Ink.success
        }
    }

    /// `color` as a **surface** hue, for a card's accent wash and its corner
    /// rings. `color` is mixed for glyphs and pills (it clears 4.5:1 on the ice
    /// canvas); a wash needs the raw signal instead, or the state reads as a
    /// grey card with a coloured badge — which is what the directory looked
    /// like before: state was said in three places and only the badge carried
    /// it. The two are deliberately separate values, not one colour used twice.
    var faceColor: Color {
        switch self {
        case .unconfigured: return Theme.statusIdle
        case .incomplete: return Theme.chartAmber
        case .ready: return Theme.chartBlue
        case .active: return Theme.chartGreen
        }
    }
    var icon: String {
        switch self {
        case .unconfigured: return "circle.dashed"
        case .incomplete: return "exclamationmark.circle"
        case .ready: return "pause.circle"
        case .active: return "checkmark.circle.fill"
        }
    }
}

struct ProviderStatusBadge: View {
    let state: ProviderCardState
    var body: some View {
        Label(state.title, systemImage: state.icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(state.color).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(state.color.opacity(Theme.isDark ? 0.15 : 0.09), in: Capsule())
    }
}

/// Native keyboard behavior with authored hover, press, focus, and disabled states.
struct ProviderActionStyle: ButtonStyle {
    var prominent = false
    var tint: Color = Theme.isDark ? Color(hex: 0xA9BFFF) : Color(hex: 0x3657C8)

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, prominent: prominent, tint: tint)
    }
    private struct ActionBody: View {
        let configuration: Configuration
        let prominent: Bool
        let tint: Color
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).frame(minHeight: 32)
                .foregroundStyle(prominent ? (Theme.isDark ? Color(hex: 0x17223B) : Color.white) : tint)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(prominent ? tint : tint.opacity(hovered ? 0.14 : 0.07))
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(hovered ? 0.55 : 0.2)))
                .shadow(color: tint.opacity(prominent && hovered ? 0.16 : 0), radius: 7, y: 3)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .onHover { if hovered != $0 { hovered = $0 } }
                .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.75), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
        }
    }
}

struct ProviderInputStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.bgPrimary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.textSecondary.opacity(0.18)))
    }
}

/// Ephemeral intent, separate from the provider/model that is actually active.
struct ProviderModelChoice: Hashable {
    let providerID: UUID
    let modelID: UUID

    static func resolve(_ choice: Self?, providers: [Provider], activeID: UUID?) -> (Provider, ModelConfig)? {
        if let choice, let provider = providers.first(where: { $0.id == choice.providerID }),
           let model = provider.models.first(where: { $0.id == choice.modelID }),
           !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (provider, model)
        }
        let provider = providers.first { $0.id == activeID && ProviderCardState.isReady($0) }
            ?? providers.first { ProviderCardState.isReady($0) }
        guard let provider, let model = ProviderCardState.model(provider) else { return nil }
        return (provider, model)
    }
}

struct ProviderModelSelector: View {
    let providers: [Provider]
    let activeID: UUID?
    @Binding var choice: ProviderModelChoice?
    @State private var presented = false
    private var target: (Provider, ModelConfig)? { ProviderModelChoice.resolve(choice, providers: providers, activeID: activeID) }
    private var isCurrent: Bool {
        guard let (provider, model) = target else { return false }
        return provider.id == activeID && provider.activeModel?.id == model.id
    }

    var body: some View {
        Button { presented = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "cube").foregroundStyle(ProviderCardState.ready.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(target?.1.name ?? "先配置 Key 和模型")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(target.map { (isCurrent ? "当前使用" : "待激活") + " · " + $0.0.name } ?? "未选择模型")
                        .font(.system(size: 10)).foregroundStyle(isCurrent ? Theme.Ink.success : Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }.padding(.horizontal, 10).frame(height: 44)
                .background(Theme.bgPrimary.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.textSecondary.opacity(0.14)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .disabled(!providers.contains { !$0.models.isEmpty })
            .help(target.map { "选择待激活模型：" + $0.1.name } ?? "请先配置模型")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ProviderModelPicker(providers: providers, activeID: activeID, choice: choice) { value in
                    choice = value
                    presented = false
                }
            }
    }
}

private struct ProviderModelPicker: View {
    let providers: [Provider]
    let activeID: UUID?
    let choice: ProviderModelChoice?
    let onSelect: (ProviderModelChoice) -> Void
    @State private var query = ""
    @State private var highlighted: ProviderModelChoice?
    @FocusState private var searching: Bool
    private var selected: ProviderModelChoice? {
        ProviderModelChoice.resolve(choice, providers: providers, activeID: activeID).map {
            ProviderModelChoice(providerID: $0.0.id, modelID: $0.1.id)
        }
    }
    private func matches(_ model: ModelConfig, provider: Provider) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (text.isEmpty || (model.name + " " + provider.name).localizedCaseInsensitiveContains(text))
    }
    private var available: [ProviderModelChoice] {
        providers.filter { ProviderCardState.isReady($0) }.flatMap { provider in
            provider.models.filter { matches($0, provider: provider) }.map { ProviderModelChoice(providerID: provider.id, modelID: $0.id) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择待激活模型").font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                RollingNumberText("\(available.count) 个可用").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            TextField("搜索模型或配置名称", text: $query)
                .textFieldStyle(ProviderInputStyle()).focused($searching)
                .onSubmit { if let item = highlighted ?? available.first, available.contains(item) { onSelect(item) } }
                .onMoveCommand { direction in
                    guard !available.isEmpty else { return }
                    let index = highlighted.flatMap { available.firstIndex(of: $0) } ?? 0
                    if direction == .down { highlighted = available[min(index + 1, available.count - 1)] }
                    if direction == .up { highlighted = available[max(index - 1, 0)] }
                }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(providers) { provider in
                            let models = provider.models.filter { matches($0, provider: provider) }
                            if !models.isEmpty {
                                Text(provider.name).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).padding(.top, 4)
                                ForEach(models) { model in
                                    let item = ProviderModelChoice(providerID: provider.id, modelID: model.id)
                                    let current = provider.id == activeID && provider.activeModel?.id == model.id
                                    Button { onSelect(item) } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: item == selected ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(ProviderCardState.ready.color)
                                            Text(model.name).font(.system(size: 12, weight: .medium))
                                                .lineLimit(2).multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                            if current { Text("使用中").font(Theme.Font.caption).foregroundStyle(Theme.Ink.success) }
                                            else if !ProviderCardState.isReady(provider) { Text("待完善").font(Theme.Font.caption).foregroundStyle(ProviderCardState.incomplete.color) }
                                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(ProviderCardState.ready.color.opacity(item == highlighted || item == selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 9))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain).disabled(!ProviderCardState.isReady(provider)).id(item)
                                }
                            }
                        }
                        if providers.allSatisfy({ provider in !provider.models.contains { matches($0, provider: provider) } }) {
                            Text("没有匹配模型，可在配置中拉取或添加。")
                                .font(Theme.Font.bodySmall).foregroundStyle(Theme.textSecondary).padding(.vertical, 20)
                        }
                    }
                }.frame(height: 260)
                    .onChange(of: highlighted) { _, item in if let item { reader.scrollTo(item) } }
            }
            Divider()
            Label("选择不会切换连接；回到卡片点击激活。", systemImage: "info.circle")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }.padding(18).frame(width: 400).foregroundStyle(Theme.textPrimary).background(Theme.cardSurface)
            .onAppear { searching = true; highlighted = selected ?? available.first }
            .onChange(of: query) { _, _ in highlighted = available.first }
    }
}

struct ProviderActivationControl: View {
    let providers: [Provider]
    let activeID: UUID?
    let choice: ProviderModelChoice?
    let onActivate: (Provider, UUID) -> Void
    private var target: (Provider, ModelConfig)? { ProviderModelChoice.resolve(choice, providers: providers, activeID: activeID) }
    private var isActive: Bool {
        guard let (provider, model) = target else { return false }
        return provider.id == activeID && provider.activeModel?.id == model.id
    }
    var body: some View {
        Button {
            guard let (provider, model) = target, ProviderCardState.isReady(provider) else { return }
            onActivate(provider, model.id)
        } label: {
            Label(isActive ? "已激活" : "激活", systemImage: isActive ? "checkmark" : "bolt.fill")
        }
        .buttonStyle(ProviderActionStyle(prominent: true, tint: isActive ? Theme.Ink.success : ProviderCardState.ready.color))
        .disabled(isActive || (target.map { !ProviderCardState.isReady($0.0) } ?? true))
        .help(target.map { "激活 " + $0.0.name + " / " + $0.1.name } ?? "请先配置地址、Key 和模型")
    }
}
