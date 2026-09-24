import SwiftUI

/// Inputs that actually change the directory. Session polls and quota refreshes
/// publish on the same stores, and comparing this snapshot lets the grid skip
/// those updates.
struct ProviderDirectoryModel: Equatable {
    var client: ProviderClient
    var providers: [Provider]
    var activeID: UUID?
    var selectedID: UUID?
    var query: String
    var category: ProviderCatalogEntry.Category?
    var configuredOnly: Bool
    var balances: [UUID: String]
}

struct ProviderDirectoryHost: View, Equatable {
    let model: ProviderDirectoryModel
    let onActivate: (Provider, UUID) -> Void
    let onUseOfficial: () -> Void
    let onClearFilters: () -> Void
    let onSelect: (ProviderCatalogEntry) -> Void
    let onOpen: (Provider) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model }

    var body: some View {
        ProviderCatalogBrowser(
            client: model.client, providers: model.providers, activeID: model.activeID,
            selectedID: model.selectedID, query: model.query, category: model.category,
            configuredOnly: model.configuredOnly, onActivate: onActivate, onUseOfficial: onUseOfficial,
            onClearFilters: onClearFilters, onSelect: onSelect, onOpen: onOpen, balances: model.balances)
    }
}

/// Preset cards own their saved connections; unknown origins stay custom.
struct ProviderCatalogBrowser: View {
    let client: ProviderClient
    let providers: [Provider]
    let activeID: UUID?
    let selectedID: UUID?
    let query: String
    let category: ProviderCatalogEntry.Category?
    let configuredOnly: Bool
    let onActivate: (Provider, UUID) -> Void
    let onUseOfficial: () -> Void
    let onClearFilters: () -> Void
    let onSelect: (ProviderCatalogEntry) -> Void
    let onOpen: (Provider) -> Void
    var balances: [UUID: String] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Partition {
        var buckets: [String: [Provider]]
        var custom: [Provider]
        func saved(_ entry: ProviderCatalogEntry) -> [Provider] { buckets[entry.id] ?? [] }
    }

