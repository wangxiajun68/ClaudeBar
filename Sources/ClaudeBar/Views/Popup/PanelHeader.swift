import SwiftUI

/// Compact popup HUD. ClaudeBar is opened to switch a model or a proxy —
/// not to read Mac specs (those already live in the meter cards).
///
/// Row 1: live facts (sessions · local proxy · rates) + refresh.
/// Row 2: three switchers — Claude Code, Codex, VPN — each a popover.
struct PanelHeader: View {
    @ProviderState([.configuration, .sessions]) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    @ObservedObject private var prefs = AppPreferences.shared
    @ObservedObject private var vpn = VpnManager.shared
    var panel: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow
            EqualRowGrid(spacing: 1, minColumnWidth: 0, fixedColumns: 3) {
                HeaderSwitchChip(
                    eyebrow: "CC",
                    title: ccModel,
                    subtitle: ccVendor,
                    tint: Theme.claude, ink: Theme.Ink.claude
                ) { _ in
                    ModelSwitchList(kind: .claude, panel: panel)
                }
                HeaderSwitchChip(
                    eyebrow: "Codex",
                    title: codexModel,
                    subtitle: codexSubtitle,
                    quotaWindows: codexStore.quotaWindows,
                    tint: Theme.codex, ink: Theme.Ink.codex,
                    quotaLoading: codexStore.quotaLoading,
                    refreshQuota: { codexStore.refreshQuota() }
                ) { _ in
                    ModelSwitchList(kind: .codex, panel: panel)
                }
                HeaderSwitchChip(
                    eyebrow: "VPN",
                    title: vpnTitle,
                    subtitle: vpnSubtitle,
                    tint: vpn.isRunning ? Theme.chartGreen : Theme.textSecondary,
                    ink: vpn.isRunning ? Theme.Ink.success : Theme.textSecondary
                ) { isPresented in
                    VpnNodePickerPanel(isPresented: isPresented)
                }
            }
            .background(Theme.hairline)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
        }
    }

    // MARK: Status row

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(runningCount > 0 ? Theme.chartGreen : Theme.Ink.idle)
                .frame(width: 6, height: 6)
            Text(runningCount > 0 ? "\(runningCount) 会话" : "空闲")
                .font(Theme.Font.section)
                .foregroundColor(Theme.textPrimary)
            statusDot
            Text(proxyFact)
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(codexStore.proxyRunning ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            if vpn.isRunning {
                statusDot
                HeaderTrafficRates()
            }
            Spacer(minLength: 4)
            Button {
                NotificationCenter.default.post(name: .showMainWindow, object: nil)
            } label: {
                GlyphWell(name: "macwindow", tint: Theme.textSecondary, size: 20)
            }
            .buttonStyle(.plain)
            .help("打开主窗口")
            .accessibilityLabel("打开主窗口")
            Button {
                providerStore.refresh()
                panel.showFeedback("已刷新")
            } label: {
                GlyphWell(name: "arrow.clockwise", tint: Theme.textSecondary, size: 20)
            }
            .buttonStyle(.plain)
            .help("刷新")
            .accessibilityLabel("刷新")
        }
    }

    private var statusDot: some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundColor(Theme.textTertiary())
    }

    // MARK: Facts

    private var runningCount: Int {
        providerStore.busySessionCount
            + providerStore.activeCursorCount
            + providerStore.activeExternalCount
    }

    private var proxyFact: String {
        if codexStore.proxyRunning { return "本地 \(prefs.codexProxyPort)" }
        if prefs.codexRoutingEnabled { return "本地 未监听" }
        return "本地 关"
    }

    private var ccModel: String {
        providerStore.activeProvider?.activeModel?.name ?? "未配置"
    }

    private var ccVendor: String {
        providerStore.activeProvider?.name ?? "添加供应商"
    }

    private var codexModel: String {
        codexStore.activeProvider?.activeModel?.name ?? "未配置"
    }

    private var codexVendor: String {
        codexStore.activeProvider?.name ?? "添加供应商"
    }

    /// Rate-limit windows under the model name. Vendor stays when the
    /// ChatGPT usage call has not returned yet.
    private var codexSubtitle: String {
        let windows = codexStore.quotaWindows
        if windows.isEmpty {
            if codexStore.quotaLoading { return "额度…" }
            return codexStore.quotaNote ?? codexVendor
        }
        return windows.map { "\($0.label)已用 \($0.usedText)" }.joined(separator: " · ")
    }

    private var vpnTitle: String {
        if vpn.state == .starting { return "启动中…" }
        if vpn.isRunning { return vpn.liveLeafName ?? "代理" }
        return "未启用"
    }

    private var vpnSubtitle: String {
        if vpn.isRunning, let delay = vpn.resolvedDelay(vpn.liveLeafName) {
            return VpnDelayStyle.text(delay)
        }
        if vpn.isRunning { return "127.0.0.1:\(prefs.vpnMixedPort)" }
        return "点击启动"
    }
}

// MARK: - Switch chip

