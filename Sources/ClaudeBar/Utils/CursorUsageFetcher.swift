import Foundation
import os

/// Cursor's plan allowance, read from the account itself (no login, no browser
/// cookies captured by us — the token is the one Cursor already stored locally).
///
/// **Two things are counted here, and they are not the same reading:**
///
/// * the **monthly plan** — dollars of included usage, reset on the billing
///   cycle boundary (`GetCurrentPeriodUsage`). Under it Cursor reports **two
///   named pools**, and they are Cursor's own names, taken from its
///   `auto-spillover-ui.ts`: **"Cursor Models"** (`autoPercentUsed` — the
///   first-party Grok / Composer models) and **"Other Models"**
///   (`apiPercentUsed` — third-party models billed at API rates). They are not
///   two money limits: the account carries a **single** `limit` +
///   `includedSpend`, and the two pools are the percentages beneath it. That is
///   why the popup's chip shows them as two named gauges rather than as a
///   second money bar;
/// * the **Grok Bot weekly window** — an independent allowance with its own
///   weekly reset (`GetSandUsageStatus`). It can sit near 0% while the monthly
///   plan is exhausted, which is exactly why it earns its own line instead of
///   being folded into one number.
///
/// **Two authentication surfaces, never interchangeable** (getting this wrong is
/// the difference between 200 and 401):
///
/// | host | header |
/// |---|---|
/// | `api2.cursor.sh` (Connect RPC) | `Authorization: Bearer <bare JWT>` |
/// | `cursor.com/api/*` (web) | `Cookie: WorkosCursorSessionToken=<sub>%3A%3A<JWT>` |
///
/// The web POSTs additionally require `Origin: https://cursor.com` or they 403.
/// So the token is sent *bare* to the RPC and *prefixed+encoded* to the web —
/// one credential, two spellings, chosen per host.
enum CursorUsageFetcher {
    private static let logger = Logger(subsystem: "com.claudebar.app",
                                       category: "CursorUsage")

    /// A single reading of Cursor's allowance. Both halves are optional because
    /// they fail independently: the plan call can succeed while the Grok window
    /// is unavailable (or vice versa), and the caller should still show what it
    /// got rather than an all-or-nothing blank.
    struct Snapshot: Equatable {
        var plan: PlanUsage?
        var grok: GrokUsage?
        /// Shown when neither half produced a reading.
        var note: String? = nil

        var isEmpty: Bool { plan == nil && grok == nil }
    }

    /// The monthly plan allowance, and the two visibly named pools inside it.
    ///
    /// Cursor reports **percentages already on a 0–100 scale** (`autoPercentUsed`,
    /// `apiPercentUsed`, `totalPercentUsed`) and **money in cents** (`totalSpend`,
    /// `limit`, …). This type keeps both in the API's own units and leaves the
    /// ×100 / ÷100 presentation to the view, so a formatting change never has to
    /// touch the decoding.
    ///
    /// `autoPercentUsed` / `apiPercentUsed` are **Cursor's own pool names**, so
    /// they are read as "Cursor Models" / "Other Models" inside the popup —
    /// see `cursorModelsFraction` / `otherModelsFraction` below.
    struct PlanUsage: Equatable, Codable {
        /// Overall used percentage, 0–100, as reported.
        var usedPercent: Double
        /// The **Other Models** pool — Cursor's `apiPercentUsed`, 0–100, when
        /// reported. "Consumed by named models": the third-party models that are
        /// billed at API rates on top of the first-party allowance.
        var apiPercentUsed: Double?
        /// The **Cursor Models** pool — Cursor's `autoPercentUsed`, 0–100, when
        /// reported. "Includes Cursor Grok and Composer", the first-party models
        /// that are the reason the plan is bought.
        var autoPercentUsed: Double?
        /// `totalSpend` in cents.
        var totalSpendCents: Double?
        /// `limit` in cents — what the plan includes.
        var limitCents: Double?
        /// `includedSpend` in cents.
        var includedSpendCents: Double?
        /// `bonusSpend` in cents (promotional usage beyond what was purchased).
        var bonusSpendCents: Double?
        /// Cursor's own server-side "you have hit the limit" flag. When set,
        /// the plan is spent regardless of how the money fields read.
        var hitLimit: Bool = false
        /// Cursor's own headline ("You've hit your usage limit").
        var displayMessage: String?
        var billingCycleStart: Date?
        var billingCycleEnd: Date?

