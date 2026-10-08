import SwiftUI
import AppKit

/// Configuration and activation are separate facts; incomplete records are never ready.
enum ProviderCardState: Equatable {
    case unconfigured, incomplete, ready, active

    /// A saved record is ready when the client could actually be pointed at it.
    ///
    /// The key requirement is the *editors'* rule, not a second, stricter one
    /// invented here: a loopback/private endpoint serves with no authentication
    /// at all, so `ProviderSetupDraft.validationError` and
    /// `ProviderConnectionDraft.validationError` both let an empty key through
    /// for it. Demanding a key anyway made exactly those records — Ollama,
    /// LM Studio, a local LiteLLM — permanently 待完善: their model picker and
    /// activation button stayed disabled even though activation itself never
    /// reads the key (`activateModel` / `activate` write the base URL and the
    /// model name, nothing else).
    static func isReady(_ provider: Provider) -> Bool {
        let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty,
              provider.models.contains(where: { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return false }
        return !provider.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ProviderCatalogEntry.isLocalEndpoint(base)
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

/// The provider card's state readout: the shared pill, plus the state's own
/// glyph.
///
/// It was a `Label` in a hand-rolled capsule with its own fill opacities
/// (0.15 / 0.09) and its own padding (8 / 5) — the same object as `StatusPill`
/// drawn with different numbers, which is how the app ended up with two
/// capsule readouts that never quite matched side by side. Same well now, and
/// the glyph rides in it.
struct ProviderStatusBadge: View {
    let state: ProviderCardState
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(state.title)
        }
        .font(Theme.Font.pill)
        .foregroundStyle(state.color)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(state.faceColor.opacity(0.12)))
    }
}

/// The keyboard behaviour the app's push button must have — focus ring, space /
/// Return, disabled — with **no** authored chrome.
///
/// Every state this used to draw (a faded fill, a rim, a press offset) now
/// belongs to `ActionPlateButtonStyle`, and this app has exactly one push-button
/// language. Two hand-rolled copies of it is how the same page ended up with a
/// rounded *rectangle* button beside a capsule one.
///
/// The style is kept as a name because the provider card passes it positionally
/// at the call site (`ProviderActionStyle(prominent:)`) and because these buttons
/// sit inside a dense card where the capsule's own proportions would fight the
/// row; it now renders that capsule regardless. Callers wanting the accent body
/// ask for it with `prominent:` exactly as before.
struct ProviderActionStyle: ButtonStyle {
    var prominent = false
    var tint: Color = Theme.claude

    func makeBody(configuration: Configuration) -> some View {
        ActionPlateButtonStyle(tone: prominent ? .accent : .neutral, tint: tint,
                               ink: nil, metrics: .regular,
                               emphasis: prominent ? .primary : .standard)
            .makeBody(configuration: configuration)
    }
}

/// The provider editors' input. It used to be its own recipe — `Theme.bgPrimary`
/// in a radius-10 box with a `textSecondary` 0.18 hairline — a fourth field
/// surface that disagreed with the other three on radius, fill and stroke. It
/// now wears `InstrumentField`, so an editor field and a search box are the
/// same object.
struct ProviderInputStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        InstrumentField(onCard: true) {
            configuration
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }
}

/// One labelled form row: the caption above the field the content draws.
///
/// It existed as a byte-identical private `field` helper in both provider
/// sheets — same 8pt stack, same 12pt medium caption, same `ProviderInputStyle`
/// on whatever went inside — so the two forms stayed in step only by hand. The
/// shared definition lives here, beside the input style both sheets take.
struct ProviderFormField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            content().textFieldStyle(ProviderInputStyle()).font(Theme.Font.bodySmall)
        }
    }
}

