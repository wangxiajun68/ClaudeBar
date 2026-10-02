import AppKit
import SwiftUI

/// VPN 页的「流量日志」：内核每条 TCP 连接的域名、命中的规则、走出的出口。
///
/// 只看 `VpnDomainLog`，所以一行日志不会让 `VPNView` 的页头、订阅卡与节点宫格
/// 重排。工作区高度由窗口决定，日志在独立视口内部滚动。
struct VpnDomainLogSection: View {
    var isVisible = true
    private let log = VpnDomainLog.shared
    @State private var historyRevision = 0
    @State private var connectionRevision = 0
    @State private var page = 0
    @State private var visibleConnections: [VpnDomainConnection] = []
    /// Mirrored, not observed wholesale: `VpnManager` also publishes
    /// `proxies`/`groups`/`testingNodes`, which delay tests rewrite on every
    /// tick, and `VPNView` keeps this section mounted while hidden. Only the
    /// running flag is read here, in the two empty-state captions.
    @State private var isRunning = VpnManager.shared.isRunning

    @State private var mode: Mode = .detail
    @State private var routeFilter: RouteFilter = .all
    @State private var query = ""
    @State private var failedOnly = false
    @State private var routeCounts: [VpnDomainRoute: Int] = [:]
    @State private var matchedCount = 0
    @State private var selectedEntry: VpnDomainEntry?
    @State private var pendingRows = 0
    @State private var lastSeenID: UInt64?
    @State private var copied = false
    @State private var confirmClear = false
    @State private var followTail = true
    @State private var scrollingDetail = false
    @State private var detailAtTail = true

    /// Immutable results from the background query; body does no historical folds.
    @State private var visibleRows: [VpnDomainEntry] = []
    @State private var visibleStats: [VpnDomainLogStat] = []
    @State private var visibleLeaks: [(service: String, hosts: [String])] = []
    @State private var tallyProxied = 0
    @State private var tallyDirect = 0
    @State private var tallyReject = 0
    private static let tailTolerance: CGFloat = 24

    enum Mode: String, CaseIterable, Identifiable {
        case detail, summary, connections
        var id: String { rawValue }
        var label: String {
            switch self {
            case .detail: return "明细"
            case .summary: return "汇总"
            case .connections: return "实时连接"
            }
        }
    }

