import Foundation

extension Notification.Name {
    /// The price catalog changed — a manual edit, an applied fetch, or a revert.
    ///
    /// A notification rather than a direct call because the writer (this file)
    /// and the readers are on different clocks: `ProviderStore` caches its
    /// per-model cost lines and its period estimate, and only rebuilds them when
    /// the *token totals* change (`publishUsage`), so a price edit alone would
    /// leave a stale figure on screen. It reacts the way it does to the Cursor
    /// ledger: `refreshUsage(rescan: false)` — no transcript changed, only the
    /// money.
    static let modelPriceDidChange = Notification.Name("com.claudebar.modelPriceDidChange")
}

/// The writable layer on top of the bundled price table.
///
/// `ModelPriceTable` is compiled in and dated; this is what lets the user see
/// it, correct it, and keep it current without a release. It owns exactly three
/// things the bundled table cannot:
///
/// 1. **Overrides** — edits and fetched rows, each stamped with the day it takes
///    effect from. `ModelPricing.resolve(_:on:)` consults them; a day of usage
///    billed before an override starts still resolves to the old rate, which is
///    what keeps a price change forward-only.
/// 2. **The check queue** — rows a fetch found but did not apply, plus vendors
///    whose page could not be parsed. Kept in memory only: it is a *report about
///    a fetch*, not a fact about prices, and a stale one after a relaunch would
///    claim a diff that no longer exists.
/// 3. **Freshness** — when the last check ran and what it said, so the settings
///    card can be honest about the age of its numbers.
///
/// What it deliberately does **not** do: fetch. `ModelPriceSources` does the
/// network work and hands rows here; this type never opens a socket, so every
/// path that writes a price goes through one validator and one JSON file.
///
/// The file lives beside `cursor-ledger.json` under Application Support, writes
/// atomically, and is left world-readable because — like that file and unlike
/// `providers.json` — it holds no credentials. Written with plain
/// `Data.write(options: .atomic)` rather than `PrivateFileWriter` for the same
/// reason.
@MainActor
final class ModelPriceCatalog: ObservableObject {
    static let shared = ModelPriceCatalog()

    /// One candidate a fetch produced, before it is applied or dismissed.
    ///
    /// Carries the resolved rate rather than the raw page text: the parsers in
    /// `ModelPriceSources` are the only things that know how to read a vendor's
    /// HTML, and re-parsing at apply time would mean a second chance to fail.
    struct Candidate: Identifiable, Equatable {
        var id: String { slug }
        let slug: String
        /// What the fetch would write. Nil `rate` means it states a reason for
        /// having no per-token price instead.
        let rate: ModelPricing.Rate?
        let unpriced: ModelPricing.Unpriced?
        let source: ModelPricing.PriceSource
        let sourceURL: String?
        /// What the catalog currently resolves for this slug today, for the
        /// diff. Nil when the table does not know the slug at all.
        let current: ModelPricing.Resolution?
        let note: String?
        /// True when the fetched row and the live one agree — shown as the
        /// "无差异" bucket rather than as a change.
        let isUnchanged: Bool
    }

    /// A vendor whose page a fetch could not read, and why. Reported rather
    /// than silently skipped: "we could not check 火山" is information the user
    /// needs to interpret a "已是最新" claim.
    struct Failure: Identifiable, Equatable {
        var id: String { vendor }
        let vendor: String
        let reason: String
    }

    /// The outcome of the last check, for the card's report block.
    struct Report: Equatable {
        var at: Date
        var appliedUSD = 0
        var appliedCNY = 0
        var unchanged = 0
        var failures: [Failure] = []
        /// Vendors skipped because they have no machine-readable page at all.
        var unparsableVendors: [String] = []
        var error: String?

        var headline: String {
            if let error { return error }
            var parts: [String] = []
            if appliedUSD > 0 { parts.append("美元 \(appliedUSD) 条已应用") }
            if appliedCNY > 0 { parts.append("人民币 \(appliedCNY) 条已应用") }
            if unchanged > 0 { parts.append("\(unchanged) 条无差异") }
            if failures.count > 0 { parts.append("\(failures.count) 条未能核对") }
            return parts.isEmpty ? "没有可用的价源返回结果" : parts.joined(separator: " · ")
        }
    }

    /// Overrides in force, keyed by canonical slug, ascending by date. Mirrors
    /// what was handed to `ModelPricing.replaceOverrides`.
    @Published private(set) var overrides: [String: [ModelPricing.PriceOverride]] = [:]
    /// Rows the last check found but did not apply, awaiting 应用 / 忽略.
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var report: Report?
    @Published private(set) var isChecking = false
    /// When the last check ran, from the cache file, so the card can date its
    /// own silence.
    @Published private(set) var lastCheckedAt: Date?

