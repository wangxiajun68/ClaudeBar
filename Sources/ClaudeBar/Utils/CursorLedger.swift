import Foundation

/// Cursor's **actual charged amount**, per model, for a window.
///
/// This is the second of the two real-money sources in this app (the other is
/// OpenRouter) — see `docs/technical/15-model-cost.md`. Everything else in
/// `ModelPricing` is a list-price *estimate*; the numbers here are what Cursor
/// deducted, so they must never be added to an estimate or rendered with the
/// word 「估算」.
///
/// **Where it comes from.** `DashboardService`'s `GetAggregatedUsageEvents` on
/// `api2.cursor.sh`, authenticated with the *same bare JWT* `CursorUsageFetcher`
/// already reads out of `state.vscdb` — no new credential, no login, no cookie
/// (the cookie spelling is only for `cursor.com/api/*`).
///
/// **Why per-window and not per-day.** The RPC takes a `[startDate, endDate]`
/// window, not a period, and it is the *only* surface that returns money with a
/// model attached. `GetFilteredUsageEvents` gives per-event rows (and a
/// `conversationId`), but it is a paged ledger of ~10k rows and its window has
/// the same limit; the aggregate is the cheap read for a period-sized window.
/// Neither returns a per-day split, which is why nothing here feeds `DayUsage`
/// or the usage river — inventing a daily distribution from a window total
/// would be fabricated data.
///
/// **Two measured traps, both architectural:**
///
/// 1. **The aggregate omits `grok-bot-*` models.** Verified against the event
///    ledger for one billing cycle: the aggregate summed to $53.51 where the
///    events summed to $57.72, and the entire $4.33 difference was
///    `grok-bot-automation` / `grok-bot-default`. So the aggregate is *a*
///    reading, not *the* reading — a surface that shows it is showing "the
///    usage Cursor attributes to your plan pools", not "everything you spent".
/// 2. **Wide windows fail non-deterministically.** Requests spanning more than
///    roughly a quarter come back `{"code":"internal","message":"internal
///    error"}` with no data — and not consistently by width: 90d failed, 91d
///    succeeded, 92d failed, 100d+ failed. A 12×30-day backfilled sweep took
///    **306 seconds and still lost one chunk** with three retries each. That is
///    why this file only ever asks for a period-sized window and why a partial
///    answer is refused outright (see `Snapshot`) rather than assembled.
///
/// Everything here is a pure parse or a pure window computation so the
/// regression harness can slice it out of the source and drive it without a
/// URLSession, exactly like `CursorUsageFetcher.parsePlan`.
enum CursorLedger {

    /// One model's window total: tokens in the four buckets this app stores
    /// everywhere else, plus Cursor's own charge in cents.
    ///
    /// The buckets are **disjoint** and map 1:1 onto `ModelUsage`'s
    /// (`input` excludes the cache fields). Cursor reports them that way
    /// already — verified: for one model on one day the aggregate's
    /// `inputTokens` (914) matched the event ledger's `inputTokens` sum (914)
    /// with the cache reads counted separately — so no folding is needed and
    /// none is done.
    struct Row: Equatable, Codable {
        /// Cursor's `model_intent` — the model id as Cursor names it, e.g.
        /// `claude-opus-5-5-medium`, `grok-4.7-medium`, `composer-2.5`. Left
        /// verbatim; `ModelPricing.canonical` is the one place that reduces it.
        var model: String
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheWriteTokens: Int = 0
        /// `totalCents` — the actual charge for this model in this window.
        var costCents: Double = 0

        var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
    }

    /// A complete reading for one window.
    ///
    /// **`rows` is all-or-nothing for the requested window.** A window that had
    /// to be asked for in chunks (see `windowChunks`) only produces a
    /// `Snapshot` if *every* chunk answered; a partial sum is never returned as
    /// if it were the window's total, because a quietly-short money figure is
    /// indistinguishable from a cheap month.
    struct Snapshot: Equatable {
        var rows: [Row]
        /// The window Cursor was actually asked about.
        var windowStart: Date
        var windowEnd: Date
        /// `true` when the caller's window was wider than Cursor will answer
        /// for and had to be narrowed to the billing cycle. The UI must say so
        /// — the figure then covers one cycle, not the period on screen.
        var truncated: Bool = false

        var isEmpty: Bool { rows.isEmpty }
        var totalCents: Double { rows.reduce(0) { $0 + $1.costCents } }
    }

    /// Cursor refuses windows wider than this. Not a documented number: found
    /// by bisecting a fixed end date, where 90d failed and 91d succeeded — the
    /// failures are non-deterministic, so the usable bound is "comfortably
    /// under", not the exact edge.
    ///
    /// 31 days rather than the ~90 the endpoint tolerates: every period this app
    /// has is at most a month, so the chunks that run in practice are exactly
    /// the ones a month needs, and a *year* period (before the planner narrows
    /// it) becomes 12 small reliable requests rather than 4 large flaky ones.
    static let maxWindowDays = 31