    /// One URL match per saved row. The grid used to match every row against
    /// every catalog entry, several times, on each store publish.
    private var partition: Partition {
        var buckets: [String: [Provider]] = [:]
        var custom: [Provider] = []
        for provider in providers {
            if let id = provider.catalogID {
                buckets[id, default: []].append(provider)
            } else if let id = ProviderCatalogEntry.matching(baseURL: provider.baseURL)?.id {
                buckets[id, default: []].append(provider)
            } else {
                custom.append(provider)
            }
        }
        return Partition(buckets: buckets, custom: custom)
    }
    private func matches(_ texts: [String]) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || texts.joined(separator: " ").localizedCaseInsensitiveContains(term)
    }
    private func entries(in layout: Partition) -> [ProviderCatalogEntry] {
        let order = Dictionary(uniqueKeysWithValues: ProviderCatalogEntry.all.enumerated().map { ($1.id, $0) })
        return ProviderCatalogEntry.all.filter { $0.endpoint(for: client) != nil || !layout.saved($0).isEmpty }.filter { entry in
            let connections = layout.saved(entry)
            let inCategory = category == nil || entry.category == category || (category == .coding && entry.includesCodingPlan)
            return inCategory && (!configuredOnly || !connections.isEmpty) && matches(
                [entry.name, entry.detail, entry.category.rawValue] + (entry.endpoint(for: client)?.models ?? []) +
                connections.flatMap { [$0.name, $0.baseURL] + $0.models.map(\.name) })
        }.sorted { lhs, rhs in
            let left = !layout.saved(lhs).isEmpty, right = !layout.saved(rhs).isEmpty
            if left != right { return left }
            return (order[lhs.id] ?? 0) < (order[rhs.id] ?? 0)
        }
    }
    private func custom(in layout: Partition) -> [Provider] {
        layout.custom.filter { matches([$0.name, $0.baseURL] + $0.models.map(\.name)) }
    }
    private var showsOfficial: Bool {
        (category == nil || category == .platform) && (!configuredOnly || activeID == nil) &&
            matches(["官方", "默认", client.title, client == .codex ? "ChatGPT OpenAI" : "Claude Anthropic"])
    }

    var body: some View {
        let layout = partition
        let visible = entries(in: layout)
        let customs = custom(in: layout)
        let pinned = pinnedActive(layout: layout)
        let restingCustoms = customs.filter { $0.id != pinned.customID }
        let showCustomSection = (category == nil || category == .gateway) && !restingCustoms.isEmpty
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if pinned.shows {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("当前激活").font(.system(size: 16, weight: .semibold, design: .rounded))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 275), spacing: 12, alignment: .top)], spacing: 12) {
                                pinnedCard(pinned, layout: layout)
                            }
                        }
                    }
                    ForEach(ProviderCatalogEntry.Category.allCases) { group in
                        let items = visible.filter {
                            (category == .coding ? group == .coding : $0.category == group) && $0.id != pinned.entryID
                        }
                        if !items.isEmpty || (group == .platform && showsOfficial && !pinned.official) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(group.rawValue).font(.system(size: 16, weight: .semibold, design: .rounded))
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 275), spacing: 12, alignment: .top)], spacing: 12) {
                                    if group == .platform && showsOfficial && !pinned.official {
                                        OfficialProviderCard(client: client, isDefault: activeID == nil, onUse: onUseOfficial)
                                    }
                                    ForEach(items) { entry in
                                        ProviderDirectoryCard(entry: entry, client: client, connections: layout.saved(entry),
                                            activeID: activeID, selectedID: selectedID, balances: balances,
                                            onAdd: { onSelect(entry) }, onOpen: onOpen, onActivate: onActivate)
                                    }
                                }
                            }
                        }
                    }
                    if showCustomSection {
                        customSection(restingCustoms)
                    }
                    if visible.isEmpty && !showCustomSection && !showsOfficial && !pinned.shows {
                        ContentUnavailableView {
                            Label("没有匹配的供应商", systemImage: "magnifyingglass")
                        } description: { Text("试试厂商、已保存名称或模型 ID。") }
                        actions: { Button("清除筛选", action: onClearFilters) }
                    }
                }.padding(.bottom, 24)
            }
        }.padding(.horizontal, 24).foregroundStyle(Theme.textPrimary)
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: category)
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: configuredOnly)
            .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: activeID)
    }

    private struct PinnedActive {
        var official = false
        var entryID: String?
        var customID: UUID?
        var shows: Bool { official || entryID != nil || customID != nil }
    }

    /// Only the live card leaves its category. The rest of that category stays put.
    private func pinnedActive(layout: Partition) -> PinnedActive {
        if activeID == nil {
            return PinnedActive(official: showsOfficial)
        }
        if let entry = ProviderCatalogEntry.all.first(where: { layout.saved($0).contains { $0.id == activeID } }),
           matches(entrySearchText(entry, layout: layout)) {
            return PinnedActive(entryID: entry.id)
        }
        if let provider = layout.custom.first(where: { $0.id == activeID }),
           matches([provider.name, provider.baseURL] + provider.models.map(\.name)) {
            return PinnedActive(customID: provider.id)
        }
        return PinnedActive()
    }

    private func entrySearchText(_ entry: ProviderCatalogEntry, layout: Partition) -> [String] {
        let connections = layout.saved(entry)
        return [entry.name, entry.detail, entry.category.rawValue] + (entry.endpoint(for: client)?.models ?? []) +
            connections.flatMap { [$0.name, $0.baseURL] + $0.models.map(\.name) }
    }

    @ViewBuilder private func pinnedCard(_ pinned: PinnedActive, layout: Partition) -> some View {
        if pinned.official {
            OfficialProviderCard(client: client, isDefault: true, onUse: onUseOfficial)
        } else if let id = pinned.entryID, let entry = ProviderCatalogEntry.entry(id: id) {
            ProviderDirectoryCard(entry: entry, client: client, connections: layout.saved(entry),
                activeID: activeID, selectedID: selectedID, balances: balances,
                onAdd: { onSelect(entry) }, onOpen: onOpen, onActivate: onActivate)
        } else if let id = pinned.customID, let provider = layout.custom.first(where: { $0.id == id }) {
            CustomProviderDirectoryCard(provider: provider, active: true,
                selected: provider.id == selectedID, balance: balances[provider.id],
                onOpen: { onOpen(provider) },
                onActivate: { onActivate(provider, $0) })
        }
    }

    private func customSection(_ customs: [Provider]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义供应商").font(.system(size: 16, weight: .semibold, design: .rounded))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 275), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(customs) { provider in
                    CustomProviderDirectoryCard(provider: provider, active: provider.id == activeID,
                        selected: provider.id == selectedID, balance: balances[provider.id],
                        onOpen: { onOpen(provider) },
                        onActivate: { onActivate(provider, $0) })
                }
            }
        }
    }
}

