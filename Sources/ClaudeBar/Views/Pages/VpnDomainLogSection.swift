import AppKit
import SwiftUI

/// VPN 页的「流量日志」：内核每条 TCP 连接的域名、命中的规则、走出的出口。
///
/// 只看 `VpnDomainLog`，所以一行日志不会让 `VPNView` 的页头、订阅卡与节点宫格
/// 重排 —— 与 `VpnLogConsole` 同一条隔离规则。右栏高度由左侧内容决定，
/// 日志在卡片内部滚动。
struct VpnDomainLogSection: View {
    @ObservedObject private var log = VpnDomainLog.shared
    @ObservedObject private var manager = VpnManager.shared

    @State private var mode: Mode = .detail
    @State private var routeFilter: RouteFilter = .all
    @State private var query = ""
    @State private var copied = false
    @State private var confirmClear = false
    @State private var followTail = true
    @State private var scrollingDetail = false
    @State private var detailAtTail = true

    /// Detail rows after the *route* filter; the search pass feeds it.
    @State private var visibleRows: [VpnDomainEntry] = []
    /// Detail rows after the *search* only. The route pill's counts have to be
    /// read from this, not from `visibleRows`: counting inside the already
    /// route-filtered set shows `0` for every pill except the selected one.
    @State private var queryRows: [VpnDomainEntry] = []
    @State private var visibleStats: [VpnDomainLogStat] = []
    /// Route tallies of `visibleRows`, folded once per recompute instead of in
    /// the body: `summaryTable` is evaluated on every publish, and three
    /// `reduce` passes plus a full per-domain fold over a 1000-row ring is not
    /// something to redo for a digit that changed in the store.
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
            SectionHeader(icon: "globe.asia.australia", title: "流量日志", tint: Theme.claude)
            toolbar
            Text(mode == .connections
                 ? "显示当前连接累计上传／下载；关闭的连接会移除。短连接可能在采样间隔内结束；进程名以内核识别结果为准。"
                 : "每行是一条新建 TCP 连接，不等同于一次请求。历史日志没有字节数；切换「实时连接」查看上传、下载与进程。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
                .fixedSize(horizontal: false, vertical: true)
            HairlineDivider()
            content
                .id("\(mode.rawValue)|\(routeFilter.rawValue)|\(query)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelCard()
        .onAppear { recompute() }
        .onChange(of: log.revision) { _, _ in recompute() }
        .onChange(of: routeFilter) { _, _ in
            followTail = true
            copied = false
            recompute()
        }
        .onChange(of: query) { _, _ in
            followTail = true
            copied = false
            recompute()
        }
        .onChange(of: mode) { _, _ in
            followTail = true
            copied = false
        }
        .alert("清空流量日志？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                log.clear()
                recompute()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空 \(log.received) 次连接记录与按域名的汇总，无法恢复。"
                 + "磁盘上的 core.log 不受影响。")
                .rollingNumber()
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s8) {
                    modePicker
                    Spacer(minLength: Theme.Space.s8)
                    logActions
                }
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    modePicker
                    HStack {
                        Spacer(minLength: 0)
                        logActions
                    }
                }
            }
            SegmentedCapsule(items: RouteFilter.allCases,
                             selection: routeFilter,
                             title: { $0.label },
                             count: { filter in
                                 if mode == .connections {
                                     return searchedConnections.filter { filter.route == nil || $0.route == filter.route }.count
                                 }
                                 return filter == .all ? queryRows.count : routeCount(filter)
                             },
                             tint: Theme.Ink.claude,
                             onSelect: { routeFilter = $0 })
            InstrumentSearchField(prompt: mode == .connections ? "域名 / 进程 / 出口 / 规则" : "域名 / 出口 / 规则", text: $query)
        }
    }

    private var modePicker: some View {
        SegmentedCapsule(items: Mode.allCases, selection: mode,
                         title: { $0.label }, tint: Theme.Ink.claude,
                         onSelect: { mode = $0 })
            .fixedSize(horizontal: true, vertical: false)
    }

    private var logActions: some View {
        HStack(spacing: Theme.Space.s8) {
            RollingNumberText("\(visibleCount) \(mode == .summary ? "域名" : "条")")
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textSecondary)
                .monospacedDigit()
            ActionButton(copied ? "已复制" : "复制") { copyVisible() }
                .disabled(visibleCount == 0)
            if mode != .connections {
                ActionButton("清空", tone: .destructive) { confirmClear = true }
                    .disabled(log.received == 0)
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
                caption: manager.isRunning
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

    /// Counted across the *search* set, not the route-filtered one — otherwise
    /// every pill but the selected one reads 0.
    private func routeCount(_ filter: RouteFilter) -> Int {
        guard let route = filter.route else { return 0 }
        return queryRows.reduce(0) { $0 + ($1.route == route ? 1 : 0) }
    }

    private var searchedConnections: [VpnDomainConnection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return log.connections.filter {
            q.isEmpty || "\($0.endpoint) \($0.process) \($0.outbound) \($0.rule)".localizedCaseInsensitiveContains(q)
        }
    }

    private var visibleConnections: [VpnDomainConnection] {
        searchedConnections.filter { routeFilter.route == nil || $0.route == routeFilter.route }
    }

    private var connectionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s8) {
                if visibleConnections.isEmpty {
                    Text(manager.isRunning ? "暂无匹配的活动连接" : "启动代理后显示活动连接")
                        .foregroundColor(Theme.textSecondary)
                }
                ForEach(visibleConnections) { connection in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.endpoint)
                            .font(Theme.Font.console)
                            .foregroundColor(routeInk(connection.route))
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleRows) { row in
                        Text(row.consoleLine)
                            .font(Theme.Font.console)
                            .foregroundColor(rowColor(row))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(row.consoleLine)
                            .id(row.id)
                            .contextMenu {
                                Button("复制该行") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(row.consoleLine, forType: .string)
                                }
                            }
                    }
                }
                .padding(Theme.Space.s8)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .frame(maxHeight: .infinity)
            .background(Theme.textTertiary().opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            // Auto-follow is a convenience, not a cage: the console used to jump
            // to the newest line unconditionally, so reading back was impossible.
            .onScrollGeometryChange(for: Bool.self) { geo in
                let distanceFromBottom = geo.contentSize.height
                    + geo.contentInsets.bottom
                    - (geo.contentOffset.y + geo.containerSize.height)
                return distanceFromBottom <= Self.tailTolerance
            } action: { _, atTail in
                detailAtTail = atTail
                if scrollingDetail { followTail = atTail }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    scrollingDetail = true
                    followTail = detailAtTail
                case .idle:
                    if scrollingDetail { followTail = detailAtTail }
                    scrollingDetail = false
                default:
                    break
                }
            }
            .onDisappear { scrollingDetail = false }
            .onChange(of: visibleRows.last?.id) { _, id in
                guard followTail, !scrollingDetail, let id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !followTail {
                    ActionButton("回到最新") {
                        followTail = true
                        if let id = visibleRows.last?.id {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                    .padding(Theme.Space.s8)
                }
            }
        }
    }

    /// `Theme.Ink.*` — the signal hues that are legible as *text* (the raw
    /// accent colours are 1.8–3.4:1 on the light canvas).
    private func rowColor(_ row: VpnDomainEntry) -> Color {
        if row.failed { return Theme.Ink.error }
        return routeInk(row.route)
    }

    // MARK: Summary

    private var summaryTable: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                summaryTableContent
                    .frame(width: max(640, geometry.size.width), alignment: .leading)
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

            let leaks = directLeaks(visibleStats)
            if !leaks.isEmpty {
                directLeakLine(leaks)
            }

            HairlineDivider()

            LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(visibleStats) { stat in
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
                .foregroundColor(Theme.textTertiary())
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
        .foregroundColor(Theme.textTertiary())
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
                .foregroundColor(Theme.textTertiary())
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

    /// The one piece of actual analysis: a service this app knows about (an LLM
    /// or a client vendor) that the core sent out **direct**. Everything else on
    /// this page reports what happened; this line reports something the user
    /// probably did not intend.
    private func directLeaks(_ stats: [VpnDomainLogStat]) -> [(service: String, hosts: [String])] {
        var byService: [String: [String]] = [:]
        var order: [String] = []
        for stat in stats where stat.direct > 0 && stat.proxied == 0 {
            for service in VpnWatchlist.matches(host: stat.host) {
                if byService[service] == nil { order.append(service) }
                byService[service, default: []].append(stat.host)
            }
        }
        return order.map { ($0, byService[$0] ?? []) }
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

    private func recompute() {
        // Called only when data, query or route changes. Revision alone is
        // insufficient: filters must work even when no new log has arrived.
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        queryRows = q.isEmpty ? log.entries : log.entries.filter { row in
            row.host.lowercased().contains(q)
                || row.outbound.lowercased().contains(q)
                || row.rule.lowercased().contains(q)
        }
        guard let route = routeFilter.route else {
            visibleRows = queryRows
            tallyRoutes()
            visibleStats = VpnDomainLog.stat(entries: visibleRows)
            return
        }
        visibleRows = queryRows.filter { $0.route == route }
        tallyRoutes()
        visibleStats = VpnDomainLog.stat(entries: visibleRows)
    }

    /// Folded once per pass, not in `body` — see the tallies' comment.
    private func tallyRoutes() {
        var proxied = 0, direct = 0, reject = 0
        for row in visibleRows {
            switch row.route {
            case .proxied: proxied += 1
            case .direct: direct += 1
            case .reject: reject += 1
            }
        }
        tallyProxied = proxied
        tallyDirect = direct
        tallyReject = reject
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

/// The collapsed section's trailing badge.
///
/// Its own view on purpose, exactly like `CollapsedLogBadge`: `VpnDomainLog`
/// publishes up to 4 Hz while a browser is loading a page, and observing it
/// from `VPNView` would re-evaluate the whole page (header, subscription list,
/// node mosaic) for a badge that is not even rendered once the section is open.
struct VPNTrafficLogBadge: View {
    @ObservedObject private var log = VpnDomainLog.shared

    var body: some View {
        if log.received > 0 {
            let failed = log.entries.reduce(0) { $0 + ($1.failed ? 1 : 0) }
            StatusPill(label: failed > 0 ? "\(log.received) 次 · \(failed) 失败" : "\(log.received) 次",
                       tint: failed > 0 ? Theme.statusWarning : Theme.statusIdle,
                       ink: failed > 0 ? Theme.Ink.warning : Theme.textSecondary)
        }
    }
}
