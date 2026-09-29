import Foundation
import Combine

/// The usage page's Cursor **actual-charge** reading.
///
/// Separate from `CursorUsageStore` on purpose. That store owns the *allowance*
/// — the percentage gauges in the popup chip, a monthly-boundary reading that
/// a 20-minute poll is plenty for. This one owns a *ledger*: per-model money
/// for the window the usage page currently has selected, which changes when the
/// user clicks a period chip and is meaningless an hour later. Two different
/// lifetimes and two different cadences, so they are two observables — a period
/// chip must not invalidate the allowance chip, and an allowance poll must not
/// repaint the usage grid.
///
/// **It never blocks the page.** The usage page renders from whatever snapshot
/// is already in memory (this run's or the last one's, rehydrated from disk) and
/// the network read happens behind it. A failed read leaves the old snapshot
/// exactly where it was — see `refresh` — because a money figure that silently
/// becomes zero is indistinguishable from a cheap month.
@MainActor
final class CursorLedgerStore: ObservableObject {
    static let shared = CursorLedgerStore()

    /// The reading, keyed by canonical model id. Empty until a first read
    /// succeeds, or non-empty from disk on relaunch.
    @Published private(set) var rows: [String: CursorLedger.Row] = [:]
    /// The window `rows` actually covers — **not** necessarily the window the
    /// page is showing. See `isStale(for:)`.
    @Published private(set) var window: DateInterval?
    /// `true` when `window` is a **narrowing** of what the page asked for —
    /// the period was wider than Cursor will answer for and the reading covers
    /// the billing cycle instead.
    ///
    /// The tile does not need this flag to draw correctly (it captions the
    /// money with `windowLabel` whenever the two windows differ, which covers
    /// the narrowed case too), so it is not published to the view layer. It
    /// exists on the value because a caller that *reasoned* about coverage
    /// without it would treat "one cycle" as "the whole period".
    private(set) var truncated = false
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var loading = false
    /// Why the last read failed, for the panel's help text. Cleared on success.
    @Published private(set) var note: String?

    /// How long a reading is served before a new one is worth asking for.
    ///
    /// Six hours, deliberately coarse: Cursor's own UI settles usage on a delay
    /// (a window that ends *now* keeps drifting for minutes — measured), and
    /// the reading is a small money figure the user compares against a monthly
    /// allowance, not a live ticker. A period-chip change bypasses this via
    /// `refresh(window:force:)`.
    static let freshWindow: TimeInterval = 6 * 3600

    /// Throttle repeated reads of the same window. A different selected
    /// window must still replace the pending request immediately.
    static let minInterval: TimeInterval = 10

    private var lastProbe: Date?
    private var task: Task<Void, Never>?
    /// The window a read is currently in flight for, so repeat `refresh` calls
    /// for the same one coalesce instead of stacking.
    private var inFlightWindow: DateInterval?
    private let cache = LedgerCache()

    private init() {
        // Warm start, same reason as `CursorUsageStore`: at launch the first
        // probe cannot succeed (it fires before the VPN writes the system
        // proxy), and the money figure from a minute ago is still the right
        // thing to draw. Replaced in place when the live reading lands.
        if let last = cache.load() {
            rows = CursorLedger.folded(last.rows)
            window = DateInterval(start: last.windowStart, end: last.windowEnd)
            truncated = last.truncated
            fetchedAt = last.at
        }
    }

    // MARK: - Reading

    /// The reading to draw for `window`, or nil when nothing covers it.
    ///
    /// A snapshot for a *different* window is still returned — the caller shows
    /// it with `isStale(for:)` saying so — because the alternative is a money
    /// row that appears and disappears as the user clicks period chips, which
    /// reads as the data being broken rather than as it being scoped.
    func snapshot(for window: DateInterval) -> CursorLedger.Snapshot? {
        guard let stored = self.window, !rows.isEmpty else { return nil }
        return CursorLedger.Snapshot(
            rows: Array(rows.values),
            windowStart: stored.start,
            windowEnd: stored.end,
            truncated: truncated
        )
    }

