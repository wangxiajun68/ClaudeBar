import SwiftUI

/// Desktop usage tile: model name, totals, tap to expand a source ring
/// (Claude Code / Codex / 第三方).
struct UsageModelCard: View {
    let stat: ModelUsage
    let slices: [SourceRing.Slice]
    var share: Double
    /// This model's estimated list-price cost, or the reason it has none.
    /// Nil only when the model has no recorded usage row at all.
    var costLine: ModelPricing.Estimate.Line? = nil
    /// The single preference this tile renders, subscribed individually.
    /// Observing `AppPreferences.shared` wholesale meant every unrelated write
    /// — a VPN port commit, a notch flag, the token-unit toggle — re-evaluated
    /// every usage tile on the page. `ExchangeRate` is narrow enough to keep.
    @State private var costDisplay = AppPreferences.shared.costDisplay
    @ObservedObject private var fx = ExchangeRate.shared
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        // Resolved once per render: `costLabel`, its second line and the help
        // text each called `presented(_:)` again, so one pass ran the pricing
        // presentation up to five times.
        let shown = costLine.map { presented($0.cost) }
        return Button {
            withAnimation(Theme.Animation.smooth) { open.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 6) {
                    Text(stat.model)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 5) {
                        HStack(spacing: 6) {
                            if !slices.isEmpty {
                                SourceStack(slices: slices, scan: hovered)
                            }
                            RollingNumberText("\(stat.calls) 次")
                                .font(Theme.Font.micro)
                                .foregroundColor(Theme.textTertiary())
                        }
                        CacheHitBadge(stat: stat)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RollingNumberText(UsageStats.formatTokens(stat.totalTokens))
                        .font(Theme.Font.displayMetricSmall)
                        .monospacedDigit()
                        .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    costLabel(shown)
                }
                AuroraSparkline(
                    values: AuroraSparkline.accentCurve(peak: min(max(share, 0.08), 1)),
                    tint: tint,
                    live: hovered
                )
                .frame(height: 28)
                if open {
                    HStack(alignment: .center, spacing: 12) {
                        SourceRing(
                            slices: slices,
                            size: 88,
                            thickness: 11,
                            centerValue: UsageStats.formatTokens(stat.totalTokens),
                            centerCaption: "来源"
                        )
                        SourceRingLegend(slices: slices)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The card takes the model's own hue, so a page of models reads as
            // a colour-keyed set, and the corner lens carries the usage glyph —
            // the card's subject, not decoration.
            .tile(tint: tint, hovered: hovered,
                  lens: DepthLensSpec(tint: tint, size: 124))
            .folderPeek(hovered)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverState($hovered)
        .help(helpText(shown))
        .accessibilityHint(open ? "收起来源明细" : "展开来源明细")
        .onReceive(AppPreferences.shared.$costDisplay.removeDuplicates()) { costDisplay = $0 }
    }

    /// The model's own accent, from `Theme`'s hash-stable per-model palette —
    /// a *shape* hue, so it drives the sparkline, the corner rings and the
    /// card's wash alike. A usage card that took the page's blue would say
    /// nothing about *which* model it is.
    ///
    /// It used to be the dominant *source*'s hue (`.claude` / `.codex` /
    /// 第三方), which is not a property of the model at all: on a relay that
    /// mixes Codex and third-party traffic for one model, the card changed
    /// colour as the mix moved — the opposite of the stable key the comments
    /// here claim. `Theme.barColor`/`barInk` exist for exactly this and were
    /// documented as this card's palette, with `barInk` left with no caller.
    private var tint: Color {
        Theme.barColor(for: stat.model)
    }

    /// Estimated list-price cost of this tile's tokens.
    ///
    /// A model with no money renders its *reason* rather than a blank: the
    /// tokens above it are real, and a tile that shows nothing next to a
    /// number invites reading it as "free". 订阅制 and 未公开价 are different
    /// facts — one means you are not billed per token, the other means we
    /// cannot know — so they get their own words.
    @ViewBuilder
    private func costLabel(_ shown: ModelPricing.Presented?) -> some View {
        if let line = costLine, let shown, let primary = shown.primary {
            VStack(alignment: .trailing, spacing: 1) {
                RollingNumberText(ModelPricing.format(primary.amount, currency: primary.currency))
                    .font(Theme.Font.tileValueSmall)
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // The second line is either the other currency (分列) or the
                // unconverted figure (折算) — both are "the number this came
                // from", which is what makes the headline checkable.
                if let below = secondLine(line.cost, shown: shown) {
                    RollingNumberText(below)
                        .font(Theme.Font.micro)
                        .monospacedDigit()
                        .foregroundColor(Theme.textTertiary())
                        .lineLimit(1)
                }
            }
            .accessibilityLabel("估算 \(ModelPricing.format(primary.amount, currency: primary.currency))")
        } else {
            Text(costLine?.unpriced?.label ?? "未计价")
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
                .help(costLine?.unpriced?.explanation ?? "价目表未收录该模型，token 不计入花费合计")
        }
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
        var lines: [String] = [open ? "收起来源" : "查看 Claude Code / Codex / 第三方用量"]
        if costLine != nil, let shown, let primary = shown.primary {
            lines.append("按官方刊例价估算 \(ModelPricing.format(primary.amount, currency: primary.currency))")
        } else if let unpriced = costLine?.unpriced {
            lines.append("\(unpriced.explanation)，不计入花费合计")
        } else {
            lines.append("价目表未收录 \(stat.model)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Cache read tokens divided by all prompt-side tokens, shared by model and
/// platform usage cards. A missing prompt side is shown as unknown, not 0%.
struct CacheHitBadge: View {
    let stat: ModelUsage

    var body: some View {
        let hasPrompt = stat.totalInputTokens > 0
        return HStack(spacing: 4) {
            Image(systemName: "memorychip")
                .font(.system(size: 10, weight: .semibold))
            Text(hasPrompt ? "命中 \(stat.cacheHitPercent)%" : "命中 —")
                .rollingNumber()
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
