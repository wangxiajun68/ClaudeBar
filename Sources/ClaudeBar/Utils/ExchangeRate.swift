import Foundation
import Combine

/// USD → CNY spot rate, for the one thing the estimator cannot do by itself:
/// add a dollar amount to a yuan amount.
///
/// `ModelPricing` deliberately holds no exchange rate — a rate is a moving
/// number, and baking one into a price table would make two different kinds of
/// estimate look like the same kind. This type is where that number lives when
/// the user explicitly asks for a single converted figure, so the conversion is
/// always attributable to a dated, visible rate.
///
/// **No request is made until the user asks for a converted display.** The
/// default (`CostDisplay.split`) never touches the network, matching how the
/// rest of this app treats outbound requests: the code path does not run until
/// the capability is switched on. A user can also pin a manual rate and never
/// fetch at all.
///
/// Sources are both keyless and daily:
///   - `open.er-api.com` (exchangerate-api's free tier; publishes its own
///     `time_next_update_utc`)
///   - `latest.currency-api.pages.dev` (fawazahmed0/currency-api, a static
///     file behind a CDN) as the fallback when the first is unreachable.
///
/// Only CNY matters here — the app prices four vendors in CNY and three in USD
/// and has no third currency — so nothing generic is built around this.
final class ExchangeRate: ObservableObject {
    static let shared = ExchangeRate()

    /// How many CNY one USD buys. Nil until a fetch succeeds or the user pins
    /// a rate; nil means "cannot convert", never "assume 1".
    @Published private(set) var usdToCny: Double?
    /// When the *provider* says its number was last refreshed (not when we
    /// fetched it). Nil for a manual rate, which has no provider date.
    @Published private(set) var providerDate: Date?
    @Published private(set) var isFetching = false
    /// Set when the last attempt failed, so the settings tile can explain why
    /// the display fell back to two currencies.
    @Published private(set) var lastError: String?

    private var cancel: AnyCancellable?
    private var inflight: Task<Void, Never>?

    /// Cached in UserDefaults rather than a file: it is three scalars, and it
    /// must survive a relaunch so a user who chose a converted display is not
    /// forced through a network call on every launch.
    private enum Keys {
        static let rate = "exchangeRate.usdToCny"
        static let providerDate = "exchangeRate.providerDate"
        static let fetchedAt = "exchangeRate.fetchedAt"
    }

    /// The provider refreshes daily; asking more than twice a day is pure
    /// waste and a needless outbound request.
    private static let ttl: TimeInterval = 12 * 3600

