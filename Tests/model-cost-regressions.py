#!/usr/bin/env python3
"""Model spend is derived arithmetic over a bundled price table.

Three failure modes are invisible in review and each produces a confidently
wrong number on the dashboard:

  * The wrong rate card answering a slug. Relays record whatever they were
    configured with, so `z-ai/glm-5`, `glm-5-20250929` and `glm-5` all arrive
    and must land on the same card; meanwhile `glm-5.3-flash` must not be
    answered by `glm-5` just because the shorter slug matches first.
  * Summing two currencies. Claude / OpenAI publish USD, the Chinese platforms
    publish CNY. Adding them (or silently dropping one) turns the headline into
    a fictional number.
  * Pricing something that has no list price at all — a subscription SKU, or a
    model whose cache-hit rate the vendor withholds. Both must be *reported*,
    not folded in at zero or at some other model's rate.

Costs the same token vectors the app records, against the production table.
No app launch, no network.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source_root = root / 'Sources/ClaudeBar/Utils'
pricing = (source_root / 'ModelPricing.swift').read_text()
table = (source_root / 'ModelPriceTable.swift').read_text()

swift = r'''
import Foundation

/// The table file carries its own doc comment above the type; keep only the
/// declaration so this compiles standalone.
PRICING
TABLE

/// Minimal stand-in for the app's aggregate — only the fields `ModelPricing`
/// reads.
struct ModelUsage {
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
    var isZero: Bool { totalTokens == 0 }
}

@main struct Regression {
    static func main() {
        // 1. Slug identity: routing metadata must not defeat the lookup.
        let aliases = [
            ("claude-sonnet-4-6", ["anthropic/claude-sonnet-4-6",
                                   "claude-sonnet-4-6-20250929",
                                   "claude-sonnet-4-6:free",
                                   "CLAUDE-SONNET-4-6"]),
            ("glm-5.3-flash", ["z-ai/glm-5.3-flash", "glm-5.3-flash-latest"]),
        ]
        for (base, variants) in aliases {
            let expected = ModelPricing.rate(for: base)
            precondition(expected != nil, "the table must price \(base)")
            for variant in variants {
                precondition(ModelPricing.rate(for: variant) == expected,
                             "\(variant) must resolve to \(base)'s card")
            }
        }

        // 2. Longest slug wins. `glm-5` must not answer for a flash model.
        if let base = ModelPricing.rate(for: "glm-5"),
           let flash = ModelPricing.rate(for: "glm-5.3-flash") {
            precondition(base != flash, "glm-5 must not price glm-5.3-flash")
        }

        // 3. Slug identity across the vendors this app ships presets for, so a
        //    renamed or prefixed id cannot silently become 未计价.
        precondition(ModelPricing.rate(for: "deepseek-v4.1-flash") != nil,
                     "the model the local configs actually use must be priced")
        precondition(ModelPricing.rate(for: "z-ai/glm-5") != nil,
                     "a vendor-namespaced id must still resolve")

        // 4. An unknown slug is unpriced, never zero-cost.
        precondition(ModelPricing.rate(for: "totally-made-up-model") == nil)
        precondition(ModelPricing.rate(for: "") == nil)

        // 5. The arithmetic: each bucket billed on its own line. Claude's
        //    cache-write premium (1.25x input) only matters if the fourth
        //    bucket is actually summed, so bill all four at once.
        let usage = ModelUsage(model: "claude-sonnet-4-6", inputTokens: 1_000_000,
                               outputTokens: 1_000_000, cacheReadTokens: 1_000_000,
                               cacheCreationTokens: 1_000_000)
        guard let priced = ModelPricing.cost(of: usage), let rate = ModelPricing.rate(for: "claude-sonnet-4-6") else {
            preconditionFailure("claude-sonnet-4-6 must be priced")
        }
        let expected = rate.input + rate.output + rate.cacheRead + rate.cacheWrite
        precondition(expected > rate.input + rate.output + rate.cacheRead,
                     "the cache-write bucket must be in the sum, not dropped")
        switch rate.currency {
        case .cny:
            precondition(abs(priced.cny - expected) < 0.0001, "CNY bucket math")
            precondition(priced.usd == 0, "a CNY card must not fill the USD bucket")
        case .usd:
            precondition(abs(priced.usd - expected) < 0.0001, "USD bucket math")
            precondition(priced.cny == 0, "a USD card must not fill the CNY bucket")
        }

        // An unknown slug costs nothing on its own — the caller must decide,
        // which `estimate` does by reporting it rather than zeroing it.
        precondition(ModelPricing.cost(of: ModelUsage(model: "totally-made-up-model",
                                                      inputTokens: 1_000_000, outputTokens: 1_000_000,
                                                      cacheReadTokens: 0, cacheCreationTokens: 0)) == nil)

        // 5. Every CNY row must be plausible as CNY and not a mislabelled USD
        //    figure. `qwen3.7-flash` shipped as `0.2 元 → 0.03` — the vendor's
        //    USD list price with the yuan sign left on, which made it 6.7× too
        //    cheap with nothing in the app able to notice. The two currencies'
        //    lists differ by ~7×, so a row far below its own vendor's cheapest
        //    real offering is the signature of that mistake.
        //
        //    The bound is deliberately loose (the cheapest real CN list prices
        //    are around ¥0.2/M, and NVIDIA's free-tier-adjacent NIM rows are
        //    not in this table at all): it catches a currency swap, not a
        //    repricing.
        for entry in ModelPriceTable.entries where entry.rate.currency == .cny {
            precondition(entry.rate.input >= 0.1,
                         "\(entry.slug): ¥\(entry.rate.input)/M input is implausibly low for a CNY list price")
            precondition(entry.rate.output > entry.rate.input,
                         "\(entry.slug): output must cost more than input on every CNY card")
        }
        // …and the specific row that was wrong stays right.
        precondition(ModelPricing.rate(for: "qwen3.7-flash")?.input == 0.2,
                     "百炼's base band for qwen3.7-flash is 0.2 元/M, not 0.03")

        // 6. Currencies stay separate through aggregation, and unpriced models
        //    are counted rather than folded in at zero.
        let estimate = ModelPricing.estimate([
            ModelUsage(model: "deepseek-v4-pro", inputTokens: 1_000_000, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0),
            ModelUsage(model: "claude-sonnet-4-6", inputTokens: 1_000_000, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0),
            ModelUsage(model: "totally-made-up-model", inputTokens: 5_000_000, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0),
        ])
        precondition(estimate.cost.cny > 0, "the DeepSeek line must land in CNY")
        precondition(estimate.cost.usd > 0, "the Claude line must land in USD")
        precondition(estimate.pricedModels == 2, "two models are priced")
        precondition(estimate.unpricedModels == 1, "the unknown slug is reported, not dropped")
        precondition(estimate.unpricedTokens == 5_000_000, "its tokens are still counted")

        // 7. A recognized model with no list price is reported with its
        //    *reason*, and is kept out of the money. Subscription SKUs and
        //    withheld rates are both "no number", but for opposite reasons:
        //    one means the user is not billed per token, the other means the
        //    vendor does not publish what they are billed.
        precondition(ModelPricing.rate(for: "kimi-for-coding") == nil,
                     "a subscription SKU must not get a rate card")
        precondition(ModelPricing.unpricedReason("kimi-for-coding") == .subscription)
        precondition(ModelPricing.unpricedReason("ark-code-latest") == .subscription,
                     "the plan alias must resolve to the subscription reason")
        precondition(ModelPricing.unpricedReason("qwen3.8-max") == .notPublished,
                     "百炼 withholds this one's cache-hit rate")
        precondition(ModelPricing.unpricedReason("gpt-5.4-pro") == .notPublished,
                     "a card with no cached-input rate must not be half-filled")
        precondition(ModelPricing.unpricedReason("totally-made-up-model") == nil,
                     "unknown is not the same as known-unpriced")
        // …but `estimate` still labels it rather than leaving a blank.
        let unknownEstimate = ModelPricing.estimate([
            ModelUsage(model: "totally-made-up-model", inputTokens: 1_000, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0),
        ])
        precondition(unknownEstimate.lines.first?.unpriced == .unknownSlug)
        precondition(unknownEstimate.unpricedCount(of: .unknownSlug) == 1)

        let mixed = ModelPricing.estimate([
            ModelUsage(model: "kimi-for-coding", inputTokens: 1_000_000, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0),
            ModelUsage(model: "qwen3.8-max", inputTokens: 1_000_000, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0),
            ModelUsage(model: "claude-sonnet-4-6", inputTokens: 1_000_000, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0),
        ])
        precondition(mixed.pricedModels == 1, "only the Claude line is priced")
        precondition(mixed.cost.cny == 0,
                     "an unpriced model must not leak any currency into the total")
        precondition(mixed.unpricedCount(of: .subscription) == 1)
        precondition(mixed.unpricedCount(of: .notPublished) == 1)
        precondition(mixed.lines.allSatisfy { $0.isPriced == ($0.unpriced == nil) })

        // 8. `dominant` picks the larger currency, `secondary` the other.
        let cnyHeavy = ModelPricing.Cost(cny: 100, usd: 10)
        precondition(cnyHeavy.dominant?.currency == .cny)
        precondition(cnyHeavy.secondary?.currency == .usd)
        let usdHeavy = ModelPricing.Cost(cny: 10, usd: 100)
        precondition(usdHeavy.dominant?.currency == .usd)
        precondition(usdHeavy.secondary?.currency == .cny)
        precondition(ModelPricing.Cost().dominant == nil, "an empty cost has no headline")
        precondition(ModelPricing.Cost(cny: 5, usd: 0).secondary == nil,
                     "a zero other-currency must not render as '$0.00'")

        // 9. Display: grouped thousands, a floor for near-zero, no NaN.
        precondition(ModelPricing.format(1284.6, currency: .cny) == "¥1,284.60")
        precondition(ModelPricing.format(999.999, currency: .usd) == "$1,000.00", "rounding must carry into grouping")
        precondition(ModelPricing.format(999.99, currency: .usd) == "$999.99", "three digits take no separator")
        precondition(ModelPricing.format(0.004, currency: .cny) == "<¥0.01")
        precondition(ModelPricing.format(0, currency: .usd) == "$0.00")
        precondition(ModelPricing.format(-5, currency: .usd) == "$0.00", "a negative cost is not a number to show")
        precondition(!ModelPricing.format(Double.nan, currency: .cny).contains("nan"))

        // 10. Every table entry is well formed: no duplicate slug (the lookup
        //     would pick one arbitrarily), and cache reads are never dearer
        //     than fresh input — that would bill a cache hit as a miss.
        var seen = Set<String>()
        for entry in ModelPriceTable.entries {
            precondition(!entry.slug.isEmpty, "an empty slug would match nothing")
            precondition(entry.slug == entry.slug.lowercased(), "slugs are compared lowercased")
            precondition(seen.insert(entry.slug).inserted, "duplicate slug: \(entry.slug)")
            // Lookups only ever run on the canonical form, so a key that is
            // not already canonical is unreachable — it would price nothing
            // and the model would show 未计价 forever.
            precondition(ModelPricing.canonical(entry.slug) == entry.slug,
                         "\(entry.slug) is not canonical: \(ModelPricing.canonical(entry.slug))")
            precondition(entry.rate.input > 0 && entry.rate.output > 0,
                         "\(entry.slug) needs a real input and output price")
            precondition(entry.rate.cacheRead <= entry.rate.input,
                         "\(entry.slug): a cache read must not cost more than fresh input")
            precondition(entry.rate.cacheRead > 0,
                         "\(entry.slug): a zero cache read would render a free bucket")
            // A zero write bucket would render a free line, so reject it — but
            // do NOT assert `cacheWrite >= input`: MiniMax publishes a write
            // price (¥2.625 for M2.7) genuinely *below* its fresh-input price
            // (¥4.2). That is the vendor's own number, not a modelling slip.
            precondition(entry.rate.cacheWrite > 0,
                         "\(entry.slug): a zero cache write would render a free bucket")
        }

        // 11. The same rules for the unpriced keys, plus: whatever the rate
        //     table may match by prefix, a listed slug must never get priced,
        //     and no key may be duplicated across the two tables.
        for (slug, reason) in ModelPriceTable.unpriced {
            precondition(ModelPricing.canonical(slug) == slug,
                         "unpriced key \(slug) is not canonical")
            precondition(!reason.explanation.isEmpty, "\(slug) needs a tooltip line")
            for entry in ModelPriceTable.entries {
                precondition(entry.slug != slug,
                             "\(slug) has both a rate card and an unpriced reason")
            }
            let probe = ModelUsage(model: slug, inputTokens: 1_000_000, outputTokens: 1_000_000,
                                   cacheReadTokens: 0, cacheCreationTokens: 0)
            precondition(ModelPricing.cost(of: probe) == nil,
                         "\(slug) is listed unpriced but cost(of:) still priced it")
            precondition(ModelPricing.resolve(slug)?.reason == reason,
                         "\(slug) must resolve to its own reason")
        }

        // 12. Resolution is one longest-match pass across BOTH tables. The
        //     trap is `gpt-5.5-pro`: it shares a prefix with the priced
        //     `gpt-5.5`, but it is a different product at a different price
        //     ($30/$180 vs $5/$30) whose cached-input rate OpenAI withholds.
        //     A "check the unpriced list first" implementation would pass the
        //     loop above and still get this wrong.
        precondition(ModelPricing.rate(for: "gpt-5.5") != nil, "the base id stays priced")
        precondition(ModelPricing.rate(for: "gpt-5.5-pro") == nil,
                     "the longer, unpriced slug must win over the prefix match")
        precondition(ModelPricing.unpricedReason("gpt-5.5-pro") == .notPublished)
        // …and the longest-match rule still holds in the priced direction.
        precondition(ModelPricing.rate(for: "glm-5.3-flash") != ModelPricing.rate(for: "glm-5"),
                     "a longer priced slug must win over a shorter one")

        // 13. The concrete ids this app's own preset catalog ships must all
        //     resolve to *something* — a rate card or a stated reason. A model
        //     the user can select but that has neither would render as a bare
        //     未计价 with no explanation.
        let shipped = ["claude-sonnet-4-6", "deepseek-v4-pro", "deepseek-v4.1-flash",
                       "kimi-k3", "kimi-for-coding", "glm-5.2", "glm-5.3-flash",
                       "qwen3.7-plus", "minimax-m3", "ark-code-latest",
                       "step-5-preview", "step-3.7-flash"]
        for slug in shipped {
            let known = ModelPricing.rate(for: slug) != nil
                || ModelPricing.unpricedReason(slug) != nil
            precondition(known, "\(slug) is shipped as a preset but the table says nothing about it")
        }

        // 14. Currency conversion is opt-in and never silent.
        //
        //     The module holds no rate: `present` takes one as a parameter, so
        //     a converted figure can only exist where the rate that produced it
        //     is in hand. The failure modes are all "a plausible wrong number":
        //     converting at 1 when no rate arrived, converting a single-currency
        //     total and calling it converted, or dropping a currency on the
        //     floor. Each gets an assertion.
        let both = ModelPricing.Cost(cny: 700, usd: 100)

        // 分列: two figures, untouched by the rate.
        let split = ModelPricing.present(both, display: .split, rate: nil)
        precondition(split.primary?.currency == .cny && split.primary?.amount == 700)
        precondition(split.secondary?.currency == .usd && split.secondary?.amount == 100)
        precondition(!split.isConverted, "分列 must not claim to have converted")
        precondition(split.fallbackReason == nil, "分列 needs no rate, so it cannot fail for want of one")

        // Converted with a rate: one figure, flagged.
        let at7 = ModelPricing.present(both, display: .cny, rate: 7)
        precondition(at7.isConverted)
        precondition(at7.primary?.currency == .cny)
        precondition(at7.primary?.amount == 1400, "700 + 100*7")
        precondition(at7.secondary == nil, "a converted total has no second currency")
        let toUSD = ModelPricing.present(both, display: .usd, rate: 7)
        precondition(toUSD.primary?.currency == .usd)
        precondition(abs((toUSD.primary?.amount ?? 0) - 200) < 0.0001, "100 + 700/7")

        // No rate → fall back to 分列 with a reason. NOT a conversion at 1.
        for missing in [nil, 0, -7, Double.nan, Double.infinity] {
            let fell = ModelPricing.present(both, display: .cny, rate: missing)
            precondition(!fell.isConverted,
                         "an unusable rate must not be used (rate: \(missing as Any))")
            precondition(fell.fallbackReason != nil, "the fallback must be explained")
            precondition(fell.primary?.currency == .cny && fell.primary?.amount == 700,
                         "the fallback must still show both real figures")
            precondition(fell.secondary?.amount == 100, "…including the one it could not convert")
        }

        // A single-currency total needs no rate at all — and must not be
        // labelled 折算, because nothing was converted.
        let onlyCNY = ModelPricing.Cost(cny: 700, usd: 0)
        let cnyOnly = ModelPricing.present(onlyCNY, display: .cny, rate: nil)
        precondition(cnyOnly.primary?.currency == .cny && cnyOnly.primary?.amount == 700)
        precondition(!cnyOnly.isConverted, "nothing was converted, so it is not a conversion")
        precondition(cnyOnly.fallbackReason == nil, "and nothing failed")
        // Asking for USD when only CNY exists still yields the CNY figure —
        // the alternative is inventing a rate to display ¥700 as $.
        let crossAsk = ModelPricing.present(onlyCNY, display: .usd, rate: nil)
        precondition(crossAsk.primary?.currency == .cny
                     && crossAsk.primary?.amount == 700,
                     "a single-currency cost is always exact; never drop it to show the requested one")

        // An empty cost presents as nothing, in every mode.
        for mode in [CostDisplay.split, .cny, .usd] {
            let empty = ModelPricing.present(ModelPricing.Cost(), display: mode, rate: 7)
            precondition(empty.primary == nil, "no usage must render no figure (\(mode))")
            precondition(empty.isConverted == false)
        }

        // `converted` itself refuses a bad rate rather than dividing by zero.
        precondition(both.converted(to: .usd, rate: 0) == nil)
        precondition(both.converted(to: .cny, rate: Double.nan) == nil)

        print("PASS: slug canonicalization, longest-match, disjoint currency buckets, "
              + "\(ModelPriceTable.entries.count) rate cards + \(ModelPriceTable.unpriced.count) stated-unpriced, "
              + "grouped formatting, opt-in conversion with no silent rate")
    }
}
'''.replace('PRICING', pricing).replace('TABLE', table)

with tempfile.TemporaryDirectory(prefix='claudebar-cost-tests-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
