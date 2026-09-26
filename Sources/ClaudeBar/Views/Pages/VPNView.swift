import SwiftUI
import AppKit

/// VPN 代理页：状态条、实时速率带、开关、订阅、无缝节点马赛克、日志。
/// 节点格等宽铺满、格间 1px 发丝线，不留自适应网格的右侧空槽。
struct VPNView: View {
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var store = VpnSubscriptionStore.shared
    @ObservedObject private var prefs = AppPreferences.shared

    @State private var testingAll = false
    @State private var groupOrder: [VpnGroup] = []
    @State private var selectedGroup: String?
    @State private var filePreview = VpnProfilePreview()
    @State private var previewGroupName: String?
    @State private var mosaicWidth: CGFloat = 720
    @State private var portDraft = ""
    @State private var logsOpen = false
    @FocusState private var portFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s12) {
                PageTitle(title: "VPN")
                overview
                VpnSubscriptionSection()
                nodeGroup
                logGroup
            }
            .padding(Theme.Space.s16)
        }
        .background(Theme.bgPrimary)
        .onAppear {
            portDraft = String(prefs.vpnMixedPort)
            if store.browsingID == nil { store.browsingID = store.activeID }
            reloadFilePreview()
            refreshGroupOrder()
            if selectedGroup == nil {
                selectedGroup = manager.primaryGroup?.name ?? groupOrder.first?.name
            }
        }
        .onChange(of: store.browsingID) { _, _ in reloadFilePreview() }
        .onChange(of: prefs.vpnMixedPort) { _, v in portDraft = String(v) }
        .onChange(of: manager.groups) { _, _ in
            refreshGroupOrder()
            if let selectedGroup, groupOrder.contains(where: { $0.name == selectedGroup }) { return }
            selectedGroup = manager.primaryGroup?.name ?? groupOrder.first?.name
        }
        .onChange(of: manager.isRunning) { _, on in
            if on { Task { await VpnNetProbe.shared.refreshIP() } }
            else { VpnNetProbe.shared.reset() }
        }
        // Port squatter: the core was not started because something else owns
        // the port. Naming the occupant is the whole point — "启动超时" left
        // the user with nothing to act on.
        //
        // Two exits, and neither of them is "kill the other app": ClaudeBar
        // reaps only its own core binary, so the user either frees the port or
        // points the proxy at a different one. The second button does the
        // obvious half of that for them.
        .alert("端口被占用，未启动代理", isPresented: portConflictBinding, presenting: manager.portConflict) { conflict in
            if conflict.port == prefs.vpnMixedPort {
                Button("换个端口") {
                    applySuggestedPort()
                    manager.portConflict = nil
                    manager.retryStart()
                }
            }
            Button("好") { manager.portConflict = nil }
        } message: { conflict in
            Text(portConflictMessage(conflict))
        }
    }

    // MARK: Compact overview (status + access + probes + subscription)

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            overviewHeader
            if manager.isRunning, manager.livePath.count >= 2 {
                HairlineDivider()
                Text(manager.livePath.joined(separator: " › "))
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Theme.Space.s12)
                    .padding(.vertical, 5)
                    .help("当前出站路径")
            }
            HairlineDivider()
            VPNTrafficStrip()
            HairlineDivider()
            VPNProbeRow()
            if case .failed(let msg) = manager.state {
                HairlineDivider()
                errorLine(msg)
            }
            if let err = store.errorMessage {
                HairlineDivider()
                errorLine(err)
            }
            if manager.state == .missingCore {
                HairlineDivider()
                coreMissingHint
                    .padding(Theme.Space.s8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    private var overviewHeader: some View {
        HStack(spacing: Theme.Space.s8) {
            if manager.state == .starting {
                OrbitLoader(size: 22, caption: "", spinning: true)
            } else {
                GlyphWell(name: statusIcon, tint: statusColor, size: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(statusHeadline)
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textPrimary)
                Text(statusSubline)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
            }
            if let node = manager.liveLeafName, isEffectivelyOn {
                Text(node)
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.Ink.claude)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.claude.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .help("当前出口")
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                AppGlyph(name: "number", size: 10)
                    .foregroundColor(Theme.textTertiary())
                TextField("7890", text: $portDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.captionMono)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                    .focused($portFocused)
                    .onSubmit { commitPort() }
                    .onChange(of: portFocused) { _, on in
                        if !on { commitPort() }
                    }
            }
            flagChip("系统代理", icon: "macwindow", isOn: $prefs.vpnSystemProxyEnabled) {
                syncSystemProxy()
            }
            flagChip("TUN", icon: "water.waves", isOn: $prefs.vpnTunEnabled) {
                if manager.isRunning { manager.reloadConfig() }
            }
            flagChip("局域网", icon: "wifi", isOn: $prefs.vpnAllowLan) {
                if manager.isRunning { manager.reloadConfig() }
            }
            SparkleCta(
                title: isEffectivelyOn ? "停止" : "启动",
                spinning: manager.state == .starting,
                kind: isEffectivelyOn ? .stop : .go
            ) {
                if isEffectivelyOn {
                    prefs.vpnEnabled = false
                } else {
                    prefs.vpnEnabled = true
                    prefs.vpnSystemProxyEnabled = true
                }
                manager.syncRuntime()
                syncSystemProxy()
            }
            .disabled(manager.state == .missingCore)
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s8)
    }

    /// Drives the port-conflict alert from `manager.portConflict`.
    private var portConflictBinding: Binding<Bool> {
        Binding(get: { manager.portConflict != nil },
                set: { if !$0 { manager.portConflict = nil } })
    }

    /// Move the mixed port to the first free port above the current one and
    /// apply it, so the caller can retry immediately.
    ///
    /// Only ever called for the *mixed* port: that one is ours to choose. The
    /// controller port is fixed on both sides of the app, so a conflict there
    /// is reported but never auto-worked-around.
    private func applySuggestedPort() {
        var candidate = prefs.vpnMixedPort + 1
        while candidate < 65_535 {
            if VpnManager.isPortFree(candidate) { break }
            candidate += 1
        }
        guard candidate < 65_535 else { return }
        prefs.vpnMixedPort = candidate
        portDraft = String(candidate)
        // Whatever picked the old port (including our own guard loop) must
        // follow, or the browser/CLI traffic still points at the dead one.
        syncSystemProxy()
    }

    /// What to tell the user: which port, who holds it, and what their options
    /// are. ClaudeBar deliberately does not offer to kill the occupant — see
    /// `VpnManager.portConflict` — so the wording points at the port field and
    /// the other app instead of promising something it will not do.
    private func portConflictMessage(_ conflict: VpnManager.PortConflict) -> String {
        var lines: [String] = []
        if let owner = conflict.owner {
            lines.append("端口 \(conflict.port) 已被「\(owner)」占用，内核未启动。")
        } else {
            lines.append("端口 \(conflict.port) 已被占用，内核未启动。")
        }
        if conflict.isOurOwnCore {
            lines.append("占用者是 ClaudeBar 自己上一次留下的内核，通常几秒内会被回收 —— 稍后重试即可。")
        } else if conflict.port == prefs.vpnMixedPort {
            lines.append("请退出占用该端口的代理软件，或在上面的端口框里换成另一个端口。")
        } else {
            lines.append("这是内核的控制端口。请退出占用它的代理软件（Clash Verge / ClashX 等）。")
        }
        return lines.joined(separator: "\n\n")
    }

    private func flagChip(_ title: String, icon: String, isOn: Binding<Bool>,
                          onChange: @escaping () -> Void) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            onChange()
        } label: {
            HStack(spacing: 4) {
                AppGlyph(name: icon, size: 10)
                Text(title)
                    .font(Theme.Font.micro)
            }
            .foregroundColor(isOn.wrappedValue ? Theme.claude : Theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(isOn.wrappedValue ? Theme.claude.opacity(0.14) : Theme.cardFill(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(isOn.wrappedValue ? Theme.claude.opacity(0.45) : Theme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.pressable)
        .help(title)
    }

    private func commitPort() {
        let next = Int(portDraft.filter(\.isNumber)) ?? prefs.vpnMixedPort
        let clamped = min(max(next, 1024), 65535)
        portDraft = String(clamped)
        guard clamped != prefs.vpnMixedPort else { return }
        prefs.vpnMixedPort = clamped
        if manager.isRunning { manager.reloadConfig() }
        syncSystemProxy()
    }

    private var coreMissingHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("未找到 mihomo。放到 \(FilePaths.vpnCoreBin.path)")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
                .lineLimit(2)
            Button("打开目录") { NSWorkspace.shared.open(FilePaths.vpnDir) }
                .adaptiveGlassButton()
        }
    }

    private func errorLine(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            AppGlyph(name: "exclamationmark.triangle.fill", size: 11)
                .foregroundColor(Theme.Ink.error)
            Text(msg)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.Ink.error)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s6)
    }

    // MARK: Node mosaic

    private var nodeGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: Theme.Space.s8) {
                sectionLabel(viewingLive ? "节点" : "节点预览", icon: "square.grid.2x2")
                if let name = browsedSubscription?.name {
                    Text(name)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if viewingLive, let group = currentGroup {
                    Button {
                        Task {
                            testingAll = true
                            await manager.testGroupDelay(group: group.name)
                            testingAll = false
                        }
                    } label: {
                        ZStack {
                            Text("测速")
                                .opacity(testingAll ? 0 : 1)
                            if testingAll {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                        .frame(width: 52, height: 22)
                    }
                    .adaptiveGlassButton()
                    .disabled(testingAll || !manager.testingNodes.isEmpty)
                    .help("和 Clash Verge 一样，用 http://cp.cloudflare.com/generate_204，超时 10 秒。超时表示这条节点连不上测试地址。")
                }
            }

            if viewingLive {
                if manager.groups.isEmpty {
                    emptyPanel("当前订阅没有可选分组。", icon: "square.grid.2x2")
                } else {
                    liveNodeCard
                }
            } else if filePreview.groups.isEmpty && filePreview.proxyNames.isEmpty {
                emptyPanel("这份订阅里还没有节点。点卡片上的刷新再看。", icon: "square.grid.2x2")
            } else {
                previewNodeCard
            }
        }
    }

    private var liveNodeCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            groupTabs
            mosaic
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    private var previewNodeCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(browsedSubscription?.id == store.activeID
                 ? "内核没在跑，这是配置里的节点。点「启动」后才能测速和切换出口。"
                 : "只是查看。点「使用」才会把内核切到这份订阅。")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(previewGroups) { group in
                        let viewing = group.name == (previewGroupName ?? previewGroups.first?.name)
                        Button { previewGroupName = group.name } label: {
                            Text(group.name)
                                .font(Theme.Font.caption)
                                .foregroundColor(viewing ? Theme.textPrimary : Theme.textSecondary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                        .strokeBorder(viewing ? Theme.hairline : Color.clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            let nodes = previewGroups.first { $0.name == (previewGroupName ?? previewGroups.first?.name) }?.nodes ?? []
            if nodes.isEmpty {
                StandbyEmptyState(label: "此分组没有节点。", symbol: "globe",
                                  tint: Theme.textSecondary)
            } else {
                LazyVGrid(columns: Theme.GridLayout.mosaic(columns: mosaicColumnCount), spacing: 1) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(Theme.Font.bodySmall)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .background(Theme.base1.opacity(0.72))
                    }
                }
                .padding(1)
                .background(Theme.hairline)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            }
        }
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
        .background {
            WidthProbe()
                .onPreferenceChange(MosaicWidthKey.self) {
                    if abs(mosaicWidth - $0) > 0.5 { mosaicWidth = $0 }
                }
        }
    }

    private var groupTabs: some View {
        let live = Set(manager.livePath)
        let names = orderedGroups.map(\.name)
        // Two different facts, two different marks. The previous shape encoded
        // both in one tint: `active` made the label blue *and* filled a capsule,
        // `viewing` only drew a border, so "the core is exiting through this
        // group" and "I am looking at this group" were the same colour at two
        // strengths. The dot is the live fact; the sliding pill is the browses
        // fact — and it is the same pill the connector and provider filters use.
        return ScrollView(.horizontal, showsIndicators: false) {
            SegmentedCapsule(items: names,
                             selection: currentGroup?.name ?? names.first ?? "",
                             title: { $0 },
                             tint: Theme.Ink.claude,
                             dotted: { live.contains($0) },
                             onSelect: { selectedGroup = $0 })
        }
    }

    private var mosaic: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidthProbe()
                .onPreferenceChange(MosaicWidthKey.self) {
                    if abs(mosaicWidth - $0) > 0.5 { mosaicWidth = $0 }
                }
            if let group = currentGroup {
                let nodes = group.nodes
                let proxiesByName = Dictionary(manager.proxies.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                let liveNodes = Set(manager.livePath)
                let testingNodes = manager.testingNodes
                if nodes.isEmpty {
                    StandbyEmptyState(label: "此分组没有节点。", symbol: "globe",
                                      tint: Theme.textSecondary)
                        .padding(.vertical, Theme.Space.s12)
                } else {
                    LazyVGrid(columns: Theme.GridLayout.mosaic(columns: mosaicColumnCount), spacing: 1) {
                        // Keyed by index: node names repeat inside a group in
                        // real subscriptions, and `id: \.self` made those
                        // duplicates a SwiftUI identity collision, so the whole
                        // grid churned on every update while warning about it.
                        ForEach(Array(nodes.enumerated()), id: \.offset) { _, name in
                            nodeCell(group: group, nodeName: name,
                                     proxy: proxiesByName[name],
                                     live: liveNodes.contains(name),
                                     testing: testingNodes.contains(name))
                        }
                    }
                    .padding(1)
                    .background(Theme.hairline)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                }
            }
        }
    }

    private func nodeCell(group: VpnGroup, nodeName: String,
                          proxy: VpnProxy?, live: Bool, testing: Bool) -> some View {
        let remembered = nodeName == group.current && !live
        return HStack(spacing: 0) {
            Button {
                Task { _ = await manager.selectNode(group: group.name, node: nodeName) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(nodeName)
                            .font(Theme.Font.bodySmall)
                            .foregroundColor(live ? Theme.Ink.claude : Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if live {
                            AppGlyph(name: "checkmark", size: 10)
                                .foregroundColor(Theme.Ink.claude)
                        }
                    }
                    Text(live ? "使用中" : (remembered ? "本组记忆" : nodeMeta(proxy)))
                        .font(Theme.Font.micro)
                        .foregroundColor(live ? Theme.claude : Theme.textTertiary())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help(live ? "当前出口" : "切换出口到 \(nodeName)")

            delayControl(nodeName: nodeName, delay: proxy?.delay, testing: testing)
                .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(live ? Theme.claude.opacity(0.16) : Theme.base1.opacity(0.72))
        .contextMenu {
            Button("测速此节点") { testOne(nodeName) }
        }
    }

    private func delayControl(nodeName: String, delay: Int?, testing: Bool) -> some View {
        Button {
            testOne(nodeName)
        } label: {
            ZStack {
                if testing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(Theme.claude)
                } else if let delay, delay == 0 {
                    Text("超时")
                        .foregroundColor(Theme.Ink.error)
                } else if let delay {
                    Text("\(min(delay, 9999))")
                        .rollingNumber()
                        .foregroundColor(delayColor(delay))
                } else {
                    Text("测")
                        .foregroundColor(Theme.textTertiary())
                }
            }
            .font(.system(.caption, design: .monospaced).monospacedDigit())
            .frame(width: 40, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(testingAll || !manager.testingNodes.isEmpty)
            .help(delay == 0
                  ? "该节点连不通（内核测 generate_204 超时）。不是订阅链接本身失效，可换节点。"
                  : "测速此节点")
    }

    /// Fire-and-forget: the manager's own `testingNodes` set drives the
    /// spinner, so a test redraws only the cells that carry it — the page no
    /// longer holds a `testingNode` @State that re-rendered the whole
    /// 1000-line body three times per test.
    private func testOne(_ node: String) {
        Task { _ = await manager.testDelay(node: node) }
    }

    private func emptyPanel(_ text: String, icon: String) -> some View {
        HStack(spacing: Theme.Space.s8) {
            AppGlyph(name: icon, size: 12)
                .foregroundColor(Theme.textTertiary())
            Text(text)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    // MARK: Logs

    private var logGroup: some View {
        DisclosureGroup(isExpanded: $logsOpen) {
            VpnLogConsole()
        } label: {
            sectionLabel("日志", icon: "text.alignleft")
                .overlay(alignment: .trailing) {
                    if !logsOpen { CollapsedLogBadge() }
                }
        }
        // The console is where a failure is diagnosed, so open it when the core
        // is not running properly. A page that is *already open* when the
        // failure lands is the common case — `waitUntilReady` gives up 15 s
        // after the spawn, and the termination handler can fire at any time —
        // so this cannot be `onAppear` alone: the page stays mounted and
        // `onAppear` never runs again.
        .onAppear { if case .failed = manager.state { logsOpen = true } }
        .onChange(of: manager.state) { _, state in
            if case .failed = state { logsOpen = true }
        }
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String, icon: String) -> some View {
        SectionHeader(icon: icon, title: text, tint: Theme.claude)
    }

    private var mosaicColumnCount: Int {
        let minCell: CGFloat = 156
        return max(3, Int((mosaicWidth + 1) / (minCell + 1)))
    }

    /// Group order, computed once per `manager.groups` change.
    ///
    /// The old computed property sorted from `body`, and its comparator called
    /// `preferred.firstIndex(of:)` *and* `localizedStandardCompare` on every
    /// comparison — with a few hundred groups in a subscription that is a lot
    /// of `O(n log n)` string collation per render, on a page that re-renders
    /// for every node test and every traffic probe.
    private func refreshGroupOrder() {
        let preferred = ["主代理"] + VpnManager.primaryGroupNames + ["♻️ 自动选择"]
        var rank: [String: Int] = [:]
        for (i, name) in preferred.enumerated() where rank[name] == nil { rank[name] = i }
        groupOrder = manager.groups.sorted { a, b in
            let ia = rank[a.name] ?? 1_000
            let ib = rank[b.name] ?? 1_000
            if ia != ib { return ia < ib }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private var orderedGroups: [VpnGroup] { groupOrder }

    private var browsedSubscription: VpnSubscription? {
        let id = store.browsingID ?? store.activeID
        return store.subscriptions.first { $0.id == id }
    }

    /// Live mosaic only for the subscription the core is actually running.
    private var viewingLive: Bool {
        browsedSubscription?.id == store.activeID && manager.isRunning
    }

    private var previewGroups: [VpnProfilePreview.Group] {
        if !filePreview.groups.isEmpty { return filePreview.groups }
        guard !filePreview.proxyNames.isEmpty else { return [] }
        return [VpnProfilePreview.Group(name: "节点", nodes: filePreview.proxyNames)]
    }

    private func reloadFilePreview() {
        guard let id = store.browsingID ?? store.activeID else {
            filePreview = VpnProfilePreview()
            return
        }
        // Off the main thread: this runs from `onAppear`, i.e. inside the page
        // switch transaction, and the profile can be a few hundred KB.
        Task {
            let preview = await store.previewAsync(for: id)
            // The user may have browsed to another card while the read was in
            // flight; the newer call owns `filePreview` then.
            guard id == (store.browsingID ?? store.activeID) else { return }
            filePreview = preview
            let names = preview.groups.map(\.name)
            if previewGroupName == nil || !names.contains(previewGroupName ?? "") {
                previewGroupName = names.first
            }
        }
    }

    private var currentGroup: VpnGroup? {
        if let selectedGroup, let g = manager.groups.first(where: { $0.name == selectedGroup }) {
            return g
        }
        return orderedGroups.first
    }

    private func nodeMeta(_ proxy: VpnProxy?) -> String {
        guard let proxy else { return "" }
        if !proxy.server.isEmpty {
            return proxy.port > 0 ? "\(proxy.server):\(proxy.port)" : proxy.server
        }
        return proxy.type
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay < 200 { return Theme.statusSuccess }
        if delay < 500 { return Theme.claudeHi }
        return Theme.statusError
    }
    private var isEffectivelyOn: Bool {
        manager.isRunning || manager.state == .starting
    }

    private var statusColor: Color {
        switch manager.state {
        case .running: return Theme.external
        case .starting: return Theme.claudeHi
        case .idle, .missingCore: return Theme.statusIdle
        case .failed: return Theme.statusError
        }
    }

    private var statusIcon: String {
        switch manager.state {
        case .running: return "bolt.fill"
        case .starting: return "hourglass"
        case .idle: return "power"
        case .missingCore: return "questionmark"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusHeadline: String {
        switch manager.state {
        case .idle: return "未启用"
        case .missingCore: return "缺少 mihomo 内核"
        case .starting: return "启动中…"
        case .running: return "运行中"
        case .failed: return "异常"
        }
    }

    private var statusSubline: String {
        switch manager.state {
        case .idle: return "开启后接管系统流量"
        case .missingCore: return "请放置 mihomo 二进制"
        case .starting: return "等待内核响应…"
        case .running:
            return "127.0.0.1:\(prefs.vpnMixedPort)"
        case .failed(let msg): return msg
        }
    }

    private func syncSystemProxy() {
        if prefs.vpnSystemProxyEnabled && manager.isRunning {
            VpnSystemProxyController.applySystemProxy(port: prefs.vpnMixedPort)
            if prefs.vpnGuardEnabled { VpnProxyGuard.shared.start() }
        } else {
            VpnProxyGuard.shared.stop()
            VpnSystemProxyController.clearSystemProxyAsync()
        }
    }
}

// MARK: - Isolated traffic strip (observes rates, not the mosaic)

private struct VPNTrafficStrip: View {
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var rates = VpnLiveRates.shared

    var body: some View {
        HStack(spacing: Theme.Space.s16) {
            VpnSpeedChart(history: rates.speedHistory)
                .frame(width: 148, height: 44)
                .opacity(manager.isRunning ? 1 : 0.35)
            compactStat("↓", VpnFormat.rate(rates.speedDown), Theme.external, width: 86,
                        help: "内核 mixed-port 实时下行，不是订阅额度。为 0 表示此刻没有连接在传数据。")
            compactStat("↑", VpnFormat.rate(rates.speedUp), Theme.claudeHi, width: 86,
                        help: "内核 mixed-port 实时上行，不是订阅额度。")
            compactStat("↓累计", VpnFormat.bytes(rates.traffic.totalDown), Theme.textPrimary, width: 64)
            compactStat("↑累计", VpnFormat.bytes(rates.traffic.totalUp), Theme.textPrimary, width: 64)
            compactStat("连接", VpnFormat.connections(rates.traffic.activeConnections), Theme.textPrimary, width: 36)
            Text(manager.coreVersion.map { "mihomo \($0)" } ?? " ")
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
                .frame(minWidth: 88, alignment: .trailing)
                .opacity(manager.coreVersion == nil ? 0 : 1)
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s8)
        .opacity(manager.isRunning ? 1 : 0.45)
    }

    private func compactStat(_ label: String, _ value: String, _ tint: Color, width: CGFloat,
                             help: String? = nil) -> some View {
        let body = VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
            RollingNumberText(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(tint)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
        return Group {
            if let help { body.help(help) } else { body }
        }
    }
}

/// Site probes + 测速 + exit IP. Isolated so delay ticks do not rebuild the mosaic.
/// 测速 keeps a fixed 52pt slot, and the site row lives in a horizontal
/// `ScrollView` that takes the remaining width (`maxWidth: .infinity`) — so a
/// change in the exit-IP string shortens the scroller's viewport instead of
/// shoving the probes sideways, and 测速 ↔ spinner swaps nothing but its own
/// 52pt box. Neither side is a fixed-width slot in code; the layout is stable
/// because the *scroller* absorbs all the slack.
private struct VPNProbeRow: View {
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var probe = VpnNetProbe.shared

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s8) {
            Button {
                Task { await probe.testAll() }
            } label: {
                ZStack {
                    Text("测速")
                        .opacity(probe.testingAll ? 0 : 1)
                    if probe.testingAll {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(width: 52, height: 22)
            }
            .adaptiveGlassButton()
            .disabled(!manager.isRunning || probe.testingAll)
            .help("测试站点连通性")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: Theme.Space.s6) {
                    ForEach(probe.sites) { site in
                        Button {
                            Task { await probe.test(id: site.id) }
                        } label: {
                            HStack(spacing: 4) {
                                Text(site.name)
                                    .foregroundColor(Theme.textSecondary)
                                Text(siteDelayLabel(site.delay))
                                    .rollingNumber()
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(siteDelayColor(site.delay))
                                    .frame(width: 36, alignment: .trailing)
                            }
                            .font(Theme.Font.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Theme.cardFill(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                        }
                        .buttonStyle(.pressable)
                        .disabled(!manager.isRunning || probe.testingAll)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                Task { await probe.refreshIP() }
            } label: {
                HStack(spacing: 6) {
                    if probe.ipLoading {
                        ProgressView().controlSize(.mini)
                    }
                    if let info = probe.ipInfo {
                        Text(countryFlag(info.countryCode))
                        Text(info.ip)
                            .font(Theme.Font.captionMono)
                            .textSelection(.enabled)
                    } else {
                        Text(probe.ipError ?? "出口 IP")
                            .foregroundColor(Theme.textTertiary())
                    }
                }
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!manager.isRunning)
            .help(ipHelp)
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s8)
    }

    private var ipHelp: String {
        if let info = probe.ipInfo {
            let geo = [info.country, info.city, info.isp].filter { !$0.isEmpty }.joined(separator: " · ")
            return geo.isEmpty ? "刷新出口 IP" : geo
        }
        return "刷新出口 IP"
    }

    private func siteDelayLabel(_ delay: Int?) -> String {
        switch delay {
        case nil: return "—"
        case -1: return "…"
        case -2, 0: return "超时"
        case let ms?: return String(format: "%4d", min(max(ms, 0), 9999))
        }
    }

    private func siteDelayColor(_ delay: Int?) -> Color {
        switch delay {
        case nil, -1: return Theme.textTertiary()
        case -2, 0: return Theme.statusError
        case let ms? where ms < 200: return Theme.statusSuccess
        case let ms? where ms < 800: return Theme.claudeHi
        default: return Theme.statusError
        }
    }

    private func countryFlag(_ code: String) -> String {
        let cc = code.uppercased()
        guard cc.count == 2,
              cc.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) else {
            return "🌐"
        }
        return String(cc.unicodeScalars.map { Character(UnicodeScalar(127397 + $0.value)!) })
    }
}

// MARK: - Width probe

private struct MosaicWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 720
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WidthProbe: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: MosaicWidthKey.self, value: geo.size.width)
        }
        .frame(height: 0)
    }
}

// MARK: - Speed chart

/// Dual sparkline with Catmull-Rom smoothing. Latest sample is on the right.
struct VpnSpeedChart: View {
    let history: [(down: Int64, up: Int64)]

    private var peak: Int64 {
        max(history.map(\.down).max() ?? 0, history.map(\.up).max() ?? 0, 1)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // Computed once: `peak` maps the whole history twice, and it used
            // to be read from inside `points` — twice per series, two series,
            // at the traffic stream's 4 Hz flush rate.
            let peak = peak
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.cardFill(0.04))
                grid(w: w, h: h)
                if history.count >= 2 {
                    series(\.up, peak: peak, stroke: Theme.claudeHi, fill: Theme.claudeHi, w: w, h: h)
                    series(\.down, peak: peak, stroke: Theme.external, fill: Theme.external, w: w, h: h)
                }
            }
        }
    }

    private func grid(w: CGFloat, h: CGFloat) -> some View {
        Path { p in
            for i in 1...2 {
                let y = h * CGFloat(i) / 3
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: w, y: y))
            }
        }
        .stroke(Theme.hairline.opacity(0.45), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
    }

    private func series(_ key: KeyPath<(down: Int64, up: Int64), Int64>, peak: Int64,
                        stroke: Color, fill: Color, w: CGFloat, h: CGFloat) -> some View {
        let pts = points(key, peak: peak, w: w, h: h)
        return ZStack {
            smooth(pts, closeTo: h)
                .fill(LinearGradient(
                    colors: [fill.opacity(0.28), fill.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom))
            smooth(pts, closeTo: nil)
                .stroke(stroke, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
    }

    private func points(_ key: KeyPath<(down: Int64, up: Int64), Int64>, peak: Int64,
                        w: CGFloat, h: CGFloat) -> [CGPoint] {
        let n = history.count
        let slots = max(60, n)
        let stepX = w / CGFloat(slots - 1)
        return history.enumerated().map { i, sample in
            let x = w - CGFloat(n - 1 - i) * stepX
            let frac = CGFloat(sample[keyPath: key]) / CGFloat(peak)
            return CGPoint(x: x, y: max(1, h * (1 - frac * 0.86) - 1.5))
        }
    }

    private func smooth(_ points: [CGPoint], closeTo baseline: CGFloat?) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        if let base = baseline {
            path.move(to: CGPoint(x: first.x, y: base))
            path.addLine(to: first)
        } else {
            path.move(to: first)
        }
        if points.count == 2 {
            path.addLine(to: points[1])
        } else {
            for i in 0..<(points.count - 1) {
                let p0 = points[max(0, i - 1)]
                let p1 = points[i]
                let p2 = points[i + 1]
                let p3 = points[min(points.count - 1, i + 2)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
        }
        if let base = baseline, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: base))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Log console

/// The collapsed console's trailing badge.
///
/// Its own view on purpose: `VpnLogStore` grows on every core line — a node
/// delay test logs several lines per node, so a 26-node 测速 writes dozens —
/// and observing it from `VPNView` re-evaluated the whole page (header,
/// subscription list, mosaic and console) twice per line, for a badge that is
/// not even rendered once the console is open.
///
/// It reports the *state*, not a line count: the ring buffer caps at 500, so a
/// three-line failure and a 500-line one both ended up reading "500 行" and the
/// count could not say how bad things were.
private struct CollapsedLogBadge: View {
    @ObservedObject private var logStore = VpnLogStore.shared
    @ObservedObject private var manager = VpnManager.shared

    var body: some View {
        let failed: Bool = { if case .failed = manager.state { return true }; return false }()
        let lines = logStore.lines.count
        // Nothing worth announcing: a healthy core that has simply been up for
        // a while is not news.
        if failed || lines > 0 {
            StatusPill(label: failed ? "启动失败 · 查看日志" : "\(lines) 行",
                       tint: failed ? Theme.statusError : Theme.statusWarning,
                       ink: failed ? Theme.Ink.error : Theme.Ink.warning)
        }
    }
}

private struct VpnLogConsole: View {
    @ObservedObject private var logStore = VpnLogStore.shared
    private var lines: [String] { logStore.lines }
    @State private var copied = false
    /// Auto-follow is a *convenience*, not a cage: it used to scroll to the
    /// newest line unconditionally, so reading back through the log was
    /// impossible — every new core line yanked the view to the bottom. Track
    /// whether the user is parked at the end and only follow from there.
    @State private var followTail = true

    private static let tailTolerance: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s6) {
            HStack {
                if lines.isEmpty {
                    StandbyEmptyState(label: "暂无日志", symbol: "doc.text",
                                      tint: Theme.textSecondary)
                } else if !followTail {
                    Button {
                        followTail = true
                    } label: {
                        Label("回到最新", systemImage: "arrow.down.to.line")
                            .font(Theme.Font.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.Ink.claude)
                }
                Spacer()
                Button(copied ? "已复制" : "复制全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .adaptiveGlassButton()
                .disabled(lines.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(Theme.Font.captionMono)
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                                .contextMenu {
                                    Button("复制该行") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(line, forType: .string)
                                    }
                                }
                        }
                    }
                    .padding(Theme.Space.s8)
                }
                .frame(height: 140)
                .background(Theme.textTertiary().opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let distanceFromBottom = geo.contentSize.height
                        + geo.contentInsets.bottom
                        - (geo.contentOffset.y + geo.containerSize.height)
                    return distanceFromBottom <= Self.tailTolerance
                } action: { _, atTail in
                    followTail = atTail
                }
                .onChange(of: lines.count) { _, count in
                    guard followTail, count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
                .onChange(of: followTail) { _, follow in
                    guard follow, !lines.isEmpty else { return }
                    withAnimation(Theme.Animation.smooth) {
                        proxy.scrollTo(lines.count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }
}
