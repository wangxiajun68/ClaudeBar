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
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 268), spacing: Theme.Space.gridGapPage, alignment: .top)]
    private var selectedProject: String? { projectPath.isEmpty ? nil : projectPath }

    var body: some View {
        let shown = visibleRecords
        let clis = visibleCLIs
        return VStack(alignment: .leading, spacing: 0) {
            header
            toolbar(count: focus == .local ? clis.count : shown.count)
            notices
            ScrollView {
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
    }

    private var removalPresented: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var visibleRecords: [ConnectorRecord] {
        let kind: ConnectorKind = switch focus {
        case .plugin: .plugin
        case .skill: .skill
        case .mcp: .mcp
        case .local: .skill
        }
        guard focus != .local else { return [] }
        return manager.records.filter { record in
            record.kind == kind &&
            (platform.map { record.platforms.contains($0) } ?? true) &&
            matches(record)
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

    private func matches(_ record: ConnectorRecord) -> Bool {
        guard !search.isEmpty else { return true }
        if record.name.localizedStandardContains(search) { return true }
        if record.scope.localizedStandardContains(search) { return true }
        if record.platforms.contains(where: { $0.title.localizedStandardContains(search) }) { return true }
        if record.sharedOwner?.localizedStandardContains(search) == true { return true }
        return manager.pluginContents[record.id]?.items.contains {
            $0.name.localizedStandardContains(search)
        } ?? false
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.s16) {
            VStack(alignment: .leading, spacing: Theme.Space.s6) {
                PageTitle(title: "连接器")
                Text("每张卡片是一处安装，启停和移除都在卡片上")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s12)
            Button { Task { await manager.refresh(projectPath: selectedProject) } } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.uiversePress)
            .connectorUtilityButton()
            .disabled(manager.isLoading)
            Button(action: chooseProject) {
                Label(projectPath.isEmpty ? "选择项目" : URL(fileURLWithPath: projectPath).lastPathComponent,
                      systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170)
            }
            .buttonStyle(.uiversePress)
            .connectorUtilityButton(accented: !projectPath.isEmpty)
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.vertical, Theme.Space.s16)
    }

    private func toolbar(count: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            HStack(spacing: Theme.Space.s8) {
                HStack(spacing: Theme.Space.s2) {
                    ForEach(ConnectorFocus.allCases) { item in
                        ConnectorKindButton(title: item.title, symbol: item.symbol,
                                            selected: focus == item) { focus = item }
                    }
                }
                .padding(3)
                .background(Theme.bgOverlay.opacity(0.62), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                Spacer(minLength: Theme.Space.s8)
                Text("\(count) 项")
                    .font(Theme.Font.microMedium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: Theme.Space.s8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(searchFocused ? Theme.Ink.claude : Theme.textSecondary)
                TextField("搜索名称、平台或包含的 Skill", text: $search)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.bodySmall)
                    .focused($searchFocused)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.s12)
            .frame(height: 38)
            .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(searchFocused ? Theme.claude.opacity(0.7) : Theme.hairline,
                                  lineWidth: searchFocused ? 1.5 : 1)
            }
            if focus != .local {
                HStack(spacing: Theme.Space.s6) {
                    platformChip(nil, title: "全部平台")
                    ForEach(ConnectorPlatform.allCases) { item in
                        platformChip(item, title: item.title)
                    }
                    Spacer()
                    if !projectPath.isEmpty {
                        Button("清除项目") { projectPath = "" }
                            .buttonStyle(.plain)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Ink.claude)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.s24)
        .padding(.bottom, Theme.Space.s12)
    }

    private func platformChip(_ item: ConnectorPlatform?, title: String) -> some View {
        let selected = platform == item
        return Button { platform = item } label: {
            Text(title)
                .font(selected ? Theme.Font.microSemibold : Theme.Font.micro)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(selected ? Theme.cardSurface : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Theme.hairline : Color.clear))
        }
        .buttonStyle(.plain)
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
        VStack(spacing: Theme.Space.s12) {
            Image(systemName: focus.symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.Ink.claude)
                .frame(width: 52, height: 52)
                .background(Theme.claude.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            Text(search.isEmpty ? "这里还没有\(focus.title)" : "没有匹配的卡片")
                .font(Theme.Font.chromeEmph)
            Text(projectPath.isEmpty ? "选择项目后，还会带上项目里的配置。" : "换一个平台或清掉搜索再看。")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .tile()
    }

    private var loadingState: some View {
        VStack(spacing: Theme.Space.s12) {
            OrbitLoader(size: 42, caption: "", spinning: true)
            Text("正在读取本机清单").font(Theme.Font.chromeEmph)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .tile()
    }

    private func messageBanner(_ message: String, symbol: String, tint: Color, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.s10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(message).font(Theme.Font.caption).lineLimit(2)
            Spacer()
            Button("关闭", action: onDismiss).buttonStyle(.plain).font(Theme.Font.caption)
        }
        .padding(Theme.Space.s12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
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

    private var tint: Color {
        switch record.platforms.first {
        case .claude: return Theme.Ink.claude
        case .codex: return Theme.Ink.codex
        case .cursor: return Theme.Ink.cursor
        case nil: return Theme.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        GlyphWell(name: record.kind.symbol, tint: tint, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name)
                                .font(Theme.Font.chromeEmph)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(record.kind == .skill ? "Skill" : record.kind.title)
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 4)
                        status
                    }
                    HStack(spacing: 4) {
                        ForEach(record.platforms) { item in
                            Text(item.title)
                                .font(Theme.Font.microMedium)
                                .foregroundStyle(platformTint(item))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(platformTint(item).opacity(0.10), in: Capsule())
                        }
                        Text(record.scope)
                            .font(Theme.Font.micro)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 22)
                    Text(blurb)
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看详情")
            Spacer(minLength: 0)
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 176, maxHeight: 176, alignment: .topLeading)
        .tile()
        .overlay(alignment: .top) {
            Capsule().fill(tint).frame(width: 28, height: 3).padding(.top, 1)
                .allowsHitTesting(false)
        }
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
}

private struct ConnectorKindButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(selected ? Theme.Font.chromeEmph : Theme.Font.chrome)
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.s10)
            .frame(height: 30)
            .background(selected ? Theme.cardSurface : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.pressable)
    }
}

private struct LocalCLICard: View {
    let cli: LocalCLIRecord
    let relatedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                GlyphWell(name: "terminal", tint: Theme.Ink.claude, size: 32)
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
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 176, maxHeight: 176, alignment: .topLeading)
        .tile()
        .overlay(alignment: .top) {
            Capsule().fill(Theme.Ink.claude).frame(width: 28, height: 3).padding(.top, 1)
                .allowsHitTesting(false)
        }
    }
}

private struct ConnectorUtilityButtonModifier: ViewModifier {
    let accented: Bool
    func body(content: Content) -> some View {
        content
            .font(Theme.Font.microSemibold)
            .foregroundStyle(accented ? Theme.Ink.claude : Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(accented ? Theme.claude.opacity(0.10) : Theme.bgOverlay,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(accented ? Theme.claude.opacity(0.22) : Theme.hairline)
                    .allowsHitTesting(false)
            }
    }
}

private extension View {
    func connectorUtilityButton(accented: Bool = false) -> some View {
        modifier(ConnectorUtilityButtonModifier(accented: accented))
    }
}
