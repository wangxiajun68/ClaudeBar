import SwiftUI

/// VPN summary: a regular dashboard tile, compact node controls in the popup.
struct VpnPowerCard: View {
    @ObservedObject private var manager = VpnManager.shared
    @ObservedObject private var rates = VpnLiveRates.shared
    @ObservedObject private var probe = VpnNetProbe.shared
    /// Dashboard: tap opens the VPN page. Popup keeps the node picker.
    var opensVPNPage: Bool = false

    private var starting: Bool {
        if case .starting = manager.state { return true }
        return false
    }

    var body: some View {
        if opensVPNPage {
            MetricTile(label: "VPN", value: manager.isRunning ? "已连接" : (starting ? "启动中" : "未启用"),
                       detail: manager.isRunning ? (manager.liveLeafName ?? "代理运行中") : statusLine,
                       tint: Theme.chartGreen, instrumentIcon: .vpn,
                       pill: manager.isRunning ? "↓ " + VpnFormat.rate(rates.speedDown) : "节点与网络") {
                NotificationCenter.default.post(name: .openVPNPage, object: nil)
            }
        } else {
            popupContent
        }
    }

    @ViewBuilder
    private var popupContent: some View {
        let inner = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    if starting {
                        OrbitLoader(size: 44, caption: "…", spinning: true)
                    } else {
                        InstrumentGlyph(kind: .vpn,
                                        tint: Theme.chartGreen,
                                        detailed: true,
                                        active: manager.isRunning)
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                    Text(statusLine)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if opensVPNPage {
                    VStack(alignment: .trailing, spacing: 4) {
                        StatusPill(
                            label: manager.isRunning ? "运行中" : (starting ? "启动中" : "未启用"),
                            tint: manager.isRunning ? Theme.chartGreen : (starting ? Theme.claudeHi : Theme.statusIdle),
                            ink: manager.isRunning ? Theme.Ink.success : (starting ? Theme.Ink.claude : Theme.Ink.idle)
                        )
                        if manager.isRunning {
                            RollingNumberText("↓\(VpnFormat.rate(rates.speedDown))  ↑\(VpnFormat.rate(rates.speedUp))")
                                .font(Theme.Font.tileMicroValue)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    VpnNodeMenu()
                }
            }
            if opensVPNPage, manager.isRunning {
                AuroraSparkline(
                    values: rates.speedHistory.map { Double($0.down + $0.up) },
                    tint: Theme.chartGreen,
                    live: true
                )
                .frame(height: 36)
            }
        }
        .padding(14)
        .tile()
        .onAppear {
            if manager.isRunning { Task { await probe.refreshIP() } }
        }

        if opensVPNPage {
            Button {
                NotificationCenter.default.post(name: .openVPNPage, object: nil)
            } label: {
                inner
            }
            .buttonStyle(.plain)
        } else {
            inner
        }
    }

    private var statusLine: String {
        if manager.isRunning {
            let node = manager.liveLeafName ?? "代理"
            return "\(node) · 127.0.0.1:\(AppPreferences.shared.vpnMixedPort)"
        }
        if case .starting = manager.state { return "启动中…" }
        return "未启用"
    }
}