/// Shares the client's toolbar row; only the category control collapses on narrow windows.
struct ProviderCategoryFilter: View {
    @Binding var category: ProviderCatalogEntry.Category?
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var filterAnimation

    var body: some View {
        Group {
            if compact {
                Picker("分类", selection: $category) {
                    Text("全部").tag(Optional<ProviderCatalogEntry.Category>.none)
                    ForEach(ProviderCatalogEntry.Category.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }.pickerStyle(.menu)
            } else {
                HStack(spacing: 4) {
                    filter("全部", value: nil)
                    ForEach(ProviderCatalogEntry.Category.allCases) { filter($0.rawValue, value: $0) }
                }
            }
        }.padding(4).background(Theme.bgOverlay, in: RoundedRectangle(cornerRadius: 12))
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: category)
    }
    private func filter(_ title: String, value: ProviderCatalogEntry.Category?) -> some View {
        Button { category = value } label: {
            Text(title).font(Theme.Font.caption).fontWeight(category == value ? .semibold : .regular)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .foregroundStyle(category == value ? Theme.textPrimary : Theme.textSecondary)
                .background {
                    if category == value {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.cardSurface)
                            .matchedGeometryEffect(id: "category", in: filterAnimation)
                    }
                }
        }.buttonStyle(.plain).accessibilityAddTraits(category == value ? .isSelected : [])
    }
}

struct ProviderDirectorySearch: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("搜索厂商、配置或模型", text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("清除搜索")
            }
        }.font(Theme.Font.bodySmall).padding(10)
            .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Every directory item uses the same height and slots. Extra configurations live
/// in a menu, never expand the grid row or disappear behind a clipped container.
private struct ProviderCardSurface<Content: View>: View {
    let state: ProviderCardState
    let selected: Bool
    let content: Content
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: ProviderCardState, selected: Bool = false, @ViewBuilder content: () -> Content) {
        self.state = state
        self.selected = selected
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18).frame(maxWidth: .infinity).frame(height: 216, alignment: .topLeading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Theme.cardSurface)
                    if state != .unconfigured {
                        RoundedRectangle(cornerRadius: 16).fill(state.color.opacity(Theme.isDark ? 0.14 : 0.08))
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
                selected || hovered ? Theme.chartBlue.opacity(0.6) :
                    state.color.opacity(state == .unconfigured ? 0.14 : 0.35)))
            .shadow(color: .black.opacity(hovered ? 0.06 : 0), radius: 10, y: 5)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: state)
    }
}

private struct ProviderDirectoryCard: View {
    @State private var modelChoice: ProviderModelChoice?
    let entry: ProviderCatalogEntry
    let client: ProviderClient
    let connections: [Provider]
    let activeID: UUID?
    let selectedID: UUID?
    var balances: [UUID: String] = [:]
    let onAdd: () -> Void
    let onOpen: (Provider) -> Void
    let onActivate: (Provider, UUID) -> Void

    private var primary: Provider? {
        connections.first { $0.id == activeID } ?? connections.first { ProviderCardState.isReady($0) } ?? connections.first
    }
    private var active: Bool { connections.contains { $0.id == activeID } }

    private var state: ProviderCardState {
        if active, connections.contains(where: { $0.id == activeID && ProviderCardState.isReady($0) }) { return .active }
        if connections.isEmpty { return .unconfigured }
        return connections.contains { ProviderCardState.isReady($0) } ? .ready : .incomplete
    }

