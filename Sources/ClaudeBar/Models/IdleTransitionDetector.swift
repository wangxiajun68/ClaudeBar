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
