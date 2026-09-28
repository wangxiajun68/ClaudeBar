import Foundation
import Combine

/// Owns the Cursor allowance reading and the background poll that keeps it
/// fresh.
///
/// A separate observable from `ProviderStore`/`CodexProviderStore` for the same
/// reason those are separate: the popup header observes it directly, and a
/// quota refresh must not invalidate the session grid, the KPI strip or the
/// action bar. It is also **not** on the 2.5 s session timer — the plan moves
/// on a monthly boundary and the Grok window weekly, so `CursorUsageFetcher`'s
/// own freshness window plus a slow poll are ample.
@MainActor
final class CursorUsageStore: ObservableObject {
    static let shared = CursorUsageStore()

    @Published private(set) var plan: CursorUsageFetcher.PlanUsage?
    @Published private(set) var grok: CursorUsageFetcher.GrokUsage?
    @Published private(set) var loading = false
    @Published private(set) var note: String?

    /// When the displayed reading was taken. Nil while nothing has been
    /// published — the chip's headline is the plan name, so a stale figure
    /// needs no other mark than the tooltip.
    @Published private(set) var readingAt: Date?

    private var task: Task<Void, Never>?
    private var timer: Timer?

    private init() {
        // Warm start: whatever the last session read is what the popup opens
        // on, so the figures are there before the first probe (which cannot
        // succeed at launch — see `CursorUsageFetcher.fetch`). Replaced in
        // place, without a spinner, when the live reading lands.
        if let last = CursorUsageFetcher.lastKnown() {
            plan = last.plan
            grok = last.grok
            readingAt = last.at
        }
    }

    /// Test/preview seam: publish a parsed reading without touching the
    /// network. Only the render harness uses it — production always goes
    /// through `refresh()`, which owns the credential read, cache and poll.
    func injectForPreview(plan: CursorUsageFetcher.PlanUsage?,
                          grok: CursorUsageFetcher.GrokUsage?) {
        self.plan = plan
        self.grok = grok
        self.note = nil
        self.loading = false
        self.readingAt = plan == nil && grok == nil ? nil : Date()
    }

    /// Launch the poll. Idempotent — safe to call from every `onAppear`.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: AppConfig.cursorQuotaPollInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    /// `manual` drops the fetcher's cache first — the whole point of the button
    /// is a *new* reading, not the one from two minutes ago.
    ///
    /// **The spinner is only for the first-ever reading.** Once there is a plan
    /// or a Grok window to show (from this session or the persisted last one),
    /// a refresh keeps them on screen and swaps the numbers when the probe
    /// answers: `loading` still gates the *button* (so a second tap cannot stack
    /// a probe), but `PanelHeader` only draws "刷新额度…" when there is nothing
    /// to draw instead. That is what makes a launch, or any refresh, read as
    /// "the figures moved" rather than "the quota is gone".
    func refresh(manual: Bool = false) {
        guard task == nil else { return }
        if manual { CursorUsageFetcher.invalidateCache() }
        loading = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            let snapshot = await CursorUsageFetcher.fetch()
            // Only a reading replaces the figures. A failure leaves the last
            // good numbers up and explains itself in `note` (which the chip
            // shows only when it has no gauges at all).
            if !snapshot.isEmpty {
                self.plan = snapshot.plan
                self.grok = snapshot.grok
                self.readingAt = Date()
            }
            self.note = snapshot.note
            self.loading = false
        }
    }
}
