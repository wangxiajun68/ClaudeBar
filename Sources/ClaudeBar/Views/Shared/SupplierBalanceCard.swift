import SwiftUI

struct SupplierBalanceCard: View {
    let entries: [ProviderStore.SupplierBalance]
    let loading: Bool
    let refresh: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: refresh) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    InstrumentBadge(kind: .balance, tint: Theme.Ink.success, engaged: hovered)
                    Text("供应商余额").font(Theme.Font.tileLabel)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
                if entries.isEmpty {
                    Text(loading ? "正在查询余额…" : "暂无可用余额")
                        .font(Theme.Font.bodySmall)
                    Text(loading ? "等待供应商响应" : "支持 DeepSeek 官方 API；点击重新查询。")
                        .font(Theme.Font.caption).foregroundColor(Theme.textSecondary)
                } else {
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.name).font(Theme.Font.chromeEmph).lineLimit(1)
                            Spacer(minLength: 4)
                            RollingNumberText(entry.amount)
                                .font(Theme.Font.tileValueSmall)
                                .monospacedDigit()
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                }
            }
            .foregroundColor(Theme.textPrimary)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
            // Green is the wallet hue — the same one `InstrumentBadge(.balance)`
            // already draws, so the surface and the mark say the same thing.
            // It is the *raw* `chartGreen`, not `Ink.success`: a wash is a
            // shape, and the pill text keeps the readable variant.
            .tile(tint: Theme.chartGreen, hovered: hovered,
                  lens: DepthLensSpec(tint: Theme.chartGreen, size: 118))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(loading)
        .onHover { if hovered != $0 { hovered = $0 } }
        .help(loading ? "正在获取供应商余额" : "点击刷新所有支持查询的供应商余额")
    }
}
