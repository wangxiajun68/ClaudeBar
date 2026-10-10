import SwiftUI

/// Both routes describe connections observed by mihomo, not all system traffic.
struct VpnRouteTrafficSummary: View {
    var proxied: VpnDomainTraffic
    var direct: VpnDomainTraffic
    var proxiedCount: Int
    var directCount: Int

    var body: some View {
        HStack(spacing: 20) {
            lane("代理", path: "本机 → 代理节点 → 目标", traffic: proxied,
                 count: proxiedCount, color: Theme.Ink.claude, symbol: "arrow.triangle.branch")
            Rectangle().fill(Theme.hairline).frame(width: 1)
            lane("直连", path: "本机 → 目标", traffic: direct,
                 count: directCount, color: Theme.Ink.success, symbol: "arrow.right")
        }
        .frame(height: 88)
        .help("上传与下载是经 VPN 内核观测到的采样累计，不随筛选变化。短连接及最后采样后的流量可能漏计；绕过内核的直连不在统计范围内。连接数对应当前搜索和失败筛选，包含代理与直连。")
    }

    private func lane(_ title: String, path: String, traffic: VpnDomainTraffic,
                      count: Int, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                AppGlyph(name: symbol, size: 14).foregroundColor(color)
                Text(title).font(Theme.Font.bodySmall.weight(.semibold)).foregroundColor(color)
                Text("\(count) 次连接").font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                Spacer(minLength: 0)
                Text(VpnFormat.bytes(traffic.total)).font(Theme.Font.bodySmall.weight(.semibold).monospacedDigit())
            }
            HStack(spacing: 12) {
                Text("↑ \(VpnFormat.bytes(traffic.upload))")
                Text("↓ \(VpnFormat.bytes(traffic.download))")
            }
            .font(Theme.Font.captionMono).foregroundColor(Theme.textPrimary)
            Text(path).font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