        /// Fraction of the plan's **included** allowance spent, 0–1.
        ///
        /// **Not** `totalSpend / limit`: `totalSpend` sums the included spend
        /// *and* `bonusSpend`, and the bonus is promotional usage that the plan
        /// does not cap. Measured on this account it made the raw ratio 24.6
        /// (2462%) — a number that would render as a pinned-full bar on an
        /// account that is merely at its included ceiling. The included spend is
        /// the numerator that can actually exceed `limit`, so it is the one that
        /// answers "how much of what I paid for is gone".
        var usedFraction: Double {
            if hitLimit { return 1 }
            if let included = includedSpendCents, let limit = limitCents, limit > 0 {
                return min(1, max(0, included / limit))
            }
            if let spent = totalSpendCents, let limit = limitCents, limit > 0 {
                // No separate `includedSpend` field in this response shape; the
                // total is the only spend figure, so it is the only numerator.
                return min(1, max(0, spent / limit))
            }
            return min(1, max(0, usedPercent / 100))
        }

        /// The **Cursor Models** pool as a used fraction, 0–1 — the first of the
        /// two named gauges on the popup chip.
        ///
        /// `nil` when Cursor did not report `autoPercentUsed`. That is a real
        /// state (older / team shapes omit it), and a missing pool must render
        /// as *absent*, not as a 0% bar that reads "all of it is left".
        var cursorModelsFraction: Double? {
            autoPercentUsed.map { min(1, max(0, $0 / 100)) }
        }

        /// The **Other Models** pool as a used fraction, 0–1 — the second named
        /// gauge. `nil` when `apiPercentUsed` is absent, for the same reason as
        /// above.
        var otherModelsFraction: Double? {
            apiPercentUsed.map { min(1, max(0, $0 / 100)) }
        }

        /// Whether Cursor reported neither pool — the chip has nothing to graph
        /// and must say so instead of drawing an empty pair.
        var hasNamedPools: Bool { cursorModelsFraction != nil || otherModelsFraction != nil }

        /// "used / limit" in dollars, e.g. "$492.45 / $20". `nil` when the API
        /// did not send the money fields (free / enterprise shapes).
        var spendText: String? {
            guard let spent = totalSpendCents, let limit = limitCents else { return nil }
            return "\(money(spent)) / \(money(limit))"
        }

        /// The reset moment, in the API's epoch-millisecond string form.
        var resetsAt: Date? { billingCycleEnd }
    }

    /// The Grok Bot weekly window — a quota independent of the monthly plan.
    struct GrokUsage: Equatable, Codable {
        /// 0–100, as reported (0.52 means "0.52% used", not "0.52 fraction").
        var usedPercent: Double
        var planName: String?
        var hasAvailableUsage: Bool?
        var currentPeriodStart: Date?
        var nextReset: Date?
    }

    /// How long a reading is served without re-asking. Gold-plated on purpose:
    /// the plan moves on a monthly boundary and the Grok window weekly, so a
    /// few minutes of staleness is invisible — and it keeps the probe from
    /// hammering the account API every time the popup re-renders.
    static let freshWindow: TimeInterval = 180

    /// Hard floor between two network probes, regardless of caller. Cursor's
    /// endpoints are not rate-limited in a way that is documented, but a
    /// popup that refreshes on a timer plus a manual button must not be able to
    /// issue bursts; three seconds is the number the field notes converge on.
    static let minInterval: TimeInterval = 3

    private static let cache = Cache()

    private final class Cache {
        private let lock = NSLock()
        private var snapshot: Snapshot?
        private var at: Date?
        /// The last time a probe *started*, for the `minInterval` floor.
        private var lastProbe: Date?

        func fresh() -> Snapshot? {
            lock.lock(); defer { lock.unlock() }
            guard let snapshot, let at, Date().timeIntervalSince(at) < freshWindow else { return nil }
            return snapshot
        }

        /// `true` when a probe is allowed right now; records the attempt.
        func admitProbe() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let lastProbe, Date().timeIntervalSince(lastProbe) < minInterval { return false }
            lastProbe = Date()
            return true
        }

