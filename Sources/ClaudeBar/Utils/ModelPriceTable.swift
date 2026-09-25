import Foundation

/// The bundled official price table behind `ModelPricing`.
///
/// Split into its own file so updating prices is a one-file edit that does not
/// touch the matching/aggregation logic (and so the regression test can compile
/// the table without the rest of the app).
///
/// Rates are **currency units per million tokens** in the vendor's own billing
/// currency — no exchange rate is applied anywhere. Each vendor block names the
/// doc page the numbers came from; `docs/technical/15-model-cost.md` lists what
/// that pass did and did not cover.
///
/// Three modelling rules, because the vendors do not agree on buckets:
///
/// 1. **No cache-write bucket** (DeepSeek, 阶跃, 火山, Kimi's non-K3 models,
///    GLM) → `cacheWrite == input`. Their docs say a first write bills as a
///    cache miss, so that is the vendor's own model, not a guess.
/// 2. **Time-of-day pricing** (DeepSeek and Ark-hosted DeepSeek: 错峰 = half)
///    → the **peak** rate is used. The rollup is keyed by (day, model) with no
///    hour, so an off-peak window cannot be applied after the fact; peak is
///    also what the work-hours usage this app observes actually pays. Off-peak
///    usage is therefore overestimated by up to 2×.
/// 3. **Tiered pricing** (context-length bands: GLM-5.x <32K/≥32K, 火山
///    doubao 2.0, qwen —max/flash) → the **base band** is used, again because
///    tiers are per-request and the rollup is not. Long-context requests are
///    underestimated.
///
/// Anthropic cache writes are quoted for the **5-minute** TTL (1.25× input);
/// the 1-hour TTL (2×) is not modelled separately.
///
/// Last verified against the vendor pages listed below: 2026-09-24.
enum ModelPriceTable {
    private typealias R = ModelPricing.Rate

