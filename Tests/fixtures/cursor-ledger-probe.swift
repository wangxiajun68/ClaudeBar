import Foundation

COSTDISPLAY

// The production `ModelUsage` slice, compiled at top level rather than
// re-declared here. The money-field guard in `cursor-ledger-regressions.py`
// *is* about this type, and a fixture stub would keep compiling — and keep the
// guard passing — even after the real model grew a money field. It needs no
// stubbing: the slice is Foundation-only (`ModelPricing.cost(of:)` reads its
// token buckets).
USAGE_SOURCE

enum CursorUsageFetcher {
NUMBER
}

LEDGER

PRICING

@main struct Regression {
    static func main() {
        // --- 1. The live aggregation payload, tokens as STRINGS -------------
        // Copied from a real `GetAggregatedUsageEvents` response for one billing
        // cycle: every token field is quoted, `totalCents` is not.
        let aggregated = """
        {"aggregations":[
          {"modelIntent":"claude-opus-5-5-medium","inputTokens":"914","outputTokens":"572259",
           "cacheWriteTokens":"1672299","cacheReadTokens":"74211531","totalCents":3465.26372,"tier":1},
          {"modelIntent":"grok-4.7-medium","inputTokens":"1317999","outputTokens":"106929",
           "cacheReadTokens":"13994880","totalCents":1027.4998,"tier":2},
          {"modelIntent":"grok-4.7-high","inputTokens":"437815","outputTokens":"73323",
           "cacheReadTokens":"9378816","totalCents":600.4992,"tier":2}],
         "totalInputTokens":"1756728","totalOutputTokens":"752511",
         "totalCacheWriteTokens":"1672299","totalCacheReadTokens":"97569227",
         "totalCostCents":5093.26252}
        """
        guard let rows = CursorLedger.parseAggregated(Data(aggregated.utf8)) else {
            preconditionFailure("the live aggregation must decode")
        }
        precondition(rows.count == 3, "three model rows, was \(rows.count)")
        // The string tokens are the whole point: an `as? Int` parser reads 0.
        precondition(rows[0].inputTokens == 914,
                     "a quoted token count must decode: got \(rows[0].inputTokens)")
        precondition(rows[0].cacheReadTokens == 74_211_531, "the largest bucket must survive")
        precondition(rows[0].cacheWriteTokens == 1_672_299,
                     "the write bucket is absent on most rows, so its presence must not be lost")
        precondition(abs(rows[0].costCents - 3465.26372) < 0.0001, "the money is a float")
        // A row without `cacheWriteTokens` reads 0 — absent is zero, not a
        // failure. `grok-4.7-*` in this very payload has no such key.
        precondition(rows[1].cacheWriteTokens == 0, "an absent write bucket is zero")

        // A body with no `aggregations` at all is nil, never an empty list: the
        // `{"code":"internal"}` envelope is exactly this shape, and an empty
        // list sums to $0.00 — a free month.
        let errorEnvelope = #"{"code":"internal","message":"internal error"}"#
        precondition(CursorLedger.parseAggregated(Data(errorEnvelope.utf8)) == nil,
                     "an error envelope must be nil, not an empty result")
        precondition(CursorLedger.parseAggregated(Data("{}".utf8)) == nil)
        // …while a window that genuinely has no usage is an empty array, which
        // is a *valid* answer and must not be confused with the above.
        guard let none = CursorLedger.parseAggregated(Data(#"{"aggregations":[]}"#.utf8)) else {
            preconditionFailure("an empty aggregation array is still a valid payload")
        }
        precondition(none.isEmpty, "a genuinely empty window is an empty list")

        // A row with no model id cannot be attributed, so it is dropped — but
        // one unusable row must not blank the whole window.
        let oneBad = """
        {"aggregations":[{"modelIntent":"","inputTokens":"5","outputTokens":"0",
          "cacheReadTokens":"0","totalCents":1.0},
         {"modelIntent":"composer-2.5","inputTokens":"100","outputTokens":"20",
          "cacheReadTokens":"0","totalCents":2.0}]}
        """
        let kept = CursorLedger.parseAggregated(Data(oneBad.utf8))
        precondition(kept?.count == 1 && kept?.first?.model == "composer-2.5",
                     "a nameless row is dropped, the rest survive")

        // --- 2. The event ledger, where `tokenUsage` can be missing --------
        // Real shapes: two token calls, and a non-token dispatch with no
        // `tokenUsage` key at all.
        let events = """
        {"totalUsageEventsCount":3,"usageEventsDisplay":[
          {"timestamp":"1790651661838","model":"grok-4.7-medium",
           "kind":"USAGE_EVENT_KIND_INCLUDED_IN_PRO","chargedCents":33.0906,
           "isTokenBasedCall":true,"isChargeable":true,
           "tokenUsage":{"inputTokens":1317,"outputTokens":568,"cacheReadTokens":649728,"totalCents":33.0906},
           "conversationId":"d6a3c3fa-6db7-47e7-b889-04b5bc0b8b71"},
          {"timestamp":"1790651661839","model":"grok-4.7-medium",
           "kind":"USAGE_EVENT_KIND_INCLUDED_IN_PRO","chargedCents":10.0,
           "isTokenBasedCall":true,"tokenUsage":{"inputTokens":100,"outputTokens":50,"totalCents":10.0}},
          {"timestamp":"1790644018079","model":"grok-bot-automation",
           "kind":"USAGE_EVENT_KIND_INCLUDED_IN_PRO","chargedCents":12.5,
           "isTokenBasedCall":false,"isChargeable":false,"usageBasedCosts":"$0.13"}]}
        """
        guard let foldedByModel = CursorLedger.parseEvents(Data(events.utf8)) else {
            preconditionFailure("the event page must decode")
        }
        let grok = foldedByModel.first { $0.model == "grok-4.7-medium" }
        precondition(grok != nil, "the token model must be present")
        precondition(grok?.inputTokens == 1417, "events aggregate, was \(grok?.inputTokens ?? -1)")
        precondition(grok?.outputTokens == 618)
        precondition(grok?.cacheReadTokens == 649_728)
        precondition(abs((grok?.costCents ?? 0) - 43.0906) < 0.0001, "money sums across events")
        // The non-token dispatch: no `tokenUsage` key at all — still a real
        // row, and still carrying a charge. That charge only exists at the
        // event's top level, so a parser that reads `tokenUsage.totalCents` and
        // stops would book this row at $0.00 while the vendor bills it.
        let bot = foldedByModel.first { $0.model == "grok-bot-automation" }
        precondition(bot != nil, "a non-token call is still a row, not a dropped page")
        precondition(bot?.totalTokens == 0, "a dispatch with no tokenUsage has no tokens")
        precondition(abs((bot?.costCents ?? 0) - 12.5) < 0.0001,
                     "a non-token call's top-level chargedCents is its cost: \(bot?.costCents ?? -1)")
        // Cursor caps `pageSize` at 1000 and answers 2000+ with a body carrying
        // neither count nor rows — which must read as nil, not as "no usage".
        precondition(CursorLedger.parseEvents(Data("{}".utf8)) == nil,
                     "a body with no usageEventsDisplay is not an empty page")
        precondition(CursorLedger.reportedEventCount(Data("{}".utf8)) == nil,
                     "and it reports no count, which is how the cap shows up")
        precondition(CursorLedger.reportedEventCount(Data(events.utf8)) == 3)
        precondition(CursorLedger.needsMorePages(page: foldedByModel, reportedTotal: 3, rowsSeen: 3) == false)
        precondition(CursorLedger.needsMorePages(page: foldedByModel, reportedTotal: 90, rowsSeen: 3),
                     "a page that left rows behind must ask for more")

        // --- 3. The effort-tier fold ---------------------------------------
        // Cursor's id must land on the local client's id, or the charge is
        // attached to a row the page never draws.
        let tiered = CursorLedger.folded(rows)
        precondition(tiered["claude-opus-5-5"] != nil,
                     "claude-opus-5-5-medium must fold onto claude-opus-5-5: \(tiered.keys.sorted())")
        precondition(tiered["grok-4.7"] != nil, "grok-4.7-medium and grok-4.7-high must merge to one row")
        // Both grok tiers land on the same row, and their money sums.
        precondition(abs((tiered["grok-4.7"]?.costCents ?? 0) - 1627.9990) < 0.001,
                     "two tiers of one model are one charge: \(tiered["grok-4.7"]?.costCents ?? -1)")
        precondition(tiered["claude-opus-5-5-medium"] == nil, "the tiered key must not survive")

        // --- 4. Windows: chunking, truncation, and the plan fallback --------
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSince1970: 1_790_582_107)
        // A month is one request.
        let month = DateInterval(start: start, duration: 31 * day)
        precondition(CursorLedger.windowChunks(month).count == 1, "a month must not be split")
        // Wider than Cursor answers for is split, contiguous, and lossless.
        let quarter = DateInterval(start: start, duration: 90 * day)
        let chunks = CursorLedger.windowChunks(quarter)
        precondition(chunks.count == 3, "90 days at 31 max is 3 chunks, was \(chunks.count)")
        precondition(chunks.first?.start == quarter.start && chunks.last?.end == quarter.end,
                     "the chunks must span the window exactly")
        for i in 1..<chunks.count {
            precondition(chunks[i].start == chunks[i - 1].end, "no gap between chunks")
        }

        // The plan: a period inside the limit is asked for as-is…
        let (fitWindow, fitTruncated) = CursorLedger.plan(for: month, billingCycle: nil)
        precondition(fitWindow == month && !fitTruncated, "a month needs no narrowing")
        // …and a year degrades to the billing cycle rather than to an arbitrary
        // slice of a year, flagged so the UI can say which span it covers.
        let year = DateInterval(start: start, duration: 365 * day)
        let cycle = DateInterval(start: start, duration: 30 * day)
        let (narrowed, didTruncate) = CursorLedger.plan(for: year, billingCycle: cycle)
        precondition(didTruncate, "a year cannot be covered in one reading")
        precondition(narrowed == cycle, "the fallback is the billing cycle, not a slice of the year")
        // With no cycle known yet (before the first allowance probe), it still
        // refuses to ask for the year — it takes the most recent fitting slice.
        let (noCycle, noCycleTruncated) = CursorLedger.plan(for: year, billingCycle: nil)
        precondition(noCycleTruncated && noCycle.duration <= CursorLedger.maxWindow,
                     "an unknown cycle must still narrow to something Cursor will answer for")
        precondition(noCycle.end == year.end, "…the most recent slice, since that is what the user asked about")

        // A past year cannot intersect the current account billing cycle.
        // Do not construct a negative DateInterval while trying that fallback.
        let previousYear = DateInterval(start: start.addingTimeInterval(-365 * day), end: start)
        let (historical, historicalTruncated) = CursorLedger.plan(for: previousYear, billingCycle: cycle)
        precondition(historicalTruncated && historical.duration > 0,
                     "a non-overlapping billing cycle must leave a valid historical window")
        precondition(historical.end == previousYear.end && historical.start >= previousYear.start,
                     "the fallback must stay inside the selected year")

        // --- 5. The actual is never an estimate ----------------------------
        // Structurally: an actual is a `ModelPricing.Cost` built from cents, and
        // `ModelPricing.estimate` only accepts `[ModelUsage]` — which carries no
        // money field at all. Both halves of that are asserted here, because
        // either one alone would let the two be mixed.
        let bill = CursorLedger.cost(cents: 3465.26)
        precondition(bill != nil, "a real charge becomes a Cost")
        precondition(abs((bill?.usd ?? 0) - 34.6526) < 0.0001,
                     "cents are converted once, at the boundary: \(bill?.usd ?? -1)")
        precondition(bill?.cny == 0,
                     "an actual is USD; filling the CNY half would double it the moment present() converts")
        precondition(CursorLedger.cost(cents: 0) == nil, "no charge is no figure, not $0.00")
        precondition(CursorLedger.cost(cents: -1) == nil, "a negative charge is not a figure")

        // `ModelUsage` must carry no money. If it ever does, `estimate` — which
        // is fed `usageStats` everywhere — would start adding real money to list
        // prices silently. The type above *is* the production slice, and the
        // name-pattern scan over it lives in `cursor-ledger-regressions.py`;
        // both the type and the scan would have to be replaced for a money
        // field to slip through.

        print("PASS: Cursor's aggregation decodes with string token counts, an absent "
              + "tokenUsage is a zero row rather than a dropped page, an error envelope is "
              + "nil rather than a free month, the effort tier folds onto the local client's "
              + "model id, windows chunk losslessly and a year degrades to the billing cycle "
              + "with a flag, and an actual charge can never reach the estimate path")
    }
}
