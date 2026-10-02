import AppKit
import SwiftUI

/// Plugin, skill and MCP installs as a fixed-height grid. Enable, disable and
/// remove sit on the card. Plugin contents are read once during the scan.
struct ConnectorsView: View {
    @ObservedObject private var manager = ConnectorManager.shared
    @AppStorage("connectorProjectPath") private var projectPath = ""
    @State private var showFeishu = false
    @State private var focus: ConnectorFocus = .plugin
    @State private var platform: ConnectorPlatform?
    @State private var search = ""
    @State private var busyIDs: Set<String> = []
    @State private var selectedRecord: ConnectorRecord?
    @State private var pendingRemoval: RemovalRequest?
    /// Bulk mode. Off on every mount — the browse state is the page's default,
    /// and a surface that reopened with checkboxes on the cards would make the
    /// ordinary path look like the special one.
    @State private var batchMode = false
    @State private var selection: Set<String> = []
    @State private var pendingBatch: BatchConfirm?
    @State private var isBatching = false

    private let columns = [GridItem(.adaptive(minimum: 268), spacing: Theme.Space.gridGapPage, alignment: .top)]
    private var selectedProject: String? { projectPath.isEmpty ? nil : projectPath }

    // Both toolbars reserve this same leading slot. The navigation control is
    // owned by the stable overlay, so neither page can recreate or reposition it.
    private let navigationWidth: CGFloat = 190

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showFeishu {
                FeishuDocumentsView(navigationWidth: navigationWidth)
            } else {
                VStack(spacing: 0) {
                    inventoryToolbar
                    inventory
                }
            }
            connectorTabs
                .frame(width: navigationWidth, height: 36, alignment: .leading)
                .padding(.horizontal, Theme.Space.s24)
                .padding(.top, Theme.Space.s12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgPrimary)
    }

    private var inventoryToolbar: some View {
        HStack(spacing: Theme.Space.s8) {
            Color.clear.frame(width: navigationWidth).accessibilityHidden(true)
            InstrumentSearchField(prompt: focus == .local ? "搜索本机命令" : "搜索名称、平台或 Skill", text: $search)
                .frame(height: 32)
            ActionIcon(symbol: "arrow.clockwise", tint: Theme.textSecondary) {
                Task { await manager.refresh(projectPath: selectedProject) }
            }
            .disabled(manager.isLoading)
            .help(manager.isLoading ? "正在扫描本机与项目配置" : "刷新连接器")
            projectControl
            if focus != .local {
                ActionButton(batchMode ? "完成管理" : "批量管理", symbol: "checklist") {
                    toggleBatchMode()
                }
                .disabled(manager.records.isEmpty)
                .help(batchMode ? "退出批量管理；已选内容会被清空" : "选中多张卡片，一次停用、启用或移除")
            }
        }
        .frame(height: 36)
        .padding(.horizontal, Theme.Space.s24)
        .padding(.top, Theme.Space.s12)
        .padding(.bottom, Theme.Space.s12)
        .disabled(isBatching || !busyIDs.isEmpty)
    }

    private var projectControl: some View {
        HStack(spacing: 4) {
            Button(action: chooseProject) {
                Label(projectPath.isEmpty ? "选择项目" : URL(fileURLWithPath: projectPath).lastPathComponent,
                      systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: projectPath.isEmpty ? nil : 160)
            }
            .buttonStyle(.plain).headerControl()
            .help(projectPath.isEmpty ? "扫描个人配置，并可添加项目配置" : projectPath)
            if !projectPath.isEmpty {
                ActionIcon(symbol: "xmark", tint: Theme.textSecondary) { projectPath = "" }
                    .help("移除项目范围，保留个人配置")
            }
        }
        .disabled(isBatching || !busyIDs.isEmpty)
    }

    private var connectorTabs: some View {
        SegmentedCapsule(items: [false, true], selection: showFeishu,
                         title: { $0 ? "飞书文档" : "连接器" },
                         symbol: { $0 ? "doc.text.image" : "puzzlepiece.extension" },
                         tint: Theme.Ink.claude, onSelect: { showFeishu = $0 })
    }

    private var inventory: some View {
        let shown = visibleRecords
        let clis = visibleCLIs
        let count = focus == .local ? clis.count : shown.count
        let loading = manager.isLoading && manager.records.isEmpty && manager.localCLIs.isEmpty
        return ScrollView {
            // The grid is the scroll view's own content, not a child of a
            // `VStack`. A grid asked for its ideal height lays out every card;
            // with a couple of hundred installs that is the whole inventory,
            // and the scroll then pays for cards that are off screen. An empty
            // or still-scanning page has nothing to virtualise, so it stays a
            // plain stack.
            if loading || count == 0 {
                VStack(alignment: .leading, spacing: 0) {
                    chrome(count: count)
                    if loading { loadingState } else { emptyState }
                }
                .padding(.horizontal, Theme.Space.s24)
                .padding(.bottom, Theme.Space.s24)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.gridGapPage) {
                    Section {
                        if focus == .local {
                            ForEach(clis) { cli in
                                // No checkbox here, and none on the bar either:
                                // see `batchTargets`.
                                LocalCLICard(cli: cli, relatedCount: relatedCount(cli.name))
                            }
                        } else {
                            ForEach(shown) { record in
                                ConnectorCard(
                                    record: record,
                                    contents: manager.pluginContents[record.id],
                                    isBusy: busyIDs.contains(record.id),
                                    selecting: batchMode,
                                    selected: selection.contains(record.id),
                                    onToggleSelection: { toggleSelection(record.id) },
                                    onDetails: { selectedRecord = record },
                                    onSetEnabled: { setEnabled($0, for: record) },
                                    onRemove: { askRemove(record) }
                                )
                            }
                        }
                    } header: {
                        chrome(count: count)
                    }
                }
                .padding(.horizontal, Theme.Space.s24)
                .padding(.bottom, Theme.Space.s24)
            }
        }
        .scrollHoverGate()
        .background(Theme.bgPrimary)
        .disabled(isBatching || !busyIDs.isEmpty)
        // The bar is an inset rather than another child of the scroll content:
        // the grid is a `LazyVGrid` directly under the `ScrollView` (that is what
        // lets it virtualise), so it cannot be wrapped in a stack to make room.
        // An inset takes the space out of the scroll view's own frame, so the
        // last row scrolls clear of the bar instead of hiding under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if batchMode && focus != .local && !manager.records.isEmpty { batchBar() }
        }
        .sheet(item: $selectedRecord) { record in
            ConnectorDetailSheet(record: record)
                .frame(width: 760, height: 620)
        }
        .confirmationDialog(pendingRemoval?.title ?? "移除", isPresented: removalPresented, titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                if let record = pendingRemoval?.record {
                    pendingRemoval = nil
                    remove(record)
                }
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(pendingRemoval?.message ?? "")
        }
        .confirmationDialog(pendingBatch?.title ?? "批量操作", isPresented: batchPresented, titleVisibility: .visible) {
            if let request = pendingBatch {
                Button(request.action == .remove ? "移除" : (request.action == .enable ? "启用" : "停用"),
                       role: request.action == .remove ? .destructive : nil) {
                    pendingBatch = nil
                    run(request)
                }
            }
            Button("取消", role: .cancel) { pendingBatch = nil }
        } message: {
            Text(pendingBatch?.message ?? "")
        }
        .task {
            // The manager outlives the page, so a banner from the last visit
            // would otherwise greet this one.
            manager.errorMessage = nil
            manager.noticeMessage = nil
            await manager.refresh(projectPath: selectedProject)
        }
        .onChange(of: projectPath) { _, _ in
            Task { await manager.refresh(projectPath: selectedProject, scanCLIs: false) }
        }
        // Bulk mode lives on the records, not on what the grid happens to be
        // showing. Switching the type filter therefore has to drop the ticks:
        // the bar would otherwise keep counting records of a kind it can no
        // longer act on, and switching back would silently re-arm them.
        // (A hidden tick can still be *deliberate* — see `batchBar`'s platform
        // pills, which say what the off-screen half of the selection is.)
        .onChange(of: focus) { _, item in
            let live = Set(item == .local
                           ? []
                           : manager.records.filter { $0.kind == kind(of: item) }.map(\.id))
            if !selection.isSubset(of: live) { selection.formIntersection(live) }
        }
        // `selectedRecord` is a *copy* captured at click time, and any refresh
        // replaces `manager.records` wholesale — so an open detail sheet could
        // keep describing an install that was just removed or disabled, and
        // read paths that no longer exist. Re-resolve it against the new list;
        // when the record is gone, close the sheet.
        .onChange(of: manager.records) { _, records in
            selection.formIntersection(Set(records.map(\.id)))
            guard let open = selectedRecord else { return }
            guard let fresh = manager.records.first(where: { $0.id == open.id }) else {
                selectedRecord = nil
                return
            }
            if fresh != open { selectedRecord = fresh }
        }
    }

    private var removalPresented: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var batchPresented: Binding<Bool> {
        Binding(get: { pendingBatch != nil }, set: { if !$0 { pendingBatch = nil } })
    }

    /// How many records belong to a focus category — a table lookup, not a walk.
    /// See `ConnectorManager.connectorCounts`.
    private func kindCount(_ item: ConnectorFocus) -> Int {
        guard item != .local else { return manager.localCLIs.count }
        return manager.count(kind: kind(of: item))
    }

    private func kind(of item: ConnectorFocus) -> ConnectorKind {
        switch item {
        case .plugin: return .plugin
        case .skill: return .skill
        case .mcp: return .mcp
        case .local: return .skill
        }
    }

    private var visibleRecords: [ConnectorRecord] {
        guard focus != .local else { return [] }
        let kind = kind(of: focus)
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = self.platform
        // Read once for the whole pass. The contents test has to be here rather
        // than in `matches`, and it deliberately consumes the same value the
        // cards do: a bundle's contents and the card that renders them are one
        // dependency, so a scan that rewrites a bundle has to invalidate both.
        let contents = manager.pluginContents
        return manager.records.filter { record in
            record.kind == kind &&
            (platform.map { record.platforms.contains($0) } ?? true) &&
            (matches(record, needle: needle)
                || (contents[record.id]?.items.contains {
                        $0.name.localizedStandardContains(needle)
                    } ?? false))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var visibleCLIs: [LocalCLIRecord] {
        manager.localCLIs.filter { cli in
            search.isEmpty || cli.name.localizedStandardContains(search) ||
            cli.summary.localizedStandardContains(search) ||
            cli.category.localizedStandardContains(search)
        }
    }

    private func relatedCount(_ name: String) -> Int {
        manager.records.reduce(0) { $0 + ($1.sharedOwner == name ? 1 : 0) }
    }

    /// Does `record` match the search box, ignoring its plugin contents?
    ///
    /// The needle is passed in rather than read from `search` so the filter has
    /// one string per pass. The contents test is applied by the caller, which
    /// reads `pluginContents` once for the whole list — reading it *per record*
    /// here made every card depend on the published dictionary, so a scan that
    /// changed any one bundle passed a new dictionary into all ~200 cards and
    /// re-rendered the grid.
    private func matches(_ record: ConnectorRecord, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        if record.name.localizedStandardContains(needle) { return true }
        if record.scope.localizedStandardContains(needle) { return true }
        if record.platforms.contains(where: { $0.title.localizedStandardContains(needle) }) { return true }
        if record.sharedOwner?.localizedStandardContains(needle) == true { return true }
        return false
    }

    /// One compact control band. Counts live on the category tabs; the
    /// trailing count is the filtered result, rather than another inventory total.
    private func chrome(count: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s10) {
            HStack(spacing: Theme.Space.s8) {
                ConnectorKindFilter(items: ConnectorFocus.allCases,
                                    selection: focus,
                                    count: kindCount,
                                    onSelect: { item in
                    // Only the pill animates, never the inventory's geometry.
                    focus = item
                    platform = nil
                })
                Spacer(minLength: Theme.Space.s8)
                if focus != .local { platformFilter }
                Text("\(count) 项")
                    .font(Theme.Font.microMono)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 48, alignment: .trailing)
            }
            if focus == .skill {
                Text(platform.map { "启停范围：\($0.title)。同名 Skill 的各个已扫描安装会一起移入或移出停用区。" }
                     ?? "启停范围：全部平台。同名独立 Skill 的所有已扫描安装会联动。")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.textSecondary)
            }
            notices
        }
        .padding(.bottom, Theme.Space.s8)
    }

    private var platformFilter: some View {
        SegmentedCapsule(items: [nil] + ConnectorPlatform.allCases.map { Optional($0) },
                         selection: platform,
                         title: { $0?.title ?? "全部" },
                         count: { item in
                             item.map { manager.count(kind: kind(of: focus), platform: $0) } ?? kindCount(focus)
                         },
                         tint: Theme.Ink.claude,
                         itemTint: { $0?.ink ?? Theme.Ink.claude },
                         onSelect: { platform = $0 })
    }

    @ViewBuilder private var notices: some View {
        if let error = manager.errorMessage {
            messageBanner(error, symbol: "exclamationmark.triangle.fill", tint: Theme.Ink.error) {
                manager.errorMessage = nil
            }
        }
        if let notice = manager.noticeMessage {
            messageBanner(notice, symbol: "checkmark.circle.fill", tint: Theme.Ink.success) {
                manager.noticeMessage = nil
            }
        }
    }

    private func setEnabled(_ enabled: Bool, for record: ConnectorRecord) {
        guard busyIDs.insert(record.id).inserted else { return }
        let targets = ConnectorBatch.expandingSkills([record], in: manager.records, platform: platform)
        let project = selectedProject
        Task {
            _ = await manager.batch(enabled ? .enable : .disable, over: targets, projectPath: project)
            busyIDs.remove(record.id)
        }
    }

    private func askRemove(_ record: ConnectorRecord) {
        guard record.canRemove else { return }
        let places = record.platforms.map(\.title).joined(separator: "、")
        pendingRemoval = RemovalRequest(
            record: record,
            title: "移除 \(record.name)",
            message: "将从\(places)移除这一处配置。Skill 会进废纸篓；插件和 MCP 会从该平台的配置里删掉。"
        )
    }

    private func remove(_ record: ConnectorRecord) {
        guard busyIDs.insert(record.id).inserted else { return }
        Task {
            await manager.remove(record, projectPath: selectedProject)
            busyIDs.remove(record.id)
        }
    }

    // MARK: - Bulk selection

    /// The targets 批量管理 can act on: exactly the rows on screen.
    ///
    /// The 本机 CLI tab has none. A CLI is a command on the PATH — nothing this
    /// page can enable, disable or remove — and its "related" skills are a
    /// *derived* association, so letting a CLI stand in for the skills that
    /// depend on it would make one click edit records the user never saw.
    private func batchTargets(records shown: [ConnectorRecord]) -> [BatchTarget] {
        shown.map { BatchTarget(id: $0.id, platforms: $0.platforms) }
    }

    private func toggleBatchMode() {
        batchMode.toggle()
        // Leaving bulk mode drops the selection: the bar is gone, so there is
        // nothing left on screen to tell the user what is still ticked.
        if !batchMode { selection.removeAll() }
    }

    private func toggleSelection(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// The selection as records, in the order the manager lists them.
    ///
    /// Filtered to real records of the current kind — the same source
    /// `selection` is named and pruned from (`batchTargets`), so the two cannot
    /// describe different sets.
    private func selectedRecords() -> [ConnectorRecord] {
        let kind = kind(of: focus)
        return manager.records.filter { record in
            record.kind == kind && selection.contains(record.id) &&
                (platform.map { record.platforms.contains($0) } ?? true)
        }
    }

    /// How many ticks an action would actually apply to — the number in the
    /// confirmation, not the number of checkboxes.
    private func actionableCount(_ action: ConnectorBatchAction) -> Int {
        batchRecords(action).count
    }

    /// The records an action would apply to, in the manager's order. One
    /// function for both the count and the run — see `ConnectorBatch.records`.
    private func batchRecords(_ action: ConnectorBatchAction) -> [ConnectorRecord] {
        let selected = selectedRecords()
        let records = action == .remove ? selected
            : ConnectorBatch.expandingSkills(selected, in: manager.records, platform: platform)
        return ConnectorBatch.records(records, for: action)
    }


    /// What a Remove would touch, for the copy. The plugin / MCP half is a
    /// config edit; a skill is a whole folder, which is the part worth naming.
    /// The count is passed in because the caller already resolved the records.
    private func removalSplit(_ records: [ConnectorRecord]) -> Int {
        records.filter { if case .skillMove = $0.method { return true } else { return false } }.count
    }

    private func askBatch(_ action: ConnectorBatchAction) {
        let targets = batchRecords(action)
        let count = targets.count
        guard count > 0 else { return }
        let places = Set(targets.flatMap(\.platforms).map(\.title))
        let where_ = places.isEmpty ? "" : "，涉及 " + places.sorted().joined(separator: "、")
        // Cursor's own state cannot be read, so a 停用 there is a *command*, not
        // a state change — the confirmation says so rather than promising an
        // outcome the app cannot know it got.
        let cursor = targets.filter { $0.batchCapability == .command }.count
        let cursorNote = cursor > 0 ? "，其中 \(cursor) 项由 Cursor 执行、状态请在 Customize 中核对" : ""
        let title: String
        let message: String
        switch action {
        case .disable:
            title = "停用选中的 \(count) 项？"
            message = (platform == nil
                ? "同名独立 Skill 的所有已扫描安装会移入停用区，影响全部平台。"
                : "同名 Skill 在当前平台已扫描到的安装会移入停用区，其他平台不受影响。")
                + where_ + cursorNote + "。"
        case .enable:
            title = "启用选中的 \(count) 项？"
            message = (platform == nil
                ? "停用的 Skill 目录会还原；被占用的路径会拒绝覆盖。"
                : "当前平台已扫描到的同名安装会还原；被占用的路径会拒绝覆盖。") + where_ + cursorNote + "。"
        case .remove:
            let skills = removalSplit(targets)
            title = "移除选中的 \(count) 项？"
            message = "Skill 会进废纸篓；插件和 MCP 会从该平台的配置里删掉。"
                + (skills > 0 ? "其中 \(skills) 个 Skill 目录会连同内容一起进废纸篓。" : "")
                + where_ + "。此操作不可撤销。"
        }
        pendingBatch = BatchConfirm(action: action, title: title, message: message,
                                    records: targets, projectPath: selectedProject)
    }

    private func run(_ request: BatchConfirm) {
        let records = request.records
        guard !records.isEmpty else { return }
        isBatching = true
        Task {
            _ = await manager.batch(request.action, over: records, projectPath: request.projectPath)
            selection.removeAll()
            isBatching = false
        }
    }

    /// The bulk action bar: a tile the width of the grid, pinned under it. It
    /// reports first (how many of what), then the shortcuts, then the three
    /// actions — destructive last, the same order the single card uses.
    ///
    /// The readout and the buttons are driven by the *records* the selection
    /// resolves to, not by `selection.count`, so a tick that belongs to a kind
    /// the bar cannot act on can never be counted as something 停用 will do.
    @ViewBuilder private func batchBar() -> some View {
        let all = batchTargets(records: visibleRecords)
        let targets = Set(all.map(\.id))
        let selected = all.filter { selection.contains($0.id) }
        // One pass of the batch policy per action, shared by the buttons and
        // the readout below: each count re-derives the selection and re-expands
        // its skills, so asking per use ran the whole filter a dozen times a
        // render.
        let disableCount = actionableCount(.disable)
        let enableCount = actionableCount(.enable)
        let removeCount = actionableCount(.remove)
        VStack(alignment: .leading, spacing: Theme.Space.s10) {
            HStack(spacing: Theme.Space.s8) {
                Text("已选 \(selected.count) 项")
                    .rollingNumber("已选 \(selected.count) 项")
                    .font(Theme.Font.chromeEmph)
                    .foregroundStyle(Theme.textPrimary)
                ForEach(selectedPlatforms(selected), id: \.self) { item in
                    StatusPill(label: "\(item.title) \(selected.filter { $0.platforms.contains(item) }.count)",
                               tint: item.face, ink: item.ink)
                }
                if selected.isEmpty {
                    Text("点卡片左上角的复选框选中；下面的快捷键可以整批选。")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: Theme.Space.s8)
                if isBatching {
                    ProgressView().controlSize(.small)
                }
                Text(selectionActionability(disable: disableCount, enable: enableCount, remove: removeCount))
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: Theme.Space.s8) {
                // The shortcuts are `ChipButton`s, not tinted text: a bare
                // coloured label is not a control, and these two sit in the
                // same row as three real buttons. `on: false` because they are
                // *momentary* — nothing stays "selected" after 全选.
                ForEach([ConnectorFocus.plugin, .skill, .mcp]) { item in
                    ChipButton("全部\(item.title)", symbol: item.symbol, on: false) { selectKind(item) }
                        .help("选择整个清单里的\(item.title)，并清除搜索与平台筛选")
                }
                Spacer(minLength: Theme.Space.s8)
                ChipButton("全选本页", symbol: "checkmark.square", on: false) { selection = targets }
                    .disabled(selected.count == all.count)
                ChipButton("清空", symbol: "xmark.square", on: false) { selection.removeAll() }
                    .disabled(selection.isEmpty)
                Spacer(minLength: Theme.Space.s8)
                ActionButton("停用") { askBatch(.disable) }
                    .disabled(isBatching || disableCount == 0)
                ActionButton("启用") { askBatch(.enable) }
                    .disabled(isBatching || enableCount == 0)
                ActionButton("移除", tone: .destructive) { askBatch(.remove) }
                    .disabled(isBatching || removeCount == 0)
            }
            .frame(height: 30)
        }
        .padding(.horizontal, Theme.Space.s16)
        .padding(.vertical, Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile(tint: Theme.claude, lift: false)
        .padding(.horizontal, Theme.Space.s24)
        .padding(.bottom, Theme.Space.s12)
        .background(Theme.bgPrimary)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// The one-line readout of what the selection can actually do. Three facts
    /// the three buttons would otherwise state only by being disabled. The
    /// counts come from the caller, which already ran the policy for the
    /// buttons — the readout used to re-derive all three.
    private func selectionActionability(disable off: Int, enable on: Int, remove removable: Int) -> String {
        let records = selectedRecords()
        guard !records.isEmpty else { return "先在上面的网格里选中要处理的项" }
        var parts: [String] = []
        if off > 0 { parts.append("可停用 \(off)") }
        if on > 0 { parts.append("可启用 \(on)") }
        if removable > 0 { parts.append("可移除 \(removable)") }
        if parts.isEmpty { return "这些项由客户端管理，本页只能查看" }
        let inert = ConnectorBatch.inert(records)
        return parts.joined(separator: " · ") + (inert > 0 ? " · 其余 \(inert) 项由客户端管理" : "")
    }

    private func selectedPlatforms(_ selected: [BatchTarget]) -> [ConnectorPlatform] {
        ConnectorPlatform.allCases.filter { item in selected.contains { $0.platforms.contains(item) } }
    }

    /// Select every record of a kind across the *whole* inventory, not just the
    /// page — "停用全部 MCP" has no per-client shortcut otherwise. The platform
    /// menu narrows this to one client afterwards.
    private func selectKind(_ item: ConnectorFocus) {
        guard item != .local else { return }
        focus = item
        platform = nil
        search = ""
        let kind = kind(of: item)
        selection = Set(manager.records.filter { $0.kind == kind }.map(\.id))
    }

    private var emptyState: some View {
        // The shared parked-instrument state, on the tile surface — so an empty
        // grid and an empty model list say "nothing here" the same way.
        StandbyEmptyState(label: search.isEmpty ? "这里还没有\(focus.title)" : "没有匹配的卡片",
                          symbol: focus.symbol,
                          tint: Theme.Ink.claude,
                          caption: emptyCaption,
                          block: true,
                          action: emptyAction)
            .frame(minHeight: 220)
            .tile()
    }

    private var emptyCaption: String {
        if !search.isEmpty || (focus != .local && platform != nil) {
            return "换一个平台或清掉搜索再看。"
        }
        return projectPath.isEmpty ? "选择项目后，还会带上项目里的配置。" : "当前项目暂无这类配置。"
    }

    private var emptyAction: (label: String, run: () -> Void)? {
        if !search.isEmpty || (focus != .local && platform != nil) {
            return ("清空筛选", { search = ""; platform = nil })
        }
        return projectPath.isEmpty ? ("选择项目", chooseProject) : nil
    }

    private var loadingState: some View {
        VStack(spacing: Theme.Space.s12) {
            OrbitLoader(size: 52, caption: "扫描")
            Text("正在读取本机清单").font(Theme.Font.chromeEmph)
            // The belt: this surface is *doing* something continuous, so the
            // liveness is drawn travelling rather than pulsed, and it stops the
            // moment the scan does. It takes the raw shape hue, not the ink
            // variant — `Theme.Ink.*` is mixed for text, and this is a stripe.
            ConveyorBelt(tint: Theme.claude, height: 4, running: true)
                .frame(width: 132)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .tile(tint: Theme.claude)
    }

    /// A notice band. It used to be a flat tinted rectangle with no edge
    /// (`tint.opacity(0.07)` in a bare `RoundedRectangle`) — colour with nothing
    /// machined about it, which read as unstyled next to the tile grid. It is
    /// now the same surface family as everything else: a wash, the inner frame
    /// ring, and the mark in a well, so a warning still looks like this app.
    private func messageBanner(_ message: String, symbol: String, tint: Color, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.s10) {
            GlyphWell(name: symbol, tint: tint, size: 26)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: Theme.Space.s8)
            Button("关闭", action: onDismiss)
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s10)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.cardSurface)
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(tint.opacity(Theme.isDark ? 0.16 : 0.09))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            InnerFrameRing(inset: 2.5, radius: Theme.Radius.md,
                           tint: tint.opacity(Theme.isDark ? 0.22 : 0.5))
        }
        .padding(.bottom, Theme.Space.s8)
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择项目"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in projectPath = url.standardizedFileURL.path }
        }
    }
}