    static let entries: [ModelPricing.Entry] = [
        // MARK: Anthropic — USD.
        // platform.claude.com/docs/en/about-claude/pricing
        // Cache read is 0.1× input except Fable 5.1 (0.025×) and Opus 5.5 (0.05×).
        // Opus 4.1/4 are retired and deliberately absent.
        .init(slug: "claude-fable-5-1", rate: R(currency: .usd, input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
        .init(slug: "claude-opus-5-5", rate: R(currency: .usd, input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5)),
        .init(slug: "claude-opus-5", rate: R(currency: .usd, input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        .init(slug: "claude-opus-4-8", rate: R(currency: .usd, input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        .init(slug: "claude-opus-4-7", rate: R(currency: .usd, input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        .init(slug: "claude-opus-4-6", rate: R(currency: .usd, input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        .init(slug: "claude-opus-4-5", rate: R(currency: .usd, input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        .init(slug: "claude-sonnet-5", rate: R(currency: .usd, input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)),
        .init(slug: "claude-sonnet-4-6", rate: R(currency: .usd, input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        .init(slug: "claude-sonnet-4-5", rate: R(currency: .usd, input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        .init(slug: "claude-haiku-4-5", rate: R(currency: .usd, input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)),

        // MARK: OpenAI — USD.
        // platform.openai.com/docs/pricing · openai.com/api/pricing
        // Writes bill as input unless the generation has a distinct write rate
        // (5.6 / 6 do: 1.25× input). ≥272K-context bands are 2× input and
        // 1.5× output — not modelled (see rule 3).
        .init(slug: "gpt-6-astra", rate: R(currency: .usd, input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)),
        .init(slug: "gpt-6-sol", rate: R(currency: .usd, input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)),
        .init(slug: "gpt-6-luna", rate: R(currency: .usd, input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125)),
        .init(slug: "gpt-5.6-sol", rate: R(currency: .usd, input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5)),
        .init(slug: "gpt-5.6-terra", rate: R(currency: .usd, input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2.5)),
        .init(slug: "gpt-5.6-luna", rate: R(currency: .usd, input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25)),
        .init(slug: "gpt-5.5", rate: R(currency: .usd, input: 5, output: 30, cacheRead: 0.5, cacheWrite: 5)),
        .init(slug: "gpt-5.4", rate: R(currency: .usd, input: 2.5, output: 15, cacheRead: 0.25, cacheWrite: 2.5)),
        .init(slug: "gpt-5.4-mini", rate: R(currency: .usd, input: 0.75, output: 4.5, cacheRead: 0.075, cacheWrite: 0.75)),
        .init(slug: "gpt-5.4-nano", rate: R(currency: .usd, input: 0.2, output: 1.25, cacheRead: 0.02, cacheWrite: 0.2)),
        .init(slug: "gpt-5.3-codex", rate: R(currency: .usd, input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 1.75)),
        .init(slug: "gpt-5.2", rate: R(currency: .usd, input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 1.75)),
        .init(slug: "gpt-5.1", rate: R(currency: .usd, input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25)),
        .init(slug: "gpt-5", rate: R(currency: .usd, input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25)),

        // MARK: DeepSeek — CNY, **peak** rate. 错峰 is exactly half.
        // api-docs.deepseek.com/quick_start/pricing
        // Peak = Beijing Mon–Fri 09:00–12:00 & 14:00–18:00, excluding CN
        // holidays. `deepseek-flash` serves V4.1-Flash; `deepseek-v4-flash` and
        // `deepseek-v4.1-flash` are the legacy ids it still accepts and bills at
        // the same rate. No cache-write bucket — a first write is a miss.
        .init(slug: "deepseek-flash", rate: R(currency: .cny, input: 2, output: 8, cacheRead: 0.04, cacheWrite: 2)),
        .init(slug: "deepseek-v4-flash", rate: R(currency: .cny, input: 2, output: 8, cacheRead: 0.04, cacheWrite: 2)),
        .init(slug: "deepseek-v4.1-flash", rate: R(currency: .cny, input: 2, output: 8, cacheRead: 0.04, cacheWrite: 2)),
        .init(slug: "deepseek-v4-pro", rate: R(currency: .cny, input: 9, output: 27, cacheRead: 0.3, cacheWrite: 9)),

        // MARK: Moonshot Kimi — CNY. platform.kimi.com/docs/pricing/chat
        // Only the K3 series has a separate cache-write charge (tiered by TTL;
        // 5-minute shown). The rest bill a write as a miss.
        .init(slug: "kimi-k3", rate: R(currency: .cny, input: 20, output: 100, cacheRead: 2, cacheWrite: 20)),
        .init(slug: "kimi-k2.7-code", rate: R(currency: .cny, input: 6.5, output: 27, cacheRead: 1.3, cacheWrite: 6.5)),
        .init(slug: "kimi-k2.7-code-highspeed", rate: R(currency: .cny, input: 13, output: 54, cacheRead: 2.6, cacheWrite: 13)),
        .init(slug: "kimi-k2.6", rate: R(currency: .cny, input: 6.5, output: 27, cacheRead: 1.1, cacheWrite: 6.5)),

        // MARK: 智谱 GLM — CNY. docs.bigmodel.cn/cn/guide/start/pricing
        // Cache *storage* is billed per M-token-hour and is currently free; a
        // write therefore bills as input. GLM-5.1 / 5-Turbo / 5 are tiered by
        // context (<32K / ≥32K) — base band shown.
        .init(slug: "glm-5.3", rate: R(currency: .cny, input: 8, output: 28, cacheRead: 2, cacheWrite: 8)),
        .init(slug: "glm-5.3-flash", rate: R(currency: .cny, input: 0.8, output: 2.8, cacheRead: 0.23, cacheWrite: 0.8)),
        .init(slug: "glm-5.3-flashx", rate: R(currency: .cny, input: 2, output: 7, cacheRead: 0.57, cacheWrite: 2)),
        .init(slug: "glm-5.2", rate: R(currency: .cny, input: 8, output: 28, cacheRead: 2, cacheWrite: 8)),
        .init(slug: "glm-5.1", rate: R(currency: .cny, input: 6, output: 24, cacheRead: 1.3, cacheWrite: 6)),
        .init(slug: "glm-5-turbo", rate: R(currency: .cny, input: 5, output: 22, cacheRead: 1.2, cacheWrite: 5)),
        .init(slug: "glm-5", rate: R(currency: .cny, input: 4, output: 18, cacheRead: 1, cacheWrite: 4)),

        // MARK: 阿里百炼 Qwen — CNY. help.aliyun.com/zh/model-studio/model-pricing
        // Explicit cache creation ≈125% of input, explicit hit ≈10% (implicit
        // hit ≈20%). `qwen3.8-max` / `qwen3.8-flash` are documented exceptions
        // whose hit rate is *not* published — see `unpriced` below rather than a
        // guessed row here. Tiered models show the base band; see rule 3.
        .init(slug: "qwen3.7-max", rate: R(currency: .cny, input: 12, output: 36, cacheRead: 1.2, cacheWrite: 15)),
        .init(slug: "qwen3.7-plus", rate: R(currency: .cny, input: 2, output: 8, cacheRead: 0.2, cacheWrite: 2.5)),
        .init(slug: "qwen3.6-plus", rate: R(currency: .cny, input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2.5)),
        // Three context bands (≤32K / ≤256K / ≤1M) at 0.2/0.6/1.2 in and
        // 0.8/2.4/4.8 out; base band shown. This row is the reason a drift
        // check earns its keep: it once carried `0.03 / 0.13`, which is the
        // *USD* list price with the yuan sign left on — 6.7× too cheap, and
        // nothing in the app could have noticed.
        .init(slug: "qwen3.7-flash", rate: R(currency: .cny, input: 0.2, output: 0.8, cacheRead: 0.02, cacheWrite: 0.25)),
        .init(slug: "qwen3-coder-plus", rate: R(currency: .cny, input: 4, output: 16, cacheRead: 0.4, cacheWrite: 5)),

        // MARK: MiniMax — CNY. platform.minimaxi.com/docs/guides/pricing-paygo
        // M3's 「永久五折」 is a permanent 50% price cut and the numbers below
        // are already the discounted ones. M3 has no published write price.
        .init(slug: "minimax-m3", rate: R(currency: .cny, input: 2.1, output: 8.4, cacheRead: 0.42, cacheWrite: 2.1)),
        .init(slug: "minimax-m2.7", rate: R(currency: .cny, input: 2.1, output: 8.4, cacheRead: 0.42, cacheWrite: 2.625)),
        .init(slug: "minimax-m2.7-highspeed", rate: R(currency: .cny, input: 4.2, output: 16.8, cacheRead: 0.42, cacheWrite: 2.625)),

        // MARK: 火山方舟 / 豆包 — CNY. volcengine.com/docs/82379/1099320
        // No cache-write column; storage is per M-token-hour. Prior-generation
        // models (2.0-*) are tiered by input length — base band shown. Ark's
        // *hosted* third-party models (glm-5.3-flash, deepseek-*) are priced
        // identically to the vendors' own rows above, so they need no entry.
        .init(slug: "doubao-seed-2.0-code", rate: R(currency: .cny, input: 3.2, output: 16, cacheRead: 0.64, cacheWrite: 3.2)),
        .init(slug: "doubao-seed-2.1-pro", rate: R(currency: .cny, input: 6, output: 30, cacheRead: 1.2, cacheWrite: 6)),
        .init(slug: "doubao-seed-2.1-lite", rate: R(currency: .cny, input: 0.8, output: 2.7, cacheRead: 0.16, cacheWrite: 0.8)),
        .init(slug: "doubao-seed-2.1-turbo", rate: R(currency: .cny, input: 3, output: 15, cacheRead: 0.6, cacheWrite: 3)),
        .init(slug: "doubao-seed-evolving", rate: R(currency: .cny, input: 6, output: 30, cacheRead: 1.2, cacheWrite: 6)),

        // MARK: 阶跃星辰 StepFun — CNY.
        // platform.stepfun.com/docs/zh/guides/pricing/details
        // No write bucket: the cache-miss price 「已包含写入新内容的费用」.
        .init(slug: "step-5-preview", rate: R(currency: .cny, input: 7, output: 20, cacheRead: 0.35, cacheWrite: 7)),
        .init(slug: "step-3.7-flash", rate: R(currency: .cny, input: 1.35, output: 8.1, cacheRead: 0.27, cacheWrite: 1.35)),
        .init(slug: "step-3.5-flash", rate: R(currency: .cny, input: 0.7, output: 2.1, cacheRead: 0.14, cacheWrite: 0.7)),
    ]

    /// Models this app recognizes but that have **no per-token list price**.
    ///
    /// These must not get a rate card: pricing a subscription SKU at some
    /// model's API rate invents a number, and pricing a model whose cache-hit
    /// rate the vendor withholds invents a worse one (cache reads dominate
    /// real token counts). They are reported as their own state instead, and
    /// excluded from the total — see `ModelPricing.Unpriced`.
    static let unpriced: [String: ModelPricing.Unpriced] = [
        // Kimi Code membership: 会员订阅，按月/年付费. Independent of the open
        // platform, and the docs state the two are separate products.
        "kimi-for-coding": .subscription,
        "kimi-for-coding-highspeed": .subscription,
        // 火山 Coding / Agent Plan: the `ark-code-latest` alias exists only on
        // the plan endpoint, which the vendor says cannot be used for API calls.
        "ark-code": .subscription,
        // 百炼 documents that these two's explicit cache-hit rate is *not* the
        // standard 10% and refers to the console for the real number.
        "qwen3.8-max": .notPublished,
        "qwen3.8-flash": .notPublished,
        // OpenAI publishes no cached-input rate for the `-pro` tiers, so any
        // cache line for them would be invented. Their input/output are known
        // ($30 / $180) but a partial card is worse than none here: cache reads
        // are most of the tokens this app counts.
        "gpt-5.4-pro": .notPublished,
        "gpt-5.5-pro": .notPublished,
    ]
}