    var body: some View {
        ProviderCardSurface(state: state, selected: connections.contains { $0.id == selectedID }) {
            HStack(alignment: .top, spacing: 12) {
                ProviderIdentityMark(entry: entry, name: entry.name, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1).help(entry.name)
                    Text(entry.detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if let balance = balanceLabel {
                    Text(balance)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .help("账户余额")
                }
            }.frame(height: 44, alignment: .top)

            ProviderModelSelector(providers: connections, activeID: activeID, choice: $modelChoice)

            HStack {
                ProviderStatusBadge(state: state)
                Spacer(minLength: 0)
                Text(protocolLabel).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }.frame(height: 22)
            HStack(spacing: 8) {
                if let provider = primary {
                    Button { onOpen(provider) } label: { Label("配置", systemImage: "slider.horizontal.3") }
                        .buttonStyle(ProviderActionStyle())
                    Menu {
                        Button("添加配置", action: onAdd).disabled(entry.endpoint(for: client) == nil)
                        ForEach(connections) { item in
                            Button("管理 " + item.name) { onOpen(item) }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 20, height: 32) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多配置")
                } else {
                    Button(action: onAdd) { Label("配置", systemImage: "plus") }
                        .buttonStyle(ProviderActionStyle()).disabled(entry.endpoint(for: client) == nil)
                }
                Spacer(minLength: 0)
                ProviderActivationControl(providers: connections, activeID: activeID, choice: modelChoice, onActivate: onActivate)
            }.frame(height: 32)
        }
    }

    private var balanceLabel: String? {
        if let active = connections.first(where: { $0.id == activeID }), let amount = balances[active.id] {
            return amount
        }
        return connections.compactMap { balances[$0.id] }.first
    }

    private var protocolLabel: String {
        guard entry.endpoint(for: client) != nil else { return "已有配置" }
        if client == .claude { return "Anthropic Messages" }
        return entry.codex?.wireAPI == "chat" ? "Chat · 本地转换" : "Responses"
    }
}

private struct CustomProviderDirectoryCard: View {
    @State private var modelChoice: ProviderModelChoice?
    let provider: Provider
    let active: Bool
    let selected: Bool
    var balance: String? = nil
    let onOpen: () -> Void
    let onActivate: (UUID) -> Void

    var body: some View {
        ProviderCardSurface(state: ProviderCardState.isReady(provider) ? (active ? .active : .ready) : .incomplete, selected: selected) {
            HStack(alignment: .top, spacing: 12) {
                ProviderIdentityMark(name: provider.name, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.name).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1).help(provider.name)
                    Text("自定义供应商").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                if let balance {
                    Text(balance)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .help("账户余额")
                }
            }.frame(height: 44, alignment: .top)
            ProviderModelSelector(providers: [provider], activeID: active ? provider.id : nil, choice: $modelChoice)
            HStack {
                ProviderStatusBadge(state: ProviderCardState.isReady(provider) ? (active ? .active : .ready) : .incomplete)
                Spacer()
                Text("\(provider.models.count) 个模型").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }.frame(height: 22)
            HStack {
                Button(action: onOpen) { Label("配置", systemImage: "slider.horizontal.3") }
                    .buttonStyle(ProviderActionStyle())
                Spacer(minLength: 0)
                ProviderActivationControl(providers: [provider], activeID: active ? provider.id : nil, choice: modelChoice,
                                          onActivate: { _, modelID in onActivate(modelID) })
            }.frame(height: 32)
        }
    }
}

/// A built-in action, not a fake saved API provider. Restores the client's own
/// configuration and login; it never requires or manufactures a provider Key.
private struct OfficialProviderCard: View {
    let client: ProviderClient
    let isDefault: Bool
    let onUse: () -> Void