    enum RouteFilter: String, CaseIterable, Identifiable {
        case all, proxied, direct, reject
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "全部"
            case .proxied: return "已代理"
            case .direct: return "直连"
            case .reject: return "拒绝"
            }
        }
        var route: VpnDomainRoute? {
            switch self {
            case .all: return nil
            case .proxied: return .proxied
            case .direct: return .direct
            case .reject: return .reject
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            toolbar
            HairlineDivider()
            content
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            pageControls
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vpnSurface()
        .foregroundColor(Theme.textPrimary)
        .task(id: requestKey) { await recompute() }
        // Subscribe to the active stream only. Connection counters must not
        // invalidate history, and hidden workspaces must not render either.
        .onReceive(log.$revision) { value in
            if isVisible && mode != .connections { historyRevision = value }
        }
        .onReceive(log.$connectionRevision) { value in
            if isVisible && mode == .connections { connectionRevision = value }
        }
        .onChange(of: isVisible) { _, visible in
            if visible { syncRevision() }
        }
        .onChange(of: mode) { _, _ in syncRevision() }
        .onReceive(VpnManager.shared.$state.removeDuplicates()) { isRunning = ($0 == .running) }
        .onChange(of: routeFilter) { _, _ in resetFollow() }
        .onChange(of: query) { _, _ in resetFollow() }
        .onChange(of: failedOnly) { _, _ in resetFollow() }
        .onChange(of: mode) { _, _ in resetFollow() }
        .popover(item: $selectedEntry) { entry in
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.endpoint).font(Theme.Font.body).textSelection(.enabled)
                LabeledContent("时间", value: entry.timeText)
                LabeledContent("路由", value: entry.route.label)
                LabeledContent("规则", value: entry.rule)
                LabeledContent("出口", value: entry.outbound)
                LabeledContent("结果", value: entry.failed ? "失败" : "已记录")
            }
            .font(Theme.Font.caption)
            .textSelection(.enabled)
            .padding(20).frame(width: 420)
        }
        .alert("清空流量日志？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                log.clear()
                resetFollow()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空当前保留的 \(log.entries.count) 条记录与汇总，无法恢复。"
                 + "磁盘上的 core.log 不受影响。")
                .rollingNumber("将清空当前保留的 \(log.entries.count) 条记录与汇总，无法恢复。"
                 + "磁盘上的 core.log 不受影响。")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        GeometryReader { geometry in
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    AppGlyph(name: "globe.asia.australia", size: 16)
                        .foregroundColor(Theme.Ink.claude)
                    if geometry.size.width >= 1000 {
                        Text("流量日志").font(Theme.Font.body).fixedSize()
                    }
                }
                .accessibilityLabel("流量日志")
                .help(mode == .connections
                      ? "当前活动连接的累计流量；短连接可能在采样间隔内结束。"
                      : "保留 \(log.entries.count.formatted()) / \(VpnDomainLog.limit.formatted()) 条；每条记录是一条新建连接。")
                modePicker(compact: geometry.size.width < 720)
                InstrumentSearchField(prompt: "搜索域名、出口、规则", text: $query)
                    .frame(minWidth: 100, maxWidth: .infinity)
                routePicker
                logActions
            }
            .frame(height: 36)
        }
        .frame(height: 36)
    }

    private func modePicker(compact: Bool) -> some View {
        SegmentedCapsule(items: Mode.allCases, selection: mode,
                         title: { compact && $0 == .connections ? "连接" : $0.label },
                         symbol: compact ? nil : modeSymbol,
                         tint: Theme.Ink.claude,
                         onSelect: { mode = $0 })
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("日志视图")
    }

    private func modeSymbol(_ item: Mode) -> String {
        switch item {
        case .detail: return "list.bullet.rectangle"
        case .summary: return "chart.bar.xaxis"
        case .connections: return "arrow.triangle.branch"
        }
    }

    private var routePicker: some View {
        HStack(spacing: 8) {
            Picker("路由", selection: $routeFilter) {
                ForEach(RouteFilter.allCases) { filter in
                    let count = filter.route.map { routeCounts[$0, default: 0] } ?? matchedCount
                    Text("\(filter.label) · \(count)").tag(filter)
                }
            }
            .labelsHidden().frame(width: 105)
            if mode != .connections {
                Toggle("仅失败", isOn: $failedOnly)
                    .toggleStyle(.checkbox).font(Theme.Font.caption)
                    .fixedSize()
            }
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var logActions: some View {
        HStack(spacing: 4) {
            if mode == .detail {
                Button {
                    followTail.toggle()
                    if followTail { pendingRows = 0; page = 0 }
                } label: {
                    AppGlyph(name: followTail ? "arrow.down.to.line" : "pause", size: 14)
                        .frame(width: 28, height: 32)
                }
                .buttonStyle(.plain).foregroundColor(followTail ? Theme.Ink.claude : Theme.textSecondary)
                .font(Theme.Font.caption)
                .accessibilityLabel(followTail ? "暂停跟随" : "跟随最新记录")
                .help("跟随最新记录；向上滚动自动暂停")
            }
            Button { copyVisible() } label: {
                AppGlyph(name: copied ? "checkmark" : "doc.on.doc", size: 14)
                    .foregroundColor(copied ? Theme.Ink.success : Theme.textSecondary)
                    .frame(width: 28, height: 32)
            }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "已复制" : "复制日志")
                .disabled(visibleCount == 0)
                .help("复制当前筛选结果")
            if mode != .connections {
                Menu {
                    Button("清空记录", role: .destructive) { confirmClear = true }
                        .disabled(log.received == 0)
                } label: { AppGlyph(name: "ellipsis", size: 14) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("日志操作")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private var content: some View {
        if mode == .connections {
            connectionList
        } else if log.entries.isEmpty {
            StandbyEmptyState(
                label: "暂无流量记录",
                symbol: "globe.asia.australia",
                tint: Theme.textSecondary,
                caption: isRunning
                    ? "内核已在运行。每次新建 TCP 连接会在此留下一行，浏览器里打开一个页面就会看到。"
                    : "启动代理后，经内核的 TCP 连接会显示在这里。",
                block: true)
        } else if visibleCount == 0 {
            StandbyEmptyState(label: "没有匹配的记录", symbol: "line.3.horizontal.decrease",
                              tint: Theme.textSecondary,
                              caption: "共 \(log.received) 次连接，没有一条同时满足当前的筛选与搜索词。")
                .padding(.vertical, Theme.Space.s8)
        } else if mode == .detail {
            detailConsole
        } else {
            summaryTable
        }
    }

    private var visibleCount: Int {
        switch mode {
        case .detail: return visibleRows.count
        case .summary: return visibleStats.count
        case .connections: return visibleConnections.count
        }
    }

    private var pageRange: Range<Int> {
        VpnDomainQuery.pageRange(count: visibleCount, page: page, newestFirst: mode == .detail)
    }

    private var detailPage: ArraySlice<VpnDomainEntry> { visibleRows[pageRange] }

    private var pageControls: some View {
        HStack(spacing: 12) {
            Text("\(visibleCount) 条 · 每页最多 \(VpnDomainQuery.pageSize) 条")
                .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            Spacer()
            Button(mode == .detail ? "更早" : "上一页") {
                if mode == .detail { followTail = false; page += 1 }
                else { page -= 1 }
            }
            .disabled(mode == .detail ? pageRange.lowerBound == 0 : page == 0)
            Text("\(min(page, max(0, (visibleCount - 1) / VpnDomainQuery.pageSize)) + 1) / \(max(1, (visibleCount + VpnDomainQuery.pageSize - 1) / VpnDomainQuery.pageSize))")
                .font(Theme.Font.captionMono)
            Button(mode == .detail ? "更新" : "下一页") {
                if mode == .detail { page = max(0, page - 1) }
                else { page += 1 }
            }
            .disabled(mode == .detail ? page == 0 : pageRange.upperBound == visibleCount)
        }
        .controlSize(.small)
    }

    private var connectionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s8) {
                if visibleConnections.isEmpty {
                    Text(isRunning ? "暂无匹配的活动连接" : "启动代理后显示活动连接")
                        .foregroundColor(Theme.textSecondary)
                }
                ForEach(visibleConnections[pageRange]) { connection in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.endpoint)
                            .font(Theme.Font.console)
                            .foregroundColor(Theme.textPrimary)
                            .textSelection(.enabled)
                        HStack(spacing: Theme.Space.s12) {
                            Text(connection.process)
                                .lineLimit(1)
                                .help(connection.process)
                            Spacer(minLength: 0)
                            Text("↑ " + VpnFormat.bytes(connection.upload))
                            Text("↓ " + VpnFormat.bytes(connection.download))
                        }
                        .font(Theme.Font.captionMono)
                        .foregroundColor(Theme.textPrimary)
                        Text("\(connection.route.label) · \(connection.rule) → \(connection.outbound)")
                            .font(Theme.Font.caption)
                            .foregroundColor(routeInk(connection.route))
                            .lineLimit(2)
                        HairlineDivider()
                    }
                }
            }
            .padding(Theme.Space.s8)
        }
    }

    // MARK: Detail

    private var detailConsole: some View {
        GeometryReader { geometry in
            let width = max(650, geometry.size.width)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    detailHeader.frame(width: width)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(detailPage) { row in
                                    detailRow(row).id(row.id)
                                }
                            }
                        }
                        .defaultScrollAnchor(.bottom, for: .initialOffset)
                        .onScrollGeometryChange(for: Bool.self) { geo in
                            geo.contentSize.height + geo.contentInsets.bottom
                                - (geo.contentOffset.y + geo.containerSize.height) <= Self.tailTolerance
                        } action: { _, atTail in
                            detailAtTail = atTail
                            if scrollingDetail && !atTail { followTail = false }
                        }
                        .onScrollPhaseChange { _, phase in
                            switch phase {
                            case .tracking, .interacting, .decelerating:
                                scrollingDetail = true
                            case .idle:
                                if scrollingDetail && detailAtTail && page == 0 { followTail = true }
                                scrollingDetail = false
                            default: break
                            }
                        }
                        .onDisappear { scrollingDetail = false }
                        .onChange(of: detailPage.last?.id) { _, id in
                            guard followTail, !scrollingDetail, let id else { return }
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                        .onChange(of: followTail) { _, follow in
                            if follow, let id = visibleRows.last?.id {
                                page = 0
                                pendingRows = 0
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !followTail {
                                ActionButton(pendingRows > 0 ? "\(pendingRows) 条新记录 · 回到最新" : "回到最新", tone: .neutral) {
                                    page = 0
                                    followTail = true
                                    pendingRows = 0
                                }
                                .padding(8)
                            }
                        }
                        .frame(width: width)
                    }
                }
                .frame(width: width, height: geometry.size.height)
            }
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            Text("时间").frame(width: 64, alignment: .leading)
            Text("域名").frame(maxWidth: .infinity, alignment: .leading)
            Text("路由").frame(width: 52, alignment: .leading)
            Text("出口").frame(width: 160, alignment: .leading)
            Text("结果").frame(width: 42, alignment: .trailing)
        }
        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 8).frame(height: 32)
        .background(Theme.bgSecondary)
    }

    private func detailRow(_ row: VpnDomainEntry) -> some View {
        // Text remains text: no row button or tap gesture can steal selection.
        HStack(spacing: 12) {
            Text(row.timeText).foregroundColor(Theme.textSecondary)
                .frame(width: 64, alignment: .leading)
            Text(row.endpoint).foregroundColor(Theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.route.label).foregroundColor(routeInk(row.route))
                .frame(width: 52, alignment: .leading)
            Text(row.outbound).foregroundColor(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 160, alignment: .leading)
            Button { selectedEntry = row } label: {
                AppGlyph(name: row.failed ? "exclamationmark.circle" : "ellipsis", size: 12)
                    .foregroundColor(row.failed ? Theme.Ink.error : Theme.textSecondary)
                    .frame(width: 42, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看完整连接详情")
            .accessibilityLabel(row.failed ? "失败 · 查看详情" : "查看连接详情")
        }
        .font(Theme.Font.captionMono)
        .textSelection(.enabled)
        .padding(.horizontal, 8).frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(row.id % 2 == 0 ? Theme.bgSecondary.opacity(0.65) : Color.clear)
        .help(row.consoleLine)
        .contextMenu {
            Button("复制该行") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.consoleLine, forType: .string)
            }
            Button("复制域名") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.host, forType: .string)
            }
        }
    }

    // MARK: Summary

    private var summaryTable: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                summaryTableContent
                    .frame(width: max(640, geometry.size.width), alignment: .leading)
                    .frame(minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
    }

    private var summaryTableContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            HStack(spacing: Theme.Space.s16) {
                tally("筛选结果", "\(visibleRows.count) 次")
                tally("域名", "\(visibleStats.count)")
                tally("已代理", "\(tallyProxied)", tint: Theme.Ink.claude)
                tally("直连", "\(tallyDirect)", tint: Theme.Ink.warning)
                tally("拒绝", "\(tallyReject)", tint: Theme.Ink.error)
                Spacer(minLength: 0)
            }
            .font(Theme.Font.caption)

            if !visibleLeaks.isEmpty {
                directLeakLine(visibleLeaks)
            }

            HairlineDivider()

            LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(visibleStats[pageRange]) { stat in
                        summaryRow(stat)
                    }
                } header: {
                    summaryHeader
                        .background(Theme.bgPrimary)
                }
            }
        }
    }

    private func tally(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundColor(Theme.textSecondary)
            Text(value)
                .font(Theme.Font.captionMono)
                .foregroundColor(tint ?? Theme.textPrimary)
                .monospacedDigit()
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: Theme.Space.s8) {
            Text("域名").frame(maxWidth: .infinity, alignment: .leading)
            Text("次数").frame(width: 44, alignment: .trailing)
            Text("路由").frame(width: 76, alignment: .leading)
            Text("最近").frame(width: 72, alignment: .trailing)
            Text("出口").frame(width: 180, alignment: .leading)
            Text("失败").frame(width: 44, alignment: .trailing)
        }
        .font(Theme.Font.microMono)
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, Theme.Space.s6)
        .padding(.vertical, 3)
    }

    private func summaryRow(_ stat: VpnDomainLogStat) -> some View {
        HStack(spacing: Theme.Space.s8) {
            Text(stat.host)
                .font(Theme.Font.console)
                .foregroundColor(stat.direct > 0 && stat.proxied == 0
                                 ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(stat.host)
            Text("\(stat.hits)")
                .font(Theme.Font.console)
                .foregroundColor(Theme.textPrimary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            routeChip(stat)
                .frame(width: 76, alignment: .leading)
            Text(stat.lastTimeText.isEmpty ? "—" : stat.lastTimeText)
                .font(Theme.Font.console)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 72, alignment: .trailing)
            Text(stat.lastOutbound.isEmpty ? "—" : stat.lastOutbound)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180, alignment: .leading)
                .help(stat.lastOutbound)
            Text(stat.failed > 0 ? "\(stat.failed)" : "—")
                .font(Theme.Font.captionMono)
                .foregroundColor(stat.failed > 0 ? Theme.Ink.error : Theme.textTertiary())
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.s6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.base1.opacity(0.5))
        .textSelection(.enabled)
        .contextMenu {
            Button("复制域名") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(stat.host, forType: .string)
            }
            Button("复制出口") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(stat.lastOutbound, forType: .string)
            }
        }
    }

    /// One micro-bar of the host's route split. A host commonly appears under
    /// two routes in one session (a rule change, a failover to DIRECT), so the
    /// bar shows the split rather than a single dominant label.
    private func routeChip(_ stat: VpnDomainLogStat) -> some View {
        let total = max(1, stat.hits)
        return HStack(spacing: 3) {
            Text(stat.lastRoute.label)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .font(Theme.Font.micro)
                .foregroundColor(routeInk(stat.lastRoute))
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if stat.proxied > 0 {
                        routeInk(.proxied).frame(width: geo.size.width * CGFloat(stat.proxied) / CGFloat(total))
                    }
                    if stat.direct > 0 {
                        routeInk(.direct).frame(width: geo.size.width * CGFloat(stat.direct) / CGFloat(total))
                    }
                    if stat.reject > 0 {
                        routeInk(.reject).frame(width: geo.size.width * CGFloat(stat.reject) / CGFloat(total))
                    }
                }
            }
            .frame(width: 12, height: 3)
            .clipShape(Capsule())
        }
        .help("已代理 \(stat.proxied) · 直连 \(stat.direct) · 拒绝 \(stat.reject)")
    }

    private func routeInk(_ route: VpnDomainRoute) -> Color {
        switch route {
        case .proxied: return Theme.Ink.claude
        case .direct: return Theme.Ink.warning
        case .reject: return Theme.Ink.error
        }
    }

    private func directLeakLine(_ leaks: [(service: String, hosts: [String])]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            AppGlyph(name: "exclamationmark.triangle.fill", size: 10)
                .foregroundColor(Theme.Ink.warning)
            Text("常见服务走了直连：" + leaks.map { "\($0.service)（\($0.hosts.prefix(2).joined(separator: ", "))）" }
                .joined(separator: " · "))
                .font(Theme.Font.caption)
                .foregroundColor(Theme.Ink.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("这些域名命中了直连规则。若本意是走代理，检查订阅里的分流规则。")
    }

    // MARK: Cache / actions

    private struct RequestKey: Equatable {
        let revision: Int
        let isVisible: Bool
        let mode: Mode
        let route: RouteFilter
        let query: String
        let failedOnly: Bool
        let followTail: Bool
    }

    private var requestKey: RequestKey {
        RequestKey(revision: mode == .connections ? connectionRevision : historyRevision,
                   isVisible: isVisible, mode: mode, route: routeFilter, query: query, failedOnly: failedOnly, followTail: followTail)
    }

    private func syncRevision() {
        historyRevision = log.revision
        connectionRevision = log.connectionRevision
    }

    private func resetFollow() {
        page = 0
        followTail = true
        pendingRows = 0
        lastSeenID = nil
        copied = false
    }

    private func recompute() async {
        guard isVisible else { return }
        let key = requestKey
        // Debounce typing; task identity cancels obsolete searches and page work.
        if !key.query.isEmpty {
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        if key.mode == .connections {
            let snapshot = log.connections
            let worker = Task.detached(priority: .userInitiated) {
                VpnDomainQuery.connections(snapshot, query: key.query, route: key.route.route)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, requestKey == key else { return }
            visibleConnections = result.rows
            routeCounts = result.counts
            matchedCount = result.matched
            page = min(page, max(0, (result.rows.count - 1) / VpnDomainQuery.pageSize))
            return
        }
        let entries = log.entries
        let worker = Task.detached(priority: .userInitiated) {
            VpnDomainQuery.run(entries: entries, query: key.query,
                               route: key.route.route, failedOnly: key.failedOnly,
                               summary: key.mode == .summary)
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled, requestKey == key else { return }
        if !followTail, let lastSeenID {
            pendingRows += result.rows.reduce(0) { $0 + ($1.id > lastSeenID ? 1 : 0) }
        }
        // Freeze the reading snapshot while paused, including at ring eviction.
        // Filters/clear reset lastSeenID, so they still replace the snapshot.
        if key.mode != .detail || followTail || lastSeenID == nil || entries.isEmpty {
            visibleRows = result.rows
        }
        lastSeenID = entries.last?.id
        visibleStats = result.stats
        visibleLeaks = result.leaks
        page = min(page, max(0, (visibleCount - 1) / VpnDomainQuery.pageSize))
        routeCounts = result.counts
        matchedCount = result.matched
        tallyProxied = key.route == .all || key.route == .proxied ? result.counts[.proxied, default: 0] : 0
        tallyDirect = key.route == .all || key.route == .direct ? result.counts[.direct, default: 0] : 0
        tallyReject = key.route == .all || key.route == .reject ? result.counts[.reject, default: 0] : 0
    }

    private func copyVisible() {
        let text: String
        switch mode {
        case .detail:
            text = visibleRows.map(\.consoleLine).joined(separator: "\n")
        case .connections:
            text = visibleConnections.map {
                "\($0.endpoint)\t\($0.process)\t↑ \(VpnFormat.bytes($0.upload))\t↓ \(VpnFormat.bytes($0.download))\t\($0.route.label)\t\($0.outbound)"
            }.joined(separator: "\n")
        case .summary:
            text = visibleStats.map {
                "\($0.host)\t\($0.hits)\t\($0.lastRoute.label)\t\($0.lastTimeText)\t\($0.lastOutbound)"
            }.joined(separator: "\n")
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
