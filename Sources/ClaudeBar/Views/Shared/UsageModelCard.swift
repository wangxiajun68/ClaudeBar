import SwiftUI

/// Desktop usage tile: model name, totals and an always-visible source ring
/// (Claude Code / Codex / 第三方).
///
/// **Two money figures, never one.** `costLine` is the list-price *estimate*
/// (tokens × the published table). `settlement` is Cursor's *actual* charge for
/// the same model, when this machine's Cursor account spent on it. They are
/// rendered as two separately-labelled numbers and are never added: a single
/// total that mixed them would be neither an estimate nor a bill. See
/// `docs/technical/15-model-cost.md`.
struct UsageModelCard: View {
    let stat: ModelUsage
    let slices: [SourceRing.Slice]
    /// This model's estimated list-price cost, or the reason it has none.
    /// Nil only when the model has no recorded usage row at all.
    var costLine: ModelPricing.Estimate.Line? = nil
    /// Cursor's **actually charged** amount for this model, if any.
    ///
    /// Kept as the raw `Cost` rather than a preformatted string so it goes
    /// through the same `ModelPricing.present` path (分列 / 折算, and the
    /// exchange-rate fallback) as the estimate beside it.
    var settlement: ModelPricing.Cost? = nil
    /// The Cursor snapshot's actual window, labelled even when a local
    /// record of the same model also exists.
    var settlementWindow: String? = nil
    var cursorStat: ModelUsage? = nil
    var cursorOnly = false
    /// The single preference this tile renders, subscribed individually.
    /// Observing `AppPreferences.shared` wholesale meant every unrelated write
    /// — a VPN port commit, a notch flag, the token-unit toggle — re-evaluated
    /// every usage tile on the page. `ExchangeRate` is narrow enough to keep.
    @State private var costDisplay = AppPreferences.shared.costDisplay
    @ObservedObject private var fx = ExchangeRate.shared

