import SwiftUI
import AppKit

/// THESIS: see and edit the actual request → tier → model relationship.
/// OWN-WORLD: the app's ice/graphite sheet, system type, recessed controls.
/// STORY: add a free endpoint, assign tasks, watch real attempts, inspect a model.
/// FIRST VIEWPORT: gateway controls above a bounded native route map; inspector
/// and a searchable lazy inventory follow. Discovery/settings stay secondary.
/// FORM: user-approved C topology overrides concept seed 3de6ff09; .impeccable/mocks/gateway/map.png.
/// FINISH: unreviewed and undocumented is unfinished; this build ends with
/// the finish review, the verdict, and DESIGN.md.
struct FreeModelGatewayView: View {
    @ObservedObject private var gateway = FreeModelGatewayStore.shared
    @ObservedObject private var prefs = AppPreferences.shared
    var onAddOpenRouter: () -> Void
    private enum Workspace: String, CaseIterable { case pool = "模型池", discovery = "发现模型", routes = "最近路由" }
    @State private var workspace = Workspace.pool
    @State private var query = ""
    @State private var selectedID: String?
    @State private var selectedTier: GatewayTaskDifficulty?
    @State private var mapPage = 0
    @State private var showSettings = false
    @State private var showConnection = false
    @State private var showAdd = false
    @State private var submitted = false
    @State private var focusRequest = 0
    @State private var providerID: UUID?
    @State private var modelID = ""
    @State private var context = "32768"
    @State private var tools = true
    @State private var images = false
    @State private var json = false
    @State private var difficulties = GatewayTaskDifficulty.allCases
    @State private var confirmedFree = false
    @State private var editingMember: String?
    @FocusState private var editorFocus: String?