private enum ConnectorFocus: String, CaseIterable, Identifiable {
    case plugin, skill, mcp, local
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plugin: return "插件"
        case .skill: return "Skills"
        case .mcp: return "MCP"
        case .local: return "本机 CLI"
        }
    }
    var symbol: String {
        switch self {
        case .plugin: return "puzzlepiece.extension"
        case .skill: return "doc.text"
        case .mcp: return "network"
        case .local: return "terminal"
        }
    }
}

private struct RemovalRequest: Identifiable {
    let id = UUID()
    let record: ConnectorRecord
    let title: String
    let message: String
}

/// One row the bulk bar can act on: the identity a tick is keyed by, plus the
/// platforms its readout counts by. Deliberately *not* a `ConnectorRecord` —
/// the bar needs nothing past those two, and copying the whole record (with its
/// URLs and connection stanza) into every bar render would rebuild far more
/// than the counts it reads.
private struct BatchTarget: Identifiable {
    let id: String
    let platforms: [ConnectorPlatform]
}

/// A bulk action awaiting confirmation. `confirmationDialog` needs its title
/// and message to survive the dialog's own re-render, so they are computed once
/// (with the counts the user was shown) rather than derived from a live
/// selection that the dialog itself might outlive.
private struct BatchConfirm: Identifiable {
    let id = UUID()
    let action: ConnectorBatchAction
    let title: String
    let message: String
    let records: [ConnectorRecord]
    let projectPath: String?
}

