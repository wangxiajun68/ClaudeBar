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
        /// Catalog entry id → saved connection count, so the sort and the
        /// "configured only" filter do not walk the bucket array per entry.
        var counts: [String: Int] = [:]
        func saved(_ entry: ProviderCatalogEntry) -> [Provider] { buckets[entry.id] ?? [] }
        func hasSaved(_ entry: ProviderCatalogEntry) -> Bool { (counts[entry.id] ?? 0) > 0 }
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
        var counts: [String: Int] = [:]
        for (id, rows) in buckets { counts[id] = rows.count }
        return Partition(buckets: buckets, custom: custom, counts: counts)
    }

    /// The search term, lowercased once; the old version lowercased a joined
    /// haystack per entry per render.
    private var searchTerm: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private func matches(_ texts: [String]) -> Bool {
        guard !searchTerm.isEmpty else { return true }
        return texts.joined(separator: " ").lowercased().contains(searchTerm)
    }

    /// Catalog entries with their saved connections attached, computed in one
    /// pass per render instead of re-deriving `endpoint(for:)` and `saved(_:)`
    /// three times per entry inside the filter, the search haystack and the
    /// sort comparator.
    private struct EntryRow: Identifiable {
        let entry: ProviderCatalogEntry
        let connections: [Provider]
        /// Catalog position — hoisted out of the comparator, which used to
        /// rebuild the whole order dictionary on every render and look it up
        /// per comparison.
        let order: Int

        var id: String { entry.id }
        var category: ProviderCatalogEntry.Category { entry.category }
    }

    private func entries(in layout: Partition) -> [EntryRow] {
        let order = Dictionary(uniqueKeysWithValues: ProviderCatalogEntry.all.enumerated().map { ($1.id, $0) })
        return ProviderCatalogEntry.all
            .filter { $0.endpoint(for: client) != nil || layout.hasSaved($0) }
            .compactMap { entry -> EntryRow? in
                let connections = layout.saved(entry)
                let inCategory = category == nil || entry.category == category
                    || (category == .coding && entry.includesCodingPlan)
                guard inCategory, !configuredOnly || !connections.isEmpty else { return nil }
                if !searchTerm.isEmpty {
                    let haystack = [entry.name, entry.detail, entry.category.rawValue]
                        + (entry.endpoint(for: client)?.models ?? [])
                        + connections.flatMap { [$0.name, $0.baseURL] + $0.models.map(\.name) }
                    guard matches(haystack) else { return nil }
                }
                return EntryRow(entry: entry, connections: connections, order: order[entry.id] ?? 0)
            }
            .sorted { lhs, rhs in
                let left = !lhs.connections.isEmpty, right = !rhs.connections.isEmpty
                if left != right { return left }
                return lhs.order < rhs.order
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
                                    ForEach(items) { row in
                                        ProviderDirectoryCard(entry: row.entry, client: client, connections: row.connections,
                                            activeID: activeID, selectedID: selectedID, balances: balances,
                                            onAdd: { onSelect(row.entry) }, onOpen: onOpen, onActivate: onActivate)
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
///
/// The wide form is the app's `SegmentedCapsule`, not a bespoke
/// `matchedGeometryEffect` row: this page and the connectors toolbar sat side by
/// side in the same family of "filter what the grid shows" controls and were
/// built two different ways, so the same gesture read as two different
/// controls. The menu form stays a `Picker` — it only appears when the row has
/// no width to give.
struct ProviderCategoryFilter: View {
    @Binding var category: ProviderCatalogEntry.Category?
    var compact = false

    /// `nil` is the 全部 entry, kept in the same list so it slides under the
    /// same selection pill as the three real categories.
    private var items: [ProviderCatalogEntry.Category?] {
        [nil] + ProviderCatalogEntry.Category.allCases.map { Optional($0) }
    }

    var body: some View {
        Group {
            if compact {
                Picker("分类", selection: $category) {
                    Text("全部").tag(Optional<ProviderCatalogEntry.Category>.none)
                    ForEach(ProviderCatalogEntry.Category.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }.pickerStyle(.menu)
            } else {
                SegmentedCapsule(items: items,
                                 selection: category,
                                 title: { $0?.rawValue ?? "全部" },
                                 tint: Theme.claude,
                                 onSelect: { category = $0 })
            }
        }
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
            // The same inset ring the tile and the panel card wear, so a field
            // on a toolbar is recognisably the same family as the surfaces it
            // sits between rather than a bare rectangle.
            .innerFrame(inset: 2.5, radius: 10)
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
            // The directory's state hue (grey / amber / blue / green) is the
            // card's accent, so the wash, the corner rings and the hover edge
            // all move through the same four states as the status badge — the
            // page used to say "state" in three unrelated places (a wash, an
            // outline, a badge) and only the badge carried the colour.
            //
            // The rings carry no glyph: this card's subject is its brand mark,
            // which lives at the *leading* edge, so a symbol in the corner would
            // be a second, competing identity.
            .tile(tint: state.faceColor, hovered: hovered,
                  lens: DepthLensSpec(tint: state.faceColor, size: 150, rings: 3))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(Theme.chartBlue.opacity(0.6), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .hoverState($hovered)
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
                    RollingNumberText(balance)
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
                    RollingNumberText(balance)
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
                RollingNumberText("\(provider.models.count) 个模型").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
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
