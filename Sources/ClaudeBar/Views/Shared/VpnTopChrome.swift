import SwiftUI

/// The popup's VPN picker: the node list with per-node delay, plus the
/// start/stop action.
///
/// Presented by `PanelHeader`'s VPN chip, which owns its own label (the running
/// node and its delay) — so this view is only the panel behind it. A companion
/// `VpnNodeMenu` used to wrap the same panel in its own bordered chip for the
/// unmounted `VpnPowerCard`; both were deleted, and this is the one VPN
/// control that ships. `VpnDelayStyle` below is shared with the chip.
struct VpnNodePickerPanel: View {
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var prefs = AppPreferences.shared
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleProxy) {
                HStack(spacing: 8) {
                    AppGlyph(name: manager.isRunning ? "stop.fill" : "play.fill", size: 11)
                    Text(manager.isRunning ? "停止代理" : "启动代理")
                        .font(Theme.Font.bodySmall)
                    Spacer(minLength: 0)
                }
                .foregroundColor(manager.isRunning ? Theme.statusError : Theme.claude)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(manager.state == .missingCore || manager.state == .starting)

            HairlineDivider()

            if manager.isRunning, let group = manager.primaryGroup, !group.nodes.isEmpty {
                Text("选择节点")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // Hoisted out of the row loop. `livePath` walks the primary
                // group and the whole selector chain, and `resolvedDelay`
                // walks it again — both are computed properties, so reading
                // them per row made one popover render O(nodes × groups).
                // Neither set changes between two rows of the same render.
                let livePath = Set(manager.livePath)
                let testingNodes = manager.testingNodes
                // `proxies` carries every node's delay, so the fallback is only
                // for a name the controller has no row for — which is what
                // `resolvedDelay` would answer too. Leaving it verbatim meant
                // the *hoist* was defeated for exactly the rows it was written
                // for, since `resolvedDelay` walks the whole selector chain per
                // row.
                // `[String: Int?]` would make every subscript a double
                // optional; `compactMapValues` keeps the tested rows and lets
                // an untested one read as "no measurement".
                let delays = Dictionary(manager.proxies.map { ($0.name, $0.delay) },
                                        uniquingKeysWith: { first, _ in first })
                    .compactMapValues { $0 }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        // Enumerated, not `id: \.self`: node names repeat inside
                        // a real subscription's group, and duplicate identity
                        // makes SwiftUI churn the whole list — the same fix
                        // `VPNView` documents for its grid.
                        ForEach(Array(group.nodes.enumerated()), id: \.offset) { _, name in
                            nodeRow(group: group.name, name: name,
                                    live: livePath.contains(name),
                                    delay: delays[name],
                                    testing: testingNodes.contains(name))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 360)
            } else {
                Button("打开 VPN 页") {
                    isPresented = false
                    NotificationCenter.default.post(.showMainWindow(page: .vpn))
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.Ink.claude)
                .padding(12)
            }
        }
        .frame(width: 268)
        .padding(.top, 4)
    }

    private func nodeRow(group: String, name: String, live: Bool, delay: Int?, testing: Bool) -> some View {
        Button {
            Task { _ = await manager.selectNode(group: group, node: name) }
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Group {
                    if live {
                        AppGlyph(name: "checkmark", size: 9)
                            .foregroundColor(Theme.Ink.claude)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 12, height: 12)
                Text(name)
                    .font(Theme.Font.caption)
                    .foregroundColor(live ? Theme.claude : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                delayCell(delay: delay, testing: testing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(live ? Theme.claude.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func delayCell(delay: Int?, testing: Bool) -> some View {
        Group {
            if testing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(Theme.claude)
                    .scaleEffect(0.7)
            } else {
                Text(VpnDelayStyle.text(delay))
                    .rollingNumber()
                    .font(.system(size: 11, design: .monospaced).weight(.medium))
                    .foregroundColor(VpnDelayStyle.color(delay))
            }
        }
        .frame(width: 52, alignment: .trailing)
    }

    private func toggleProxy() {
        if manager.isRunning {
            prefs.vpnEnabled = false
            manager.syncRuntime()
            VpnProxyGuard.shared.stop()
            VpnSystemProxyController.clearSystemProxyAsync()
            isPresented = false
        } else {
            prefs.vpnEnabled = true
            prefs.vpnSystemProxyEnabled = true
            manager.syncRuntime()
            // The VPN page does this in the same place (`syncSystemProxy`), and
            // it is not redundant with the apply that `waitUntilReady` performs
            // once the core answers: the reason to re-apply *here* is the
            // crash-orphan case. A force-quit inside `clearSystemProxyAsync`'s
            // window leaves macOS still pointing at a mixed port nothing owns,
            // and `syncRuntime` → `startCore` only spawns a process — it cannot
            // repair a stale system-proxy entry that was never cleared.
            VpnSystemProxyController.applySystemProxy(port: prefs.vpnMixedPort)
            if prefs.vpnGuardEnabled { VpnProxyGuard.shared.start() }
        }
    }
}

enum VpnDelayStyle {
    static func text(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        if ms <= 0 { return "超时" }
        return "\(ms)ms"
    }

    static func color(_ ms: Int?) -> Color {
        guard let ms else { return Theme.textTertiary() }
        if ms <= 0 { return Theme.statusError }
        if ms < 200 { return Theme.statusSuccess }
        if ms < 800 { return Theme.claudeHi }
        return Theme.statusError
    }
}


// MARK: - Compact VPN pill (row 1)

/// The popup's VPN readout, moved up to the status row so the header switcher
/// row can carry a third *quota* family (Cursor) instead of a third control.
///
/// It is the same reading the old VPN chip showed — the live node and its delay,
/// or the port it is listening on — compressed to one line for the dense top
/// strip. The picker itself (`VpnNodePickerPanel`) has not moved; this pill is
/// its presentational trigger.
struct VpnStatusPill: View {
    @ObservedObject private var vpn = VpnManager.shared
    /// 0 = full (status row), 1 = tight. The status row has room for the node
    /// name; a caller that is itself cramped can shrink it to dot + delay.
    var compact = false

    var body: some View {
        Button {
            NotificationCenter.default.post(.showMainWindow(page: .vpn))
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(vpn.isRunning ? Theme.chartGreen : Theme.Ink.idle)
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(vpn.isRunning ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var label: String {
        switch vpn.state {
        case .starting: return "VPN 启动中…"
        case .missingCore: return "VPN 未装内核"
        default: break
        }
        if vpn.isRunning {
            let leaf = vpn.liveLeafName ?? "代理"
            if compact { return VpnDelayStyle.text(vpn.resolvedDelay(leaf)) }
            if let delay = vpn.resolvedDelay(leaf) {
                return "\(leaf) · \(VpnDelayStyle.text(delay))"
            }
            return leaf
        }
        return "VPN 未启用"
    }

    private var help: String {
        if vpn.isRunning {
            let leaf = vpn.liveLeafName ?? "代理"
            return "VPN · \(leaf) · \(VpnDelayStyle.text(vpn.resolvedDelay(leaf))) · 点击打开 VPN 页"
        }
        return "VPN 未启用 · 点击打开 VPN 页"
    }
}

// MARK: - Cursor allowance picker

/// The panel behind the popup's Cursor chip: the monthly plan, the two pools
/// inside it (**Cursor Models** / **Other Models**), and the Grok Bot weekly
/// window (a **separate** quota) underneath — with the account's plan name as
/// the subtitle.
///
/// The monthly row is the plan's own bar (`includedSpend / limit`, Cursor's
/// shared allowance) and the two pool rows are the percentages beneath it, so
/// the panel answers both "how much of the month is gone" and "which pool is
/// eating it". The Grok Bot window stays its own bar: it resets weekly and its
/// percentage is independent, so folding it into either pool would be wrong.
struct CursorUsagePanel: View {
    @ObservedObject private var store = CursorUsageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HairlineDivider()
            content
        }
        .frame(width: 262)
        .onAppear { store.refresh() }
    }

    private var header: some View {
        HStack(spacing: 7) {
            ProductBrandMark(brand: .cursor, well: false).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Cursor 额度").font(Theme.Font.bodySmall).foregroundColor(Theme.textPrimary)
                Text(planName).font(Theme.Font.micro).foregroundColor(Theme.textTertiary())
            }
            Spacer(minLength: 4)
            Button { store.refresh(manual: true) } label: {
                if store.loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(store.loading)
            .help("刷新 Cursor 额度")
            .accessibilityLabel("刷新 Cursor 额度")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        if store.plan == nil && store.grok == nil {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.note ?? (store.loading ? "正在读取额度…" : "暂无 Cursor 额度"))
                    .font(Theme.Font.bodySmall).foregroundColor(Theme.textSecondary)
                Text("需要在 Cursor 中登录（本地读取 state.vscdb）")
                    .font(Theme.Font.micro).foregroundColor(Theme.textTertiary())
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let plan = store.plan { planRow(plan) }
                if let grok = store.grok { grokRow(grok) }
                if let message = store.plan?.displayMessage, !message.isEmpty {
                    Text(message)
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.Ink.warning)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// The monthly plan: a wide bar over the shared allowance, the money, and
    /// the two named pools beneath it.
    ///
    /// The bar is `includedSpend / limit` — Cursor's **single** monthly money
    /// limit; the two pools are percentages of it, not money limits of their
    /// own (the server sends one `limit` + `includedSpend`, never two). Naming
    /// them "Cursor Models" / "Other Models" is the point of the row: it is
    /// which pool is being consumed, which the old "API / Auto" abbreviations
    /// did not say.
    private func planRow(_ plan: CursorUsageFetcher.PlanUsage) -> some View {
        let used = plan.usedFraction
        let tint = used >= 0.9 ? Theme.Ink.error : (used >= 0.75 ? Theme.Ink.warning : Theme.Ink.success)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("月度额度").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                Spacer(minLength: 4)
                RollingNumberText("\(Int((used * 100).rounded()))%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
            }
            ContextBar(ratio: used, height: 5, tint: tint)
            if let spend = plan.spendText {
                Text(spend).font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                if let cursorModels = plan.autoPercentUsed {
                    subMetric("Cursor Models", cursorModels)
                }
                if let otherModels = plan.apiPercentUsed {
                    subMetric("Other Models", otherModels)
                }
                if let reset = plan.resetsAt {
                    Text("\(Self.shortDate(reset)) 重置")
                        .font(Theme.Font.micro).foregroundColor(Theme.textTertiary())
                }
            }
        }
    }

    private func grokRow(_ grok: CursorUsageFetcher.GrokUsage) -> some View {
        let used = grok.usedPercent
        let tint = used >= 90 ? Theme.Ink.error : (used >= 75 ? Theme.Ink.warning : Theme.Ink.success)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Grok Bot 周额度").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                Spacer(minLength: 4)
                RollingNumberText(String(format: "%.2f%%", used))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
            }
            ContextBar(ratio: used / 100, height: 5, tint: tint)
            if let reset = grok.nextReset {
                Text("\(Self.shortDate(reset)) 重置")
                    .font(Theme.Font.micro).foregroundColor(Theme.textTertiary())
            }
        }
    }

    private func subMetric(_ label: String, _ percent: Double) -> some View {
        HStack(spacing: 3) {
            Text(label).font(Theme.Font.micro).foregroundColor(Theme.textTertiary())
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Theme.textSecondary)
        }
    }

    /// The account's plan tier, when Cursor reported one ("Pro", "Ultra", …).
    private var planName: String {
        if let name = store.grok?.planName, !name.isEmpty { return name }
        return "Cursor 账户"
    }

    /// `10月3日 20:31` — the reset moment, date-qualified because both windows
    /// are days away and a bare clock would read as "today".
    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(date) { formatter.dateFormat = "HH:mm" }
        else { formatter.dateFormat = "M月d日" }
        return formatter.string(from: date)
    }
}
