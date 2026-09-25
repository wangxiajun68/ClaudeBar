import SwiftUI

/// Custom popover (not `Menu`) so delay sits in a fixed trailing column
/// and can be colored. Native menus cannot align or tint per-field.
struct VpnNodeMenu: View {
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var prefs = AppPreferences.shared
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                AppGlyph(name: "globe", size: 11)
                    .foregroundColor(manager.isRunning ? Theme.claude : Theme.textSecondary)
                Text(labelText)
                    .font(Theme.Font.micro)
                    .foregroundColor(manager.isRunning ? Theme.claude : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 88, alignment: .leading)
                if manager.isRunning, let delay = manager.resolvedDelay(manager.liveLeafName) {
                    Text(VpnDelayStyle.text(delay))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(VpnDelayStyle.color(delay))
                }
                AppGlyph(name: "chevron.down", size: 8)
                    .foregroundColor(Theme.textTertiary())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(manager.isRunning ? Theme.claude.opacity(0.14) : Theme.cardFill(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(manager.isRunning ? Theme.claude.opacity(0.4) : Theme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(manager.isRunning ? "停止代理或切换节点（与 VPN 页同步）" : "启动代理并选择节点")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VpnNodePickerPanel(isPresented: $open)
        }
        .onAppear {
            if manager.isRunning { Task { await manager.refreshProxies() } }
        }
    }

    private var labelText: String {
        if manager.state == .starting { return "启动中…" }
        if manager.isRunning { return manager.liveLeafName ?? "代理" }
        return "启动代理"
    }
}

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

