import Foundation

/// How estimated spend is presented when a period spans both currencies.
///
/// `split` is the default and the honest one: CNY and USD are never added
/// together, each gets its own figure. The converted modes exist because a user
/// paying in one currency wants *a* single number, and refusing to give one just
/// pushes the conversion somewhere less visible. Converting is opt-in precisely
/// because it requires a rate this app does not otherwise need — and because a
/// converted figure is a *third* kind of estimate, not a better one.
///
/// Lives here rather than in `AppPreferences` so the pricing rules and the
/// switch that selects between them stay in one file, and so the regression
/// test can exercise them without pulling in the app's preference graph.
enum CostDisplay: String, CaseIterable, Identifiable {
    /// 分列：主数字 + 「另有 $43.20」. No rate, no network.
    case split
    /// 全部折算成人民币.
    case cny
    /// 全部折算成美元.
    case usd

    var id: String { rawValue }

    var label: String {
        switch self {
        case .split: return "分列"
        case .cny: return "人民币"
        case .usd: return "美元"
        }
    }

    /// Whether this mode needs an exchange rate (and therefore a fetch).
    var needsRate: Bool { self != .split }
}

/// Official list-price estimation for locally recorded token counts.
///
/// The app measures tokens itself (transcripts for Claude Code / Codex, the
/// local proxy for everything else) but never sees a bill: subscription plans
/// are not metered per token, and third-party relays do not return per-request
/// cost. So "花费" here is an **estimate at the vendor's published list price**
/// — the number answers "what would this usage have cost on the metered API",
/// not "what was charged". Every surface that shows it says so: the tile's
/// tooltip leads with 按官方刊例价估算（非账单）.
///
/// Prices are a bundled table, not a live lookup: there is no documented
/// pricing endpoint on the Chinese platforms, and a number that silently
/// changes under the user is worse than one that is visibly dated. The table
/// lives in `ModelPriceTable`; `updated` is the date it was last checked
/// against the vendors' pages, and `docs/technical/15-model-cost.md` records
/// what that check did and did not cover.
///
/// Matching is on the model slug the caller already recorded. A slug the table
/// does not know is never folded in at zero — a total that quietly omits half
/// the usage is a wrong number wearing a confident face. It is reported
/// instead, with the reason: see `Unpriced`.
enum ModelPricing {

    /// The billing currency of a rate card. Vendors publish in one or the
    /// other; nothing here invents an exchange rate.
    enum Currency {
        case cny, usd

        var symbol: String { self == .cny ? "¥" : "$" }
    }

    /// One published rate card, in **currency units per million tokens**.
    ///
    /// `input` is fresh (cache-miss) prompt tokens. `cacheRead` is a prompt
    /// cache hit and `cacheWrite` is writing into the cache. Vendors with no
    /// cache-write bucket price a write as a miss, which is their own stated
    /// model — the table sets `cacheWrite == input` rather than zero, and
    /// `Tests/model-cost-regressions.py` rejects any zero bucket, because a
    /// zero would render a silently free line.
    struct Rate: Equatable {
        var currency: Currency
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }

    /// Why a model has no rate card.
    ///
    /// The distinction matters to the user, who can act on it: a subscription
    /// SKU means "you are not billed per token at all", a withheld rate means
    /// "the vendor does not publish it", and an unknown slug means "this table
    /// has not caught up with your model". All three are excluded from the
    /// total; only the last is this app's to fix.
    enum Unpriced {
        /// A 会员 / 套餐 SKU billed by subscription, not per token. Pricing it
        /// at some model's API rate would invent a number.
        case subscription
        /// A pay-as-you-go model whose list price the vendor does not publish
        /// (百炼's documented cache-hit exceptions). Folding it in at the
        /// standard 10% would invent a worse one — cache reads are most of the
        /// tokens.
        case notPublished
        /// No table row and no stated reason: a slug this table has not seen.
        case unknownSlug

        var label: String {
            switch self {
            case .subscription: return "订阅制"
            case .notPublished: return "未公开价"
            case .unknownSlug: return "未计价"
            }
        }

