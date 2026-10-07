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
    ///
    /// `Int`-backed rather than `String`-backed so a persisted override file
    /// cannot be made unreadable by a rename: the raw value is a stable number,
    /// and an unknown one decodes to nil rather than to a silently different
    /// currency. `Codable` is on the enum itself because the override record
    /// in `ModelPriceCatalog` round-trips through JSON.
    enum Currency: Int, Codable {
        case cny, usd

        var symbol: String { self == .cny ? "¥" : "$" }

        /// The vendor's own billing currency name, for the editor's picker.
        var label: String { self == .cny ? "人民币" : "美元" }

        var code: String { self == .cny ? "CNY" : "USD" }
    }

    /// Where an override's numbers came from. Persisted, so this is also the
    /// audit trail the settings card renders: a row that says 内置 and a row
    /// that says 官方页 are two different claims, and the UI must be able to
    /// tell them apart.
    enum PriceSource: Int, Codable, Equatable {
        /// The user typed it in the settings card.
        case manual
        /// A row fetched from `models.dev`, whose prices are USD.
        case fetchedUSD
        /// A row parsed out of a vendor's own pricing page, in CNY.
        case fetchedCNY
        /// A row the user fetched, whose later manual edit replaced it. Kept so
        /// the fetched value survives a revert to 手动 rather than being lost.
        case fetchedAndEdited

        var label: String {
            switch self {
            case .manual: return "手动"
            case .fetchedUSD: return "models.dev"
            case .fetchedCNY: return "官方页"
            case .fetchedAndEdited: return "手动（曾抓取）"
            }
        }

        /// One line explaining the provenance, shown under an edited row.
        var explanation: String {
            switch self {
            case .manual:
                return "你在设置中手动填写的价格"
            case .fetchedUSD:
                return "从 models.dev 拉取（美元刊例价）"
            case .fetchedCNY:
                return "从厂商官方定价页解析（人民币刊例价）"
            case .fetchedAndEdited:
                return "先抓取后手动修改"
            }
        }
    }

    /// One published rate card, in **currency units per million tokens**.
    ///
    /// `input` is fresh (cache-miss) prompt tokens. `cacheRead` is a prompt
    /// cache hit and `cacheWrite` is writing into the cache. Vendors with no
    /// cache-write bucket price a write as a miss, which is their own stated
    /// model — the table sets `cacheWrite == input` rather than zero, and
    /// `Tests/model-cost-regressions.py` rejects any zero bucket, because a
    /// zero would render a silently free line.
    struct Rate: Codable, Equatable {
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
    enum Unpriced: Int, Codable, Equatable {
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
            /// Why some or all of this line's usage cannot be priced.
            let unpriced: Unpriced?
            let unpricedTokens: Int

            var isPriced: Bool { unpriced == nil || cost.cny > 0 || cost.usd > 0 }
            var isPartial: Bool { isPriced && unpriced != nil }

            init(model: String, cost: Cost, unpriced: Unpriced?, unpricedTokens: Int = 0) {
                self.model = model
                self.cost = cost
                self.unpriced = unpriced
                self.unpricedTokens = unpricedTokens
            }
        }

        var lines: [Line] = []
        var cost = Cost()
        /// Models with priced / unpriced usage; a partially priced model appears in both.
        var pricedModels = 0
        var unpricedModels = 0
        /// Tokens behind `unpricedModels` — surfaced in the tooltip so the
        /// user can see how much of the total is not covered.
        var unpricedTokens = 0

        var isEmpty: Bool { lines.isEmpty }

        /// How many models fell into one `Unpriced` bucket. The buckets mean
        /// different things to the user, but every aggregate surface prints one
        /// merged count (`unpricedModels`); only the regression harness reads
        /// this split.
        func unpricedCount(of reason: Unpriced) -> Int {
            lines.reduce(0) { $0 + ($1.unpriced == reason ? 1 : 0) }
        }

        /// The unpriced share, as one sentence. The popup's copy had drifted to
        /// 「N 个含未计价用量」 while the island card and the session row said
        /// 「N 个模型未计价」; the wording lives here so the three cannot
        /// disagree again.
        var unpricedCaption: String {
            unpricedModels > 0 ? "\(unpricedModels) 个模型未计价" : ""
        }

        /// The parts of the caption under a money headline, in the order every
        /// surface shows them. Each surface lays the parts out its own way —
        /// the session row's tooltip, the popup and the island tooltips join
        /// them with `" · "`, the island card and the model tiles print only
        /// the first — which is why this returns parts rather than a finished
        /// sentence.
        ///
        /// `presented` is the amount **after 显示货币 was applied**
        /// (`present(_:display:rate:)`), and taking it here is what keeps a
        /// caption consistent with the headline above it. A caption built from
        /// the raw pair instead contradicts a converted headline: 分列's
        /// 「另有 $43.20」 under a ¥ total is the one thing the user did not
        /// ask to see. So the parts follow the presentation:
        ///
        /// - a stated fallback comes before the figures it qualifies — it
        ///   explains why the headline is not what was requested;
        /// - then the *other* money: the second currency in 分列, or the
        ///   original dominant behind a converted figure, so the conversion
        ///   can be checked against the vendor's own currency;
        /// - then the merged unpriced-model count.
        ///
        /// `includeDominant` is the tooltip form: it repeats the headline
        /// figure it describes, so the second currency needs no 「另有」 lead.
        /// Without it the parts are the caveat alone, printed under a headline
        /// the surface draws itself.
        func detailParts(presented: Presented, includeDominant: Bool = false) -> [String] {
            var parts: [String] = []
            if includeDominant, let primary = presented.primary {
                parts.append(ModelPricing.format(primary.amount, currency: primary.currency))
            }
            if let reason = presented.fallbackReason { parts.append(reason) }
            if let secondary = presented.secondary {
                let figure = ModelPricing.format(secondary.amount, currency: secondary.currency)
                // The lead the second figure takes follows the role it plays:
                // beside the headline it is a peer of it, under it an addition.
                parts.append(includeDominant ? figure : "另有 " + figure)
            } else if presented.isConverted, let source = cost.dominant,
                      source.currency != presented.primary?.currency {
                // The converted figure folds two currencies together; the
                // original amount stays legible beside it. Skipped when the
                // conversion landed on the dominant's own currency — there is
                // no second number left to check.
                parts.append(ModelPricing.format(source.amount, currency: source.currency))
            }
            if !unpricedCaption.isEmpty { parts.append(unpricedCaption) }
            return parts
        }

        /// What a surface with nothing to caveat shows instead: a stated
        /// 暂无用量 only when the period has no lines at all — an estimate
        /// whose models all priced has a figure and needs no caption beside it.
        var emptyCaption: String { isEmpty ? "暂无用量" : "" }
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

    /// One user/fetched override on top of the bundled table.
    ///
    /// Declared **here** rather than in `ModelPriceCatalog` for two reasons that
    /// are really one: `ModelPricing` must resolve against overrides without
    /// the catalog — the regression harness pastes this file and the price
    /// table into a bare `swiftc` template with no app dependencies — and the
    /// record is nothing but a `Rate` plus the metadata that makes it
    /// auditable. The catalog owns the *list*; this owns one row.
    ///
    /// Overrides are **ordered by `effectiveFrom`**: the same slug may carry
    /// several, and a date resolves to the newest one not after it. That is what
    /// keeps a price change from rewriting history — a day of usage recorded
    /// before the change still resolves to the old rate.
    struct PriceOverride: Codable, Equatable {
        var slug: String

        /// The rate card, or nil when the row instead states a reason for there
        /// being none.
        var rate: Rate?
        /// Why there is no `rate` — 订阅制 / 未公开价. Nil when `rate` is set.
        var unpriced: Unpriced?

        /// `yyyy-MM-dd`, the same day key `UsageIndex`/`ProxyUsageStore` roll up
        /// by, so a usage day and an override date compare as plain strings.
        var effectiveFrom: String

        var source: PriceSource
        /// The page the numbers were parsed from, when `source` is fetched.
        /// Fetched rows are only auditable if this survives, so it is persisted
        /// rather than reconstructed.
        var sourceURL: String?
        /// When the fetch or manual edit that produced this row ran.
        var checkedAt: Date?
        /// Free-text caveat recorded at write time — e.g. an official page that
        /// quotes two context bands and had to be reduced to one.
        var note: String?

        /// The resolution this row states, or nil when it states neither a rate
        /// nor a reason — a malformed row, which the catalog refuses to write.
        var resolution: Resolution? {
            if let rate { return .priced(rate) }
            if let unpriced { return .unpriced(unpriced) }
            return nil
        }
    }

    /// The overrides in force, keyed by canonical slug, each list ascending by
    /// `effectiveFrom`. Guarded rather than `@MainActor`-isolated because the
    /// resolution path runs on the usage scan's detached tasks; swapping the
    /// whole dictionary under one lock keeps it to a single critical section
    /// and makes the read path free of torn state.
    private static let overrideLock = NSLock()
    nonisolated(unsafe) private static var overrides: [String: [PriceOverride]] = [:]

    /// Install the catalog's overrides. An **empty** dictionary restores exactly
    /// the bundled-table behaviour, which is what keeps this feature purely
    /// additive: no number changes until a user or a fetch writes one.
    static func replaceOverrides(_ table: [String: [PriceOverride]]) {
        overrideLock.lock()
        defer { overrideLock.unlock() }
        overrides = table.mapValues { rows in
            rows.sorted { $0.effectiveFrom < $1.effectiveFrom }
        }
    }
    /// Resolve a recorded model slug against both tables, as of `date`.
    ///
    /// Longest-match still decides (`glm-5` loses to `glm-5.3-flash`), but the
    /// override table participates in the same pass: an override for a *longer*
    /// slug beats a bundled row for a shorter one, and vice versa. That is the
    /// same one-pass rule this method documents, extended to a third table —
    /// checking overrides "first" would let an override for `glm-5` swallow the
    /// bundled `glm-5.3-flash`.
    ///
    /// **The equal-length case goes to the override.** A user edit or a fetched
    /// row is normally for a slug the bundled table already prices — those are
    /// exactly the models a user wants to correct — so a strictly-longer rule
    /// left every such override stored, listed and reported as applied while
    /// every cost path kept billing the bundled rate. Only the source order is
    /// load-bearing, so `consider` takes the later candidate on a tie and the
    /// override pass runs last.
    static func resolve(_ model: String, on date: String) -> Resolution? {
        let name = canonical(model)
        guard !name.isEmpty else { return nil }
        var best: (slug: String, resolution: Resolution)?

        overrideLock.lock()
        let snapshot = overrides
        overrideLock.unlock()

        func consider(_ slug: String, _ resolution: Resolution) {
            guard matches(name, slug) else { return }
            if best == nil || slug.count >= best!.slug.count { best = (slug, resolution) }
        }
        for entry in table { consider(entry.slug, .priced(entry.rate)) }
        for (slug, reason) in ModelPriceTable.unpriced { consider(slug, .unpriced(reason)) }
        for (slug, rows) in snapshot {
            // The newest row starting on or before `date` wins; a row that
            // starts later leaves the earlier one (or the bundled table) in
            // force, which is what keeps a price change forward-only.
            var applied: PriceOverride?
            for row in rows where row.effectiveFrom <= date { applied = row }
            if let applied, let resolution = applied.resolution { consider(slug, resolution) }
        }
        return best?.resolution
    }

    /// Resolve as of today — the date-less entry point, for callers that are
    /// genuinely about "now". Anything costing a *recorded* day must pass that
    /// day: see `estimate(_:on:)` and `estimate(days:)`.
    static func resolve(_ model: String) -> Resolution? {
        resolve(model, on: dayKey(Date()))
    }

    /// `yyyy-MM-dd` in the local calendar — the day-key format both usage
    /// rollups store (`UsageIndex`, `ProxyUsageStore`), so an override's
    /// `effectiveFrom` and a usage day compare as plain strings.
    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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
        cost(of: usage, on: dayKey(Date()))
    }

    /// Cost one model's aggregate as of `date`.
    static func cost(of usage: ModelUsage, on date: String) -> Cost? {
        guard let rate = resolve(usage.model, on: date)?.rate else { return nil }
        return cost(of: usage, rate: rate)
    }

    /// The four-bucket arithmetic, split out because the date-less and the dated
    /// path bill identically — the only thing a date changes is *which* rate
    /// they bill at.
    private static func cost(of usage: ModelUsage, rate: Rate) -> Cost {
        let million = 1_000_000.0
        // Written as four named terms rather than one chained expression: the
        // chain pushed this file's type-checker past its budget once already
        // ("unable to type-check in reasonable time") and this is the hot path.
        let input = Double(usage.inputTokens) / million * rate.input
        let output = Double(usage.outputTokens) / million * rate.output
        let cacheRead = Double(usage.cacheReadTokens) / million * rate.cacheRead
        let cacheWrite = Double(usage.cacheCreationTokens) / million * rate.cacheWrite
        let amount = input + output + cacheRead + cacheWrite
        var cost = Cost()
        switch rate.currency {
        case .cny: cost.cny = amount
        case .usd: cost.usd = amount
        }
        return cost
    }

    /// Cost a whole period's per-model aggregates, at today's prices.
    static func estimate(_ usages: [ModelUsage]) -> Estimate {
        estimate(usages, on: dayKey(Date()))
    }

    /// Cost a set of per-model aggregates as of one date.
    ///
    /// Correct for a single day's slice and for the settings card's preview. A
    /// *multi-day* period must go through `estimate(days:)` instead: pricing a
    /// whole month at one date is exactly how a mid-month price change would
    /// silently rewrite the days before it.
    static func estimate(_ usages: [ModelUsage], on date: String) -> Estimate {
        var out = Estimate()
        for usage in usages {
            guard !usage.isZero else { continue }
            guard let cost = cost(of: usage, on: date) else {
                out.lines.append(Estimate.Line(model: usage.model, cost: Cost(),
                                               unpriced: resolve(usage.model, on: date)?.reason ?? .unknownSlug,
                                               unpricedTokens: usage.totalTokens))
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

    /// Cost a period held as one bucket per day, each day at the price in force
    /// **on that day**.
    ///
    /// This is what makes a price change forward-only. The rollup already
    /// carries `(day, model)` rows — `UsageIndex.fetchDailyModels(in:)` for
    /// Claude Code / Codex and `ProxyUsageStore.fetchDailyModels(startDay:endDay:)`
    /// for the proxy — so no schema change and no re-derivation is needed: the
    /// per-day rows were always there, they were just summed into one period
    /// before being priced.
    ///
    /// Lines are merged by recorded slug afterwards, so a model that spans a
    /// price change still renders as one line, with the two segments' amounts
    /// already added. The split is in the arithmetic, not the presentation.
    static func estimate(days: [String: [ModelUsage]]) -> Estimate {
        var out = Estimate()
        var costByModel: [String: Cost] = [:]
        var tokensByModel: [String: Int] = [:]
        var unpricedByModel: [String: Unpriced] = [:]
        var unpricedTokensByModel: [String: Int] = [:]

        for (day, usages) in days.sorted(by: { $0.key < $1.key }) {
            for usage in usages where !usage.isZero {
                tokensByModel[usage.model, default: 0] += usage.totalTokens
                if let cost = cost(of: usage, on: day) {
                    let running = costByModel[usage.model] ?? Cost()
                    costByModel[usage.model] = Cost(cny: running.cny + cost.cny,
                                                    usd: running.usd + cost.usd)
                } else {
                    unpricedByModel[usage.model] = resolve(usage.model, on: day)?.reason ?? .unknownSlug
                    unpricedTokensByModel[usage.model, default: 0] += usage.totalTokens
                }
            }
        }

        // Ordered by token volume, matching `estimate(_:)`, so the card's lines
        // keep the same ranking whichever path produced them.
        for (model, tokens) in tokensByModel.sorted(by: { $0.value > $1.value }) {
            if let cost = costByModel[model] {
                out.lines.append(Estimate.Line(model: model, cost: cost, unpriced: unpricedByModel[model],
                                               unpricedTokens: unpricedTokensByModel[model] ?? 0))
                out.cost.cny += cost.cny
                out.cost.usd += cost.usd
                out.pricedModels += 1
            } else {
                out.lines.append(Estimate.Line(model: model, cost: Cost(),
                                               unpriced: unpricedByModel[model] ?? .unknownSlug,
                                               unpricedTokens: tokens))
            }
            if let missing = unpricedTokensByModel[model] {
                out.unpricedModels += 1
                out.unpricedTokens += missing
            }
        }
        return out
    }

    /// Reduce a recorded slug to the vendor's own model id.
    ///
    /// Relays hand back whatever they were configured with, so the same
    /// upstream model arrives as `anthropic/claude-sonnet-4-6`,
    /// `claude-sonnet-4-6-20250929`, or `claude-sonnet-4-6:free`. The vendor
    /// id is the common core; everything around it is routing metadata.
    // Shared immutable patterns: pricing and ledger matching call canonical
    // for every recorded model. Preserve ICU's Unicode digit/$ semantics.
    private static let snapshotSuffixes: [NSRegularExpression] = {
        [try! NSRegularExpression(pattern: #"-\d{8}$"#),
         try! NSRegularExpression(pattern: #"@\d{8}$"#)]
    }()

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
        for pattern in snapshotSuffixes {
            guard let match = pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let range = Range(match.range, in: name) else { continue }
            name = String(name[..<range.lowerBound])
        }
        // A trailing effort / speed tier. Cursor names the *same* upstream
        // model by its reasoning tier (`claude-opus-5-5-medium`), where the
        // client configures it bare (`claude-opus-5-5`), so without this the
        // two land on separate usage rows and the Cursor charge has no row to
        // attach to. Only the vendor's own effort vocabulary is stripped —
        // `-thinking` is a tier of one model here, `-fast` a speed variant.
        //
        // Looped, not a single strip: Cursor writes the tier(s) as a chain
        // (`claude-4.6-sonnet-medium-thinking` was in the account's own ledger),
        // and one pass would leave `-medium` on the end.
        //
        // This runs before the price-table lookup, which is a longest-slug
        // prefix match, so stripping can only ever move a lookup *towards* the
        // base tier. No slug in `ModelPriceTable` ends in one of these words
        // (asserted in `Tests/model-cost-regressions.py`), so nothing priced is
        // made unpriced by this step.
        while let tier = tierSuffix(of: name) {
            name = String(name.dropLast(tier.count))
        }
        return name
    }

    /// The effort / speed word this slug ends in, or nil. Ordered longest-first
    /// so `-xhigh` is not read as `-high` — and matched on the *hyphen* so a
    /// vendor's own compound like `-highspeed` is not mistaken for `-high`.
    private static func tierSuffix(of name: String) -> String? {
        for tier in ["-xhigh", "-medium", "-thinking", "-high", "-low", "-fast"]
        where name.hasSuffix(tier) && name.count > tier.count {
            return tier
        }
        return nil
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