        func store(_ snapshot: Snapshot) {
            lock.lock(); defer { lock.unlock() }
            self.snapshot = snapshot
            at = Date()
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            snapshot = nil
            at = nil
        }
    }

    /// Drop the in-memory cached reading so the next caller goes to the
    /// network. Called by a manual refresh, where the whole point is a new
    /// reading. The *on-disk* last reading is deliberately kept — see
    /// `lastKnown()`.
    static func invalidateCache() { cache.clear() }

    // MARK: - Last known reading (across launches)

    /// The last successful reading, persisted to disk.
    ///
    /// **Why this exists.** At launch the first probe always fails: the app
    /// fires it before the VPN has written the system proxy (mihomo is ready
    /// 2–4 s in; see `fetch()`), so the popup used to open on a spinner and
    /// then on a note, with the last real numbers gone — the *same* numbers that
    /// were on screen a minute before the app was closed. A quota that moves on
    /// a monthly (and weekly) boundary does not become wrong in the seconds a
    /// relaunch takes, so the previous reading is shown immediately and the
    /// figures are replaced in place when the live one lands.
    ///
    /// It is a plain file rather than `UserDefaults`: it belongs next to the
    /// other ClaudeBar state under Application Support, and it carries no
    /// secrets (a used percentage and two dates — no token, no email).
    struct LastKnown: Codable, Equatable {
        var plan: PlanUsage?
        var grok: GrokUsage?
        /// When the reading was taken, so a caller can say how old it is.
        var at: Date
    }

    private static let lastKnownFile = FilePaths.appSupportDir
        .appendingPathComponent("cursor-allowance.json")

    /// The persisted reading, or nil when there has never been one.
    static func lastKnown() -> LastKnown? {
        guard let data = try? Data(contentsOf: lastKnownFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LastKnown.self, from: data)
    }

    /// Remember a good reading for the next launch. Best-effort: a failed write
    /// costs the warm start, never the live one.
    private static func remember(_ snapshot: Snapshot) {
        guard !snapshot.isEmpty else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(LastKnown(plan: snapshot.plan,
                                                   grok: snapshot.grok,
                                                   at: Date())) else { return }
        try? data.write(to: lastKnownFile, options: .atomic)
    }

    /// Read Cursor's allowance. Returns a `Snapshot` whose `note` explains any
    /// failure — never throws, because every caller is a UI refresh that wants
    /// to *show* the failure, not handle it.
    static func fetch() async -> Snapshot {
        if let fresh = cache.fresh() { return fresh }

        // Re-read credentials here, inside the probe, so a token Cursor rotated
        // while the app was open is picked up without restarting ClaudeBar.
        guard let credentials = await Task.detached(priority: .utility, operation: {
            CursorDB.readCredentials()
        }).value else {
            return Snapshot(note: "未找到 Cursor 数据")
        }
        guard let token = credentials.accessToken, !token.isEmpty else {
            return Snapshot(note: "Cursor 未登录")
        }
        // Retried like the Codex fetch, but for a failure mode the Codex
        // fetcher does not have.
        //
        // The probe uses the *system* proxy (no `connectionProxyDictionary`),
        // and the app applies that proxy seconds after it starts —
        // `VpnManager.waitUntilReady` writes it only once mihomo
        // answers `GET /version`, 2–4 s in. The launch fetch fires before that,
        // so it is sent to whatever the last session left behind: a
        // `127.0.0.1:<port>` with no listener, which fails instantly. Every
        // launch was therefore born with "Cursor 额度查询失败" and stayed there
        // until the 20-minute poll or a manual refresh. Measured in `vpn.log`
        // and the unified log: kernel ready 13:34:54, requests failed
        // 13:34:53.880, proxy written 13:34:57.
        //
        // A retry on the *timer* alone would not do: the second attempt needs to
        // land after the proxy is written, which is a fixed few seconds away, so
        // the backoff is the delay. `minInterval` used to reject any second
        // probe inside three seconds and answer "Cursor 额度刷新过快" — a
        // different wrong answer — so the wait is part of the retry rather than
        // a rejection of it.
        for attempt in 1...2 {
            guard !Task.isCancelled else { return retryExhaustedNote() }
            guard cache.admitProbe() else {
                // Still too soon (another caller probed a moment ago); serve the
                // last reading if we have one rather than issuing a burst.
                return cache.fresh() ?? Snapshot(note: "Cursor 额度刷新过快")
            }

            async let plan = fetchPlan(token: token)
            async let grok = fetchGrok(subject: credentials.subject, token: token)
            let (planResult, grokResult) = await (plan, grok)

            var snapshot = Snapshot(plan: planResult, grok: grokResult)
            if !snapshot.isEmpty {
                snapshot.note = nil
                cache.store(snapshot)
                remember(snapshot)
                return snapshot
            }
            guard attempt < 2 else { break }
            logger.warning("Cursor allowance probe failed; retrying once after the launch proxy window")
            try? await Task<Never, Never>.sleep(for: .milliseconds(retryDelayMilliseconds))
        }
        return retryExhaustedNote()
    }

    /// How long the one retry waits before its probe.
    ///
    /// Chosen to clear both gates it has to clear: the fetcher's own
    /// `minInterval` floor (3 s) and the app's system-proxy write (mihomo ready
    /// at ~2 s plus the `networksetup` pass, measured 3–4 s from launch). 4 s
    /// leaves the retry landing just after the proxy is written.
    static let retryDelayMilliseconds = 4_000

    /// What a caller gets when every attempt came back empty. Names the two
    /// likely causes in one line — a proxy that has not come up yet, or a
    /// signed-out Cursor — because at launch those are the only two.
    private static func retryExhaustedNote() -> Snapshot {
        Snapshot(note: "Cursor 额度查询失败")
    }

    /// The account's billing cycle, from the last good allowance reading.
    ///
    /// Taken from memory rather than persisted separately: `CursorUsageStore`
    /// already holds a `PlanUsage` with both ends of the cycle, and it is
    /// persisted to `cursor-allowance.json`, so this is a read of state the app
    /// keeps anyway. It exists for `CursorLedger`'s window planner, which needs
    /// a fallback window for a period Cursor will not answer for (年 / 全部).
    ///
    /// `nil` before the first successful probe — the planner then narrows to
    /// the most recent fitting slice and says so.
    @MainActor
    static func billingCycle() -> DateInterval? {
        guard let start = CursorUsageStore.shared.plan?.billingCycleStart,
              let end = CursorUsageStore.shared.plan?.billingCycleEnd,
              end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    // MARK: - Plan (api2.cursor.sh Connect RPC)

    /// `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
    /// with a **bare** Bearer JWT. This is the primary, most complete reading:
    /// it carries the money fields, both percentages and Cursor's own message.
    ///
    /// `https://www.cursor.com` 308-redirects to the apex, so the RPC host is
    /// used directly instead of following one.
    ///
    /// **No `connectionProxyDictionary` is set — deliberately.** Both probes
    /// call `URLSession.shared`, which inherits the system's HTTP/HTTPS proxy,
    /// and that is the path that reaches `api2.cursor.sh` from a mainland
    /// network: the direct route 401s/`403`s behind the GFW, and the tunneled
    /// one is the only one that carries the token through. A
    /// `connectionProxyDictionary` pointing at the mihomo mixed port was
    /// considered and **rejected** — it would hard-wire the probe to
    /// ClaudeBar's own VPN being enabled, and the reading is supposed to follow
    /// whatever network the user is on (this is also why a direct probe answers
    /// 200 when a system proxy is up: the proxy is what is doing the reaching).
    ///
    /// The cost of inheriting the system proxy is the launch window: for the
    /// first ~4 s the proxy may still point at a dead port from the last
    /// session. `fetch()`'s retry is what covers that.
    private static func fetchPlan(token: String) async -> PlanUsage? {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            logger.error("Cursor plan usage request failed")
            return nil
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            logger.error("Cursor plan usage HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
            return nil
        }
        return parsePlan(data)
    }

    /// Decode the plan payload. **Every field is optional** and unknown shapes
    /// yield `nil` rather than a zero — a zero would read as "0% used", which is
    /// a worse lie than "unavailable". `totalPercentUsed` is the only field the
    /// view truly needs, so a response with just that still produces a value.
    static func parsePlan(_ data: Data) -> PlanUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let planUsage = root["planUsage"] as? [String: Any] ?? [:]

        // Percentages first: without one there is nothing to draw.
        let used = number(planUsage["totalPercentUsed"])
            ?? number(planUsage["apiPercentUsed"])
            ?? number(planUsage["autoPercentUsed"])
            ?? planSpendFallback(planUsage)
        guard let used else { return nil }

        return PlanUsage(
            usedPercent: clampPercent(used),
            apiPercentUsed: number(planUsage["apiPercentUsed"]).map(clampPercent),
            autoPercentUsed: number(planUsage["autoPercentUsed"]).map(clampPercent),
            totalSpendCents: number(planUsage["totalSpend"]),
            limitCents: number(planUsage["limit"]),
            includedSpendCents: number(planUsage["includedSpend"]),
            bonusSpendCents: number(planUsage["bonusSpend"]),
            hitLimit: (root["displayMessage"] as? String)?
                .localizedCaseInsensitiveContains("hit your usage limit") ?? false,
            displayMessage: root["displayMessage"] as? String,
            billingCycleStart: epoch(root["billingCycleStart"]),
            billingCycleEnd: epoch(root["billingCycleEnd"])
        )
    }

    /// When no percentage is present, derive one from the money so a plan with
    /// only `totalSpend` / `limit` still renders.
    private static func planSpendFallback(_ planUsage: [String: Any]) -> Double? {
        guard let spent = number(planUsage["totalSpend"]),
              let limit = number(planUsage["limit"]), limit > 0 else { return nil }
        return min(100, max(0, spent / limit * 100))
    }

    // MARK: - Grok Bot weekly window (cursor.com web)

    /// `POST https://cursor.com/api/dashboard/get-sand-usage-status`. This is a
    /// **web** endpoint, so it wants the cookie form *and* an `Origin` header —
    /// the bare JWT that satisfies the RPC above would 401 here.
    private static func fetchGrok(subject: String?, token: String) async -> GrokUsage? {
        guard let subject, !subject.isEmpty else { return nil }
        guard let url = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cookieValue(subject: subject, token: token),
                         forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            logger.error("Cursor Grok usage request failed")
            return nil
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            logger.error("Cursor Grok usage HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
            return nil
        }
        return parseGrok(data)
    }

    /// The `WorkosCursorSessionToken` value: `<sub>::<jwt>`, percent-encoded.
    ///
    /// The `sub` contains a `|` (`google-oauth2|user_…`) and the cookie value
    /// contains the `::` separator; both must be percent-encoded or the header
    /// (and Cursor's parser) mis-splits them. `:` is encoded too — that is what
    /// the web client sends, and it is what the server accepts.
    static func cookieValue(subject: String, token: String) -> String {
        // Encode the *value* only. The name's own `=` is cookie syntax and must
        // stay literal — running it through the encoder turned the header into
        // `WorkosCursorSessionToken%3D…`, which is a cookie named
        // "WorkosCursorSessionToken%3D…" and authenticates nothing.
        var allowed = CharacterSet.urlQueryAllowed
        // `urlQueryAllowed` leaves `:` and `+` alone, and both are meaningful
        // inside a cookie value; encode them explicitly along with the ones the
        // value itself contains.
        allowed.remove(charactersIn: ":=+&|")
        let value = "\(subject)::\(token)".addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "WorkosCursorSessionToken=\(value)"
    }

    static func parseGrok(_ data: Data) -> GrokUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let used = number(root["usagePercent"]) else { return nil }
        return GrokUsage(
            usedPercent: clampPercent(used),
            planName: root["cursorPlanName"] as? String,
            hasAvailableUsage: root["hasAvailableUsage"] as? Bool,
            currentPeriodStart: iso8601(root["currentPeriodStart"]),
            nextReset: iso8601(root["nextResetTimestampUtc"])
        )
    }

    // MARK: - Decoding helpers

    private static func clampPercent(_ value: Double) -> Double { min(100, max(0, value)) }

    /// A finite `Double` from a JSON value that may be a number **or a string**.
    ///
    /// Cursor is inconsistent about this across its own endpoints: the period
    /// and Grok payloads send numbers, while `GetAggregatedUsageEvents` sends
    /// every token count as a string (`"inputTokens":"914"`). Shared with
    /// `CursorLedger` rather than reimplemented, because a second coercion that
    /// only accepted `NSNumber` would silently read the whole aggregation as
    /// zero — a wrong answer that looks like an empty month.
    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = value as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }

    /// Cursor returns the billing cycle as an **epoch-millisecond string**
    /// (`"1787903707000"`), while the web endpoints use ISO-8601 for the Grok
    /// window. Two formats on two surfaces for the same concept, so both parsers
    /// are tolerant of either — a shape swap must not blank the reset line.
    private static func epoch(_ value: Any?) -> Date? {
        if let raw = number(value), raw > 0 {
            let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
            return Date(timeIntervalSince1970: seconds)
        }
        return iso8601(value)
    }

    private static func iso8601(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Cents → dollars, with a leading sign and no trailing `.00` on whole
    /// dollars: `49245 → "$492.45"`, `2000 → "$20"`.
    static func money(_ cents: Double) -> String {
        let dollars = cents / 100
        let whole = dollars.rounded() == dollars
        return "$" + dollars.formatted(.number.precision(.fractionLength(whole ? 0 : 2)))
    }
}
