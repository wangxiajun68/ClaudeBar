import Foundation

/// Edge detector for "session just finished its turn" transitions.
///
/// Callers feed each poll's busy ids in; the detector diffs against the
/// previous poll and reports the ids that went busy → idle-and-alive. The
/// first poll only seeds the map (no burst of notifications at launch), and
/// ids that disappear between polls are pruned, never reported.
///
/// Instances are used only from the main actor (inside `ProviderStore`'s
/// publish blocks), so no locking is needed despite the mutable state.
struct IdleTransitionDetector<ID: Hashable> {
    /// Ids that were busy at the previous poll.
    private var wasBusy: Set<ID> = []

    /// Diff this poll's busy ids against the last poll's. Returns the ids
    /// that just went idle (busy last poll, not busy now) and whether any
    /// session is currently busy (drives the menu-bar icon).
    mutating func record(busyIDs: Set<ID>) -> (newlyIdle: Set<ID>, anyBusy: Bool) {
        let newlyIdle = wasBusy.subtracting(busyIDs)
        wasBusy = busyIDs
        return (newlyIdle, !busyIDs.isEmpty)
    }
}

/// A busy edge only opens a short candidate window. A notification is emitted
/// once the transcript also proves that a new final answer was delivered.
/// This excludes permission prompts, tool pauses, aborted turns and stale
/// busy-state fallbacks. The first snapshot seeds existing answers silently.
struct ConfirmedCompletionDetector<ID: Hashable> {
    private var previousBusy: Set<ID>?
    private var known: Set<ID> = []
    private var notified: [ID: String] = [:]
    private var pending: [ID: Date] = [:]

    mutating func record(_ snapshots: [(id: ID, isBusy: Bool, completionID: String?)],
                         now: Date = Date()) -> Set<ID> {
        let busy = Set(snapshots.filter { $0.isBusy }.map { $0.id })
        let live = Set(snapshots.map { $0.id })
        var completed: Set<ID> = []
        for snapshot in snapshots where !known.contains(snapshot.id) {
            notified[snapshot.id] = snapshot.completionID
        }
        if let previousBusy {
            for snapshot in snapshots {
                if snapshot.isBusy {
                    pending[snapshot.id] = nil
                    continue
                }
                if previousBusy.contains(snapshot.id) {
                    pending[snapshot.id] = now.addingTimeInterval(10)
                }
                guard let deadline = pending[snapshot.id], now <= deadline,
                      let completionID = snapshot.completionID,
                      notified[snapshot.id] != completionID else { continue }
                notified[snapshot.id] = completionID
                pending[snapshot.id] = nil
                completed.insert(snapshot.id)
            }
        }
        known = live
        notified = notified.filter { live.contains($0.key) }
        pending = pending.filter { live.contains($0.key) && now <= $0.value }
        self.previousBusy = busy
        return completed
    }
}

/// Edge detector for "a Codex quota window just rolled over".
///
/// Codex reports each window as a *used* percentage plus the reset time, and
/// the percentage drops back to ~0 when the allowance refreshes. Announcing
/// that is the whole point: it is the one moment a user on a depleted 5-hour
/// window can start again, and nothing else in the app surfaces it.
///
/// A naive "usedPercent < 5" test fires constantly — the glance polls every
/// 4.2 s, and a window that is genuinely near-empty sits under the threshold
/// for many polls. So this tracks the *transition*:
///
///   * the first sighting of a window only seeds it (no alert at launch),
///   * a reset requires the window to have been meaningfully used, then to
///     drop by a large margin — a small dip is provider rounding, not a reset,
///   * the reset time moving *forward* also counts, because Codex rolls the
///     window over before the percentage always updates,
///   * the same rollover is never announced twice.
struct QuotaResetDetector {
    private struct Seen {
        var usedPercent: Double
        var resetsAt: Date?
    }

    private var seen: [String: Seen] = [:]
    /// Windows already announced, keyed by label + the reset instant, so a
    /// rollover is reported once even if the percentage stays near zero.
    private var announced: Set<String> = []

    /// A drop this large means the allowance refreshed rather than ticked.
    /// Resets go to ~0 from whatever was used; the largest legitimate
    /// same-window fall is rounding, well under 5 points.
    private static let dropThreshold: Double = 20
    /// Below this the window had nothing to reset, so there is nothing worth
    /// telling the user about.
    private static let usedFloor: Double = 5

    /// Diff this poll's windows against the last poll's. Returns the windows
    /// that just rolled over, in the order they appear.
    mutating func record(_ windows: [CodexQuotaWindow]) -> [CodexQuotaWindow] {
        var reset: [CodexQuotaWindow] = []
        var live: Set<String> = []

        for window in windows {
            live.insert(window.label)
            let key = "\(window.label)|\(window.resetsAt?.timeIntervalSince1970 ?? -1)"
            let previous = seen[window.label]

            let dropped = previous.map { $0.usedPercent - window.usedPercent >= Self.dropThreshold } ?? false
            let wasUsed = previous.map { $0.usedPercent >= Self.usedFloor } ?? false
            // A *forward* reset instant is the other half of a rollover: Codex
            // sometimes advances the schedule before the percentage catches up.
            // It is gated by the same `wasUsed` floor — a window that had
            // nothing left to refresh must stay silent whichever signal moves,
            // otherwise an already-empty window announces a reset it did not
            // experience.
            let rolledForward = previous.flatMap { $0.resetsAt }.map { before in
                guard let now = window.resetsAt else { return false }
                return now > before.addingTimeInterval(60)
            } ?? false

            if previous != nil,
               wasUsed, (dropped || rolledForward),
               !announced.contains(key) {
                announced.insert(key)
                reset.append(window)
            }
            seen[window.label] = Seen(usedPercent: window.usedPercent, resetsAt: window.resetsAt)
        }

        // A window that vanished (account change, provider swap) must not keep
        // stale state around and fire on its return.
        seen = seen.filter { live.contains($0.key) }
        announced = announced.filter { entry in
            // Entries are "label|instant"; keep one whose label stage is live
            // so a window that is still present is not re-announced.
            guard let label = entry.split(separator: "|").first.map(String.init) else { return false }
            return live.contains(label)
        }
        return reset
    }
}