/// The selection box. Drawn rather than a stock `Toggle`: a checkbox in this app
/// is a small target on a card that already answers the pointer, so it takes the
/// same 6 → 10 % wash and hoisted rim `ActionIcon` uses, and its checked state is
/// the accent's ink, not a system blue.
private struct ConnectorTick: View {
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(selected ? Theme.Ink.claude : Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.claude.opacity(hovered ? 0.10 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if hovered != $0 { hovered = $0 } }
        .animation(reduceMotion ? nil : Theme.Motion.state, value: selected)
        .accessibilityLabel(selected ? "取消选择" : "选择")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct ConnectorCard: View {
    let record: ConnectorRecord
    let contents: PluginBundleContents?
    let isBusy: Bool
    /// Bulk mode. In it the body opens the detail sheet as usual — the tick is
    /// its own target in the corner — and the card's own action row is dropped,
    /// because the same three actions are on the bar one row below and two
    /// copies of "停用" that act differently is exactly how a user clicks the
    /// wrong one.
    var selecting = false
    var selected = false
    var onToggleSelection: (() -> Void)? = nil
    let onDetails: () -> Void
    let onSetEnabled: (Bool) -> Void
    let onRemove: () -> Void
    @State private var hovered = false
    /// The card's platform hue as **text** — the `GlyphWell` mark and the
    /// per-platform chips, both of which need the readable variant.
    private var tint: Color {
        record.platforms.first?.ink ?? Theme.textSecondary
    }

    /// The same platform hue as a **surface** — the card wash.
    /// Deliberately a second value rather than `tint` used twice: the ink mix
    /// lands near-navy behind a card whose own title is `textPrimary`, so the
    /// wash read as a dark smudge instead of as the card's accent. (`nil` — a
    /// connector with no platform — keeps the neutral hairline, i.e. no wash.)
    private var faceTint: Color? {
        record.platforms.first?.face
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        // Reserve the leading slot for the independent selection
                        // button overlaid below, outside the detail button.
                        if selecting {
                            Color.clear.frame(width: 24, height: 24)
                        }
                        // The active category supplies the kind; use the
                        // subtitle for this installation's scope instead.
                        GlyphWell(name: record.kind.symbol,
                                  tint: tint, size: 32, engaged: hovered,
                                  mark: record.brandWellMark)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(record.scope)
                                .font(Theme.Font.microSemibold)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 4)
                    }
                    Text(blurb)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                    HStack(spacing: 4) {
                        ForEach(record.platforms) { item in
                            // The same pill every other readout in the app uses,
                            // so a platform chip and a status chip are one
                            // object. The wash takes the shape hue, the label
                            // the ink variant.
                            StatusPill(label: item.title,
                                       tint: item.face,
                                       ink: item.ink)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 22)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(selecting ? "查看详情；左上角是选择框" : "查看详情")
            // Reserve the action row so entering bulk mode keeps grid geometry stable.
            if selecting {
                HStack { Spacer(); status }.frame(height: 30)
            } else {
                actions
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 164, maxHeight: 164, alignment: .topLeading)
        // One independent selection target, aligned with the reserved header
        // slot. Keeping it outside the detail button avoids nested buttons.
        .overlay(alignment: .topLeading) {
            if selecting {
                ConnectorTick(selected: selected) { onToggleSelection?() }
                    .offset(x: 12, y: 16)
            }
        }
        .tile(tint: faceTint, hovered: hovered)
        .hoverState($hovered)
    }

    private var blurb: String {
        if record.kind == .plugin {
            let items = contents?.items ?? []
            if items.isEmpty { return "这处安装里没有单独列出的 Skill 或 MCP。" }
            let skills = items.filter { $0.kind == "Skill" }.count
            let mcp = items.filter { $0.kind == "MCP" }.count
            let names = items.prefix(4).map(\.name).joined(separator: " · ")
            var head = [String]()
            if skills > 0 { head.append("\(skills) 个 Skill") }
            if mcp > 0 { head.append("\(mcp) 个 MCP") }
            let prefix = head.isEmpty ? "包含" : head.joined(separator: " · ")
            return prefix + "  ·  " + names
        }
        if let owner = record.sharedOwner { return "由 \(owner) 提供" }
        if record.summary.contains("/") { return record.scope }
        return record.summary
    }

    private var status: some View {
        StatusPill(label: statusLabel, tint: statusTint, ink: statusInk)
    }

    private var statusLabel: String {
        if let enabled = record.enabled { return enabled ? "已启用" : "已停用" }
        if record.method.isCursorMCP { return "待确认" }
        return "客户端管理"
    }

    private var statusTint: Color {
        record.enabled == true ? Theme.statusSuccess : Theme.textSecondary
    }

    private var statusInk: Color {
        record.enabled == true ? Theme.Ink.success : Theme.textSecondary
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if isBusy {
                ProgressView().controlSize(.small)
                    .frame(height: 28)
            } else if let enabled = record.enabled, record.canToggle {
                Button(enabled ? "停用" : "启用") { onSetEnabled(!enabled) }
                    .connectorUtilityButton(accented: !enabled)
            } else if case .cursorMCP = record.method {
                Button("启用") { onSetEnabled(true) }
                    .connectorUtilityButton(accented: true)
                Button("停用") { onSetEnabled(false) }
                    .connectorUtilityButton()
            } else {
                Button("查看详情", action: onDetails)
                    .connectorUtilityButton()
            }
            Spacer(minLength: 4)
            status
            if record.canRemove && !isBusy {
                Button("移除", action: onRemove)
                    .connectorUtilityButton()
            }
        }
        .frame(height: 30)
    }
}

