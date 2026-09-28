import Foundation

/// Edge detector for "a turn just delivered its answer".
///
/// The rule is a **new turn key on a session whose own files were just
/// written**, and the parts are each load-bearing:
///
///   * **New key.** The key changes exactly when a turn has delivered
///     something (Claude's `turnCount` + answer uuid, Codex's
///     `task_complete.turn_id`, Cursor's `turn-<offset>`), and a key that has
///     already been announced never fires again — at any poll cadence. A turn
///     that was killed mid-flight, aborted, or is only pausing on a permission
///     prompt leaves the key where it was, so it stays silent. (That is why
///     Claude's key carries the turn counter: the same answer text delivered
///     twice by two turns is two keys, and the *same* turn re-read by two polls
///     is one.)
///   * **Fresh.** The session's last write has to be recent — a poll interval
///     or two — so a turn that ended while the app was not polling (asleep,
///     relaunched, hidden for a long stretch) does not announce itself late.
///     It also lets a turn shorter than the poll interval through: the busy
///     edge may fall between two polls, but the key and the write do not.
///   * **Not busy.** A key can only be set by a finished turn, but the flag is
///     cheap and it keeps the alert off a session that is somehow mid-turn
///     again.
///
/// The first sighting of an id only seeds it (no burst of notifications at
/// launch — the user has already read whatever the session is sitting on), and
/// ids that disappear between polls are pruned, never reported.
struct ConfirmedCompletionDetector<ID: Hashable> {
    /// Ids seen at least once — the seed set.
    private var known: Set<ID> = []
    /// The last turn key announced per id.
    private var announced: [ID: String] = [:]

    /// `turnKey` is nil when the snapshot carries no answer for the current
    /// turn, which is the common case inside a turn. `fresh` is the caller's
    /// own clock against the session's last write — the caller knows which
    /// timestamp is meaningful for its tool.
    mutating func record(_ snapshots: [(id: ID, isBusy: Bool, turnKey: String?, fresh: Bool)]) -> Set<ID> {
        let live = Set(snapshots.map { $0.id })
        var completed: Set<ID> = []
        for snapshot in snapshots {
            guard known.contains(snapshot.id) else {
                known.insert(snapshot.id)
                announced[snapshot.id] = snapshot.turnKey
                continue
            }
            guard !snapshot.isBusy, snapshot.fresh,
                  let key = snapshot.turnKey,
                  announced[snapshot.id] != key else { continue }
            announced[snapshot.id] = key
            completed.insert(snapshot.id)
        }
        known = known.intersection(live)
        announced = announced.filter { live.contains($0.key) }
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