    private var openRouter: [CodexProvider] { gateway.connections.filter { FreeModelPool.isOpenRouter($0.baseURL) } }
    private var selected: CodexProvider? { gateway.connections.first { $0.id == providerID } }
    private var editable: Bool { gateway.canEdit }
    private var results: [FreeModelPool.CatalogModel] {
        gateway.pool.catalog.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }
    private var presentation: [GatewayMapMember] {
        let providers = Dictionary(gateway.connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let catalog = Set(gateway.pool.catalog.map(\.id))
        let now = Date()
        return gateway.pool.members.map { member in
            let provider = providers[member.providerID]
            let health = gateway.snapshot.health[member.id]
            let state: GatewayMemberState
            if !member.enabled { state = .paused }
            else if member.difficulties.isEmpty { state = .unassigned }
            else if provider == nil || provider?.apiKey.isEmpty == true || !validEndpoint(provider?.baseURL ?? "") { state = .credentials }
            else if provider.map({ FreeModelPool.isOpenRouter($0.baseURL) }) == true,
                    now.timeIntervalSince(gateway.pool.discoveredAt ?? .distantPast) >= 48 * 3600 { state = .expired }
            else if provider.map({ FreeModelPool.isOpenRouter($0.baseURL) }) == true, !catalog.contains(member.model) { state = .unavailable }
            else if (health?.cooldownUntil ?? .distantPast) > now { state = .cooling }
            else { state = (health?.successes ?? 0) > 0 ? .ready : .untested }
            return .init(member: member, provider: provider?.name ?? "已删除供应商", state: state)
        }
    }
    private func validEndpoint(_ base: String) -> Bool {
        guard let url = URLComponents(string: base) else { return false }
        return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil && !LocalProxyAddress.isLoopback(base)
    }

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                if gateway.loading { ProgressView("读取模型池…").frame(maxWidth: .infinity).padding(20) }
                if let error = gateway.error { errorBanner(error) }
                gatewayBar
                if !gateway.pool.members.isEmpty { overview(presentation).id("gateway-map") }
                workspaceBar
                switch workspace {
                case .pool: inventory(presentation)
                case .discovery: discovery
                case .routes: activity
                }
            }
            .padding(.horizontal, Theme.Space.s24)
            .padding(.bottom, Theme.Space.s24)
        }
        .onChange(of: focusRequest) { _, _ in scroll.scrollTo("gateway-map", anchor: .top) }
        }
        .task { await gateway.observeStatus() }
        .task {
            // A slow clock only expires cooldown labels. The live map uses the
            // push channel, so short requests never wait for this tick.
            while !Task.isCancelled {
                await gateway.refreshStatus()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onChange(of: gateway.pool.members.map(\.id), initial: true) { _, ids in
            if selectedID == nil || !ids.contains(selectedID ?? "") { selectedID = ids.first }
            mapPage = min(mapPage, max(0, (ids.count - 1) / 5))
        }
        .onChange(of: providerID) { _, _ in
            if let editingMember, gateway.pool.members.first(where: { $0.id == editingMember })?.providerID == providerID { return }
            editingMember = nil
            modelID = selected?.activeModel?.name ?? selected?.models.first?.name ?? ""
            confirmedFree = false
        }
        .onChange(of: showAdd) { _, shown in if !shown { submitted = false } }
        .sheet(isPresented: $showAdd) { modelEditor }
    }

    private var gatewayBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { gatewayIdentity; Spacer(minLength: 12); gatewayActions }
            VStack(alignment: .leading, spacing: 14) { gatewayIdentity; gatewayActions }
        }
        .padding(18)
        .panelCard(tint: Theme.cursor)
    }
    private var gatewayIdentity: some View {
        HStack(spacing: 12) {
            GlyphWell(name: "point.3.connected.trianglepath.dotted", tint: gateway.pool.enabled ? Theme.Ink.cursor : Theme.Ink.idle, size: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text("Auto 模型池").font(Theme.Font.brand).foregroundStyle(Theme.textPrimary)
                Text(gateway.saving ? "正在保存…" : "\(gateway.pool.members.count) 个模型 · \(gateway.pool.strategy.title) · \(gateway.snapshot.active) 处理中 · \(gateway.snapshot.queued) 排队")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            Toggle("启用 Auto", isOn: binding(\.enabled))
                .labelsHidden().toggleStyle(InstrumentToggleStyle(showsLabel: false, width: 48))
                .disabled(!editable).accessibilityLabel("启用 Auto 模型网关")
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    private var gatewayActions: some View {
        HStack(spacing: 8) {
            ActionButton("设置", symbol: "gearshape") { showSettings.toggle() }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    ScrollView { VStack(spacing: 16) { controls; admissionControls; discoveryControls }.padding(16) }
                        .frame(width: 460, height: 610).background(Theme.bgPrimary)
                }
            ActionButton("接入", symbol: "link") { showConnection.toggle() }
                .popover(isPresented: $showConnection, arrowEdge: .bottom) {
                    ScrollView { connection.padding(16) }.frame(width: 480, height: 540).background(Theme.bgPrimary)
                }
        }
    }

    private func overview(_ items: [GatewayMapMember]) -> some View {
        let ids = GatewayTopologyLayout.visibleIDs(members: gateway.pool.members, flights: gateway.snapshot.flights,
                                                  selected: selectedID, page: mapPage)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mapMembers = ids.compactMap { byID[$0] }
        return VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack { mapHeading; Spacer(minLength: 8); mapPagination }
                VStack(alignment: .leading, spacing: 10) { mapHeading; mapPagination }
            }
            GatewayTopologyView(members: mapMembers, flights: gateway.snapshot.flights, selectedID: selectedID,
                selectedTier: selectedTier, enabled: gateway.pool.enabled,
                onSelect: { selectedID = $0 }, onTier: { selectedTier = selectedTier == $0 ? nil : $0; workspace = .pool })
            HStack(spacing: 14) {
                routeKey("真实请求", color: Theme.claude)
                routeKey("完成", color: Theme.statusSuccess)
                routeKey("失败", color: Theme.statusError)
                Spacer(minLength: 0)
                Text("点选模型查看详情").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }.help("蓝色流动来自真实请求；绿色／红色闪光表示完成／失败。")
            if let item = byID[selectedID ?? ""] {
                HairlineDivider()
                inspector(item)
            }
        }.padding(20).panelCard()
    }
    private func routeKey(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }.fixedSize()
    }
    private var mapHeading: some View {
        HStack(spacing: 8) {
            Text("实时路由").font(Theme.Font.chromeEmph).foregroundStyle(Theme.textPrimary)
            Text(gateway.snapshot.active > 0 ? "正在处理" : "等待请求")
                .font(Theme.Font.caption).foregroundStyle(gateway.snapshot.active > 0 ? Theme.Ink.claude : Theme.textSecondary)
        }
    }
    private var mapPagination: some View {
        HStack(spacing: 8) {
            Text("\(mapPage + 1) / \(max(1, (gateway.pool.members.count + 4) / 5)) 页")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            ActionIcon(symbol: "chevron.left", tint: Theme.textSecondary, size: 26) { mapPage -= 1 }
                .disabled(mapPage == 0).accessibilityLabel("上一页模型")
            ActionIcon(symbol: "chevron.right", tint: Theme.textSecondary, size: 26) { mapPage += 1 }
                .disabled((mapPage + 1) * 5 >= gateway.pool.members.count).accessibilityLabel("下一页模型")
        }.foregroundStyle(Theme.textSecondary)
    }
    private func inspector(_ item: GatewayMapMember) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.member.name).font(Theme.Font.chromeEmph).foregroundStyle(Theme.textPrimary)
                        .lineLimit(2).help(item.member.name)
                    Text(item.member.model).font(Theme.Font.captionMono).foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle).help(item.member.model)
                }
                Spacer(minLength: 8)
                memberMenu(item.member)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { inspectorFacts(item); Spacer(minLength: 8); tierAssignment(item.member) }
                VStack(alignment: .leading, spacing: 16) { inspectorFacts(item); tierAssignment(item.member) }
            }
        }
    }
    private func inspectorFacts(_ item: GatewayMapMember) -> some View {
        let health = gateway.snapshot.health[item.id]
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(item.provider) · \(item.member.contextLength.formatted()) 上下文")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            GatewayCapabilities(tools: item.member.supportsTools, images: item.member.supportsImages, json: item.member.supportsJSON, text: true)
            HStack(spacing: 7) {
                Circle().fill(item.state.tint).frame(width: 6, height: 6)
                Text("\(item.state.title) · 成功 \(health?.successes ?? 0) / 失败 \(health?.failures ?? 0)")
                    .font(Theme.Font.caption).foregroundStyle(item.state.ink)
            }
            if let until = health?.cooldownUntil, until > Date() {
                Text("冷却至 \(until.formatted(date: .omitted, time: .standard))").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
    private func tierAssignment(_ member: FreeModelPool.Member) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("承接任务难度 · 可多选").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                ForEach(GatewayTaskDifficulty.allCases, id: \.self) { tier in
                    tierChip(tier, selected: member.difficulties.contains(tier)) {
                        gateway.change { pool in
                            guard let i = pool.members.firstIndex(where: { $0.id == member.id }) else { return }
                            pool.members[i].difficulties = GatewayTaskDifficulty.allCases.filter {
                                $0 == tier ? !member.difficulties.contains(tier) : member.difficulties.contains($0)
                            }
                        }
                    }
                }
            }
        }.disabled(!editable)
    }
    private func tierChip(_ tier: GatewayTaskDifficulty, selected: Bool, action: @escaping () -> Void) -> some View {
        GatewayTierChip(tier: tier, selected: selected, action: action)
    }

    private var workspaceBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { workspaceTabs; Spacer(minLength: 8); addButton }
            VStack(alignment: .leading, spacing: 12) { workspaceTabs; addButton }
        }
    }
    private var workspaceTabs: some View {
        SegmentedCapsule(items: Workspace.allCases, selection: workspace,
            title: { $0.rawValue }, tint: Theme.Ink.cursor) { workspace = $0; query = "" }
    }
    private var addButton: some View {
        ActionButton(tone: .accent, tint: Theme.Ink.cursor, emphasis: .primary, perform: {
            editingMember = nil; submitted = false; confirmedFree = false; difficulties = GatewayTaskDifficulty.allCases
            if providerID == nil { providerID = gateway.connections.first?.id }
            showAdd = true
        }) {
            AppGlyph(name: "plus", size: 12).foregroundStyle(Theme.isDark ? Theme.fieldWell : .white)
            Text("添加模型").foregroundStyle(Theme.isDark ? Theme.fieldWell : .white)
        }.disabled(!editable)
    }
    private func inventory(_ items: [GatewayMapMember]) -> some View {
        let filtered = items.filter { item in
            (selectedTier == nil || item.member.difficulties.contains(selectedTier!))
                && (query.isEmpty || item.member.name.localizedCaseInsensitiveContains(query)
                    || item.member.model.localizedCaseInsensitiveContains(query) || item.provider.localizedCaseInsensitiveContains(query))
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                InstrumentSearchField(prompt: "搜索模型或供应商", text: $query)
                if let tier = selectedTier {
                    Button { selectedTier = nil } label: { Label(tier.displayName, systemImage: "xmark.circle.fill") }
                        .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.Ink.cursor).fixedSize()
                        .help("取消难度筛选")
                }
                Text("\(filtered.count) 个").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize()
            }
            if items.isEmpty {
                emptyPool
            } else if filtered.isEmpty {
                Text("没有匹配的模型，试试其他关键词或取消难度筛选。")
                    .font(Theme.Font.bodySmall).foregroundStyle(Theme.textSecondary).padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { item in
                        GatewayInventoryRow(item: item, selected: selectedID == item.id,
                            editable: editable, canMoveUp: gateway.pool.members.first?.id != item.id,
                            canMoveDown: gateway.pool.members.last?.id != item.id, onSelect: { selectedID = item.id; focusRequest += 1 },
                            onEnable: { enabled in setEnabled(item.member, enabled: enabled) },
                            onEdit: { edit(item.member) }, onMove: { move(item.member, by: $0) },
                            onRemove: { gateway.change { $0.members.removeAll { $0.id == item.id } } })
                            .equatable()
                    }
                }
            }
            Text("未测试表示尚无成功请求。只路由启用且能力匹配的免费模型；自动判断可升档，不会自动降档。")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).panelCard()
    }
    private var emptyPool: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("先给 Auto 一个可选的模型").font(Theme.Font.chromeEmph).foregroundStyle(Theme.textPrimary)
            Text("从已有供应商提交免费模型，或发现 OpenRouter 的免费目录。加入后，路由拓扑会显示真实的档位连接。")
                .font(Theme.Font.bodySmall).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            ActionButton("浏览免费目录", symbol: "sparkle.magnifyingglass") { workspace = .discovery; query = "" }
        }.padding(.vertical, 20)
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { discoveryHeading; Spacer(minLength: 8); discoverButton }
                VStack(alignment: .leading, spacing: 12) { discoveryHeading; discoverButton }
            }
            HStack(spacing: 8) {
                Picker("OpenRouter 凭据", selection: binding(\.openRouterProviderID)) {
                    Text("选择 OpenRouter 供应商").tag(UUID?.none)
                    ForEach(openRouter) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: 300).disabled(!editable)
                ActionButton("添加供应商", action: onAddOpenRouter)
            }
            if gateway.pool.openRouterProviderID == nil {
                Text("目录可匿名发现；加入模型前请选择已保存的 OpenRouter 凭据。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            InstrumentSearchField(prompt: "搜索免费模型", text: $query)
            if gateway.pool.catalog.isEmpty {
                Text(gateway.discovering ? "正在读取免费目录…" : "点击「立即发现」读取最新免费模型。")
                    .font(Theme.Font.bodySmall).foregroundStyle(Theme.textSecondary).padding(.vertical, 20)
            } else if results.isEmpty {
                Text("没有匹配的免费模型。").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).padding(.vertical, 20)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(results) { model in
                    GatewayCatalogCard(model: model,
                        joined: gateway.pool.members.contains { $0.model == model.id && $0.providerID == gateway.pool.openRouterProviderID },
                        canJoin: editable && gateway.pool.openRouterProviderID != nil) { gateway.add(model) }
                        .equatable()
                }
            }
            Text("只接纳公布价格全为零的文本模型。收费变化、下架或目录过期后停止路由。定期发现与自动加入在「设置」调整。")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).panelCard()
    }
    private var discoveryHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("OpenRouter 免费目录 · \(gateway.pool.catalog.count)").font(Theme.Font.chromeEmph).foregroundStyle(Theme.textPrimary)
            Text(gateway.pool.discoveredAt.map { "更新于 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未更新目录")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
    }
    private var discoverButton: some View {
        ActionButton(perform: { gateway.discover() }) {
            if gateway.discovering { ProgressView().controlSize(.mini) }
            else { AppGlyph(name: "arrow.clockwise", size: 12).foregroundStyle(Theme.textSecondary) }
            Text(gateway.discovering ? "发现中…" : "立即发现")
        }.disabled(gateway.discovering || !editable)
    }
    private var discoveryControls: some View {
        SettingsGroup(title: "免费模型发现") {
            SettingsToggleRow(title: "定期发现免费模型", isOn: binding(\.discoveryEnabled))
            SettingsDivider()
            SettingsRow(title: "发现间隔") {
                Picker("发现间隔", selection: binding(\.refreshHours)) {
                    ForEach([1, 6, 24], id: \.self) { Text("\($0) 小时").tag($0) }
                }.labelsHidden().frame(width: 130)
            }
            SettingsDivider()
            SettingsToggleRow(title: "自动加入新发现模型", caption: "默认关闭。开启后加入所选 OpenRouter 供应商，保留已有模型的档位设置。", isOn: binding(\.automaticallyJoin))
        }.disabled(!editable)
    }
    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack { activityHeading; Spacer(minLength: 8); resetButton }
                VStack(alignment: .leading, spacing: 12) { activityHeading; resetButton }
            }
            if gateway.snapshot.routes.isEmpty {
                Text("尚无路由记录。第三方客户端使用 model: auto 发起请求后，这里会显示实际尝试。")
                    .font(Theme.Font.bodySmall).foregroundStyle(Theme.textSecondary).padding(.vertical, 20)
            }
            LazyVStack(spacing: 0) {
                ForEach(gateway.snapshot.routes) { route in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(route.model).font(Theme.Font.captionMono).foregroundStyle(Theme.textPrimary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text("\(route.provider) · \(route.difficulty.displayName) \(route.difficulty.rawValue) · \(route.routing.kind.title)")
                                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(route.status == 0 ? "已中断" : "HTTP \(route.status)")
                                    .foregroundStyle((200..<300).contains(route.status) ? Theme.Ink.success : Theme.Ink.warning)
                                Text("\(route.latency, specifier: "%.2f") 秒")
                                Text(route.date.formatted(date: .omitted, time: .standard))
                            }.font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize()
                        }
                        Text("\(route.routing.source.title) · \(route.routing.reason) · \(route.selection)")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 14)
                    HairlineDivider()
                }
            }
            Text("保留本次运行最近 40 次尝试。此处不存请求正文；延迟为上游响应头耗时。")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }.padding(18).panelCard()
    }
    private var activityHeading: some View {
        Text("\(gateway.snapshot.requests) 个请求 · \(gateway.snapshot.active) 处理中 · \(gateway.snapshot.queued) 排队")
            .font(Theme.Font.chromeEmph).foregroundStyle(Theme.textPrimary)
    }
    private var resetButton: some View { ActionButton("重置冷却") { gateway.resetHealth() } }
    private var modelEditor: some View {
        VStack(spacing: 0) {
            HStack {
                GlyphWell(name: editingMember == nil ? "plus" : "slider.horizontal.3", tint: Theme.Ink.cursor, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(editingMember == nil ? "添加免费模型" : "编辑模型能力").font(Theme.Font.brand)
                    Text("复用已保存连接 · 不切换客户端配置").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("关闭") { showAdd = false }.buttonStyle(.plain).disabled(submitted)
                    .keyboardShortcut(.cancelAction).help("关闭编辑器；尚未提交的字段不会保存")
            }.foregroundStyle(Theme.textPrimary).padding(20)
            HairlineDivider()
            ScrollView {
                VStack(spacing: 12) {
                    if let error = gateway.error { errorBanner(error) }
                    addFromProvider
                }.padding(20)
            }
            HairlineDivider()
            VStack(alignment: .leading, spacing: 16) {
                Toggle("确认该模型可免费使用", isOn: $confirmedFree)
                    .toggleStyle(InstrumentToggleStyle()).disabled(!editable || submitted)
                HStack(spacing: 12) {
                    Text(submitted ? "正在保存…" : "保存后可在模型池调整档位")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    ActionButton(tone: .accent, tint: Theme.Ink.cursor, emphasis: .primary, perform: addManual) {
                        AppGlyph(name: "plus", size: 12).foregroundStyle(Theme.isDark ? Theme.fieldWell : .white)
                        Text(gateway.pool.members.contains { $0.providerID == providerID && $0.model == modelID } ? "更新池内模型" : "加入 Auto 池")
                            .foregroundStyle(Theme.isDark ? Theme.fieldWell : .white)
                    }.disabled(!editable || submitted || providerID == nil || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !confirmedFree || (Int(context) ?? 0) <= 0)
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(20).background(Theme.cardSurface)
        }.frame(width: 600, height: 680).background(Theme.bgPrimary)
            .interactiveDismissDisabled(submitted)
    }
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AppGlyph(name: "exclamationmark.circle", size: 16).foregroundStyle(Theme.Ink.error)
            Text(message).font(Theme.Font.bodySmall).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("关闭") { gateway.error = nil }.buttonStyle(.plain).font(Theme.Font.caption)
        }.padding(14).panelCard(tint: Theme.statusError)
    }
    private func memberMenu(_ member: FreeModelPool.Member) -> some View {
        Menu {
            Button("编辑模型能力") { edit(member) }.disabled(member.discovered)
            Button(member.enabled ? "停用模型" : "启用模型") { setEnabled(member, enabled: !member.enabled) }
            Button("复制模型 ID") { copy(member.model) }
            Button("上移优先级") { move(member, by: -1) }.disabled(gateway.pool.members.first?.id == member.id)
            Button("下移优先级") { move(member, by: 1) }.disabled(gateway.pool.members.last?.id == member.id)
            Button("移出模型池", role: .destructive) { gateway.change { $0.members.removeAll { $0.id == member.id } } }
        } label: { AppGlyph(name: "ellipsis", size: 16).frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(!editable)
        .accessibilityLabel("\(member.name) 模型操作")
    }
    private func setEnabled(_ member: FreeModelPool.Member, enabled: Bool) {
        gateway.change { pool in
            if let i = pool.members.firstIndex(where: { $0.id == member.id }) { pool.members[i].enabled = enabled }
        }
    }
    private func edit(_ member: FreeModelPool.Member) {
        submitted = false
        editingMember = member.id; providerID = member.providerID; modelID = member.model
        context = String(member.contextLength); tools = member.supportsTools; images = member.supportsImages
        json = member.supportsJSON; difficulties = member.difficulties; confirmedFree = false
        showAdd = true
    }
    private var controls: some View {
        SettingsGroup(title: "Auto 模型网关", symbol: "point.3.connected.trianglepath.dotted",
                      caption: "只使用池内模型。工具、图片和上下文不匹配的模型会跳过；限流与故障会自动冷却。免费额度仍由各平台的账户规则决定。") {
            SettingsToggleRow(title: "启用 Auto", caption: "第三方客户端将模型名设为 auto 或 claudebar/auto。",
                isOn: binding(\.enabled))
            SettingsDivider()
            SettingsToggleRow(title: "接管全部第三方请求", caption: "开启后，第三方客户端的显式模型名也会改由池内模型执行。",
                isOn: binding(\.interceptAll))
            SettingsDivider()
            SettingsRow(title: "路由策略") {
                Picker("路由策略", selection: binding(\.strategy)) {
                    ForEach(FreeModelPool.Strategy.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 160)
            }
            SettingsDivider()
            SettingsRow(title: "最多尝试", caption: "只在响应尚未开始时尝试备用模型。") {
                Stepper("\(gateway.pool.maxAttempts) 个模型", value: binding(\.maxAttempts), in: 1...5)
            }

            SettingsDivider()
            SettingsRow(title: "每分钟上限", caption: "计入备用尝试，避免失败时连续消耗免费额度。") {
                Stepper("\(gateway.pool.requestsPerMinute) 次", value: binding(\.requestsPerMinute), in: 1...60)
            }
        }.disabled(!editable)
    }

    private var admissionControls: some View {
        VStack(spacing: 16) {
            SettingsGroup(title: "并发与队列", symbol: "line.3.horizontal.decrease",
                          caption: "同一供应商配置下的模型共享并发额度。队列按到达顺序安排可运行请求；繁忙供应商不会阻塞其他供应商。") {
                SettingsRow(title: "全局并发", caption: "流式请求直到完成或断开才释放额度。") {
                    Stepper("\(gateway.pool.maxConcurrent) 个", value: binding(\.maxConcurrent), in: 1...8)
                }
                SettingsDivider()
                SettingsRow(title: "供应商默认并发", caption: "新加入的供应商沿用此值，可在下方单独覆盖。") {
                    Stepper("\(gateway.pool.defaultProviderConcurrent) 个", value: binding(\.defaultProviderConcurrent), in: 1...8)
                }
                SettingsDivider()
                SettingsRow(title: "等待队列容量", caption: "含备用等待；正文合计最多 64 MiB。0 表示不排队。") {
                    Stepper("\(gateway.pool.maxQueued) 个", value: binding(\.maxQueued), in: 0...128)
                }
                SettingsDivider()
                SettingsRow(title: "每供应商队列", caption: "防止单一供应商占满全局等待队列。") {
                    Stepper("\(gateway.pool.providerQueueCapacity) 个", value: binding(\.providerQueueCapacity), in: 1...128)
                }
                SettingsDivider()
                SettingsRow(title: "最长排队时间", caption: "队列满返回 429，等待超时返回 504；排队不消耗每分钟额度。") {
                    Stepper("\(gateway.pool.queueTimeoutSeconds) 秒", value: binding(\.queueTimeoutSeconds), in: 1...120)
                }
            }
            if !admissionProviders.isEmpty {
                SettingsGroup(title: "供应商并发", caption: "按已保存的连接配置隔离。等待队列可转到其他兼容供应商；保存设置会中止旧配置下的等待。") {
                    ForEach(Array(admissionProviders.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { SettingsDivider() }
                        let load = gateway.snapshot.providers[provider.id] ?? .init()
                        SettingsRow(title: provider.name,
                                    caption: "\(load.active) 处理中 · \(load.queued) 排队 · \(gateway.pool.providerConcurrent[provider.id.uuidString] == nil ? "默认" : "单独设置")") {
                            Stepper("\(gateway.pool.concurrentLimit(for: provider.id)) 个", value: Binding(
                                get: { gateway.pool.concurrentLimit(for: provider.id) },
                                set: { limit in gateway.change { $0.providerConcurrent[provider.id.uuidString] = limit } }), in: 1...8)
                            if gateway.pool.providerConcurrent[provider.id.uuidString] != nil {
                                ActionIcon(symbol: "arrow.counterclockwise", tint: Theme.textSecondary, size: 24) {
                                    gateway.change { $0.providerConcurrent[provider.id.uuidString] = nil }
                                }.help("恢复默认并发").accessibilityLabel("\(provider.name) 恢复默认并发")
                            } else {
                                Color.clear.frame(width: 24, height: 24).accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }.disabled(!editable)
    }
    private var admissionProviders: [CodexProvider] {
        let ids = Set(gateway.pool.members.map(\.providerID))
        return gateway.connections.filter { ids.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var connection: some View {
        SettingsGroup(title: "第三方客户端接入") {
            SettingsRow(title: "Base URL", caption: LocalProxyAddress.openaiRoot) {
                ActionButton("复制地址") { copy(LocalProxyAddress.openaiRoot) }
            }
            SettingsDivider()
            SettingsRow(title: "模型名", caption: "OpenAI Chat Completions、Responses 和 Anthropic Messages 均可接入。") {
                ActionButton("复制 auto") { copy("auto") }
            }
            SettingsDivider()
            SettingsRow(title: "自动判断任务", caption: "只填 model: auto 即可。本地规则结合用户目标与工具续轮判断难度；不确定时按 medium。可选 task_difficulty: low / medium / high 覆盖判断。") {
                ActionButton("复制请求示例") {
                    copy("{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"分析并排查偶发死锁\"}]}")
                }
            }
            SettingsDivider()
            ProxyAccessToken()
            SettingsDivider()
            ProxyCurlExample(model: "auto")
            SettingsDivider()
            SettingsToggleRow(title: "记录第三方流量", caption: "在「流量」页查看每次尝试的实际供应商和模型。", isOn: $prefs.proxyThirdPartyTrafficEnabled)
            if !prefs.codexRoutingEnabled {
                Text("本地代理未启用，请在「设置 → 本地代理」开启后接入。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Ink.warning)
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
    }

    private var addFromProvider: some View {
        SettingsGroup(title: "从已有供应商提交", caption: "使用现有 Claude Code / Codex 配置的 OpenAI 兼容接口，不激活供应商、不改客户端配置。其他平台的免费资格与能力由你确认，网关不会把付费模型当作免费额度。") {
            SettingsRow(title: "供应商") {
                Picker("供应商", selection: $providerID) {
                    Text("选择已配置供应商").tag(UUID?.none)
                    ForEach(gateway.connections) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 240)
            }
            SettingsDivider()
            SettingsRow(title: "模型 ID") {
                HStack {
                    TextField("完整模型 ID", text: $modelID).focused($editorFocus, equals: "model")
                        .textFieldStyle(InstrumentFieldStyle(focused: editorFocus == "model")).frame(width: 230)
                    Menu("已有模型") {
                        ForEach(selected?.models ?? []) { model in Button(model.name) { modelID = model.name } }
                    }.disabled(selected == nil)
                }
            }
            SettingsDivider()
            SettingsRow(title: "上下文长度") {
                TextField("32768", text: $context).font(Theme.Font.captionMono).multilineTextAlignment(.trailing)
                    .focused($editorFocus, equals: "context").textFieldStyle(InstrumentFieldStyle(focused: editorFocus == "context")).frame(width: 110)
            }
            SettingsDivider()
            SettingsRow(title: "任务难度", caption: "可多选，加入后也能在池内直接调整。") {
                HStack(spacing: Theme.Space.s12) {
                    ForEach(GatewayTaskDifficulty.allCases, id: \.self) { difficulty in
                        GatewayTierChip(tier: difficulty, selected: difficulties.contains(difficulty)) {
                            difficulties = GatewayTaskDifficulty.allCases.filter { $0 == difficulty ? !difficulties.contains(difficulty) : difficulties.contains($0) }
                        }
                    }
                }
            }
            SettingsDivider()
            SettingsToggleRow(title: "支持工具调用", isOn: $tools)
            SettingsDivider()
            SettingsToggleRow(title: "支持图片输入", isOn: $images)
            SettingsDivider()
            SettingsToggleRow(title: "支持结构化 JSON", isOn: $json)
        }.disabled(!editable)
    }

    private func binding<Value>(_ key: WritableKeyPath<FreeModelPool, Value>) -> Binding<Value> {
        Binding(get: { gateway.pool[keyPath: key] }, set: { newValue in gateway.change { $0[keyPath: key] = newValue } })
    }
    private func move(_ member: FreeModelPool.Member, by offset: Int) {
        gateway.change { value in
            guard let index = value.members.firstIndex(where: { $0.id == member.id }),
                  value.members.indices.contains(index + offset) else { return }
            value.members.swapAt(index, index + offset)
        }
    }
    private func addManual() {
        guard let provider = selected, let length = Int(context), length > 0 else { return }
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf8.count <= 200 else { gateway.error = "模型 ID 不能为空，且最多为 200 字节。"; return }
        if FreeModelPool.isOpenRouter(provider.baseURL) {
            guard let found = gateway.pool.catalog.first(where: { $0.id == model }) else {
                gateway.error = "该 OpenRouter 模型不在当前免费目录中，请先发现并核对完整 ID。"; return
            }
            submitted = true
            gateway.change(completion: completeManual) { value in
                var member = found.member(providerID: provider.id)
                member.difficulties = difficulties
                if let index = value.members.firstIndex(where: { $0.id == member.id }) {
                    member.enabled = value.members[index].enabled
                    value.members[index] = member
                } else { value.members.append(member) }
            }
        } else {
            submitted = true
            gateway.change(completion: completeManual) { value in
                let member = FreeModelPool.Member(providerID: provider.id, model: model, name: model,
                    contextLength: length, supportsTools: tools, supportsImages: images, supportsJSON: json,
                    difficulties: difficulties)
                if let index = value.members.firstIndex(where: { $0.id == member.id }) {
                    var updated = member; updated.enabled = value.members[index].enabled
                    value.members[index] = updated
                } else { value.members.append(member) }
            }
        }
    }
    private func completeManual(_ succeeded: Bool) {
        submitted = false
        guard succeeded else { return }
        selectedID = providerID.map { $0.uuidString + ":" + modelID.trimmingCharacters(in: .whitespacesAndNewlines) }
        confirmedFree = false; showAdd = false; workspace = .pool; focusRequest += 1
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