/// The type filter (插件 / Skills / MCP / 本机 CLI) as one segmented capsule:
/// a single milled group with a sliding selection pill and per-item counts.
///
/// It used to be a capsule *containing* four capsules, each with its own
/// border and shadow — four cards in a card, and the selection only legible as
/// "which one is filled". The counts move into the item itself, so the filter
/// answers "how many of each" without a second lookup.
private struct ConnectorKindFilter: View {
    let items: [ConnectorFocus]
    let selection: ConnectorFocus
    let count: (ConnectorFocus) -> Int
    let onSelect: (ConnectorFocus) -> Void

    var body: some View {
        SegmentedCapsule(items: items,
                         selection: selection,
                         title: { $0.title },
                         symbol: { $0.symbol },
                         count: count,
                         tint: Theme.Ink.claude,
                         onSelect: onSelect)
    }
}

/// A local CLI's avatar: the command's own two-letter monogram on a wash of the
/// hue its name hashes to.
///
/// Not a `GlyphWell`: that well draws an *icon* — a symbol or a client's bundled
/// artwork — and a command-line tool has neither. What it does have is a name,
/// which is the only honest thing to draw at 40pt. The hue comes from `djb2` of
/// the name, so the grid reads as a roster of distinct entries instead of 20
/// copies of one terminal glyph. See `LocalCLIRecord.monogram`.
private struct CLIAvatar: View {
    let record: LocalCLIRecord
    var size: CGFloat = 40
    var engaged = false