/// Bundled brand assets: offline, light/dark variants, no remote image requests.
///
/// It sits here with the other shared provider controls rather than in the
/// quick-setup sheet that first defined it: the directory and both editors
/// draw the mark, so the sheet was never its owner.
struct ProviderIdentityMark: View {
    var entry: ProviderCatalogEntry?
    let name: String
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let entry, let image = ProviderBrandImages.image(entry.iconName, dark: Theme.isDark) {
                Image(nsImage: image).resizable().scaledToFit().padding(size * 0.14)
            } else {
                // A custom or asset-less provider gets its own initial — the
                // one thing that can tell two tiles without a bundled mark
                // apart — instead of the single rack glyph they all used to
                // share. Same idiom as the CLI avatars on the connectors page.
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .accessibilityHidden(true)
    }
}

private enum ProviderBrandImages {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(_ name: String, dark: Bool) -> NSImage? {
        let key = "\(name)-\(dark ? "dark" : "light")"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: key, withExtension: "png", subdirectory: "ProviderIcons")
                ?? Bundle.main.url(forResource: name, withExtension: "ico", subdirectory: "ProviderIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

/// Ephemeral intent, separate from the provider/model that is actually active.
struct ProviderModelChoice: Hashable {
    let providerID: UUID
    let modelID: UUID

    static func isCurrent(_ provider: Provider, _ model: ModelConfig, activeID: UUID?) -> Bool {
        provider.id == activeID && provider.activeModel?.id == model.id
    }

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
        return ProviderModelChoice.isCurrent(provider, model, activeID: activeID)
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
                // The model selector is a field the user opens rather than
                // types into — same well, same rim, so it reads as one of the
                // inputs around it instead of as a fourth box design.
                .instrumentWell(radius: Theme.Radius.md, onCard: false)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
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
                                    let current = ProviderModelChoice.isCurrent(provider, model, activeID: activeID)
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
                                            .background(ProviderCardState.ready.color.opacity(item == highlighted || item == selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain).disabled(!ProviderCardState.isReady(provider)).id(item)
                                }
                            }
                        }
                        if providers.allSatisfy({ provider in !provider.models.contains { matches($0, provider: provider) } }) {
                            StandbyEmptyState(label: "没有匹配模型，可在配置中拉取或添加。",
                                              symbol: "magnifyingglass",
                                              tint: Theme.textSecondary)
                                .padding(.vertical, Theme.Space.s12)
                        }
                    }
                }.frame(height: 260)
                    .onChange(of: highlighted) { _, item in if let item { reader.scrollTo(item) } }
            }
            HairlineDivider()
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
        return ProviderModelChoice.isCurrent(provider, model, activeID: activeID)
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

/// The provider card's 抓包 switch: the same fact the editor's
/// 「记录请求报文」 toggle writes, lifted onto the card beside 配置 for a saved
/// connection.
///
/// The value is **not** held locally. `captureEnabled` lives on the saved
/// `Provider` / `CodexProvider` and reaches the card through the same published
/// providers the rest of the card reads, so there is one source of truth:
/// flipping it here, in the editor, or from the CLI (`providers capture`)
/// always redraws the same card. A `@State` copy would let the card and its
/// own editor disagree the moment either wrote.
///
/// The glyph carries both facts at a glance (colour = on/off, slashed mark =
/// off) and the wording mirrors the editor's toggle, because this is the same
/// setting said in two places rather than a second one.
struct ProviderCaptureControl: View {
    let enabled: Bool
    let providerName: String
    let onToggle: (Bool) -> Void

    private var tint: Color { enabled ? Theme.Ink.success : Theme.textSecondary }

    var body: some View {
        Button { onToggle(!enabled) } label: {
            Label(enabled ? "抓包" : "未抓包", systemImage: enabled ? "dot.radiowaves.left.and.right" : "dot.radiowaves.left.and.right.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(enabled ? 0.14 : 0.07)))
                .overlay(Capsule().strokeBorder(tint.opacity(enabled ? 0.30 : 0.14), lineWidth: 0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(enabled
              ? "正在记录 \(providerName) 的请求报文，写进「流量」页；点一下关闭"
              : "记录 \(providerName) 的请求报文：打开后这个供应商的请求会带着完整对话写进「流量」页，正文只留在本机")
        .accessibilityLabel("记录请求报文")
        .accessibilityValue(enabled ? "开启" : "关闭")
    }
}