    /// How long a check stays fresh. The upstream sources refresh daily; a week
    /// keeps the automatic check to roughly four requests a month per install,
    /// which is what makes it defensible to run without being asked.
    static let checkInterval: TimeInterval = 7 * 24 * 3600

    private let file = FilePaths.appSupportDir.appendingPathComponent("price-overrides.json")

    private init() {
        load()
        ModelPricing.replaceOverrides(overrides)
    }

    // MARK: - Reading

    /// Every slug the card should list: the bundled table, the stated-unpriced
    /// list, and any override for a slug the bundled table has never heard of
    /// (a model the user added by hand).
    ///
    /// Bundled rows come first so the list's resting order is the table's own
    /// (vendors group together); overrides are added for slugs that are not
    /// already present. The view sorts within that by the same longest-slug
    /// discipline `ModelPricing.matches` uses, so `glm-5` sits above
    /// `glm-5.3-flash`.
    var allSlugs: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in ModelPriceTable.entries where seen.insert(entry.slug).inserted {
            out.append(entry.slug)
        }
        for slug in ModelPriceTable.unpriced.keys where seen.insert(slug).inserted {
            out.append(slug)
        }
        for slug in overrides.keys where seen.insert(slug).inserted {
            out.append(slug)
        }
        return out.sorted()
    }

    /// The override in force for `slug` today, or nil when the bundled table is
    /// what the app is billing from.
    func activeOverride(for slug: String) -> ModelPricing.PriceOverride? {
        let today = ModelPricing.dayKey(Date())
        return overrides[slug]?.last { $0.effectiveFrom <= today }
    }

    /// All override rows for a slug, oldest first — the edit sheet shows the
    /// history so a past change is visible rather than silent.
    func history(for slug: String) -> [ModelPricing.PriceOverride] { overrides[slug] ?? [] }

    /// What the app resolves for a slug today, override or bundled.
    func resolution(for slug: String) -> ModelPricing.Resolution? {
        ModelPricing.resolve(slug)
    }

    var overrideCount: Int {
        overrides.values.reduce(0) { $0 + $1.count }
    }

    var customSlugCount: Int {
        overrides.values.filter { !$0.isEmpty }.count
    }

    var isStale: Bool {
        guard let lastCheckedAt else { return false }
        return Date().timeIntervalSince(lastCheckedAt) > Self.checkInterval
    }

    // MARK: - Writing

    enum WriteError: LocalizedError {
        case emptySlug
        case notCanonical(String)
        case missingRate
        case nonPositiveBucket(String)
        case cacheReadAboveInput
        case badDate(String)

        var errorDescription: String? {
            switch self {
            case .emptySlug:
                return "模型名不能为空"
            case .notCanonical(let name):
                return "请填写厂商的规范模型名（现在是 \(name)），例如 glm-5.3、deepseek-flash"
            case .missingRate:
                return "请填写输入与输出单价"
            case .nonPositiveBucket(let bucket):
                return "\(bucket) 必须大于 0——填 0 会让这一桶静默地免费"
            case .cacheReadAboveInput:
                return "缓存读不应高于输入价"
            case .badDate(let text):
                return "生效日期格式应为 2026-09-30，现在是 \(text)"
            }
        }
    }

    /// Validate and store one override.
    ///
    /// The rules are the ones `Tests/model-cost-regressions.py` already holds
    /// the bundled table to — a zero bucket is rejected here for the same reason
    /// it is rejected there: it renders a silently free line, and a total that
    /// is quietly too low is worse than one that refuses to compute. A
    /// `cacheRead` above `input` is not impossible in principle but has never
    /// been true of any vendor on this table, so it is far more likely a typo
    /// (a rate typed in per-token instead of per-million) than a real price.
    @discardableResult
    func record(slug rawSlug: String,
                rate: ModelPricing.Rate?,
                unpriced: ModelPricing.Unpriced? = nil,
                effectiveFrom: String,
                source: ModelPricing.PriceSource,
                sourceURL: String? = nil,
                note: String? = nil) throws -> ModelPricing.PriceOverride {
        let trimmed = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { throw WriteError.emptySlug }
        let canonical = ModelPricing.canonical(trimmed)
        guard canonical == trimmed else { throw WriteError.notCanonical(trimmed) }
        guard Self.isDayKey(effectiveFrom) else { throw WriteError.badDate(effectiveFrom) }

        var slate: ModelPricing.Rate?
        if let rate {
            guard rate.input > 0, rate.output > 0 else { throw WriteError.missingRate }
            let buckets: [(String, Double)] = [
                ("输入价", rate.input), ("输出价", rate.output),
                ("缓存读", rate.cacheRead), ("缓存写", rate.cacheWrite),
            ]
            for (label, value) in buckets where !(value > 0) {
                throw WriteError.nonPositiveBucket(label)
            }
            guard rate.cacheRead <= rate.input else { throw WriteError.cacheReadAboveInput }
            slate = rate
        } else {
            guard unpriced != nil else { throw WriteError.missingRate }
        }

        let row = ModelPricing.PriceOverride(
            slug: canonical,
            rate: slate,
            unpriced: slate == nil ? (unpriced ?? .notPublished) : nil,
            effectiveFrom: effectiveFrom,
            source: source,
            sourceURL: sourceURL,
            checkedAt: Date(),
            note: note)

        var rows = overrides[canonical] ?? []
        // One row per (slug, effectiveFrom): re-editing the same day's entry
        // replaces it rather than stacking a second row that would resolve to
        // whichever sorted last.
        rows.removeAll { $0.effectiveFrom == effectiveFrom }
        rows.append(row)
        overrides[canonical] = rows.sorted { $0.effectiveFrom < $1.effectiveFrom }

        commit()
        return row
    }

    /// Drop every override for a slug — the row reverts to the bundled table (or
    /// to 未计价 when the bundled table never had it).
    func revert(slug: String) {
        guard overrides.removeValue(forKey: slug) != nil else { return }
        commit()
    }

    func revertAll() {
        guard !overrides.isEmpty else { return }
        overrides = [:]
        commit()
    }

    // MARK: - Checking

    /// Run a full check against every source.
    ///
    /// `autoApply` is the difference between the two ways this is reached, and
    /// it is the user's own distinction rather than an implementation detail:
    ///
    /// - **The 查询更新 button** (`autoApply: true`) applies what it reads. The
    ///   user asked, so the result takes effect and the report says what changed.
    /// - **The weekly background check** (`autoApply: false`) only *proposes*:
    ///   rows that differ become candidates the card surfaces, and nothing is
    ///   written until the user acts. A price that changes under the user
    ///   without them asking is the thing this app's cost rules exist to avoid,
    ///   and a background job is exactly where that would happen quietly.
    ///
    /// USD and CNY are treated identically here; where the numbers come from is
    /// the sources' business.
    func check(autoApply: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var report = Report(at: Date())
        var found: [ModelPriceCatalog.Candidate] = []

        // Dollar vendors, one conditional request.
        do {
            if let rows = try await ModelPriceSources.fetchModelsDev() {
                for row in rows {
                    found.append(candidate(from: row, source: .fetchedUSD,
                                           url: "https://models.dev/api.json"))
                }
            }
        } catch {
            report.error = "models.dev：\(error.localizedDescription)"
        }

        // Yuan vendors, one page each. A page that fails or reads as nothing is
        // reported and skipped — never back-filled from an aggregate source,
        // whose domestic prices are the international ones.
        for vendor in ModelPriceSources.vendors {
            do {
                let html = try await ModelPriceSources.fetchPage(vendor.url)
                let rows = vendor.parse(html)
                if rows.isEmpty {
                    report.failures.append(.init(vendor: vendor.name,
                                                 reason: "页面结构与解析器不符，未能读取"))
                    continue
                }
                for row in rows {
                    found.append(candidate(from: row, source: .fetchedCNY, url: vendor.url))
                }
            } catch {
                report.failures.append(.init(vendor: vendor.name,
                                             reason: error.localizedDescription))
            }
        }
        report.failures.append(contentsOf: ModelPriceSources.uncheckable.map {
            Failure(vendor: $0.vendor, reason: $0.reason)
        })
        report.unparsableVendors = report.failures.map(\.vendor)
        report.unchanged = found.filter(\.isUnchanged).count

        if autoApply {
            for row in found where !row.isUnchanged {
                apply(row)
                switch row.source {
                case .fetchedUSD: report.appliedUSD += 1
                case .fetchedCNY: report.appliedCNY += 1
                default: break
                }
            }
            candidates = []
            // `apply` already wrote each row; only the report and the timestamp
            // are left.
            self.report = report
            lastCheckedAt = report.at
            saveMeta()
        } else {
            // Keep only the rows that differ from what is live — a proposal
            // identical to the current table is noise, and on the second week
            // it would be the entire list.
            candidates = found.filter { !$0.isUnchanged }
            self.report = report
            lastCheckedAt = report.at
            saveMeta()
        }
        NotificationCenter.default.post(name: .modelPriceDidChange, object: nil)
    }

    /// Turn a source's row into a proposal, resolving what is live now so the
    /// card can show a diff instead of a bare number.
    private func candidate(from row: ModelPriceSources.ParsedRow,
                           source: ModelPricing.PriceSource,
                           url: String) -> Candidate {
        let current = ModelPricing.resolve(row.slug)
        let proposed = ModelPricing.Resolution.priced(row.rate)
        return Candidate(slug: row.slug,
                         rate: row.rate,
                         unpriced: nil,
                         source: source,
                         sourceURL: url,
                         current: current,
                         note: row.note,
                         isUnchanged: current == proposed)
    }

    /// Called at launch: run a check only when the last one has aged out. Never
    /// applies — see `check(apply:)`.
    func autoCheckIfStale() {
        guard let lastCheckedAt else {
            // Never checked: wait for a manual 查询更新 rather than making the
            // first network request of a fresh install behind the user's back.
            return
        }
        guard Date().timeIntervalSince(lastCheckedAt) > Self.checkInterval else { return }
        guard !isChecking else { return }
        Task { await check(autoApply: false) }
    }

    // MARK: - Check queue

    /// Replace the pending candidates with a fetch's findings. Rows that agree
    /// with what is already live are recorded as `isUnchanged` and not applied.
    func setCandidates(_ rows: [Candidate], report: Report) {
        candidates = rows
        self.report = report
        lastCheckedAt = report.at
        saveMeta()
    }

    func applyAllCandidates() {
        for candidate in candidates where !candidate.isUnchanged {
            apply(candidate)
        }
        candidates = []
    }

    func dismissAllCandidates() {
        candidates = []
        // The check did happen; only its proposal was discarded. Keeping the
        // timestamp is what stops a dismissed diff from being re-proposed on
        // every launch.
        saveMeta()
    }

    func apply(_ candidate: Candidate) {
        // A fetch always starts today. Backdating it would rewrite usage already
        // recorded under the old price, which is the one thing a fetch must
        // never do silently; the editor is where a user can pick an earlier
        // date knowingly.
        try? record(slug: candidate.slug,
                    rate: candidate.rate,
                    unpriced: candidate.unpriced,
                    effectiveFrom: ModelPricing.dayKey(Date()),
                    source: candidate.source,
                    sourceURL: candidate.sourceURL,
                    note: candidate.note)
        candidates.removeAll { $0.slug == candidate.slug }
    }

    func dismiss(_ candidate: Candidate) {
        candidates.removeAll { $0.slug == candidate.slug }
    }

    /// Drop any candidate whose slug the live table already agrees on — called
    /// after an edit so a stale proposal does not sit next to the fresh row.
    func pruneCandidates() {
        candidates.removeAll { candidate in
            candidate.current == resolution(for: candidate.slug)
        }
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var version: Int
        var overrides: [ModelPricing.PriceOverride]
        var lastCheckedAt: Date?
    }

    private static let fileVersion = 1

    private func commit() {
        ModelPricing.replaceOverrides(overrides)
        pruneCandidates()
        save()
        NotificationCenter.default.post(name: .modelPriceDidChange, object: nil)
    }

    private func save() {
        saveMeta()
    }

    private func saveMeta() {
        let rows = overrides.values.flatMap { $0 }
        let stored = Stored(version: Self.fileVersion, overrides: rows, lastCheckedAt: lastCheckedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        // Atomic, and left at the default mode: this file holds prices, not
        // credentials, exactly like cursor-ledger.json next to it.
        try? data.write(to: file, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data),
              stored.version == Self.fileVersion else { return }
        var table: [String: [ModelPricing.PriceOverride]] = [:]
        for row in stored.overrides where row.resolution != nil {
            table[row.slug, default: []].append(row)
        }
        overrides = table.mapValues { $0.sorted { $0.effectiveFrom < $1.effectiveFrom } }
        lastCheckedAt = stored.lastCheckedAt
    }

    /// `yyyy-MM-dd` — the day-key format the usage rollups use, so an override's
    /// `effectiveFrom` compares as a string against a stored usage day.
    static func isDayKey(_ text: String) -> Bool {
        guard text.count == 10 else { return false }
        let parts = text.split(separator: "-")
        guard parts.count == 3 else { return false }
        guard parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        guard parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        return ModelPricing.dayKey(fromDayKey: text) != nil
    }
}

extension ModelPricing {
    /// Parse a `yyyy-MM-dd` day key back to a date, or nil. Used only to reject
    /// impossible dates in the editor (`2026-13-45`), never on a hot path.
    static func dayKey(fromDayKey text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        guard let date = Calendar.current.date(from: components) else { return nil }
        return dayKey(date) == text ? date : nil
    }
}

extension ModelPricing.Currency {
    /// The catalog's editor needs a stable order for its picker.
    static let allCases: [ModelPricing.Currency] = [.cny, .usd]
}