    /// Whether the reading on hand does **not** cover `window`, so the view can
    /// caption it with the window it does cover.
    ///
    /// Token totals must match the requested window. A one-day tolerance
    /// would reuse yesterday's tokens when the user pages to today.
    func isStale(for window: DateInterval) -> Bool {
        guard let stored = self.window else { return true }
        return abs(stored.start.timeIntervalSince(window.start)) > 1
            || abs(stored.end.timeIntervalSince(window.end)) > 1
    }

    /// The window the current reading covers, as a short caption
    /// ("9月28日–10月28日"), or nil when there is nothing to say.
    ///
    /// Date-qualified because a billing window is weeks long: a bare day number
    /// would not say which month it belongs to, and the point of the caption is
    /// that the money on screen covers a *different* span than the tokens do.
    var windowLabel: String? { Self.windowLabel(window) }

    /// `9月28日–10月28日` for any window, so a caller that is *about* to read
    /// one can caption it before the reading lands.
    static func windowLabel(_ window: DateInterval?) -> String? {
        guard let window else { return nil }
        return "\(cursorLedgerShortDate(window.start))–\(cursorLedgerShortDate(window.end))"
    }

    // MARK: - Refresh

    /// Ask for `window`, unless the reading on hand already answers for it.
    ///
    /// `force` skips both the freshness window and the coalescing check — that
    /// is the manual refresh button, where the whole point is a new reading.
    func refresh(window: DateInterval, billingCycle: DateInterval? = nil, force: Bool = false) {
        let plan = CursorLedger.plan(for: window, billingCycle: billingCycle)
        guard !plan.window.duration.isZero else { return }

        if !force {
            if !isStale(for: plan.window), let fetchedAt,
               Date().timeIntervalSince(fetchedAt) < Self.freshWindow { return }
            if inFlightWindow == plan.window { return }
            if !isStale(for: plan.window), let lastProbe,
               Date().timeIntervalSince(lastProbe) < Self.minInterval { return }
        }
        task?.cancel()
        lastProbe = Date()
        inFlightWindow = plan.window
        loading = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // A cancelled read must not clear the newer request's handle.
                if !Task.isCancelled {
                    self.task = nil
                    self.inFlightWindow = nil
                }
            }

            let read = await CursorLedgerReader.read(plan: plan)
            guard !Task.isCancelled else { return }
            self.loading = false
            guard let read else {
                // Failure keeps everything: the money stays on screen and the
                // note explains itself. A zero would be a lie about the month.
                self.note = "Cursor 用量查询失败"
                return
            }
            self.rows = read.folded
            self.window = plan.window
            self.truncated = plan.truncated
            self.fetchedAt = Date()
            self.note = nil
            self.cache.save(read, plan: plan)
            // Tells `ProviderStore` to re-read the money map. `rescan: false` on
            // its side — nothing on disk changed.
            NotificationCenter.default.post(name: .cursorLedgerDidChange, object: nil)
        }
    }
}

// MARK: - Reader

/// `9月28日` — the window caption's date format. Date-qualified because a
/// billing window is weeks long and a bare day number would not say which month
/// it belongs to.
func cursorLedgerShortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日"
    return formatter.string(from: date)
}

/// The network side, split out so the store stays a state machine.
private enum CursorLedgerReader {
    /// One reading of `plan.window`. Returns nil on any failure — the caller
    /// keeps what it had.
    static func read(plan: (window: DateInterval, truncated: Bool))
        async -> (folded: [String: CursorLedger.Row], raw: [CursorLedger.Row])? {
        // Credentials are re-read here, inside the probe, for the same reason
        // `CursorUsageFetcher.fetch` does: Cursor rotates the access token in
        // place while the IDE runs, so a token cached even an hour ago 401s.
        guard let credentials = await Task.detached(priority: .utility, operation: {
            CursorDB.readCredentials()
        }).value, let token = credentials.accessToken, !token.isEmpty else { return nil }

        // The requested window is answered for in chunks, and **a chunk that
        // never answers fails the whole read**. A partial sum returned as a
        // window total is indistinguishable from a cheap month, which is the
        // one outcome this feature must not produce. In practice a period-sized
        // window is a single chunk; the loop exists for the window a *year*
        // period produces before the planner narrows it (and for the rare case
        // where the planner has no billing cycle to narrow to).
        var all: [CursorLedger.Row] = []
        for chunk in CursorLedger.windowChunks(plan.window) {
            guard let rows = await readChunk(chunk, token: token) else { return nil }
            all += rows
        }
        return (CursorLedger.folded(all), all)
    }