    private var tint: Color { Color(hex: record.hue) }

    var body: some View {
        Text(record.monogram)
            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .fill(tint.opacity(engaged ? 0.16 : 0.09))
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .strokeBorder(tint.opacity(engaged ? 0.32 : 0.16), lineWidth: 0.75)
            }
            .accessibilityHidden(true)
    }
}

private struct LocalCLICard: View {
    let cli: LocalCLIRecord
    let relatedCount: Int
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                // The command's own monogram, in the command's own hue. See
                // `LocalCLIRecord.monogram` for why this is not a logo: the
                // inventory is a list of *commands*, most of which have no mark
                // to bundle, and 20 identical terminals read as a failed render.
                CLIAvatar(record: cli, size: 32, engaged: hovered)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cli.name)
                        .font(Theme.Font.chromeEmph)
                        .lineLimit(1)
                    Text(cli.category)
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                StatusPill(label: "已安装", tint: Theme.statusSuccess, ink: Theme.Ink.success)
            }
            Text(cli.summary)
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack {
                Text(relatedCount > 0 ? "\(relatedCount) 项关联能力" : "本机命令")
                    .rollingNumber(relatedCount > 0 ? "\(relatedCount) 项关联能力" : "本机命令")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("定位") {
                    NSWorkspace.shared.activateFileViewerSelecting([cli.source])
                }
                .connectorUtilityButton()
            }
            .frame(height: 30)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 164, maxHeight: 164, alignment: .topLeading)
        // Surface hue, not the ink variant: `Theme.Ink.claude` is mixed for
        // text and lands near-navy as a wash. The header mark keeps the ink.
        .tile(tint: Theme.claude, hovered: hovered,
              lens: DepthLensSpec(tint: Theme.claude, size: 132))
        .hoverState($hovered)
    }
}

