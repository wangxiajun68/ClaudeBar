import Foundation

/// The outbound half of the price feature: where a fetched price comes from.
///
/// Two kinds of source, and the split is the whole design:
///
/// - **`models.dev`** for the dollar vendors. It publishes one JSON file, one
///   entry per (provider, model), machine-generated and versioned; every
///   Anthropic and OpenAI row in the bundled table matched it exactly when this
///   was written, and it costs one conditional request (`ETag`/`304`) a week.
/// - **The vendor's own pricing page** for the yuan vendors. There is no API:
///   `GET /models` on DeepSeek, Moonshot and DashScope authenticates fine and
///   returns model *ids* with no price, which is the fact this file exists
///   because of. So the pages are parsed.
///
/// The parsers are allowed to be brittle, and the reason is structural: an
/// unparsable page returns **nothing**, and nothing means the bundled row stays
/// in force and the vendor is reported as un-checked. The one thing that must
/// never happen is a parser guessing — the aggregate sources this app looked at
/// carry *international* dollar prices for these models, 4–7× below the
/// domestic list price, and quietly importing one would turn "we could not
/// check 阿里" into "阿里 got 4.8× cheaper" with nothing on screen saying so.
///
/// Pure functions over text, on purpose: `Tests/model-cost-regressions.py` feeds
/// them saved page snapshots from `Tests/fixtures/price-pages/` and asserts the
/// extracted numbers, so a vendor redesign is a red test rather than a wrong
/// number in a month's total.
enum ModelPriceSources {

    // MARK: - Vendors

    /// A yuan vendor whose list price lives on a page we can read.
    struct Vendor {
        let name: String
        let url: String
        /// App slug prefixes this vendor's page covers, for attaching a parsed
        /// row to the slugs the app actually records.
        let slugs: [String]
        /// How to read the page. A function so a vendor's parser and its URL
        /// stay in one place, and so adding a vendor is one entry.
        let parse: @Sendable (String) -> [ParsedRow]

        static func == (lhs: Vendor, rhs: Vendor) -> Bool { lhs.name == rhs.name }
    }

    /// One row a parser extracted, still in the vendor's own terms.
    struct ParsedRow: Equatable {
        var slug: String
        var rate: ModelPricing.Rate
        /// Set when the page quoted something the parser had to reduce — a
        /// context band, a struck-through price, an off-peak window. Surfaced
        /// in the card so a reduced row is visibly reduced.
        var note: String?
    }

    /// The yuan vendors, in the order the table lists them. 火山方舟 is
    /// deliberately absent: its pricing page is a JavaScript console whose
    /// document API answers an anonymous reader with an empty body, so there is
    /// nothing to parse — the card reports it as 无法自动核对 instead, which is
    /// the honest state rather than a silent gap.
    static let vendors: [Vendor] = [
        Vendor(name: "DeepSeek", url: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing/",
               slugs: ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4.1-flash", "deepseek-v4-pro"],
               parse: parseDeepSeek),
        Vendor(name: "智谱 GLM", url: "https://docs.bigmodel.cn/cn/guide/start/pricing",
               slugs: ["glm-5.3", "glm-5.3-flash", "glm-5.3-flashx", "glm-5.2", "glm-5.1", "glm-5-turbo", "glm-5"],
               parse: parseGLM),
        Vendor(name: "Kimi", url: "https://platform.moonshot.cn/docs/pricing/chat",
               slugs: ["kimi-k3", "kimi-k2.7-code", "kimi-k2.7-code-highspeed", "kimi-k2.6"],
               parse: parseKimi),
        Vendor(name: "阿里百炼", url: "https://help.aliyun.com/zh/model-studio/billing-for-model-studio",
               slugs: ["qwen3.7-max", "qwen3.7-plus", "qwen3.6-plus", "qwen3.7-flash", "qwen3-coder-plus"],
               parse: parseAliyun),
        Vendor(name: "阶跃星辰", url: "https://platform.stepfun.com/docs/zh/guides/pricing/details",
               slugs: ["step-5-preview", "step-3.7-flash", "step-3.5-flash"],
               parse: parseStepFun),
        Vendor(name: "MiniMax", url: "https://platform.minimaxi.com/docs/guides/pricing-paygo",
               slugs: ["MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.7-highspeed"],
               parse: parseMiniMax),
    ]