    var body: some View {
        // Each presentation is shared by the visible rows and accessibility.
        let shown = costLine.map { presented($0.cost) }
        let actual = settlement.map { presented($0) }
        return VStack(alignment: .leading, spacing: 10) {
            Text(stat.model)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(stat.model)
            HStack(spacing: 8) {
                Label(cursorOnly ? "Cursor 官方" : "\(stat.calls) 本地调用",
                      systemImage: cursorOnly ? "cursorarrow" : "arrow.up.arrow.down")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                Spacer(minLength: 4)
                CacheHitBadge(stat: stat, rolls: false)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(UsageStats.formatTokens(stat.totalTokens))
                    .font(Theme.Font.displayMetricSmall)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(cursorOnly ? "Cursor Token" : "本地 Token")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            }
            costLabel(shown, actual: actual)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let cursorStat {
                HStack(spacing: 5) {
                    Image(systemName: "cursorarrow")
                    Text("Cursor Token")
                    Spacer(minLength: 4)
                    Text(UsageStats.formatTokens(cursorStat.totalTokens)).monospacedDigit().fixedSize()
                }
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textSecondary)
                .help("Cursor 账单窗口：\(settlementWindow ?? "未提供日期")，未加入本地 Token")
            }
            TokenMixStrip(stats: [stat], compact: true, rolls: false)
            HStack(alignment: .center, spacing: 12) {
                SourceRing(slices: slices, size: 64, thickness: 8,
                           centerValue: "来源", centerCaption: cursorOnly ? "账单" : "本地", rolls: false)
                sourceLegend
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Static surface: no hover tracking, scanning, digit transitions or lens.
        .tile(tint: tint, lift: false)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .help(helpText(shown))
        .onReceive(AppPreferences.shared.$costDisplay.removeDuplicates()) { costDisplay = $0 }
    }

    /// Keep the name on one row, with share and quantity below it. The ring
    /// never competes with three columns of text at narrow card widths.
    private var sourceLegend: some View {
        let total = slices.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(slices) { slice in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Circle().fill(slice.color).frame(width: 5, height: 5)
                        Text(slice.label)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(total > 0 ? "\(Int((Double(slice.value) / Double(total) * 100).rounded()))%" : "—")
                            .foregroundColor(Theme.textTertiary())
                            .monospacedDigit()
                            .fixedSize()
                    }
                    Text("\(UsageStats.formatTokens(slice.value)) Token")
                        .foregroundColor(Theme.textTertiary())
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 10)
                }
            }
        }
        .font(Theme.Font.micro)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Stable model colour, independent of the source mix.
    private var tint: Color { Theme.barColor(for: stat.model) }

    /// Estimates and actual charges remain separately labelled rows.
    @ViewBuilder
    private func costLabel(_ shown: ModelPricing.Presented?, actual: ModelPricing.Presented?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            estimateRow(shown)
            settlementRow(actual)
        }
        .accessibilityLabel(accessibilityMoney(shown, actual: actual))
    }

    /// A full-width amount row leaves the main Token figure its own space.
    @ViewBuilder
    private func estimateRow(_ shown: ModelPricing.Presented?) -> some View {
        if let line = costLine, let shown, let primary = shown.primary {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Label(line.isPartial ? "本地部分估算" : "本地估算", systemImage: "calculator")
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                    Spacer(minLength: 4)
                    Text(ModelPricing.format(primary.amount, currency: primary.currency))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize()
                }
                if line.isPartial {
                    Text("\(UsageStats.formatTokens(line.unpricedTokens)) Token 未计价")
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let below = secondLine(line.cost, shown: shown) {
                    Text(below)
                        .font(Theme.Font.micro)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
            }
        } else if !cursorOnly {
            Text("本地\(costLine?.unpriced?.label ?? "未计价")")
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
                .help(costLine?.unpriced?.explanation ?? "价目表未收录该模型，token 不计入花费合计")
        }
    }

    /// Cursor's real charge, worded so it can never be read as an estimate.
    ///
    /// 「Cursor 实扣」 rather than 「实收」 or a bare figure: the number belongs to
    /// one vendor's ledger, and naming the vendor is what tells the user which
    /// of the two rows on this tile is checkable against a statement.
    @ViewBuilder
    private func settlementRow(_ shown: ModelPricing.Presented?) -> some View {
        if let shown {
            let amount = shown.primary ?? (currency: ModelPricing.Currency.usd, amount: 0)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Label("Cursor 实扣", systemImage: "creditcard")
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.Ink.cursor)
                    Spacer(minLength: 4)
                    Text(ModelPricing.format(amount.amount, currency: amount.currency))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize()
                }
                if let settlement, let below = secondLine(settlement, shown: shown) {
                    Text(below)
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                        .monospacedDigit()
                        .lineLimit(1)
                }
                // Always identify the Cursor window; its tokens and charge
                // stay separate from the local period on the same card.
                if let settlementWindow {
                    Text(settlementWindow)
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
            }
        }
    }

    /// One label covering both figures, spelled out — VoiceOver gets no benefit
    /// from the two-row layout, and 「估算」 on an actual charge (or the reverse)
    /// is the one thing this tile must never say.
    private func accessibilityMoney(_ shown: ModelPricing.Presented?, actual: ModelPricing.Presented?) -> String {
        var parts: [String] = []
        if costLine != nil, let shown, let primary = shown.primary {
            parts.append("估算 \(ModelPricing.format(primary.amount, currency: primary.currency))")
        }
        if let actual {
            let primary = actual.primary ?? (currency: ModelPricing.Currency.usd, amount: 0)
            parts.append("Cursor 实扣 \(ModelPricing.format(primary.amount, currency: primary.currency))")
        }
        return parts.joined(separator: "，")
    }

    private func presented(_ cost: ModelPricing.Cost) -> ModelPricing.Presented {
        ModelPricing.present(cost, display: costDisplay, rate: fx.effectiveRate)
    }

    /// The smaller line under the headline, or nil when there is nothing left
    /// to say.
    private func secondLine(_ cost: ModelPricing.Cost, shown: ModelPricing.Presented) -> String? {
        if let secondary = shown.secondary {
            return ModelPricing.format(secondary.amount, currency: secondary.currency)
        }
        // Converted: show the original amount instead, so a converted per-model
        // figure can be checked against the vendor's own currency.
        guard shown.isConverted, let source = cost.dominant,
              source.currency != shown.primary?.currency else { return nil }
        return ModelPricing.format(source.amount, currency: source.currency)
    }

    private func helpText(_ shown: ModelPricing.Presented?) -> String {
        var lines: [String] = [cursorOnly ? "Cursor 官方账单窗口用量" : "Claude Code / Codex / 第三方本地用量"]
        if costLine != nil, let shown, let primary = shown.primary {
            lines.append("按官方刊例价估算 \(ModelPricing.format(primary.amount, currency: primary.currency))")
        } else if let unpriced = costLine?.unpriced {
            lines.append("\(unpriced.explanation)，不计入花费合计")
        } else if !cursorOnly {
            lines.append("价目表未收录 \(stat.model)")
        }
        if let cursorStat {
            lines.append("Cursor：\(cursorStat.totalTokens.formatted()) Token（\(settlementWindow ?? "账单窗口")），与本地用量分别统计")
        }
        if let line = costLine, line.isPartial {
            lines.append("另有 \(UsageStats.formatTokens(line.unpricedTokens)) Token 未计价，金额仅覆盖有价格的日期")
        }
        return lines.joined(separator: "\n")
    }
}

/// Cache read tokens divided by all prompt-side tokens, shared by model and
/// platform usage cards. A missing prompt side is shown as unknown, not 0%.
struct CacheHitBadge: View {
    let stat: ModelUsage
    var rolls = true

    var body: some View {
        let hasPrompt = stat.totalInputTokens > 0
        return HStack(spacing: 4) {
            Image(systemName: "memorychip")
                .font(.system(size: 10, weight: .semibold))
            Text(hasPrompt ? "命中 \(stat.cacheHitPercent)%" : "命中 —")
                .rollingNumber(hasPrompt ? "命中 \(stat.cacheHitPercent)%" : "命中 —", rolls: rolls)
        }
        .font(Theme.Font.microSemibold)
        .foregroundStyle(hasPrompt ? Theme.Ink.success : Theme.textTertiary())
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(hasPrompt ? Theme.chartGreen.opacity(0.11) : Theme.cardFill(0.06)))
        .help(hasPrompt
              ? "缓存读取 Token ÷ 输入、缓存读取与缓存写入 Token 总和"
              : "没有输入 Token，无法计算缓存命中率")
        .accessibilityLabel(hasPrompt ? "缓存命中率 \(stat.cacheHitPercent)%" : "缓存命中率暂无数据")
    }
}