/// The connector card's own action buttons.
///
/// `accented` is the *suggested* action (启用 on a disabled connector), not a
/// second button family: it fills the app's one machined pill with the accent
/// instead of the well tone. The inverted white fill on hover is kept because it
/// is this card's own gesture — a dense card of small controls needs one thing
/// that visibly takes over when the pointer arrives — but the body, the rim, the
/// lit top edge and the press all come from `ActionPlateButtonStyle`, so a
/// connector button and a page-band button are finally the same object.
private struct ConnectorUtilityButtonModifier: ViewModifier {
    let accented: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .buttonStyle(ConnectorUtilityButtonStyle(accented: accented,
                                                     hovered: $hovered))
            .hoverState($hovered)
    }
}

private struct ConnectorUtilityButtonStyle: ButtonStyle {
    let accented: Bool
    @Binding var hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        // One style, not two: SwiftUI hands `makeBody` to the style *closest*
        // to the `Button` and discards the rest, so the `.uiversePress` the
        // call sites used to chain here never ran — it shadowed this one
        // rather than compositing with it, and every connector action drew as a
        // bare label with no plate and no disabled treatment. The plate owns
        // both by itself (`ActionPlateButtonStyle`: `scaleEffect(0.97)` on
        // press, 0.34 opacity + desaturation when disabled).
        ActionPlateButtonStyle(tone: accented || hovered ? .accent : .neutral,
                               tint: Theme.claude, ink: nil, metrics: .regular)
            .makeBody(configuration: configuration)
    }
}

