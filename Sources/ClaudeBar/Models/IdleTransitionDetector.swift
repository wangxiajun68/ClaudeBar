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
