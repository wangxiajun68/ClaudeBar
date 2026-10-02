import SwiftUI
import AppKit

/// VPN workspace: runtime and subscriptions on the left, full-height traffic on the right.
struct VPNView: View {
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var store = VpnSubscriptionStore.shared
    @ObservedObject private var prefs = AppPreferences.shared

    @State private var testingAll = false
    @State private var groupOrder: [VpnGroup] = []
    @State private var selectedGroup: String?
    @State private var filePreview = VpnProfilePreview()
    @State private var previewGroupName: String?
    @State private var nodeQuery = ""
    @State private var switchingNode: String?
    @State private var nodeError: String?
    @State private var settingsOpen = false
    @State private var compactPage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var portDraft = ""
    @State private var logsOpen = false
    @State private var nodesOpen = false
    @FocusState private var portFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                VStack(alignment: .leading, spacing: Theme.Space.s12) {
                    HStack {
                        PageTitle(title: "VPN")
                        Spacer()
                        Button { logsOpen.toggle() } label: {
                            AppGlyph(name: "text.alignleft", size: 16)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(Theme.textSecondary)
                        .help("内核日志")
                        .popover(isPresented: $logsOpen) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("内核日志").font(Theme.Font.body)
                                VpnLogConsole()
                            }
                            .padding(16)
                            .frame(width: 640, height: 400)
                        }
                    }
                    let wide = geometry.size.width >= 900
                    let workspaceWidth = max(0, geometry.size.width - 32)
                    if !wide {
                        Picker("工作区", selection: $compactPage) {
                            Text("流量日志").tag(0)
                            Text("订阅管理").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    // Keep both workspaces alive when switching the compact page.
                    HStack(alignment: .top, spacing: wide ? Theme.Space.s12 : 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                                overview
                                VpnSubscriptionSection(onBrowse: { nodesOpen = true })
                                    .padding(Theme.Space.s12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .vpnSurface()
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .frame(width: wide ? min(380, max(340, (workspaceWidth - Theme.Space.s12) * 0.28))
                               : (compactPage == 1 ? workspaceWidth : 0))
                        .clipped()
                        .opacity(wide || compactPage == 1 ? 1 : 0)
                        .allowsHitTesting(wide || compactPage == 1)
                        .disabled(!wide && compactPage != 1)
                        .accessibilityHidden(!wide && compactPage != 1)
                        trafficGroup(visible: wide || compactPage == 0)
                            .frame(width: wide ? nil : (compactPage == 0 ? workspaceWidth : 0))
                            .frame(maxWidth: wide ? .infinity : nil, maxHeight: .infinity)
                            .clipped()
                            .opacity(wide || compactPage == 0 ? 1 : 0)
                            .allowsHitTesting(wide || compactPage == 0)
                            .disabled(!wide && compactPage != 0)
                            .accessibilityHidden(!wide && compactPage != 0)
                            .layoutPriority(1)
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(!nodesOpen)
                .accessibilityHidden(nodesOpen)

                if nodesOpen {
                    Button { closeNodes() } label: { Color.black.opacity(0.14) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭节点面板")
                    nodeGroup
                        .frame(width: min(720, max(280, geometry.size.width - 32)))
                        .frame(maxHeight: .infinity)
                        .background(Theme.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))
                        .shadow(color: .black.opacity(0.12), radius: 24, x: -8, y: 8)
                        .padding(12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: nodesOpen)
        }
        .scrollHoverGate()
        .background(Theme.bgPrimary)
        .foregroundColor(Theme.textPrimary)
        .onAppear {
            portDraft = String(prefs.vpnMixedPort)
            if store.browsingID == nil { store.browsingID = store.activeID }
            reloadFilePreview()
            if case .failed = manager.state { logsOpen = true }
            refreshGroupOrder()
            if selectedGroup == nil {
                selectedGroup = manager.primaryGroup?.name ?? groupOrder.first?.name
            }
        }
        .onChange(of: store.browsingID) { _, _ in
            reloadFilePreview()
            nodeQuery = ""
            nodeError = nil
        }
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
        .onChange(of: manager.state) { _, state in
            if case .failed = state { logsOpen = true }
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
            HairlineDivider()
            VPNTrafficStrip(compact: true)
            HairlineDivider()
            Button { nodesOpen = true } label: {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    activeNodeSummary
                    HStack(spacing: Theme.Space.s8) {
                        AppGlyph(name: "square.grid.2x2", size: 15)
                            .foregroundColor(Theme.Ink.claude)
                        Text("浏览节点")
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.textSecondary)
                        Spacer(minLength: 8)
                        AppGlyph(name: "chevron.right", size: 10)
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, Theme.Space.s12)
                .padding(.vertical, Theme.Space.s8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看订阅分组、选择节点和测速")
            HairlineDivider()
            VPNProbeRow()
            if case .failed(let msg) = manager.state {
                HairlineDivider()
                errorLine(msg)
            }
            if manager.state == .missingCore {
                HairlineDivider()
                coreMissingHint
                    .padding(Theme.Space.s8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vpnSurface()
    }

    private var overviewHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s8) {
                overviewStatus
                overviewControls
            }
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                overviewStatus
                overviewControls
            }
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s8)
    }

    private var overviewStatus: some View {
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
            Spacer(minLength: 0)
        }
    }

    private var overviewControls: some View {
        HStack(spacing: Theme.Space.s8) {
            Toggle("系统代理", isOn: $prefs.vpnSystemProxyEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(Theme.Font.caption)
                .onChange(of: prefs.vpnSystemProxyEnabled) { _, _ in syncSystemProxy() }
            Button { settingsOpen.toggle() } label: {
                AppGlyph(name: "slider.horizontal.3", size: 16)
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.textSecondary)
            .help("端口与网络设置")
            .popover(isPresented: $settingsOpen) { networkSettings }
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
        .fixedSize(horizontal: true, vertical: false)
    }

    private var networkSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("网络设置").font(Theme.Font.body)
            HStack {
                Text("代理端口").font(Theme.Font.caption)
                Spacer()
                TextField("7890", text: $portDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.captionMono)
                    .frame(width: 80)
                    .focused($portFocused)
                    .onSubmit { commitPort() }
                    .onChange(of: portFocused) { _, focused in
                        if !focused { commitPort() }
                    }
            }
            Toggle("TUN 模式", isOn: $prefs.vpnTunEnabled)
                .onChange(of: prefs.vpnTunEnabled) { _, _ in
                    if manager.isRunning { manager.reloadConfig() }
                }
            Toggle("允许局域网连接", isOn: $prefs.vpnAllowLan)
                .onChange(of: prefs.vpnAllowLan) { _, _ in
                    if manager.isRunning { manager.reloadConfig() }
                }
            if let version = manager.coreVersion {
                Text("mihomo \(version)").font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(20)
        .frame(width: 300)
        .onDisappear { commitPort() }
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
            lines.append("请退出占用该端口的代理软件，或在网络设置里换成另一个端口。")
        } else {
            lines.append("这是内核的控制端口。请退出占用它的代理软件（Clash Verge / ClashX 等）。")
        }
        return lines.joined(separator: "\n\n")
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
            ActionButton("打开目录") { NSWorkspace.shared.open(FilePaths.vpnDir) }
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                AppGlyph(name: "square.grid.2x2", size: 20)
                    .foregroundColor(Theme.Ink.claude)
                VStack(alignment: .leading, spacing: 3) {
                    Text("节点").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(browsedSubscription?.name ?? "尚未添加订阅")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { closeNodes() } label: { AppGlyph(name: "xmark", size: 14) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("关闭节点面板")
            }
            if viewingLive {
                activeNodeSummary
            } else {
                Label("配置预览 · 启用订阅后可切换和测速", systemImage: "info.circle")
                    .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 12) {
                if viewingLive {
                    Picker("分组", selection: Binding(
                        get: { currentGroup?.name ?? "" },
                        set: { selectedGroup = $0; nodeError = nil })) {
                        ForEach(orderedGroups) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden().frame(maxWidth: 220)
                } else {
                    Picker("分组", selection: Binding(
                        get: { previewGroupName ?? previewGroups.first?.name ?? "" },
                        set: { previewGroupName = $0 })) {
                        ForEach(previewGroups) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden().frame(maxWidth: 220)
                }
                Spacer()
                Text("\(browserNodes.count) 个节点")
                    .font(Theme.Font.captionMono).foregroundColor(Theme.textSecondary)
                if viewingLive, let group = currentGroup {
                    ActionButton(testingAll ? "测速中" : "测速", tone: .neutral) {
                        Task {
                            testingAll = true
                            await manager.testGroupDelay(group: group.name)
                            testingAll = false
                        }
                    }
                    .disabled(testingAll || !manager.testingNodes.isEmpty)
                }
            }
            InstrumentSearchField(prompt: "搜索节点", text: $nodeQuery)
            if let nodeError {
                Label(nodeError, systemImage: "exclamationmark.triangle")
                    .font(Theme.Font.caption).foregroundColor(Theme.Ink.error)
            }
            HairlineDivider()
            nodeBrowserList
        }
        .padding(20)
        .foregroundColor(Theme.textPrimary)
    }

    private var browserNodes: [String] {
        if viewingLive { return currentGroup?.nodes ?? [] }
        return previewGroups.first { $0.name == (previewGroupName ?? previewGroups.first?.name) }?.nodes ?? []
    }

    private var nodeBrowserList: some View {
        let nodes = browserNodes.enumerated().filter {
            nodeQuery.isEmpty || $0.element.localizedCaseInsensitiveContains(nodeQuery)
        }
        let proxies = Dictionary(manager.proxies.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let live = Set(manager.livePath)
        return ScrollView {
            LazyVStack(spacing: 0) {
                if nodes.isEmpty {
                    StandbyEmptyState(label: nodeQuery.isEmpty ? "暂无节点" : "没有匹配的节点",
                                      symbol: "network", tint: Theme.textSecondary)
                        .padding(.vertical, 40)
                }
                ForEach(nodes, id: \.offset) { _, name in
                    if viewingLive, let group = currentGroup {
                        nodeCell(group: group, nodeName: name, proxy: proxies[name],
                                 live: live.contains(name), testing: manager.testingNodes.contains(name))
                    } else {
                        HStack(spacing: 12) {
                            AppGlyph(name: "globe", size: 14).foregroundColor(Theme.textSecondary)
                            Text(name).font(Theme.Font.bodySmall).lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .frame(height: 48)
                        .padding(.horizontal, 12)
                        .help(name)
                    }
                    HairlineDivider()
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func closeNodes() {
        nodesOpen = false
        nodeQuery = ""
        nodeError = nil
    }

    /// The line that has to survive the collapse: the node the core is exiting
    /// through, in the same chip the overview header uses. Idle, the primary
    /// group's remembered leaf stands in — "本组记忆", the same word the cell
    /// uses — and with neither (or before `/proxies` lands) the group name and
    /// the node count, so the collapsed row is never an empty band.
    private var activeNodeSummary: some View {
        HStack(spacing: Theme.Space.s8) {
            Text("当前节点")
                .font(Theme.Font.caption)
                .foregroundColor(Theme.textTertiary())
            if manager.isRunning, let leaf = manager.liveLeafName, !leaf.isEmpty {
                Text(leaf)
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.Ink.claude)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.claude.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .help("当前出口")
                VPNCurrentNodeLatency(node: leaf)
            } else if let group = currentGroup, let remembered = rememberedNode(group) {
                Text(remembered)
                    .font(Theme.Font.captionMono)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("本组记忆")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            } else if let group = currentGroup {
                Text(group.name)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                Text("共 \(group.nodes.count) 个节点")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            }
        }
    }

    /// The primary group's remembered leaf, resolved *through* nested selectors
    /// (`GLOBAL now = 主代理`, `主代理 now = 香港 A01`), so the collapsed row
    /// names a node rather than an intermediate group. Two hops, then stop: a
    /// cycle in the config must not spin here.
    private func rememberedNode(_ group: VpnGroup) -> String? {
        var name = group.current
        for _ in 0..<2 {
            guard !name.isEmpty, let next = manager.groups.first(where: { $0.name == name }) else { break }
            name = next.current
        }
        return name.isEmpty ? nil : name
    }

    private func nodeCell(group: VpnGroup, nodeName: String,
                          proxy: VpnProxy?, live: Bool, testing: Bool) -> some View {
        let remembered = nodeName == group.current && !live
        return HStack(spacing: 12) {
            AppGlyph(name: live ? "checkmark.circle.fill" : "globe", size: 16)
                .foregroundColor(live ? Theme.Ink.claude : Theme.textSecondary)
            Button {
                switchingNode = nodeName
                nodeError = nil
                Task {
                    let ok = await manager.selectNode(group: group.name, node: nodeName)
                    switchingNode = nil
                    if !ok { nodeError = "切换失败，请重试或选择其他节点" }
                }
            } label: {
                HStack(spacing: 12) {
                    Text(nodeName)
                        .font(Theme.Font.bodySmall)
                        .foregroundColor(live ? Theme.Ink.claude : Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if switchingNode == nodeName {
                        ProgressView().controlSize(.mini)
                    } else if live || remembered {
                        Text(live ? "使用中" : "本组记忆")
                            .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(switchingNode != nil)
            .help(nodeName + (live ? " · 当前出口" : " · 点击切换"))
            delayControl(nodeName: nodeName, delay: proxy?.delay, testing: testing)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(live ? Theme.claude.opacity(0.07) : Color.clear)
        .contextMenu {
            Button("测速此节点") { testOne(nodeName) }
            Button("复制节点名称") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(nodeName, forType: .string)
            }
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
                        .rollingNumber("\(min(delay, 9999))")
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

    // MARK: Logs

    /// 流量日志（域名）：内核每条 TCP 连接走出的出口与命中的规则。
    ///
    /// Its own section *and* its own store (`VpnDomainLog`, isolated like
    /// `VpnLogStore`) — a connection line must not re-evaluate this page's
    /// header, subscription list and node mosaic. Nothing here reads the store;
    /// the section observes it on its own.
    private func trafficGroup(visible: Bool) -> some View {
        VpnDomainLogSection(isVisible: visible)
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

    private func delayColor(_ delay: Int) -> Color {
        if delay < 200 { return Theme.Ink.success }
        if delay < 500 { return Theme.Ink.claude }
        return Theme.Ink.error
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
        case .running: return "shield.lefthalf.filled"
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
    var compact = false
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var rates = VpnLiveRates.shared

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    VpnSpeedChart(history: rates.speedHistory)
                        .frame(height: 24)
                        .opacity(manager.isRunning ? 1 : 0.35)
                    HStack(spacing: Theme.Space.s12) {
                        compactStat("下载", VpnFormat.rate(rates.speedDown), Theme.Ink.success, width: 80,
                                    help: "内核 mixed-port 实时下行，不是订阅额度。")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        compactStat("上传", VpnFormat.rate(rates.speedUp), Theme.Ink.claude, width: 80,
                                    help: "内核 mixed-port 实时上行，不是订阅额度。")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    totals
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.s12) {
                        liveRates
                        Spacer(minLength: Theme.Space.s12)
                        totals
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.s8) {
                        liveRates
                        totals
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s8)
        .opacity(manager.isRunning ? 1 : 0.45)
    }

    private var liveRates: some View {
        HStack(spacing: Theme.Space.s12) {
            VpnSpeedChart(history: rates.speedHistory)
                .frame(width: compact ? 80 : 120, height: 32)
                .opacity(manager.isRunning ? 1 : 0.35)
            compactStat("下载", VpnFormat.rate(rates.speedDown), Theme.Ink.success, width: compact ? 72 : 110,
                        help: "内核 mixed-port 实时下行，不是订阅额度。为 0 表示此刻没有连接在传数据。")
            compactStat("上传", VpnFormat.rate(rates.speedUp), Theme.Ink.claude, width: compact ? 72 : 110,
                        help: "内核 mixed-port 实时上行，不是订阅额度。")
        }
    }

    private var totals: some View {
        HStack(spacing: Theme.Space.s12) {
            compactStat("累计下载", VpnFormat.bytes(rates.traffic.totalDown), Theme.textPrimary, width: compact ? 72 : 110)
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            compactStat("累计上传", VpnFormat.bytes(rates.traffic.totalUp), Theme.textPrimary, width: compact ? 72 : 110)
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            compactStat("连接", VpnFormat.connections(rates.traffic.activeConnections), Theme.textPrimary, width: compact ? 48 : 64)
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)

        }
    }

    private func compactStat(_ label: String, _ value: String, _ tint: Color, width: CGFloat,
                             help: String? = nil) -> some View {
        let body = VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
            RollingNumberText(value)
                .font(.system(size: compact ? 15 : 17, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: width, alignment: .leading)
        }
        return Group {
            if let help { body.help(help) } else { body }
        }
    }
}

/// Latest measurement for the actual running leaf, isolated from live-rate ticks.
private struct VPNCurrentNodeLatency: View {
    let node: String
    @ObservedObject private var manager = VpnManager.shared

    var body: some View {
        let delay = manager.proxies.first { $0.name == node }?.delay
        let testing = manager.testingNodes.contains(node)
        HStack(spacing: 5) {
            AppGlyph(name: "speedometer", size: 12)
            Text(testing ? "测速中" : delay.map { $0 > 0 ? "\($0) ms" : "超时" } ?? "未测速")
                .font(Theme.Font.captionMono)
        }
        .foregroundColor(delay == 0 ? Theme.Ink.error : (delay != nil ? Theme.Ink.success : Theme.textSecondary))
        .fixedSize(horizontal: true, vertical: false)
        .help("当前节点最近一次测速结果；点击站点可检测实际访问延迟")
    }
}

/// Always-visible probes. Adaptive cells wrap rather than hide services offscreen.
private struct VPNProbeRow: View {
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var probe = VpnNetProbe.shared

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                AppGlyph(name: "network", size: 14)
                    .foregroundColor(Theme.textSecondary).help("连通性 · 延迟单位为毫秒")
                ForEach(probe.sites) { site in
                    siteButton(site).frame(minWidth: 70, maxWidth: .infinity)
                }
                exitIP
                testAllButton
            }
            VStack(spacing: 8) {
                HStack { exitIP; Spacer(); testAllButton }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                    ForEach(probe.sites) { site in siteButton(site) }
                }
            }
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, 8)
    }

    private var testAllButton: some View {
        Button { Task { await probe.testAll() } } label: {
            AppGlyph(name: probe.testingAll ? "hourglass" : "speedometer", size: 15)
                .frame(width: 30, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.Ink.claude)
        .disabled(!manager.isRunning || probe.testingAll)
        .accessibilityLabel(probe.testingAll ? "检测中" : "全部测速")
        .help("通过当前代理检测全部站点")
    }

    private func siteButton(_ site: VpnSiteProbe) -> some View {
        Button { Task { await probe.test(id: site.id) } } label: {
            HStack(spacing: 4) {
                Text(site.name).foregroundColor(Theme.textPrimary).lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                Text(siteDelayLabel(site.delay))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(siteDelayColor(site.delay))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!manager.isRunning || probe.testingAll || site.delay == -1)
        .help("通过当前代理检测 " + site.name + "；显示毫秒")
    }

    private var exitIP: some View {
        Button { Task { await probe.refreshIP() } } label: {
            HStack(spacing: 6) {
                if probe.ipLoading { ProgressView().controlSize(.mini) }
                AppGlyph(name: "globe", size: 12)
                Text(probe.ipInfo?.ip ?? (probe.ipError == nil ? "出口 IP" : "查询失败"))
                    .font(Theme.Font.captionMono)
            }
            .foregroundColor(Theme.textSecondary)
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!manager.isRunning || probe.ipLoading)
        .help(ipHelp)
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
        case let ms?: return String(min(max(ms, 0), 9999))
        }
    }

    private func siteDelayColor(_ delay: Int?) -> Color {
        switch delay {
        case nil, -1: return Theme.textSecondary
        case -2, 0: return Theme.Ink.error
        case let ms? where ms < 200: return Theme.Ink.success
        case let ms? where ms < 800: return Theme.Ink.claude
        default: return Theme.Ink.error
        }
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
                ActionButton(copied ? "已复制" : "复制全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
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