/// One cell of the header switcher row. Eyebrow + current value + popover.
private struct HeaderSwitchChip<Popover: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var quotaWindows: [CodexQuotaWindow] = []
    /// Chip accent — also drives the eyebrow, which is text.
    var tint: Color
    /// Readable counterpart of `tint` for the eyebrow; see `StatusPill`.
    var ink: Color? = nil
    var quotaLoading = false
    var refreshQuota: (() -> Void)? = nil
    @ViewBuilder var popover: (Binding<Bool>) -> Popover

    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { open.toggle() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Text(eyebrow).font(Theme.Font.eyebrow).foregroundColor(ink ?? tint)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold)).foregroundColor(Theme.textTertiary())
                    }
                    Text(title).font(Theme.Font.section).foregroundColor(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    if refreshQuota == nil { subtitleLabel }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.uiversePress)
            .popover(isPresented: $open, arrowEdge: .bottom) { popover($open) }
            .help("\(eyebrow)：\(title) · \(subtitle)")

            if let refreshQuota {
                Button(action: refreshQuota) {
                    HStack(spacing: 4) {
                        if quotaLoading {
                            ProgressView().controlSize(.mini)
                            Text("刷新额度…").font(Theme.Font.meta).foregroundColor(Theme.textSecondary)
                        } else if quotaWindows.isEmpty {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            subtitleLabel
                        } else {
                            CodexQuotaGauges(windows: quotaWindows)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(quotaLoading)
                .help(quotaLoading ? "正在获取 Codex 额度" : "点击刷新 Codex 额度")
                .accessibilityLabel(quotaLoading ? "正在刷新 Codex 额度" : "刷新 Codex 额度")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.cardSurface)
    }

    private var subtitleLabel: some View {
        Text(subtitle).font(Theme.Font.meta).foregroundColor(Theme.textSecondary)
            .lineLimit(1).truncationMode(.middle)
    }

}

// MARK: - Model switch list

private enum ModelSwitchKind { case claude, codex }

private struct ModelSwitchList: View {
    @ProviderState([.configuration, .sessions]) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    let kind: ModelSwitchKind
    var panel: PanelState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kind == .claude ? "切换 Claude Code" : "切换 Codex")
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if rows.isEmpty {
                Button("去添加供应商") {
                    dismiss()
                    NotificationCenter.default.post(name: .showMainWindow, object: nil)
                    NotificationCenter.default.post(name: .openProvidersEditor, object: nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.Ink.claude)
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            if row.isHeader {
                                Text(row.title)
                                    .font(Theme.Font.micro)
                                    .foregroundColor(Theme.textTertiary())
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 3)
                            } else {
                                Button {
                                    activate(row)
                                    panel.showFeedback("\(kind == .claude ? "CC" : "Codex") · \(row.title)")
                                    dismiss()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: row.active ? "checkmark" : "")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(Theme.Ink.claude)
                                            .frame(width: 12)
                                        Text(row.title)
                                            .font(Theme.Font.caption)
                                            .foregroundColor(row.active ? Theme.claude : Theme.textPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(row.active ? Theme.claude.opacity(0.12) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 6)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 240)
    }

    private struct Row: Identifiable {
        let id: String
        var isHeader: Bool
        var title: String
        var providerID: UUID
        var modelID: UUID
        var active: Bool
    }

    private var rows: [Row] {
        switch kind {
        case .claude:
            return providerStore.providers.flatMap { p -> [Row] in
                let header = Row(id: "h-\(p.id)", isHeader: true, title: p.name,
                                 providerID: p.id, modelID: p.id, active: false)
                let models = p.models.map { m in
                    Row(id: "\(p.id)-\(m.id)", isHeader: false, title: m.name,
                        providerID: p.id, modelID: m.id,
                        active: p.id == providerStore.activeProviderID
                            && m.name.caseInsensitiveCompare(providerStore.currentEnv?.ANTHROPIC_MODEL ?? "") == .orderedSame)
                }
                return [header] + models
            }
        case .codex:
            return codexStore.providers.flatMap { p -> [Row] in
                let header = Row(id: "h-\(p.id)", isHeader: true, title: p.name,
                                 providerID: p.id, modelID: p.id, active: false)
                let models = p.models.map { m in
                    let active = p.id == codexStore.activeProviderID
                        && (p.activeModelID == m.id
                            || (p.activeModelID == nil && m.id == p.models.first?.id))
                    return Row(id: "\(p.id)-\(m.id)", isHeader: false, title: m.name,
                               providerID: p.id, modelID: m.id, active: active)
                }
                return [header] + models
            }
        }
    }

    private func activate(_ row: Row) {
        switch kind {
        case .claude:
            providerStore.activateModel(providerID: row.providerID, modelID: row.modelID)
        case .codex:
            codexStore.activate(providerID: row.providerID, modelID: row.modelID)
        }
    }
}

/// Only the small rate label observes the traffic stream.
private struct HeaderTrafficRates: View {
    @ObservedObject private var rates = VpnLiveRates.shared

    var body: some View {
        Text("↓\(VpnFormat.compact(rates.speedDown)) ↑\(VpnFormat.compact(rates.speedUp))")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Theme.textSecondary)
            .lineLimit(1)
    }
}
