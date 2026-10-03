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

    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var permissionObserver: NSObjectProtocol?

    private init() {
        // Warm start: whatever the last session read is what the popup opens
        // on, so the figures are there before the first probe (which cannot
        // succeed at launch — see `CursorUsageFetcher.fetch`). Replaced in
        // place, without a spinner, when the live reading lands.
        if let last = CursorUsageFetcher.lastKnown() {
            plan = last.plan
            grok = last.grok
        }
    }
    /// Launch the poll. Idempotent — safe to call from every `onAppear`.
    ///
    /// The 读取 Cursor 会话 switch gates the whole Cursor path, not just the
    /// session list: the allowance probe opens `state.vscdb` and sends the
    /// account's access token to cursor.com, which is exactly what the switch's
    /// caption promises not to do while it is off. Turning it back on starts
    /// the poll from here (via `.permissionDidChange`), so the setting takes
    /// effect without a relaunch.
    func start() {
        timer?.invalidate()
        guard PermissionGate.allows(.cursorData) else {
            permissionObserver = permissionObserver ?? NotificationCenter.default.addObserver(
                forName: .permissionDidChange, object: nil, queue: .main) { [weak self] note in
                    guard (note.object as? AppPermission) == .cursorData else { return }
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if PermissionGate.allows(.cursorData) { self.start(); self.refresh() }
                        else { self.stop() }
                    }
                }
            return
        }
        timer = Timer.scheduledTimer(
            withTimeInterval: AppConfig.cursorQuotaPollInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = AppConfig.cursorQuotaPollInterval * 0.1
    }

    /// Stop the poll and forget the live reading — used when the switch is
    /// turned off, so the next launch does not open the DB for a reading the
    /// user opted out of.
    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        loading = false
        note = nil
        plan = nil
        grok = nil
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
        // The switch gates every entry point, not just the timer: the manual
        // refresh button in the popup chip runs through here.
        guard PermissionGate.allows(.cursorData) else { return }
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
            }
            self.note = snapshot.note
            self.loading = false
        }
    }
}
