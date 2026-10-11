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
        return HStack(spacing: 8) {
            Label(usage.map { "Token " + TokenMagnitude.format($0.total, style: tokenUnit.rawValue) }
                  ?? (source == nil ? "Token 未提供" : "Token —"), systemImage: "sum")
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 0)
            Label(costLabel(usage, shown), systemImage: "creditcard")
                .foregroundColor(shown?.primary == nil ? Theme.textSecondary : Theme.textPrimary)
                .layoutPriority(1)
        }
        .font(.system(size: 12, weight: .medium)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.8)
        .help(detail(usage, shown))
        .accessibilityElement(children: .combine)
        .onReceive(AppPreferences.shared.$costDisplay.removeDuplicates()) { costDisplay = $0 }
        .onReceive(AppPreferences.shared.$tokenUnitStyle.removeDuplicates()) { tokenUnit = $0 }
    }

    private func costLabel(_ usage: SessionUsageSummary?, _ shown: ModelPricing.Presented?) -> String {
        guard let usage, let shown else { return source == nil ? "花费未提供" : "估算 —" }
        guard let primary = shown.primary else { return "花费未计价" }
        var label = "估算 " + ModelPricing.format(primary.amount, currency: primary.currency)
        if let secondary = shown.secondary {
            label += " + " + ModelPricing.format(secondary.amount, currency: secondary.currency)
        }
        if usage.cost.unpricedModels > 0 { label += " · 部分" }
        return label
    }

    private func detail(_ usage: SessionUsageSummary?, _ shown: ModelPricing.Presented?) -> String {
        guard let usage, let shown else {
            return source == nil ? "Cursor 暂未提供独立会话的 token 用量与花费。上下文百分比不等于累计 token。"
                : "索引暂无该会话的累计用量；缺失数据不表示零用量或零花费。"
        }
        return "会话累计（含子代理与工作流），不同于上下文占用\n"
            + "输入 \(usage.input) · 输出 \(usage.output) · 缓存 \(usage.cache) · 合计 \(usage.total) tokens\n"
            + "按各日生效价目表估算，非实际账单\n"
            + usage.cost.detailParts(presented: shown, includeDominant: true).joined(separator: " · ")
            + usage.cost.lines.compactMap { line in
                line.unpriced.map { "\n" + line.model + "：" + $0.explanation }
            }.joined()
    }
}