    /// The widest window Cursor will answer for, as a duration.
    static var maxWindow: TimeInterval { Double(maxWindowDays) * 86_400 }

    // MARK: - Window planning

    /// Split `window` into requests Cursor will accept.
    ///
    /// A period-sized window is one chunk. The usage page's period can be
    /// 年/全部, which is far past the limit — those are **not** back-filled by
    /// paging a year of days: a 12-chunk sweep was measured at 306 s with a
    /// chunk still failing after three retries, which is both too slow for a
    /// page that repaints and not reliable enough to show a total. A year is
    /// narrowed to the billing cycle instead — see `plan(for:billingCycle:)`,
    /// which is what the store actually calls. This function is the general
    /// case that the narrowing falls back to when there is no cycle to use.
    ///
    /// The chunks are laid end to end with no gap and no overlap. The API's
    /// boundaries are inclusive-ish (verified: `[t0, t0]` returned data and
    /// `[t0-1, t0]` returned the same single row), so a seam belongs to exactly
    /// one chunk — the next one — and nothing is double-counted or dropped.
    static func windowChunks(_ window: DateInterval) -> [(start: Date, end: Date)] {
        guard window.duration > maxWindow else { return [(window.start, window.end)] }
        var out: [(start: Date, end: Date)] = []
        var cursor = window.start
        while cursor < window.end {
            let end = min(cursor.addingTimeInterval(maxWindow), window.end)
            out.append((cursor, end))
            cursor = end
        }
        return out
    }

    /// What to actually ask for, given the page's period window and (when
    /// known) the account's billing cycle.
    ///
    /// Returns a `truncated` flag when the period on screen could not be
    /// covered. `.year` and `.all` land here; a day / month / custom window
    /// inside the limit does not.
    static func plan(for window: DateInterval,
                     billingCycle: DateInterval?) -> (window: DateInterval, truncated: Bool) {
        if window.duration <= maxWindow { return (window, false) }
        if let cycle = billingCycle, cycle.duration > 0 {
            // The cycle is the widest window Cursor will answer for that still
            // means something to the user, so a year view degrades to it rather
            // than to an arbitrary 31-day slice of the year.
            let start = max(cycle.start, window.start)
            let end = min(cycle.end, window.end)
            if end > start {
                let clipped = DateInterval(start: start, end: end)
                if clipped.duration <= maxWindow { return (clipped, true) }
            }
        }
        // No cycle known (never probed yet): take the most recent slice that
        // fits rather than refusing, and say it is truncated.
        let start = window.end.addingTimeInterval(-maxWindow)
        return (DateInterval(start: max(start, window.start), end: window.end), true)
    }

    // MARK: - Parsing