    private init() {
        let stored = UserDefaults.standard.double(forKey: Keys.rate)
        if stored > 0 { usdToCny = stored }
        let date = UserDefaults.standard.double(forKey: Keys.providerDate)
        if date > 0 { providerDate = Date(timeIntervalSince1970: date) }

        // Fetch only when conversion is actually on, and only when the cached
        // rate is missing or older than the TTL. `dropFirst` skips the current
        // value: launching with the display already set to a converted mode
        // still needs a fetch, and that is handled by `start()` below.
        cancel = AppPreferences.shared.$costDisplay
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] display in
                guard display.needsRate else { return }
                self?.refreshIfStale()
            }
    }

    /// Called once at launch. Fetches only if the saved preference already
    /// asks for a converted display.
    func start() {
        guard AppPreferences.shared.costDisplay.needsRate else { return }
        refreshIfStale()
    }

    /// The rate to display with, honouring a manual override. Nil means the
    /// caller must fall back to showing both currencies.
    var effectiveRate: Double? {
        if let manual = AppPreferences.shared.manualUSDToCNY { return manual }
        return usdToCny
    }

    var isManual: Bool { AppPreferences.shared.manualUSDToCNY != nil }

    /// True when the cached rate is older than the TTL but still usable — worth
    /// showing, worth flagging.
    var isStale: Bool {
        let fetched = UserDefaults.standard.double(forKey: Keys.fetchedAt)
        guard fetched > 0 else { return false }
        return Date().timeIntervalSince1970 - fetched > Self.ttl
    }

    /// "1 USD = 7.12 CNY · 2026-09-24" / "手动汇率 1 USD = 7.20 CNY".
    var note: String? {
        guard let rate = effectiveRate else { return nil }
        let amount = String(format: "%.4g", rate)
        if isManual { return "手动汇率 1 USD = \(amount) CNY" }
        guard let providerDate else { return "1 USD = \(amount) CNY" }
        let day = UsageStats.formatter("yyyy-MM-dd").string(from: providerDate)
        let suffix = isStale ? "，已超过 12 小时未更新" : ""
        return "1 USD = \(amount) CNY · \(day)\(suffix)"
    }

    /// Fetch when there is no usable rate or it has aged out. Single-flight:
    /// both the launch hook and a preference change can land here at once.
    func refreshIfStale() {
        guard AppPreferences.shared.manualUSDToCNY == nil else { return }
        let fetched = UserDefaults.standard.double(forKey: Keys.fetchedAt)
        let age = fetched > 0 ? Date().timeIntervalSince1970 - fetched : .infinity
        guard age > Self.ttl || usdToCny == nil else { return }
        refresh()
    }

    /// Force a fetch — the settings tile's "更新" button. Rethrows nothing;
    /// failure surfaces through `lastError`.
    func refresh() {
        guard inflight == nil else { return }
        isFetching = true
        // One `@MainActor` task rather than `Task { await MainActor.run { … } }`:
        // the nested form captures the `[weak self]` shadow into a second
        // closure, which is a Swift 6 error (`#SendableClosureCaptures`).
        inflight = Task { @MainActor [weak self] in
            let quote = await Self.fetch()
            guard let self else { return }
            self.isFetching = false
            self.inflight = nil
            if let quote {
                self.usdToCny = quote.rate
                self.providerDate = quote.date
                self.lastError = nil
                UserDefaults.standard.set(quote.rate, forKey: Keys.rate)
                UserDefaults.standard.set(quote.date?.timeIntervalSince1970 ?? 0,
                                          forKey: Keys.providerDate)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.fetchedAt)
            } else {
                // Keep whatever is cached: a stale rate beats no rate, and
                // `isStale` already tells the user it is old. There is only one
                // failure to report because there is only one thing the user
                // can do about it (set a manual rate).
                self.lastError = "汇率查询失败，请检查网络或改用手动汇率"
            }
            NotificationCenter.default.post(name: .exchangeRateDidChange, object: nil)
        }
    }

    struct Quote {
        let rate: Double
        let date: Date?
    }

    private static func fetch() async -> Quote? {
        // Primary, then fallback. Both failing is one outcome for the caller —
        // it cannot act on either host separately.
        if let quote = await fetchERAPI() { return quote }
        return await fetchCurrencyAPI()
    }

    /// `open.er-api.com/v6/latest/USD` → `rates.CNY`.
    private static func fetchERAPI() async -> Quote? {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return nil }
        guard let json = await getJSON(url) else { return nil }
        guard (json["result"] as? String) == "success",
              let rates = json["rates"] as? [String: Any],
              let rate = number(rates["CNY"]), rate > 0 else { return nil }
        // The provider's own refresh stamp, not ours — the number is what is
        // dated, and it is always a day behind our fetch.
        return Quote(rate: rate, date: parseProviderDate(json["time_last_update_utc"] as? String))
    }

    /// `latest.currency-api.pages.dev/v1/currencies/usd.json` → `usd.cny`.
    /// A static file behind a CDN, so it stays up when the JSON API does not.
    private static func fetchCurrencyAPI() async -> Quote? {
        guard let url = URL(string: "https://latest.currency-api.pages.dev/v1/currencies/usd.json") else { return nil }
        guard let json = await getJSON(url), let usd = json["usd"] as? [String: Any],
              let rate = number(usd["cny"]), rate > 0 else { return nil }
        let date = (json["date"] as? String).flatMap { day in
            formatter("yyyy-MM-dd").date(from: day)
        }
        return Quote(rate: rate, date: date)
    }

    private static func getJSON(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        // These hosts serve JSON to any client; the UA only makes the free
        // tier's logs legible.
        request.setValue("ClaudeBar/\(appVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    /// "Thu, 24 Sep 2026 00:02:32 +0000" — the free tier's format. Parsed with
    /// a fixed `en_US_POSIX` locale: the host always emits English weekday and
    /// month names, and a device set to Chinese would otherwise fail to parse.
    private static func parseProviderDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return rfc1123.date(from: text)
    }

    private static let rfc1123: DateFormatter = {
        let made = DateFormatter()
        made.locale = Locale(identifier: "en_US_POSIX")
        made.timeZone = TimeZone(identifier: "UTC")
        made.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return made
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let made = DateFormatter()
        made.locale = Locale(identifier: "en_US_POSIX")
        made.timeZone = TimeZone(identifier: "UTC")
        made.dateFormat = format
        return made
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

extension Notification.Name {
    static let exchangeRateDidChange = Notification.Name("com.claudebar.exchangeRateDidChange")
}