private extension View {
    func connectorUtilityButton(accented: Bool = false) -> some View {
        modifier(ConnectorUtilityButtonModifier(accented: accented))
    }

    // `connectorSurface` was its own card surface — a clipped card with one
    // stroked arc in the corner, a hover lift and a hover shadow. It is now
    // `.tile(tint:hovered:lens:)`: the tile draws the same corner ornament as a
    // `DepthLens` (three rings shrinking *and* drifting toward the corner, at
    // one `Canvas` instead of one view per ring) plus the same lift and shadow,
    // so the connector grid and every other grid in the app are literally the
    // same surface.
}

/// The platform hue, in the two variants every readout on this page needs.
/// Kept here rather than on the model: `ConnectorManager` imports only
/// Foundation/Combine, and a view colour has no business in a model file.
private extension ConnectorPlatform {
    /// `Theme.Ink` — the readable variant, for a glyph or a pill label.
    var ink: Color {
        switch self {
        case .claude: Theme.Ink.claude
        case .codex: Theme.Ink.codex
        case .cursor: Theme.Ink.cursor
        }
    }

    /// `Theme.*` — the piece's own hue, for a wash or a ring. The ink mix
    /// lands near-navy behind a label or as a surface fill, which is the
    /// mistake the ink/shape pair exists to prevent.
    var face: Color {
        switch self {
        case .claude: Theme.claude
        case .codex: Theme.codex
        case .cursor: Theme.cursor
        }
    }
}