    /// Decode `GetAggregatedUsageEvents`.
    ///
    /// The token fields arrive as **strings** (`"inputTokens":"914"`) while
    /// `totalCents` is a JSON number — a shape nothing else in this app has.
    /// `CursorUsageFetcher.number` already accepts both forms, so the same
    /// helper is used here rather than a second, subtly-different coercion.
    ///
    /// Returns `nil` only when the payload is not the expected object or has no
    /// `aggregations` array at all. A row with an empty `model_intent` is
    /// dropped (it cannot be attributed to anything) but does **not** fail the
    /// parse — one unusable row must not blank a whole window.
    static func parseAggregated(_ data: Data) -> [Row]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aggregations = root["aggregations"] as? [[String: Any]] else { return nil }
        var rows: [Row] = []
        rows.reserveCapacity(aggregations.count)
        for entry in aggregations {
            let model = (entry["modelIntent"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !model.isEmpty else { continue }
            rows.append(Row(
                model: model,
                inputTokens: int(entry["inputTokens"]),
                outputTokens: int(entry["outputTokens"]),
                cacheReadTokens: int(entry["cacheReadTokens"]),
                cacheWriteTokens: int(entry["cacheWriteTokens"]),
                costCents: CursorUsageFetcher.number(entry["totalCents"]) ?? 0
            ))
        }
        return rows
    }

    /// Decode one page of `GetFilteredUsageEvents`, summing the events into
    /// per-model rows.
    ///
    /// Kept beside `parseAggregated` because the two disagree in ways that
    /// matter and the disagreement is the point of having both:
    ///
    /// * **it includes `grok-bot-*`**, which the aggregate drops — so this is
    ///   the complete reading, and the one to use when the two must be
    ///   reconciled;
    /// * **`tokenUsage` may be absent entirely.** Non-token calls
    ///   (`isTokenBasedCall:false`, `chargedCents:0`, e.g. a `grok-bot-*`
    ///   sub-agent dispatch) send no `tokenUsage` key at all. That is a real
    ///   zero-value row, not a parse failure, and it must not abort the page.
    /// * **`cacheWriteTokens` is often absent** while the other three are
    ///   present — also zero, per the same rule.
    ///
    /// `totalCents` inside `tokenUsage` equals the event's top-level
    /// `chargedCents` exactly (checked across 9,895 archived events), so the
    /// nested figure is used and no cross-check is needed. Values are added as
    /// integers then converted, so a page of large token counts cannot drift.
    static func parseEvents(_ data: Data) -> [Row]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["usageEventsDisplay"] as? [[String: Any]] else { return nil }
        var byModel: [String: Row] = [:]
        for event in events {
            let model = (event["model"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !model.isEmpty else { continue }
            let usage = event["tokenUsage"] as? [String: Any] ?? [:]
            var row = byModel[model] ?? Row(model: model)
            row.inputTokens += int(usage["inputTokens"])
            row.outputTokens += int(usage["outputTokens"])
            row.cacheReadTokens += int(usage["cacheReadTokens"])
            row.cacheWriteTokens += int(usage["cacheWriteTokens"])
            row.costCents += CursorUsageFetcher.number(usage["totalCents"])
                ?? CursorUsageFetcher.number(event["chargedCents"]) ?? 0
            byModel[model] = row
        }
        return Array(byModel.values)
    }

    /// How many rows a page of `GetFilteredUsageEvents` holds, and whether the
    /// parse saw them all.
    ///
    /// Cursor caps `pageSize` at 1000 — 2000 and above return a body with
    /// neither `totalUsageEventsCount` nor `usageEventsDisplay` rather than an
    /// error, which reads as "no usage" to a naive parser. Anything that pages
    /// the ledger must use this constant and check `needsMorePages`.
    static let maxPageSize = 1000

    /// `true` when a page left rows behind. `parseEvents` cannot tell on its
    /// own because it only sees one page.
    static func needsMorePages(page: [Row]?,
                               reportedTotal: Int?,
                               rowsSeen: Int) -> Bool {
        guard page != nil, let reportedTotal else { return false }
        return rowsSeen < reportedTotal
    }

    /// The total row count a `GetFilteredUsageEvents` page reported, so a
    /// caller can decide whether to keep paging. `nil` when the body did not
    /// carry one (which is also how a too-large `pageSize` shows up).
    static func reportedEventCount(_ data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["totalUsageEventsCount"] as? NSNumber)?.intValue
    }

    // MARK: - Helpers

    /// A non-negative integer from a JSON value that may be a number *or* a
    /// string. Nonsense and negatives collapse to 0 rather than trapping: a
    /// token count is a display figure and must never be able to crash a
    /// refresh.
    static func int(_ value: Any?) -> Int {
        guard let number = CursorUsageFetcher.number(value), number.isFinite, number > 0 else { return 0 }
        return Int(number.rounded())
    }

    /// Fold rows onto their canonical model id, summing tokens *and* cents.
    ///
    /// This is what makes Cursor's `claude-opus-5-5-medium` land on the same
    /// row as Claude Code's `claude-opus-5-5` — `ModelPricing.canonical` drops
    /// the effort suffix. Tokens are summed because they are the same tokens;
    /// money is summed because it is the same kind of money (all Cursor's).
    /// The result is keyed by canonical id so the view can look a row up by the
    /// model name it already has.
    static func folded(_ rows: [Row]) -> [String: Row] {
        var out: [String: Row] = [:]
        for row in rows {
            let key = ModelPricing.canonical(row.model)
            guard !key.isEmpty else { continue }
            var entry = out[key] ?? Row(model: key)
            entry.inputTokens += row.inputTokens
            entry.outputTokens += row.outputTokens
            entry.cacheReadTokens += row.cacheReadTokens
            entry.cacheWriteTokens += row.cacheWriteTokens
            entry.costCents += row.costCents
            out[key] = entry
        }
        return out
    }

    /// The actual charge, as the app's cost type, so it can be formatted and
    /// currency-converted by the same `ModelPricing.present` path every other
    /// money figure uses.
    ///
    /// Cursor bills in USD (a Pro account's `totalSpend`/`limit` are cents of
    /// USD), so the cost lands in the `usd` half of `Cost` and the `cny` half
    /// stays zero. Adding a converted CNY figure here would double-count it the
    /// moment `present` converts — the conversion is a *presentation* step, and
    /// `Cost.converted(to:)` is where it happens.
    static func cost(cents: Double) -> ModelPricing.Cost? {
        guard cents > 0 else { return nil }
        return ModelPricing.Cost(usd: cents / 100)
    }
}
