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
    /// `log.revision` this cache was built from — a publish that changed
    /// nothing (the store's own `clear`) is not worth another pass.
    @State private var computedRevision = -1
    private static let tailTolerance: CGFloat = 24
    /// 汇总表只画前 N 个域名；其余收口成一行。
    private static let statLimit = 10

    enum Mode: String, CaseIterable, Identifiable {
        case detail, summary
        var id: String { rawValue }
        var label: String { self == .detail ? "明细" : "汇总" }
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
            Text("内核只在 info 级记录**新建 TCP 连接**：没有字节数、不记 UDP，"
                 + "所以这里回答的是「谁走了哪条出口、命中了哪条规则」，不是「用了多少流量」。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
                .fixedSize(horizontal: false, vertical: true)
            HairlineDivider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelCard()
        .onAppear { recompute() }
        .onReceive(log.$revision) { _ in recompute() }
        .onChange(of: routeFilter) { _, _ in recompute() }
        .onChange(of: query) { _, _ in recompute() }
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
            HStack(spacing: Theme.Space.s8) {
                SegmentedCapsule(items: Mode.allCases,
                                 selection: mode,
                                 title: { $0.label },
                                 tint: Theme.Ink.claude,
                                 onSelect: { mode = $0 })
                Spacer(minLength: 0)
                RollingNumberText("\(visibleCount)")
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textTertiary())
                    .monospacedDigit()
                ActionButton(copied ? "已复制" : "复制") { copyVisible() }
                    .disabled(visibleCount == 0)
                ActionButton("清空", tone: .destructive) { confirmClear = true }
                    .disabled(log.received == 0)
            }
            SegmentedCapsule(items: RouteFilter.allCases,
                             selection: routeFilter,
                             title: { $0.label },
                             count: { $0 == .all ? queryRows.count : routeCount($0) },
                             tint: Theme.Ink.claude,
                             onSelect: { routeFilter = $0 })
            InstrumentSearchField(prompt: "域名 / 出口 / 规则", text: $query)
        }
    }

    @ViewBuilder private var content: some View {
        if log.entries.isEmpty {
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
        mode == .detail ? visibleRows.count : visibleStats.count
    }

    /// Counted across the *search* set, not the route-filtered one — otherwise
    /// every pill but the selected one reads 0.
    private func routeCount(_ filter: RouteFilter) -> Int {
        guard let route = filter.route else { return 0 }
        return queryRows.reduce(0) { $0 + ($1.route == route ? 1 : 0) }
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
                followTail = atTail
            }
            .onChange(of: visibleRows.count) { _, count in
                guard followTail, count > 0 else { return }
                proxy.scrollTo(visibleRows[count - 1].id, anchor: .bottom)
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
        ScrollView([.horizontal, .vertical]) {
            summaryTableContent
                .frame(minWidth: 560)
        }
    }

    private var summaryTableContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            HStack(spacing: Theme.Space.s16) {
                tally("共", "\(log.received) 次")
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

            LazyVStack(alignment: .leading, spacing: 1) {
                summaryHeader
                ForEach(visibleStats.prefix(Self.statLimit)) { stat in
                    summaryRow(stat)
                }
            }
            if visibleStats.count > Self.statLimit {
                let rest = visibleStats.dropFirst(Self.statLimit)
                Text("其余 \(rest.count) 个域名 · \(rest.reduce(0) { $0 + $1.hits }) 次")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .padding(.top, 4)
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
            Text("路由").frame(width: 44, alignment: .trailing)
            Text("最近").frame(width: 60, alignment: .trailing)
            Text("出口").frame(width: 180, alignment: .leading)
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
            Text("\(stat.hits)")
                .font(Theme.Font.console)
                .foregroundColor(Theme.textPrimary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            routeChip(stat)
                .frame(width: 44, alignment: .trailing)
            Text(stat.lastTimeText.isEmpty ? "—" : stat.lastTimeText)
                .font(Theme.Font.console)
                .foregroundColor(Theme.textTertiary())
                .frame(width: 60, alignment: .trailing)
            Text(stat.lastOutbound.isEmpty ? "—" : stat.lastOutbound)
                .font(Theme.Font.captionMono)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180, alignment: .leading)
            if stat.failed > 0 {
                Text("⚠ \(stat.failed)")
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.Ink.warning)
            }
        }
        .padding(.horizontal, Theme.Space.s6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.base1.opacity(0.5))
    }

    /// One micro-bar of the host's route split. A host commonly appears under
    /// two routes in one session (a rule change, a failover to DIRECT), so the
    /// bar shows the split rather than a single dominant label.
    private func routeChip(_ stat: VpnDomainLogStat) -> some View {
        let total = max(1, stat.hits)
        return HStack(spacing: 3) {
            Text(stat.lastRoute.label)
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
        guard computedRevision != log.revision || queryRows.isEmpty != log.entries.isEmpty else { return }
        computedRevision = log.revision
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
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