    /// One chunk, with the retry the backend's own flakiness requires.
    ///
    /// Cursor's window RPC fails **non-deterministically** on wide spans and
    /// occasionally on narrow ones (measured: a 7-day window that answered on
    /// the second try). The retry is not for a launch proxy window like the
    /// allowance probe's — it is for the backend — so it is short and does not
    /// surface to the UI. Three attempts with a 400 / 800 ms backoff: the
    /// failures clear in well under a second when they clear at all, and a
    /// reading that takes longer than that is not worth holding `loading` for.
    private static func readChunk(_ chunk: (start: Date, end: Date),
                                  token: String) async -> [CursorLedger.Row]? {
        for attempt in 1...3 {
            guard !Task.isCancelled else { return nil }
            if let rows = await fetchAggregated(token: token, window: chunk) { return rows }
            if attempt < 3 { try? await Task<Never, Never>.sleep(for: .milliseconds(400 * attempt)) }
        }
        return nil
    }

    /// `POST api2.cursor.sh/aiserver.v1.DashboardService/GetAggregatedUsageEvents`.
    ///
    /// The window is sent as **epoch-millisecond strings** and the server reads
    /// them in the caller's local timezone (verified: a local-midnight window
    /// matched the local-day event count, a UTC-midnight one did not). Session
    /// config is `URLSession.shared` with no `connectionProxyDictionary`, so the
    /// system proxy is inherited — the same deliberate choice the allowance
    /// probe documents, and the only path that reaches Cursor from a mainland
    /// network (a direct probe also answers 200, but with 4–7 s tail latency
    /// against 1.5–3.6 s through the proxy).
    private static func fetchAggregated(token: String,
                                        window: (start: Date, end: Date)) async -> [CursorLedger.Row]? {
        guard let url = URL(string:
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetAggregatedUsageEvents")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "startDate": String(Int(window.start.timeIntervalSince1970 * 1000)),
            "endDate": String(Int(window.end.timeIntervalSince1970 * 1000)),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        // The RPC is slow enough that the default 60 s is never the binding
        // constraint, but 20 s keeps a hung read from holding `loading` on.
        request.timeoutInterval = 20

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // `parseAggregated` refuses the error envelope (`{"code":"internal"}`)
        // by returning nil — it has no `aggregations` array — which is exactly
        // the signal the retry loop is watching for. A window that legitimately
        // has no usage returns an *empty* array, and that must not retry.
        return CursorLedger.parseAggregated(responseData)
    }
}

// MARK: - Disk

/// The last good reading, so the usage page has money on it the instant the
/// window opens rather than after a 3-second round trip.
///
/// A JSON file next to the allowance's, not `UserDefaults`: it belongs with the
/// rest of ClaudeBar's state under Application Support, and it carries no
/// secrets — model ids, token counts and a dollar figure, no token and no email.
///
/// One reading only. A per-window cache was considered and rejected: the usage
/// page has five periods, Cursor's window cannot follow 年/全部 anyway, and the
/// set of windows a user actually visits is stable enough that a single "last
/// one" covers the relaunch case this exists for.
private final class LedgerCache {
    private let url = FilePaths.appSupportDir.appendingPathComponent("cursor-ledger.json")

    private struct Stored: Codable {
        var rows: [CursorLedger.Row]
        var windowStart: Date
        var windowEnd: Date
        var truncated: Bool
        var at: Date
    }

    func load() -> (rows: [CursorLedger.Row], windowStart: Date, windowEnd: Date,
                    truncated: Bool, at: Date)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data) else { return nil }
        return (stored.rows, stored.windowStart, stored.windowEnd, stored.truncated, stored.at)
    }

    func save(_ read: (folded: [String: CursorLedger.Row], raw: [CursorLedger.Row]),
              plan: (window: DateInterval, truncated: Bool)) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stored = Stored(rows: read.raw,
                            windowStart: plan.window.start,
                            windowEnd: plan.window.end,
                            truncated: plan.truncated,
                            at: Date())
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
