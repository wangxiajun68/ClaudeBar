import AppKit
import SwiftUI

/// Plugin, skill and MCP installs as a fixed-height grid. Enable, disable and
/// remove sit on the card. Plugin contents are read once during the scan.
struct ConnectorsView: View {
    @StateObject private var manager = ConnectorManager()
    @AppStorage("connectorProjectPath") private var projectPath = ""
    @State private var focus: ConnectorFocus = .plugin
    @State private var platform: ConnectorPlatform?
    @State private var search = ""
    @State private var busyIDs: Set<String> = []
    @State private var selectedRecord: ConnectorRecord?
    @State private var pendingRemoval: RemovalRequest?

    private let columns = [GridItem(.adaptive(minimum: 268), spacing: Theme.Space.gridGapPage, alignment: .top)]
    private var selectedProject: String? { projectPath.isEmpty ? nil : projectPath }

    var body: some View {
        let shown = visibleRecords
        let clis = visibleCLIs
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                toolbar(count: focus == .local ? clis.count : shown.count)
                notices
                if manager.isLoading && manager.records.isEmpty && manager.localCLIs.isEmpty {
                    loadingState
                        .padding(.horizontal, Theme.Space.s24)
                } else if focus == .local {
                    cardGrid(isEmpty: clis.isEmpty) {
                        ForEach(clis) { cli in
                            LocalCLICard(cli: cli,
                                         relatedCount: relatedCount(cli.name))
                        }
                    }
                } else {
                    cardGrid(isEmpty: shown.isEmpty) {
                        ForEach(shown) { record in
                            ConnectorCard(
                                record: record,
                                contents: manager.pluginContents[record.id],
                                isBusy: busyIDs.contains(record.id),
                                onDetails: { selectedRecord = record },
                                onSetEnabled: { setEnabled($0, for: record) },
                                onRemove: { askRemove(record) }
                            )
                        }
                    }
                }
            }
        }
        .background(Theme.bgPrimary)
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
        .task { await manager.refresh(projectPath: selectedProject) }
        .onChange(of: projectPath) { _, _ in
            Task { await manager.refresh(projectPath: selectedProject, scanCLIs: false) }
        }
        // `selectedRecord` is a *copy* captured at click time, and any refresh
        // replaces `manager.records` wholesale — so an open detail sheet could
        // keep describing an install that was just removed or disabled, and
        // read paths that no longer exist. Re-resolve it against the new list;
        // when the record is gone, close the sheet.
        .onChange(of: manager.records.map(\.id)) { _, ids in
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

    private var header: some View {
        ConnectorInventoryHeader(
            focus: focus,
            platform: platform,
            counts: Dictionary(uniqueKeysWithValues: ConnectorPlatform.allCases.map { item in
                (item, manager.count(kind: kind(of: focus), platform: item))
            }),
            kindCounts: Dictionary(uniqueKeysWithValues: ConnectorFocus.allCases.map { item in
                (item, item == .local ? manager.localCLIs.count : manager.count(kind: kind(of: item)))
            }),
            localCount: manager.localCLIs.count,
            total: manager.records.count,
            currentCount: kindCount(focus),
            loading: manager.isLoading,
            projectName: projectPath.isEmpty ? nil : URL(fileURLWithPath: projectPath).lastPathComponent,
            onSelectPlatform: { item in
                withAnimation(Theme.Motion.state) {
                    // Tapping the selected chip clears the filter, which is
                    // what the chip's own selected state implies and what the
                    // empty state's 「清空筛选」 says it does.
                    platform = (item != nil && platform == item) ? nil : item
                    if focus == .local { focus = .plugin }
                }
            },
            onRefresh: { Task { await manager.refresh(projectPath: selectedProject) } },
            onChooseProject: chooseProject
        )
        .padding(.horizontal, Theme.Space.s24)
        .padding(.top, Theme.Space.s8)
        .padding(.bottom, Theme.Space.s16)
    }

    private func toolbar(count: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            HStack(spacing: Theme.Space.s8) {
                ConnectorKindFilter(items: ConnectorFocus.allCases,
                                    selection: focus,
                                    count: kindCount,
                                    onSelect: { item in
                    withAnimation(Theme.Motion.state) {
                        focus = item
                        // A platform filter picked under 插件 means
                        // nothing under Skills; carrying it over landed
                        // the user on a silently empty grid.
                        platform = nil
                    }
                })
                Spacer(minLength: Theme.Space.s8)
                Text("\(count) 项")
                    .font(Theme.Font.microMedium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            InstrumentSearchField(prompt: "搜索名称、平台或包含的 Skill", text: $search)
                .frame(height: 38)
            if !projectPath.isEmpty {
                Button("清除项目筛选") { projectPath = "" }
                    .buttonStyle(.plain)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Ink.claude)
            }
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.bottom, Theme.Space.s12)
    }

    private func cardGrid<Cards: View>(isEmpty: Bool, @ViewBuilder cards: () -> Cards) -> some View {
        Group {
            if isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.gridGapPage) {
                    cards()
                }
            }
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.bottom, Theme.Space.s24)
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
        Task {
            await manager.setEnabled(enabled, for: record, projectPath: selectedProject)
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
        .padding(.horizontal, Theme.Space.s24)
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

/// The page's header card: title, live counts, refresh / project controls, and
/// the platform filter. The three client destinations are real filters; scan and
/// project stay reachable from every state, because a scan is the answer to
/// "this list looks wrong" and hiding it behind the filter would be a trap.
///
/// The *type* filter (插件 / Skills / MCP / 本机 CLI) is not here — it lives in
/// `toolbar` below this card, since it selects what the page shows rather than
/// describing what was found.
private struct ConnectorInventoryHeader: View {
    let focus: ConnectorFocus
    let platform: ConnectorPlatform?
    let counts: [ConnectorPlatform: Int]
    /// The three type totals the reading strip prints, keyed by focus kind.
    let kindCounts: [ConnectorFocus: Int]
    let localCount: Int
    let total: Int
    let currentCount: Int
    let loading: Bool
    let projectName: String?
    let onSelectPlatform: (ConnectorPlatform?) -> Void
    let onRefresh: () -> Void
    let onChooseProject: () -> Void

    var body: some View {
        PageHeaderCard(tint: Theme.Ink.claude,
                       faceTint: Theme.claude,
                       orbit: orbitReading) { engaged in
            VStack(alignment: .leading, spacing: Theme.Space.s14) {
                HStack(alignment: .top, spacing: Theme.Space.s12) {
                    GlyphWell(name: "puzzlepiece.extension",
                              tint: Theme.Ink.claude, size: 38, engaged: engaged)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("连接器")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Text(subtitle)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: Theme.Space.s8)
                    // The header's own buttons are the readout's controls, so
                    // they take the published instrument button — a capsule
                    // well with a lit perimeter that travels once on hover.
                    Button(action: onRefresh) {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(loading)
                    .headerControl()
                    Button(action: onChooseProject) {
                        Label(projectName ?? "选择项目", systemImage: "folder")
                            .lineLimit(1)
                    }
                    .headerControl()
                }

                // The composition strip. The header's job is to answer "what is
                // in here" before the grid does, and four grey figures answering
                // it separately is not an answer — it is four numbers to read.
                // Drawn as one proportional bar instead: each type owns a
                // segment sized by its share, so the *shape* of the inventory is
                // legible in one glance and the figures are there for the reader
                // who wants them.
                inventoryStrip

                if focus != .local {
                    // The platform row is the same segmented capsule as the type
                    // filter below it, with one difference: each item keeps its own
                    // hue, because Claude / Codex / Cursor are identities rather
                    // than entries in one list. Four equal-width bordered cards
                    // (the previous shape) drew a second card grid inside the
                    // header card and made the selection read as "which one is
                    // filled" instead of "where am I".
                    SegmentedCapsule(items: platformItems,
                                     selection: platform,
                                     title: { $0?.title ?? "全部" },
                                     symbol: { item in
                                         item.map(platformSymbol) ?? "square.grid.2x2"
                                     },
                                     count: { item in
                                         item.map { counts[$0] ?? 0 } ?? currentCount
                                     },
                                     tint: Theme.Ink.claude,
                                     itemTint: { item in
                                         item.map(platformTint) ?? Theme.Ink.claude
                                     },
                                     fillsWidth: true,
                                     onSelect: onSelectPlatform)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// The header's arc: how much of the whole inventory the current filter
    /// shows. A header that already states the total should draw where the
    /// current view sits inside it — the weather card's orbit, used as a
    /// reading. Hidden while scanning, when the figure is not a reading yet.
    private var orbitReading: Double? {
        guard !loading, total > 0 else { return nil }
        if focus == .local {
            return localCount > 0 ? 1 : 0
        }
        return Double(currentCount) / Double(total)
    }

    private var subtitle: String {
        if loading { return "正在扫描本机与项目配置" }
        if focus == .local { return "本机已安装 \(localCount) 个 CLI" }
        return "共 \(total) 项能力 · 当前分类 \(currentCount) 项"
    }

    /// The types the strip proportions, in the order the filter lists them.
    private var stripParts: [(focus: ConnectorFocus, count: Int, face: Color, ink: Color)] {
        [
            (.plugin, kindCounts[.plugin] ?? 0, Theme.claude, Theme.Ink.claude),
            (.skill, kindCounts[.skill] ?? 0, Theme.cursor, Theme.Ink.cursor),
            (.mcp, kindCounts[.mcp] ?? 0, Theme.statusSuccess, Theme.Ink.success),
        ]
    }

    private var stripTotal: Int {
        max(1, stripParts.reduce(0) { $0 + $1.count })
    }

    /// One proportional bar plus a legend that doubles as the figures. The bar
    /// takes the **shape** hues (a fill), the legend the **ink** ones (text) —
    /// the same split every other bar-and-label pair in the app keeps.
    private var inventoryStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(stripParts, id: \.focus) { part in
                        let share = CGFloat(part.count) / CGFloat(stripTotal)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(part.face.opacity(part.count == 0 ? 0.13 : 0.85))
                            .frame(width: max(3, geo.size.width * share - 2))
                    }
                }
            }
            .frame(height: 6)

            HStack(spacing: Theme.Space.s14) {
                ForEach(stripParts, id: \.focus) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.face).frame(width: 6, height: 6)
                        Text(part.focus.title)
                            .font(Theme.Font.micro)
                            .foregroundStyle(Theme.textSecondary)
                        Text("\(part.count)")
                            .font(Theme.Font.microSemibold)
                            .monospacedDigit()
                            .foregroundStyle(part.ink)
                            .contentTransition(.numericText())
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Image(systemName: "terminal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary())
                    Text("本机 CLI")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(localCount)")
                        .font(Theme.Font.microSemibold)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    /// `nil` is the 全部 entry, kept in the same list so it slides under the
    /// same selection pill as the three real clients.
    private var platformItems: [ConnectorPlatform?] {
        [nil] + ConnectorPlatform.allCases.map { Optional($0) }
    }

    private func platformTint(_ item: ConnectorPlatform) -> Color {
        switch item {
        case .claude: Theme.Ink.claude
        case .codex: Theme.Ink.codex
        case .cursor: Theme.Ink.cursor
        }
    }

    private func platformSymbol(_ item: ConnectorPlatform) -> String {
        switch item {
        case .claude: "terminal"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        }
    }
}

/// The header's own control: a capsule *milled into* the header card rather
/// than a second white chip laid on it, plus the 3D button reference's
/// **perimeter sweep** — a lit arc that travels the control's own edge once
/// when the pointer arrives and then stops.
///
/// It used to be a flat grey capsule with a grey border and **no hover response
/// at all** (`bgSecondary` fill, `Theme.hairline` stroke) — the single most
/// generic object on a page whose complaint was that it read as plain. Two
/// things fix it, both cheap:
///
/// 1. the well is the *recessed* fill (`Theme.fieldWell`) so the button reads as
///    a control sitting in the band, not another card;
/// 2. the accent rim and the one-shot sweep say "this is a target" before the
///    click. The sweep is one trimmed shape and runs only on hover, never on a
///    loop — a permanent rotating border is chrome that never stops meaning
///    anything, and it is what the reference does that this deliberately does
///    not.
private struct HeaderControlModifier: ViewModifier {
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(height: 32)
            .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
            .background(Theme.fieldWell, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(hovered ? Theme.claude.opacity(0.45) : Theme.hairline,
                                  lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if !reduceMotion {
                    PerimeterSweep(active: hovered, tint: Theme.claude.opacity(0.9), lineWidth: 1.4)
                        .padding(0.5)
                }
            }
            .overlay { GroundShadow(active: hovered).offset(y: 18).opacity(0.5) }
            .contentShape(Capsule())
            .onHover { if hovered != $0 { hovered = $0 } }
            .animation(Theme.Motion.state, value: hovered)
    }
}

private extension View {
    func headerControl() -> some View { modifier(HeaderControlModifier()) }
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

private struct ConnectorCard: View {
    let record: ConnectorRecord
    let contents: PluginBundleContents?
    let isBusy: Bool
    let onDetails: () -> Void
    let onSetEnabled: (Bool) -> Void
    let onRemove: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The card's platform hue as **text** — the `GlyphWell` mark and the
    /// per-platform chips, both of which need the readable variant.
    private var tint: Color {
        switch record.platforms.first {
        case .claude: return Theme.Ink.claude
        case .codex: return Theme.Ink.codex
        case .cursor: return Theme.Ink.cursor
        case nil: return Theme.textSecondary
        }
    }

    /// The same platform hue as a **surface** — the wash and the corner rings.
    /// Deliberately a second value rather than `tint` used twice: the ink mix
    /// lands near-navy behind a card whose own title is `textPrimary`, so the
    /// wash read as a dark smudge instead of as the card's accent. (`nil` — a
    /// connector with no platform — keeps the neutral hairline, i.e. no wash.)
    private var faceTint: Color? {
        switch record.platforms.first {
        case .claude: return Theme.claude
        case .codex: return Theme.codex
        case .cursor: return Theme.cursor
        case nil: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        GlyphWell(name: record.kind.symbol, tint: tint, size: 40, engaged: hovered)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(record.kind == .skill ? "Skill" : record.kind.title)
                                .font(Theme.Font.microSemibold)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 4)
                        status
                    }
                    Text(blurb)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                    HStack(spacing: 4) {
                        ForEach(record.platforms) { item in
                            // The same pill every other readout in the app uses,
                            // so a platform chip and a status chip are one
                            // object. The wash takes the shape hue, the label
                            // the ink variant.
                            StatusPill(label: item.title,
                                       tint: platformFaceTint(item),
                                       ink: platformTint(item))
                        }
                        Text(record.scope)
                            .font(Theme.Font.micro)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 22)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看详情")
            Spacer(minLength: 0)
            HairlineDivider()
            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210, alignment: .topLeading)
        .tile(tint: faceTint, hovered: hovered, lens: lens)
        // The 3D card's gesture, on the one page where the tiles *are* the
        // page. Only the hovered card transforms, so the cost is bounded to one
        // subtree however many tiles are in the grid; Reduce Motion drops the
        // tilt and keeps the lift `.tile()` already applies.
        .depthTilt(corner: Theme.Radius.lg, hovered: hovered, reduceMotion: reduceMotion)
        .hoverState($hovered)
    }

    /// The corner ornament, drawn in the card's own platform hue as a surface,
    /// matching the wash under it. Sized past the tile's 22pt radius so it
    /// reads as depth behind the header rather than as a badge; the type mark
    /// itself is the `GlyphWell` in that header, so the rings stay hue-only and
    /// the card keeps one identity, not two.
    private var lens: DepthLensSpec? {
        guard let faceTint else { return nil }
        return DepthLensSpec(tint: faceTint, size: 132, rings: 3)
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
                    .buttonStyle(.uiversePress)
                    .connectorUtilityButton(accented: !enabled)
            } else if case .cursorMCP = record.method {
                Button("启用") { onSetEnabled(true) }
                    .buttonStyle(.uiversePress)
                    .connectorUtilityButton(accented: true)
                Button("停用") { onSetEnabled(false) }
                    .buttonStyle(.uiversePress)
                    .connectorUtilityButton()
            } else {
                Text("在客户端中管理")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 4)
            if record.canRemove && !isBusy {
                Button("移除", action: onRemove)
                    .buttonStyle(.uiversePress)
                    .connectorUtilityButton()
            }
        }
        .frame(height: 30)
    }

    private func platformTint(_ item: ConnectorPlatform) -> Color {
        switch item {
        case .claude: return Theme.Ink.claude
        case .codex: return Theme.Ink.codex
        case .cursor: return Theme.Ink.cursor
        }
    }

    /// The same platform hue as a **shape** — the `StatusPill` wash. The ink
    /// mix lands near-navy behind a pill's own label, which is the mistake the
    /// ink/shape pair exists to prevent.
    private func platformFaceTint(_ item: ConnectorPlatform) -> Color {
        switch item {
        case .claude: return Theme.claude
        case .codex: return Theme.codex
        case .cursor: return Theme.cursor
        }
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

private struct LocalCLICard: View {
    let cli: LocalCLIRecord
    let relatedCount: Int
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                GlyphWell(name: "terminal", tint: Theme.Ink.claude, size: 40, engaged: hovered)
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
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("定位") {
                    NSWorkspace.shared.activateFileViewerSelecting([cli.source])
                }
                .buttonStyle(.uiversePress)
                .connectorUtilityButton()
            }
            .frame(height: 30)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210, alignment: .topLeading)
        // Surface hue, not the ink variant: `Theme.Ink.claude` is mixed for
        // text and lands near-navy as a wash. The header mark keeps the ink.
        .tile(tint: Theme.claude, hovered: hovered,
              lens: DepthLensSpec(tint: Theme.claude, size: 132))
        .hoverState($hovered)
    }
}

private struct ConnectorUtilityButtonModifier: ViewModifier {
    let accented: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .font(Theme.Font.microSemibold)
            .foregroundStyle(hovered ? (Theme.isDark ? Color.black : .white) :
                             (accented ? Theme.Ink.claude : Theme.textPrimary))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(hovered ? Theme.textPrimary : (accented ? Theme.claude.opacity(0.11) : Theme.bgOverlay),
                        in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(hovered ? Theme.textPrimary : (accented ? Theme.claude.opacity(0.25) : Theme.hairline))
                    .allowsHitTesting(false)
            }
            // The same one-shot perimeter the header's controls wear. Without
            // it the page had two capsule button languages: the header's lit
            // ring and the card's plain edge. The inverted fill stays — it is
            // this control's own gesture and the reason it reads as the card's
            // primary action.
            .overlay {
                if accented, !reduceMotion {
                    PerimeterSweep(active: hovered, tint: Theme.claude.opacity(0.8),
                                   lineWidth: 1.3)
                        .padding(0.5)
                }
            }
            .hoverState($hovered)
            .animation(reduceMotion ? nil : Theme.Motion.state, value: hovered)
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
