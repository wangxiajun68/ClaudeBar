#!/usr/bin/env python3
"""The completion alert must fire on a new answer, and only on a new answer.

Each rule below is a failure mode measured on this machine's own transcripts:

  * a killed or interrupted turn flips busy → idle with **no** new answer, and
    the turn key is what keeps it silent (the old detector compared answer ids
    and re-announced an answer the user had already read, because its memory was
    pruned whenever a poll gap exceeded the candidate window);
  * a turn that ends while nobody is polling (app hidden for a stretch, machine
    asleep, relaunch) must not announce itself late — hence `fresh`;
  * a turn *shorter* than the poll interval must still fire: the busy edge can
    fall between two polls, but the key and the recent write do not;
  * the first sighting of a session only seeds it, so launching the app does not
    announce whatever answer the session is already sitting on.

Extracts `ConfirmedCompletionDetector` from the production source, no app
launch.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Models/IdleTransitionDetector.swift').read_text()
start = source.index('struct ConfirmedCompletionDetector<ID: Hashable> {')
end = source.index('\n}\n', start) + len('\n}\n')
body = source[start:end]

swift = r'''
import Foundation

DETECTOR

@main struct Regression {
    static func main() {
        typealias Snap = (id: String, isBusy: Bool, turnKey: String?, fresh: Bool)

        func snap(_ id: String, busy: Bool = false, key: String?, fresh: Bool = true) -> Snap {
            (id, busy, key, fresh)
        }

        // 1. The normal end of a turn: idle, a new key, a fresh write.
        var d = ConfirmedCompletionDetector<String>()
        _ = d.record([snap("a", key: nil)])                       // seed at launch
        let first = d.record([snap("a", key: "7|uuid-1")])
        precondition(first == ["a"], "a new key on a fresh, idle session fires; got \(first)")

        // 1b. A *new* turn delivering a new answer fires again — the counter is
        //     what makes the key new.
        let nextTurn = d.record([snap("a", key: "8|uuid-2")])
        precondition(nextTurn == ["a"], "a later turn must fire again")

        // 2. The same key is never announced twice, whatever the poll cadence.
        var d2 = ConfirmedCompletionDetector<String>()
        _ = d2.record([snap("a", key: "3|uuid-0")])
        _ = d2.record([snap("a", key: "3|uuid-0")])
        for _ in 0..<50 {
            precondition(d2.record([snap("a", key: "3|uuid-0")]).isEmpty,
                         "the same key must stay silent forever")
        }

        // 3. A killed turn: idle again with the key from before the turn.
        var d3 = ConfirmedCompletionDetector<String>()
        _ = d3.record([snap("a", key: "3|uuid-0")])
        _ = d3.record([snap("a", busy: true, key: nil)])
        let killed = d3.record([snap("a", key: "3|uuid-0")])
        precondition(killed.isEmpty, "a turn killed mid-flight must stay silent; got \(killed)")

        // 4. A stale end of turn — the app was hidden or asleep when it landed.
        var d4 = ConfirmedCompletionDetector<String>()
        _ = d4.record([snap("a", key: "3|uuid-0")])
        let stale = d4.record([snap("a", key: "4|uuid-1", fresh: false)])
        precondition(stale.isEmpty, "an end of turn nobody was watching must stay silent; got \(stale)")

        // 5. A turn shorter than the poll interval: never observed busy, but the
        //    key and the fresh write both moved.
        var d5 = ConfirmedCompletionDetector<String>()
        _ = d5.record([snap("a", key: nil)])
        let shortTurn = d5.record([snap("a", key: "1|uuid-1")])
        precondition(shortTurn == ["a"], "a turn shorter than the poll interval must fire")

        // 6. Mid-turn: busy with no key yet, then the answer.
        var d6 = ConfirmedCompletionDetector<String>()
        _ = d6.record([snap("a", key: nil)])
        for _ in 0..<5 {
            precondition(d6.record([snap("a", busy: true, key: nil)]).isEmpty,
                         "a busy session is not a completion")
        }
        let answered = d6.record([snap("a", key: "2|uuid-9")])
        precondition(answered == ["a"], "the answer after a busy stretch fires")

        // 7. Launch seeds silently, at any state the session is found in.
        var d7 = ConfirmedCompletionDetector<String>()
        precondition(d7.record([snap("a", key: "9|uuid")]).isEmpty, "the first poll seeds")
        var d7b = ConfirmedCompletionDetector<String>()
        precondition(d7b.record([snap("a", busy: true, key: nil)]).isEmpty, "a busy first poll seeds")

        // 8. Ids that disappear are pruned; a returning id re-seeds rather than
        //    firing for the answer it was last seen with.
        var d8 = ConfirmedCompletionDetector<String>()
        _ = d8.record([snap("a", key: "9|uuid")])
        _ = d8.record([])
        let back = d8.record([snap("a", key: "9|uuid")])
        precondition(back.isEmpty, "a returning id must re-seed, not fire")

        // 9. Sessions are independent: one silent turn must not mute another,
        //    and one completion must not fire for both.
        var d9 = ConfirmedCompletionDetector<String>()
        _ = d9.record([snap("a", key: nil), snap("b", key: nil)])
        let mixed = d9.record([snap("a", key: "1|u"), snap("b", busy: true, key: nil)])
        precondition(mixed == ["a"], "only the session that delivered fires; got \(mixed)")

        print("PASS: fires on a new key (normal, short, after-busy, later turns), stays silent for "
              + "killed/stale/repeated/unseeded turns, seeds at launch, prunes departures")
    }
}
'''.replace('DETECTOR', body)

with tempfile.TemporaryDirectory(prefix='claudebar-completion-tests-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
