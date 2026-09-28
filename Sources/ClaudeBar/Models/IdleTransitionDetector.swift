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

/// Decides when the next Codex allowance poll is worth making — the heartbeat,
/// plus one extra look on top when a reset instant is near.
///
/// The heartbeat is kept: the reading is what the panel shows, the allowance
/// moves as it is spent, and the user watches that move. But a heartbeat alone
/// answers the wrong question about the *alert*. It exists for the moment a
/// depleted window refills, and at a fixed tick that moment is reported 0–15
/// minutes late — a reset that lands one second after a poll waits the whole
/// quarter hour. So on top of the heartbeat the scheduler aims one extra poll
/// at the instant the reading announces:
///
///   * the reading is fetched at least every `fallback`, unchanged;
///   * if a window resets inside `horizon`, that instant is aimed at with a
///     one-shot poll `grace` after it — a window resets where it says it does,
///     so this is the earliest a new reading can differ;
///   * if the reading has not moved at that instant (Codex sometimes announces
///     the new schedule before the percentage follows) the heartbeat — which
///     was running underneath the whole time — carries on, so a rollover is
///     never missed, only reported late in that one case;
///   * everything else is the heartbeat.
///
/// The detection rule itself is untouched: this only decides *when* to look. An
/// aimed poll still has to survive `QuotaResetDetector`, so nothing here can
/// manufacture an alert.
///
/// An instant is re-aimed only inside `dueWindow` of itself. Without that bound
/// a reset that fails to fetch would leave a stale instant aimed at on every
/// reading, and the schedule would poll every `grace` until the window happened
/// to move; past the bound the heartbeat carries on. The test is
/// `resetsAt <= dueWindow old`, i.e. waiting for the reset is never more urgent
/// than the heartbeat, so an instant the app slept past is looked at rather
/// than skimmed over.
struct QuotaPollScheduler {
    /// The steady heartbeat: the longest the poll may go without a reading.
    let fallback: TimeInterval
    /// Slack after a reset instant before the confirming poll.
    let grace: TimeInterval
    /// How far ahead a reset instant is worth an extra poll.
    let horizon: TimeInterval
    /// How long past a reset instant it is still worth aiming at.
    let dueWindow: TimeInterval

    /// The next poll after a reading fetched at `now`.
    ///
    /// `previous` is the instant the reading that is being replaced named — a
    /// look at it must not be armed on the strength of the reading that already
    /// took place at that instant. At launch it is empty for exactly that
    /// reason: an app starting up after an instant has passed must wait out the
    /// heartbeat, not probe for a reset that has already been delivered.
    func nextInterval(now: Date,
                      windows: [CodexQuotaWindow],
                      previous: [String: Date?]) -> TimeInterval {
        let instants = windows.compactMap(\.resetsAt)
        let horizon = now.addingTimeInterval(self.horizon)

        // A reset about to happen: look at it as it happens, and no later than
        // the heartbeat would have looked anyway (`min`).
        if let soon = instants.filter({ $0 > now && $0 <= horizon }).min() {
            return min(fallback, max(grace, soon.timeIntervalSince(now) + grace))
        }

        // A reset that has just passed — the poll slept through it, or the clock
        // stepped — and the reading is at most `dueWindow` old. Still the one
        // the previous reading named, which is what tells a reading that was
        // *due* here and did not move from one whose schedule merely advanced.
        // Look once; the heartbeat covers a reading that turns out not to move.
        let stale = instants.filter { $0 <= now && now.timeIntervalSince($0) <= dueWindow }
        if stale.contains(where: { isUnchanged($0, previous) }) { return grace }

        return fallback
    }

    /// Whether a window still names `instant` — the "this reading expected a
    /// reset here and did not move" test. `nil` (a window that does not say
    /// when it resets) does not match, so a degraded reading never holds the
    /// schedule on an instant it cannot confirm.
    private func isUnchanged(_ instant: Date, _ resetsByLabel: [String: Date?]) -> Bool {
        resetsByLabel.values.contains { $0 == instant }
    }
}
