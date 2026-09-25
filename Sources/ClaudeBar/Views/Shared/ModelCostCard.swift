import SwiftUI

/// The dashboard's model-spend tile: estimated list-price cost of the
/// selected period's usage, with the period and the coverage of the table in
/// the detail line.
///
/// Replaces the 本地代理 tile. The proxy's running state still has three
/// dedicated surfaces (the popup header chip, the traffic page banner and
/// 设置 → 本地代理), so nothing became unreachable — whereas spend had no
/// home outside the usage page's per-model tiles.
struct ModelCostCard: View {
    let estimate: ModelPricing.Estimate
    /// Long form ("2026年9月") — the tooltip and the spoken label.
    let periodLabel: String
    /// Short form ("9月" / "今天") — the header pill, which has one line and
    /// no room for the year.
    let shortPeriodLabel: String
    let action: () -> Void
    /// The one preference this tile renders, subscribed individually. The
    /// wholesale `@ObservedObject` re-rendered the dashboard's spend tile (and
    /// its per-model help text: two `filter`s over `estimate.lines`, up to 15
    /// formatted lines) on every unrelated preference write.
    @State private var costDisplay = AppPreferences.shared.costDisplay
    @ObservedObject private var fx = ExchangeRate.shared

    /// The period's total, with the display preference applied.
    private func presented(_ cost: ModelPricing.Cost) -> ModelPricing.Presented {
        ModelPricing.present(cost, display: costDisplay, rate: fx.effectiveRate)
    }

    var body: some View {
        // Resolved once per render — `headline`, `detail` and `helpText` each
        // called this again.
        let shown = presented(estimate.cost)
        // Amber is the money hue here (the green wallet belongs to the supplier
        // balance card, and spend is not a state colour). `tint` paints the
        // *shape* — the badge glyph — while `pillInk` is the pill's text, which
        // needs the readable variant: raw amber measures 1.84:1 as ink.
        return MetricTile(label: "模型花费", value: headline(shown), detail: detail(shown),
                          tint: Theme.chartAmber, instrumentIcon: .cost,
                          pill: shortPeriodLabel, pillInk: Theme.Ink.warning, action: action)
            .help(helpText(shown))
            .accessibilityHint("在用量页查看 \(periodLabel) 的模型用量")
            .onReceive(AppPreferences.shared.$costDisplay.removeDuplicates()) { costDisplay = $0 }
    }

    /// The headline figure, or a dash when nothing in the period is priced.
    private func headline(_ shown: ModelPricing.Presented) -> String {
        guard let primary = shown.primary else { return "—" }
        return ModelPricing.format(primary.amount, currency: primary.currency)
    }

    /// Model coverage plus the second currency, in one line.
    private func detail(_ shown: ModelPricing.Presented) -> String {
        var parts: [String] = []
        if estimate.pricedModels > 0 {
            parts.append("\(estimate.pricedModels) 个模型")
        }
        // In 分列 mode the other currency goes here. Once converted there is no
        // second figure — say what the number *is* instead, so a converted
        // total cannot be mistaken for a plain sum of two currencies.
        if let secondary = shown.secondary {
            parts.append("另有 \(ModelPricing.format(secondary.amount, currency: secondary.currency))")
        } else if shown.isConverted {
            parts.append("按汇率折算")
        }
        // The three families are excluded from the total for different reasons
        // — "you are not billed per token", "the vendor won't say", and "we
        // haven't added it yet" — so the user can tell which one to act on.
        // The detail line is one line at 11pt; only the first applies.
        for (count, text) in [ (estimate.unpricedCount(of: .subscription), "订阅制"),
                               (estimate.unpricedCount(of: .notPublished), "未公开价"),
                               (estimate.unpricedCount(of: .unknownSlug), "未计价") ] {
            guard parts.count < 3 else { break }
            if count > 0 { parts.append("\(count) 个\(text)") }
        }
        return parts.isEmpty ? "本周期暂无用量" : parts.joined(separator: " · ")
    }

    /// The full per-model breakdown, so the truncated detail line never hides
    /// a model the user cannot account for.
    private func helpText(_ shown: ModelPricing.Presented) -> String {
        guard !estimate.isEmpty else { return "\(periodLabel) 暂无用量" }
        var lines = ["\(periodLabel) 按官方刊例价估算（非账单）"]
        // A converted total is only as good as its rate, so the rate is stated
        // before the numbers it produced.
        if shown.isConverted, let note = fx.note { lines.append("折算汇率：\(note)") }
        if let reason = shown.fallbackReason { lines.append(reason) }
        // Priced first — the unpriced tail is unbounded, and dropping a priced
        // model to make room for a "no number" line would be backwards.
        for line in estimate.lines.filter(\.isPriced).prefix(8) {
            lines.append("\(line.model)：\(amountText(line.cost))")
        }
        for line in estimate.lines.filter({ !$0.isPriced }).prefix(6) {
            guard let unpriced = line.unpriced else { continue }
            lines.append("\(line.model)：\(unpriced.label)——\(unpriced.explanation)")
        }
        if estimate.unpricedModels > 0 {
            lines.append("未计入合计的模型共 \(UsageStats.formatTokens(estimate.unpricedTokens)) token")
        }
        lines.append("价目表核查于 \(ModelPricing.updated)")
        return lines.joined(separator: "\n")
    }

    /// One model's amount, honouring the display preference. A converted model
    /// shows both figures (`¥21.5（$3.00）`) — a converted per-model line is the
    /// easiest place for a rounding artefact to hide, and showing the source
    /// number makes it checkable.
    private func amountText(_ cost: ModelPricing.Cost) -> String {
        let shown = presented(cost)
        guard let primary = shown.primary else { return "—" }
        let head = ModelPricing.format(primary.amount, currency: primary.currency)
        guard shown.isConverted, let source = cost.dominant,
              source.currency != primary.currency else { return head }
        return "\(head)（\(ModelPricing.format(source.amount, currency: source.currency))）"
    }
}