        /// Tooltip line for one model.
        var explanation: String {
            switch self {
            case .subscription:
                return "该模型按订阅计费，没有按 token 的刊例价"
            case .notPublished:
                return "官方未公开该模型的缓存命中价，无法估算"
            case .unknownSlug:
                return "价目表未收录该模型名，可在设置中反馈或自行核对"
            }
        }
    }

    /// A priced amount, split by currency. Both stay separate — see `Currency`.
    ///
    /// Comparing the two as bare numbers is meaningless (¥100 ≠ $100), so
    /// which one headlines is a display choice, not a conversion: the larger
    /// amount leads and the other gets its own line. A user with mostly
    /// domestic models sees ¥ lead, a Claude-heavy user sees $ lead.
    struct Cost: Equatable {
        var cny: Double = 0
        var usd: Double = 0

        /// The larger of the two, for a one-number headline. `nil` when
        /// nothing priced.
        var dominant: (currency: Currency, amount: Double)? {
            if cny == 0 && usd == 0 { return nil }
            return cny >= usd ? (.cny, cny) : (.usd, usd)
        }

        /// The other currency, for the detail line.
        var secondary: (currency: Currency, amount: Double)? {
            guard let dominant else { return nil }
            let other: (Currency, Double) = dominant.currency == .cny ? (.usd, usd) : (.cny, cny)
            return other.1 > 0 ? (other.0, other.1) : nil
        }

        /// Both currencies folded into one, through an explicit rate.
        ///
        /// The rate is a **parameter, never a stored constant** — this is the
        /// only place in the module that adds a yuan amount to a dollar amount,
        /// and it should be impossible to reach without the rate that justified
        /// it being in hand. A non-positive rate returns nil rather than
        /// converting at 1, which would silently report dollars as yuan.
        func converted(to target: Currency, rate: Double) -> Double? {
            guard rate > 0, rate.isFinite else { return nil }
            switch target {
            case .cny: return cny + usd * rate
            case .usd: return usd + cny / rate
            }
        }
    }

