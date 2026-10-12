import SwiftUI

private struct SessionUsageSummariesKey: EnvironmentKey {
    static let defaultValue: [SessionUsageSummary.Request: SessionUsageSummary] = [:]
}

extension EnvironmentValues {
    var sessionUsageSummaries: [SessionUsageSummary.Request: SessionUsageSummary] {
        get { self[SessionUsageSummariesKey.self] }
        set { self[SessionUsageSummariesKey.self] = newValue }
    }
}

/// A compact lifetime token / estimated cost line, separate from context fill.
struct SessionUsageReadout: View {
    let source: UsageSource?
    let sessionId: String
    @Environment(\.sessionUsageSummaries) private var summaries
    @State private var costDisplay = AppPreferences.shared.costDisplay
    @State private var tokenUnit = AppPreferences.shared.tokenUnitStyle
    @ObservedObject private var fx = ExchangeRate.shared

    private var summary: SessionUsageSummary? {
        source.flatMap { summaries[.init(source: $0, sessionId: sessionId)] }
    }

    var body: some View {
        let usage = summary
        let shown = usage.map { ModelPricing.present($0.cost.cost, display: costDisplay, rate: fx.effectiveRate) }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Token")
                    .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                    .fixedSize()
                RollingNumberText(usage.map { TokenMagnitude.format($0.total, style: tokenUnit.rawValue) }
                                  ?? (source == nil ? "未提供" : "—"))
                    .font(usage == nil ? Theme.Font.caption : .system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(usage == nil ? Theme.textSecondary : Theme.Ink.claude)
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(height: 29, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Label("花费", systemImage: "creditcard")
                    .font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                    .fixedSize()
                RollingNumberText(costLabel(usage, shown))
                    .font(shown?.primary == nil ? Theme.Font.caption : .system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(shown?.primary == nil ? Theme.textSecondary : Theme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(height: 29, alignment: .trailing)
                if let usage, let shown {
                    let parts = shown.secondary.map { "+ " + ModelPricing.format($0.amount, currency: $0.currency) }
                    let caveat = [parts, usage.cost.unpricedModels > 0 && shown.primary != nil ? "部分未计价" : nil]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !caveat.isEmpty {
                        Text(caveat).font(Theme.Font.micro).foregroundColor(Theme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .help(detail(usage, shown))
        .accessibilityElement(children: .combine)
        .onReceive(AppPreferences.shared.$costDisplay.removeDuplicates()) { costDisplay = $0 }
        .onReceive(AppPreferences.shared.$tokenUnitStyle.removeDuplicates()) { tokenUnit = $0 }
    }

    private func costLabel(_ usage: SessionUsageSummary?, _ shown: ModelPricing.Presented?) -> String {
        guard usage != nil, let shown else { return source == nil ? "未提供" : "—" }
        guard let primary = shown.primary else { return "未计价" }
        return ModelPricing.format(primary.amount, currency: primary.currency)
    }

    private func detail(_ usage: SessionUsageSummary?, _ shown: ModelPricing.Presented?) -> String {
        guard let usage, let shown else {
            return source == nil ? "Cursor 暂未提供独立会话的 token 用量与花费。上下文百分比不等于累计 token。"
                : "索引暂无该会话的累计用量；缺失数据不表示零用量或零花费。"
        }
        return "会话累计（含子代理与工作流），不同于上下文占用\n"
            + "输入 \(usage.input) · 输出 \(usage.output) · 缓存 \(usage.cache) · 合计 \(usage.total) tokens\n"
            + "按各日生效价目表计算\n"
            + usage.cost.detailParts(presented: shown, includeDominant: true).joined(separator: " · ")
            + usage.cost.lines.compactMap { line in
                line.unpriced.map { "\n" + line.model + "：" + $0.explanation }
            }.joined()
    }
}