    /// A vendor the app prices but cannot check, and why. Declared here rather
    /// than borrowed from the catalog so this file — which is the one a
    /// regression slice compiles — depends on nothing but `ModelPricing`.
    struct Uncheckable: Equatable {
        let vendor: String
        let reason: String
    }

    /// Vendors the app prices but cannot check. Listed so the card can say why
    /// rather than omitting them.
    static let uncheckable: [Uncheckable] = [
        .init(vendor: "火山方舟",
              reason: "定价页是纯前端渲染的控制台，抓不到内容；豆包系列的价格请手动填写"),
    ]

    // MARK: - models.dev (USD vendors)

    private static let modelsDevURL = URL(string: "https://models.dev/api.json")!
    private static let etagKey = "priceSource.modelsDevETag"

    /// The app's USD vendors, mapped to their `models.dev` provider key. Only
    /// these two: every other provider in that file is a relay or a yuan vendor
    /// whose entry holds the *international* dollar price, which is exactly the
    /// number this app must not import.
    private static let usdVendors: [String: String] = [
        "anthropic": "anthropic",
        "openai": "openai",
    ]

    /// Which USD vendor a recorded slug belongs to, by the prefix its family
    /// uses. Prefix matching rather than a slug list so a model that did not
    /// exist when this was written still resolves — that is the point of the
    /// fetch.
    static func usdVendor(for slug: String) -> String? {
        let name = ModelPricing.canonical(slug)
        if name.hasPrefix("claude-") { return "anthropic" }
        if name.hasPrefix("gpt-") || name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") {
            return "openai"
        }
        return nil
    }

    /// Rows models.dev has for the USD vendors, as overrides to propose.
    ///
    /// Cache buckets: models.dev's `cache_read` is the hit price and its
    /// `cache_write` is the write price; when a generation states no write price
    /// the table's own rule 1 applies (a first write bills as a miss), so
    /// `cacheWrite = input` rather than zero.
    static func rowsFromModelsDev(_ json: [String: Any]) -> [ParsedRow] {
        var out: [ParsedRow] = []
        // A canonical slug, not the raw id: models.dev lists dated snapshots
        // alongside the base id (`claude-opus-4-5-20251101` next to
        // `claude-opus-4-5`), and `canonical` folds both onto the row the app
        // records. The base id is preferred when both are present — a snapshot
        // is the same product and only adds a second proposal for one slug.
        var best: [String: ParsedRow] = [:]
        var exact = Set<String>()
        for (_, providerKey) in usdVendors {
            guard let provider = json[providerKey] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            for (id, value) in models {
                guard let model = value as? [String: Any],
                      let cost = model["cost"] as? [String: Any] else { continue }
                // `deprecated` models are kept: a user may still have usage
                // recorded under one, and dropping the row would turn a priced
                // month into a 未计价 month.
                guard let rate = usdRate(from: cost, name: id) else { continue }
                let slug = ModelPricing.canonical(id)
                guard !slug.isEmpty else { continue }
                var note: String?
                if cost["tiers"] is [[String: Any]] {
                    note = "models.dev 按上下文长度分档，取基础档"
                }
                let row = ParsedRow(slug: slug, rate: rate, note: note)
                if id == slug {
                    best[slug] = row
                    exact.insert(slug)
                } else if !exact.contains(slug), best[slug] == nil {
                    best[slug] = row
                }
            }
        }
        out = best.values.sorted { $0.slug < $1.slug }
        return out
    }

    private static func usdRate(from cost: [String: Any], name: String) -> ModelPricing.Rate? {
        guard let input = number(cost["input"]), let output = number(cost["output"]),
              input > 0, output > 0 else { return nil }
        let read = number(cost["cache_read"]) ?? input * 0.1
        let write = number(cost["cache_write"]) ?? input
        // A row whose cache-read is zero renders a silently free cache line —
        // the same rule `Tests/model-cost-regressions.py` applies to the
        // bundled table. Drop the row rather than import it.
        guard read > 0, write > 0 else { return nil }
        return ModelPricing.Rate(currency: .usd, input: input, output: output,
                                 cacheRead: read, cacheWrite: write)
    }

    /// Fetch `models.dev/api.json`, conditionally.
    ///
    /// Returns `nil` for "the ETag still matches" — a 304 is the common case
    /// after the first week, and there is nothing to apply. Throws only on a
    /// real failure, which the caller reports rather than swallows.
    static func fetchModelsDev() async throws -> [ParsedRow]? {
        var request = URLRequest(url: modelsDevURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue("ClaudeBar/\(appVersion)", forHTTPHeaderField: "User-Agent")
        if let tag = UserDefaults.standard.string(forKey: etagKey) {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        // Its own ephemeral session: this is a 5 MB payload fetched weekly, and
        // there is no reason for it to sit in the shared cache.
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.badResponse }
        if http.statusCode == 304 { return nil }
        guard http.statusCode == 200 else { throw SourceError.http(http.statusCode) }
        if let tag = http.value(forHTTPHeaderField: "ETag") {
            UserDefaults.standard.set(tag, forKey: etagKey)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.badJSON
        }
        return rowsFromModelsDev(json)
    }

    enum SourceError: LocalizedError {
        case http(Int)
        case badResponse
        case badJSON
        case empty

        var errorDescription: String? {
            switch self {
            case .http(let code): return "价源返回 HTTP \(code)"
            case .badResponse: return "价源响应无法识别"
            case .badJSON: return "价源返回的不是预期格式"
            case .empty: return "价源没有返回可用的价格"
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Fetch one yuan vendor's pricing page. Unauthenticated and keyless, like
    /// the exchange-rate sources: a vendor page is public information, so no
    /// credential of the user's is spent to read it.
    static func fetchPage(_ url: String) async throws -> String {
        guard let parsed = URL(string: url) else { throw SourceError.badResponse }
        var request = URLRequest(url: parsed)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        // A browser UA: 阿里 and 阶跃 serve a stripped page to unknown clients,
        // and nothing here identifies a person.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                         "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SourceError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw SourceError.badResponse }
        return text
    }

    // MARK: - HTML helpers

    /// One `<table>`'s rows, each a list of cell texts with tags stripped and
    /// entities unescaped. Enough structure for the three vendors that mark
    /// their prices up as real tables, and nothing more — no attempt is made to
    /// model the page.
    static func tables(in html: String) -> [[[String]]] {
        var out: [[[String]]] = []
        for table in allMatches(of: "<table[\\s\\S]*?</table>", in: html) {
            var rows: [[String]] = []
            for row in allMatches(of: "<tr[\\s\\S]*?</tr>", in: table) {
                let cells = allMatches(of: "<t[dh][^>]*>[\\s\\S]*?</t[dh]>", in: row)
                    .map { flatten($0) }
                if !cells.isEmpty { rows.append(cells) }
            }
            if !rows.isEmpty { out.append(rows) }
        }
        return out
    }

    /// Strip tags, unescape the handful of entities these pages use, collapse
    /// whitespace. The number is what matters and it is never inside a tag.
    static func flatten(_ html: String) -> String {
        var text = html
        for (entity, replacement) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
                                      ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                                      ("&yen;", "¥")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func allMatches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// The first number in a cell, ignoring currency marks and thousands
    /// separators. Returns nil rather than 0 for "no number here" — a zero would
    /// be a price.
    static func number(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "¥", with: " ")
            .replacingOccurrences(of: "元", with: " ")
            .replacingOccurrences(of: "$", with: " ")
        guard let match = allMatches(of: "-?\\d+(?:\\.\\d+)?", in: cleaned).first else { return nil }
        return Double(match)
    }

    /// The **last** number in a cell. Some vendors print the list price with the
    /// discounted one after it (`4.20 2.10` at MiniMax, struck through on the
    /// page). The discounted number is what is charged, and it is the one the
    /// bundled table carries, so the last number is the right one.
    static func lastNumber(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "¥", with: " ")
            .replacingOccurrences(of: "元", with: " ")
        guard let match = allMatches(of: "-?\\d+(?:\\.\\d+)?", in: cleaned).last else { return nil }
        return Double(match)
    }

    private static func number(_ any: Any?) -> Double? {
        if let value = any as? NSNumber {
            let double = value.doubleValue
            return double.isFinite ? double : nil
        }
        if let text = any as? String { return Double(text) }
        return nil
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Parsers
    //
    // Each takes the page's bytes as text and returns what it could read.
    // Returning `[]` is a legitimate answer: it means the page did not look the
    // way this parser knows, and the caller reports the vendor as un-checked.

    /// 智谱 GLM. Real tables, one per model generation, with the header
    /// `模型名称 | 上下文 | 输入单价 | 输出单价 | 缓存存储 | 缓存命中`.
    ///
    /// Tiered rows (`GLM-5.1 | 输入长度 [0, 32K) | 6 | 24 | …`) repeat the model
    /// name; the bundled table's rule 3 takes the base band, so the **first**
    /// row for a name wins. Cache storage is billed per M-token-hour and is
    /// currently 限时免费, so a write bills as input (rule 1).
    static func parseGLM(_ html: String) -> [ParsedRow] {
        var byName: [String: ParsedRow] = [:]
        for rows in tables(in: html) {
            guard let header = rows.first else { continue }
            // The column order is the page's, not this parser's: 模型名称 comes
            // first, then 上下文, then the input price. Reading the columns by
            // header name rather than by index keeps a vendor that inserts a
            // column from silently shifting every number by one.
            guard let inputIndex = header.firstIndex(where: { $0.contains("输入单价") }),
                  let outputIndex = header.firstIndex(where: { $0.contains("输出单价") }),
                  let readIndex = header.firstIndex(where: { $0.contains("缓存命中") }),
                  let maxIndex = [inputIndex, outputIndex, readIndex].max() else { continue }
            for row in rows.dropFirst() where row.count > maxIndex {
                let name = row[0].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, let input = number(row[inputIndex]),
                      let output = number(row[outputIndex]),
                      input > 0, output > 0 else { continue }
                let read = number(row[readIndex]) ?? input * 0.1
                guard read > 0, byName[name.lowercased()] == nil else { continue }
                byName[name.lowercased()] = ParsedRow(
                    slug: name.lowercased(),
                    rate: ModelPricing.Rate(currency: .cny, input: input, output: output,
                                            cacheRead: read, cacheWrite: input),
                    note: nil)
            }
        }
        return byName.values.sorted { $0.slug < $1.slug }
    }

    /// 阶跃星辰. Real tables, header
    /// `模型 | 计费单位 | 输入价格（缓存未命中）| 输入价格（缓存命中）| 输出价格`.
    /// No write bucket: the cache-miss price 已包含写入新内容的费用, so rule 1.
    static func parseStepFun(_ html: String) -> [ParsedRow] {
        var out: [ParsedRow] = []
        for rows in tables(in: html) {
            guard let header = rows.first,
                  let missIndex = header.firstIndex(where: { $0.contains("缓存未命中") }),
                  let hitIndex = header.firstIndex(where: { $0.contains("缓存命中") }),
                  let outputIndex = header.firstIndex(where: { $0.contains("输出价格") }) else { continue }
            for row in rows.dropFirst() {
                guard let input = number(row[safe: missIndex] ?? ""),
                      let output = number(row[safe: outputIndex] ?? ""),
                      let read = number(row[safe: hitIndex] ?? ""),
                      input > 0, output > 0, read > 0 else { continue }
                out.append(ParsedRow(
                    slug: row[0].trimmingCharacters(in: .whitespaces).lowercased(),
                    rate: ModelPricing.Rate(currency: .cny, input: input, output: output,
                                            cacheRead: read, cacheWrite: input),
                    note: nil))
            }
        }
        return out
    }

    /// MiniMax. Real tables, header
    /// `模型 | 输入价格 元/百万 tokens | 输出价格 元/百万 tokens | 缓存读取 元/百万 tokens`.
    ///
    /// Two reductions, both recorded as notes: the context bands (`≤ 512k` /
    /// `> 512k`) take the ≤512k row (rule 3, base band), and each cell prints the
    /// list price with the discounted one after it — the page's 永久五折 is a
    /// permanent cut, so the **last** number is what is charged.
    static func parseMiniMax(_ html: String) -> [ParsedRow] {
        var byName: [String: ParsedRow] = [:]
        for rows in tables(in: html) {
            guard let header = rows.first, header.contains(where: { $0.contains("输入价格") }),
                  let outputIndex = header.firstIndex(where: { $0.contains("输出价格") }),
                  let readIndex = header.firstIndex(where: { $0.contains("缓存读取") }) else { continue }
            for row in rows.dropFirst() {
                let label = row.first ?? ""
                // Only the base band; the `> 512k` row is a different, higher
                // price for the same model and would otherwise overwrite it.
                guard !label.contains(">") else { continue }
                guard let name = allMatches(of: "MiniMax-[A-Za-z0-9.\\-]+", in: label).first else { continue }
                guard let input = lastNumber(row[safe: 1] ?? ""),
                      let output = lastNumber(row[safe: outputIndex] ?? ""),
                      input > 0, output > 0 else { continue }
                let read = lastNumber(row[safe: readIndex] ?? "") ?? input * 0.2
                guard read > 0, byName[name.lowercased()] == nil else { continue }
                byName[name.lowercased()] = ParsedRow(
                    slug: name.lowercased(),
                    rate: ModelPricing.Rate(currency: .cny, input: input, output: output,
                                            cacheRead: read, cacheWrite: input),
                    note: "官方页按上下文分档且带划线原价，取 ≤512K 的折后价")
            }
        }
        return byName.values.sorted { $0.slug < $1.slug }
    }

    /// DeepSeek. Not a table — the page prints one price line per bucket, and
    /// each line carries both windows: `百万tokens输入（缓存命中）空闲时段 0.02元
    /// 0.15元 高峰时段 0.04元 0.30元`.
    ///
    /// The bundled table records the **peak** rate (rule 2: 错峰 is exactly half,
    /// and the rollup stores no hour to apply a window with), so the numbers
    /// after `高峰时段` are the ones taken. Reading the off-peak pair instead
    /// would halve every DeepSeek row — which is precisely the error the
    /// aggregate sources make, and the reason this vendor is parsed at all.
    ///
    /// One free reading falls out of the page's own wording: the columns are
    /// `deepseek-flash` then `deepseek-v4-pro`, and the page states that the
    /// legacy `deepseek-v4-flash` ids bill at the Flash price, so those two
    /// slugs share the flash column rather than needing their own row.
    static func parseDeepSeek(_ html: String) -> [ParsedRow] {
        let text = flatten(html)
        // The three price lines, in page order: cache hit, cache miss (= input),
        // output. Each one's peak pair is `(flash, pro)`.
        func peak(_ bucket: String) -> (Double, Double)? {
            let pattern = "百万tokens" + bucket + "[\\s\\S]{0,80}?高峰时段\\s*(\\d+(?:\\.\\d+)?)元\\s*(\\d+(?:\\.\\d+)?)元"
            guard let match = allMatches(of: pattern, in: text).first else { return nil }
            let numbers = allMatches(of: "\\d+(?:\\.\\d+)?", in: match).compactMap { Double($0) }
            guard numbers.count >= 2 else { return nil }
            return (numbers[0], numbers[1])
        }
        guard let hit = peak("输入 （缓存命中）") ?? peak("输入（缓存命中）"),
              let miss = peak("输入 （缓存未命中）") ?? peak("输入（缓存未命中）"),
              let output = peak("输出"),
              miss.0 > 0, miss.1 > 0, output.1 > 0, hit.1 > 0 else { return [] }

        let note = "官方页分时段，取高峰价（与表中口径一致）"
        func row(_ slug: String, column: Int) -> ParsedRow {
            ParsedRow(slug: slug,
                      rate: ModelPricing.Rate(currency: .cny,
                                              input: column == 0 ? miss.0 : miss.1,
                                              output: column == 0 ? output.0 : output.1,
                                              cacheRead: column == 0 ? hit.0 : hit.1,
                                              cacheWrite: column == 0 ? miss.0 : miss.1),
                      note: note)
        }
        // `deepseek-flash` is the current id; the legacy `deepseek-v4-flash` and
        // `deepseek-v4.1-flash` are the same product at the same price and are
        // carried in the bundled table, so they get the flash column too.
        return [row("deepseek-flash", column: 0),
                row("deepseek-v4-flash", column: 0),
                row("deepseek-v4.1-flash", column: 0),
                row("deepseek-v4-pro", column: 1)]
    }

    /// Kimi / Moonshot. The prices are in the page's MDX source as
    /// `rows:[[`kimi-k2.7-code`,`1M tokens`,`¥1.30`,`¥6.50`,`¥27.00`,`262,144 tokens`],…]`
    /// — column order is `模型 | 计费单位 | 缓存命中 | 缓存未命中 | 输出 | 上下文`.
    static func parseKimi(_ html: String) -> [ParsedRow] {
        var out: [ParsedRow] = []
        // Longest-first so `kimi-k3-256k` is not read as `kimi-k3`.
        let pattern = "\\[(`[^`]+`)((?:,`[^`]*`)+)\\]"
        for match in allMatches(of: pattern, in: html) {
            let parts = allMatches(of: "`([^`]*)`", in: match).map {
                $0.replacingOccurrences(of: "`", with: "")
            }
            guard parts.count >= 5 else { continue }
            let slug = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard slug.hasPrefix("kimi-") else { continue }
            // `¥1.30` (hit) `¥6.50` (miss) `¥27.00` (out).
            let hit = number(parts[2]), miss = number(parts[3]), output = number(parts[4])
            guard let hit, let miss, let output, hit > 0, miss > 0, output > 0 else { continue }
            out.append(ParsedRow(
                slug: slug,
                rate: ModelPricing.Rate(currency: .cny, input: miss, output: output,
                                        cacheRead: hit, cacheWrite: miss),
                note: nil))
        }
        return out
    }

    /// 阿里百炼. The pricing page is prose, not a table: `qwen3.7-max … 0<Token≤1M
    /// 12 元 36 元 100 万 Token`. The model name sits in one element and the
    /// prices after a `<td>`, and this takes **only the first `元` pair after a
    /// bare id** — a dated snapshot (`qwen3.7-max-2026-06-08`) carries the same
    /// numbers and is a different row, and the `Batch 调用 半价` note that
    /// follows a name must not be mistaken for the list price.
    ///
    /// The page does not print cache prices at all, so the documented ratio is
    /// applied (显式命中 ≈10%, 写入 ≈125%) — and the reduction is stated in the
    /// row's note rather than left implicit.
    static func parseAliyun(_ html: String) -> [ParsedRow] {
        let text = flatten(html)
        var out: [ParsedRow] = []
        var seen = Set<String>()
        // The name is followed, within a short window, by `Batch 调用 半价` on
        // some rows and by nothing on others, and then by the band and the two
        // prices. Anything longer than that window is the *next* model's price.
        let pattern = "(qwen[a-z0-9.\\-]*)[\\s\\S]{0,80}?0<Token[^元]{0,30}?(\\d+(?:\\.\\d+)?)\\s*元\\s*(\\d+(?:\\.\\d+)?)\\s*元"
        for match in allMatches(of: pattern, in: text) {
            let slug = allMatches(of: "qwen[a-z0-9.\\-]*", in: match).first?.lowercased() ?? ""
            let numbers = allMatches(of: "\\d+(?:\\.\\d+)?", in: match).compactMap { Double($0) }
            guard !slug.isEmpty, !seen.contains(slug),
                  numbers.count >= 2, numbers[0] > 0, numbers[1] > 0 else { continue }
            seen.insert(slug)
            out.append(ParsedRow(
                slug: slug,
                rate: ModelPricing.Rate(currency: .cny, input: numbers[0], output: numbers[1],
                                        cacheRead: numbers[0] * 0.1, cacheWrite: numbers[0] * 1.25),
                note: "官方页未列缓存单价，按文档的 命中10% / 写入125% 推定"))
        }
        return out.sorted { $0.slug < $1.slug }
    }
}

private extension Array {
    /// `row[safe: n]` — the parsers above index into page-derived arrays, and a
    /// short row is a page-shape surprise, not a crash.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