    /// What the UI should draw for one amount, after the display preference is
    /// applied. Resolved here rather than in the view so the same rules govern
    /// the tile, the model cards and the tooltip.
    struct Presented: Equatable {
        /// The headline figure.
        var primary: (currency: Currency, amount: Double)?
        /// The second figure in 分列 mode; nil once converted, because there is
        /// only one number left.
        var secondary: (currency: Currency, amount: Double)?
        /// True when `primary` came from folding two currencies together, so
        /// the UI can say so instead of presenting it as a plain sum.
        var isConverted = false
        /// Set when the user asked for a converted figure but no rate was
        /// available; the presentation then falls back to 分列 and this
        /// explains why.
        var fallbackReason: String?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.primary?.currency == rhs.primary?.currency
                && lhs.primary?.amount == rhs.primary?.amount
                && lhs.secondary?.currency == rhs.secondary?.currency
                && lhs.secondary?.amount == rhs.secondary?.amount
                && lhs.isConverted == rhs.isConverted
                && lhs.fallbackReason == rhs.fallbackReason
        }
    }

    /// Apply a display preference to an amount.
    ///
    /// `display` decides the currency; `rate` (USD→CNY) is required only by the
    /// converted modes. When it is missing or a mode has nothing to convert,
    /// this degrades to 分列 with a stated reason — never to a silent
    /// conversion, and never to a dropped currency.
    static func present(_ cost: Cost, display: CostDisplay, rate: Double?) -> Presented {
        switch display {
        case .split:
            return Presented(primary: cost.dominant, secondary: cost.secondary)

        case .cny, .usd:
            let target: Currency = display == .cny ? .cny : .usd
            // One currency only: nothing to convert, so no rate is needed and
            // the figure is exact. Do not advertise a conversion that did not
            // happen.
            if cost.cny == 0 || cost.usd == 0 {
                let only: (Currency, Double) = cost.cny > 0 ? (.cny, cost.cny) : (.usd, cost.usd)
                guard only.1 > 0 else { return Presented() }
                return Presented(primary: (only.0, only.1))
            }
            guard let converted = cost.converted(to: target, rate: rate ?? 0) else {
                return Presented(primary: cost.dominant, secondary: cost.secondary,
                                 fallbackReason: "未取得汇率，暂按两种货币分列")
            }
            return Presented(primary: (target, converted), isConverted: true)
        }
    }

    /// The result of costing a set of per-model aggregates.
    struct Estimate: Equatable {
        /// Per-model cost, in the order the aggregates arrived (already
        /// sorted by token volume).
        struct Line: Equatable {
            let model: String
            let cost: Cost
            /// Why this line has no money, or nil when it is priced.
            let unpriced: Unpriced?

            var isPriced: Bool { unpriced == nil }

            init(model: String, cost: Cost, unpriced: Unpriced?) {
                self.model = model
                self.cost = cost
                self.unpriced = unpriced
            }
        }

        var lines: [Line] = []
        var cost = Cost()
        /// Models the table recognized / did not.
        var pricedModels = 0
        var unpricedModels = 0
        /// Tokens behind `unpricedModels` — surfaced in the tooltip so the
        /// user can see how much of the total is not covered.
        var unpricedTokens = 0

        var isEmpty: Bool { lines.isEmpty }

        /// How many models fell into one `Unpriced` bucket. The buckets mean
        /// different things to the user, so the head line splits them.
        func unpricedCount(of reason: Unpriced) -> Int {
            lines.reduce(0) { $0 + ($1.unpriced == reason ? 1 : 0) }
        }
    }

    /// What the table knows about one slug.
    ///
    /// Both tables are consulted in **one** longest-match pass rather than
    /// "check unpriced first" — that ordering would let a short unpriced entry
    /// swallow a longer priced one (`qwen3.8-max` is unpriced; `qwen3.8-max-prime`
    /// is not, and is not the same product). Length decides, which is already
    /// how the rate table disambiguates `glm-5` from `glm-5.3-flash`.
    enum Resolution: Equatable {
        case priced(Rate)
        case unpriced(Unpriced)

        var rate: Rate? { if case .priced(let r) = self { return r }; return nil }
        var reason: Unpriced? { if case .unpriced(let u) = self { return u }; return nil }
    }

    /// Resolve a recorded model slug against both tables.
    static func resolve(_ model: String) -> Resolution? {
        let name = canonical(model)
        guard !name.isEmpty else { return nil }
        var best: (slug: String, resolution: Resolution)?
        func consider(_ slug: String, _ resolution: Resolution) {
            guard matches(name, slug) else { return }
            if best == nil || slug.count > best!.slug.count { best = (slug, resolution) }
        }
        for entry in table { consider(entry.slug, .priced(entry.rate)) }
        for (slug, reason) in ModelPriceTable.unpriced { consider(slug, .unpriced(reason)) }
        return best?.resolution
    }

    /// The rate card for a recorded model slug, or nil when it has none —
    /// either because the slug is unknown or because its price is stated as
    /// unavailable. Use `resolve(_:)` when the distinction matters.
    static func rate(for model: String) -> Rate? { resolve(model)?.rate }

    /// Why the table has no price for this slug, or nil when it is priced (or
    /// unknown). See `Unpriced`.
    static func unpricedReason(_ model: String) -> Unpriced? { resolve(model)?.reason }

    /// Cost one model's aggregate, or nil when it has no rate card. Each token
    /// bucket is billed on its own line — that is the whole point of storing
    /// them disjointly.
    static func cost(of usage: ModelUsage) -> Cost? {
        guard let rate = resolve(usage.model)?.rate else { return nil }
        let million = 1_000_000.0
        let amount = Double(usage.inputTokens) / million * rate.input
            + Double(usage.outputTokens) / million * rate.output
            + Double(usage.cacheReadTokens) / million * rate.cacheRead
            + Double(usage.cacheCreationTokens) / million * rate.cacheWrite
        var cost = Cost()
        switch rate.currency {
        case .cny: cost.cny = amount
        case .usd: cost.usd = amount
        }
        return cost
    }

    /// Cost a whole period's per-model aggregates.
    static func estimate(_ usages: [ModelUsage]) -> Estimate {
        var out = Estimate()
        for usage in usages {
            guard !usage.isZero else { continue }
            guard let cost = cost(of: usage) else {
                out.lines.append(Estimate.Line(model: usage.model, cost: Cost(),
                                               unpriced: unpricedReason(usage.model) ?? .unknownSlug))
                out.unpricedModels += 1
                out.unpricedTokens += usage.totalTokens
                continue
            }
            out.lines.append(Estimate.Line(model: usage.model, cost: cost, unpriced: nil))
            out.cost.cny += cost.cny
            out.cost.usd += cost.usd
            out.pricedModels += 1
        }
        return out
    }

    /// Reduce a recorded slug to the vendor's own model id.
    ///
    /// Relays hand back whatever they were configured with, so the same
    /// upstream model arrives as `anthropic/claude-sonnet-4-6`,
    /// `claude-sonnet-4-6-20250929`, or `claude-sonnet-4-6:free`. The vendor
    /// id is the common core; everything around it is routing metadata.
    static func canonical(_ model: String) -> String {
        var name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return "" }
        // OpenRouter's `:free` / `:nitro` / `:floor` routing suffixes.
        if let colon = name.lastIndex(of: ":"), name[name.index(after: colon)...].allSatisfy({ $0.isLetter }) {
            name = String(name[..<colon])
        }
        // `vendor/model` — the namespace is a routing prefix, never part of
        // the vendor's own id. Take the last segment (`z-ai/glm-5` → `glm-5`).
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        // `-latest` and dated snapshots both resolve to the base id.
        for suffix in ["-latest", "@latest"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        // A trailing `-YYYYMMDD` (or `@YYYYMMDD`) build stamp.
        for separator in ["-", "@"] {
            guard let range = name.range(of: separator + #"\d{8}$"#, options: .regularExpression) else { continue }
            name = String(name[..<range.lowerBound])
        }
        return name
    }

    /// Slug match with a token boundary: `claude-sonnet-4-6` claims
    /// `claude-sonnet-4-6-20250929` but not `claude-sonnet-4-65`.
    private static func matches(_ name: String, _ slug: String) -> Bool {
        name == slug || name.hasPrefix(slug + "-")
    }

    /// Date the table below was last verified against vendor pricing pages.
    static let updated = "2026-09-24"

    /// Currency amount at the precision these prices are actually quoted to.
    ///
    /// A month of light use lands under a unit (¥0.42), so two decimals is the
    /// floor; a heavy month runs to thousands and the grouping separator does
    /// the reading work. Below ¥0.01 the number rounds to "0.00", which reads
    /// as "nothing" rather than "almost nothing" — say so instead.
    ///
    /// Grouping is done by hand rather than through `NumberFormatter`: this is
    /// called from `body` on the densest page in the app, and a formatter per
    /// layout pass is the kind of allocation this codebase avoids elsewhere
    /// (see the cached formatters in `UsageStats`).
    static func format(_ amount: Double, currency: Currency) -> String {
        let symbol = currency.symbol
        guard amount.isFinite, amount > 0 else { return "\(symbol)0.00" }
        if amount < 0.01 { return "<\(symbol)0.01" }
        let rounded = (amount * 100).rounded() / 100
        let text = String(format: "%.2f", rounded)
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        return symbol + group(String(parts[0])) + "." + (parts.count > 1 ? parts[1] : "00")
    }

    /// Insert thousand separators into a run of digits.
    private static func group(_ digits: String) -> String {
        guard digits.count > 3 else { return String(digits) }
        var out = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0 && offset % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return String(out.reversed())
    }

    /// Table last checked: see `docs/technical/15-model-cost.md` for the
    /// source URL behind every row. Ordered longest-slug-wins at lookup time,
    /// so declaration order here carries no meaning.
    struct Entry {
        let slug: String
        let rate: Rate
    }

    private static let table: [Entry] = ModelPriceTable.entries
}