    var body: some View {
        ProviderCardSurface(state: isDefault ? .active : .ready) {
            HStack(spacing: 12) {
                ProviderIdentityMark(entry: ProviderCatalogEntry.all.first { $0.id == (client == .codex ? "openai" : "anthropic") },
                                     name: "官方", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("官方").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(client == .codex ? "Codex · ChatGPT 登录" : "Claude Code · Claude 登录")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.frame(height: 44, alignment: .top)
            Text("使用客户端自己的登录和模型。切换后新建会话生效，已有配置保留。")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
            HStack {
                ProviderStatusBadge(state: isDefault ? .active : .ready)
                Spacer()
                Text("官方模型").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }.frame(height: 22)
            HStack {
                Text("登录状态由客户端管理").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                Button(action: onUse) { Label(isDefault ? "重新应用" : "激活", systemImage: "bolt.fill") }
                    .buttonStyle(ProviderActionStyle(prominent: true, tint: isDefault ? Theme.Ink.success : ProviderCardState.ready.color))
                    .help("切回官方连接，清除第三方覆盖，保留供应商配置")
            }.frame(height: 32)
        }
    }
}

struct ProviderConnectionDetail: View {
    let provider: Provider
    let client: ProviderClient
    let active: Bool
    let currentModel: String?
    let wireAPI: String
    let onAddModels: (Set<String>) -> Void
    let outcome: (ModelConfig) -> ConnectivityOutcome
    let onActivate: (UUID) -> Void
    let onTest: (ModelConfig) -> Void
    let onEdit: () -> Void
    let onCapture: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    ProviderIdentityMark(entry: ProviderCatalogEntry.matching(baseURL: provider.baseURL), name: provider.name, size: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(provider.name).font(.system(size: 21, weight: .semibold, design: .rounded))
                        Text(active ? "当前用于 \(client.title)" : "已保存 · 随时切换").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("编辑", action: onEdit).buttonStyle(ProviderActionStyle())
                }
                Text(provider.baseURL.isEmpty ? "尚未填写接口地址" : provider.baseURL)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled).lineLimit(2)
                HStack {
                    Label(provider.authToken.isEmpty ? "尚未填写 Key" : "已保存 API Key", systemImage: "key.horizontal")
                    Spacer()
                    Toggle("记录流量", isOn: Binding(get: { provider.captureEnabled }, set: { _ in onCapture() }))
                        .toggleStyle(.switch).controlSize(.small)
                }.font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Divider()
                HStack {
                    Text("模型").font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    ProviderModelFetchButton(baseURL: provider.baseURL, apiKey: provider.authToken, wireAPI: wireAPI,
                        existingNames: Set(provider.models.map { $0.name.lowercased() }), onImport: onAddModels)
                }
                if provider.models.isEmpty {
                    Button("添加模型", action: onEdit).buttonStyle(ProviderActionStyle())
                }
                ForEach(provider.models) { model in
                    modelRow(model)
                }
            }.padding(24)
        }
    }
    private func modelRow(_ model: ModelConfig) -> some View {
        let result = outcome(model)
        let current = active && currentModel == model.name
        return VStack(alignment: .leading, spacing: 8) {
            Text(model.name).font(.system(size: 13, weight: .medium, design: .monospaced)).textSelection(.enabled)
            HStack(spacing: 10) {
                if current { Label("使用中", systemImage: "checkmark.circle.fill").font(Theme.Font.caption).foregroundStyle(Theme.Ink.success) }
                Spacer()
                Button { onTest(model) } label: {
                    HStack(spacing: 5) {
                        if result.state == .running { ProgressView().controlSize(.mini) }
                        Text(result.state == .running ? "检测中" : "检测连接")
                    }
                }.disabled(result.state == .running).buttonStyle(ProviderActionStyle()).controlSize(.small)
                Button(current ? "已启用" : "切换使用") { onActivate(model.id) }
                    .buttonStyle(ProviderActionStyle(prominent: true))
                    .disabled(current || provider.authToken.isEmpty || provider.baseURL.isEmpty)
            }
            if !result.detail.isEmpty {
                Text(result.detail).font(Theme.Font.caption)
                    .foregroundStyle(result.state == .failed ? Theme.Ink.error : Theme.textSecondary)
                    .textSelection(.enabled)
            }
        }.padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider() }
    }
}
