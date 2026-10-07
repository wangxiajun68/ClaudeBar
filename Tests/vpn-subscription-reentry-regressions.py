#!/usr/bin/env python3
"""The subscription page's write lock: the real value type, executed.

The page lets the user add a subscription, query every subscription, update
one subscription's profile and delete one — and each of the first three
downloads over the network and can restart the core, while a delete must not
run underneath a download that is about to write the same profile. The lock
that serialises them used to be three loose `@State` flags (`busyID`,
`queryingAll`, `adding`) with two defects that no amount of reading the view
catches:

  * the flags were set inside `Task { … }` closures, whose bodies run a
    main-actor turn *after* the click returns — a second click delivered in
    the same event batch saw the old values and passed every guard;
  * `activate`'s guard read `busyID` alone, which is precisely nil during a
    core restart that `activate` itself had already begun (finding 37,
    2026-10-05 review).

`SubscriptionBusy` is the single source of truth now, and it is a plain value
type so the policy can be *executed* here rather than described. The section's
view body still cannot be compiled without SwiftUI, so its wiring — claim
before every write, `manager.state` in `activate` — is pinned textually, the
same split `vpn-format-regressions.py` uses for the store.

No network, no VPN, no app launch.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
section = (root / 'Sources/ClaudeBar/Views/Pages/VPNSubscriptionSection.swift').read_text()


def braced(text, signature):
    start = text.index(signature)
    i = text.index('{', start)
    depth, j = 0, i
    while True:
        if text[j] == '{':
            depth += 1
        elif text[j] == '}':
            depth -= 1
            if depth == 0:
                break
        j += 1
    return text[start:j + 1]


busy_type = braced(section, 'struct SubscriptionBusy: Equatable {')

swift = f'''
import Foundation

/// The production lock, sliced whole — the assertions below drive the shipped
/// policy, not a restatement of it.
{busy_type}

@main struct Regression {{
    static func main() {{
        let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

        // 1. One operation at a time: a second claim while held is refused,
        //    whatever the pair of owners is.
        var busy = SubscriptionBusy()
        precondition(busy.isIdle && busy.updatingID == nil && !busy.isAdding && !busy.isQueryingAll)
        precondition(busy.claim(.update(a)), "an idle lock must accept the first claim")
        precondition(!busy.claim(.update(b)), "a second update must not overlap the first")
        precondition(!busy.claim(.queryAll), "查询全部 must not start under an update")
        precondition(!busy.claim(.add), "an add must not start under an update")
        precondition(busy.updatingID == a, "the spinner id must be the operation that holds the lock")
        precondition(!busy.isQueryingAll && !busy.isAdding)

        // 2. The straggler rule — the one that made `activate` wrong: a
        //    completion that lands after a newer claim must not clear it. The
        //    release names its owner, and only the owner it names is freed.
        busy.release(.update(b))
        precondition(!busy.isIdle, "a stranger's release must not free another operation's lock")
        busy.release(.update(a))
        precondition(busy.isIdle, "the owner's own release frees the lock")

        // 3. The exact finding-37 interleaving still shows why `activate`
        //    cannot lean on the lock alone: once the update that started a
        //    reload finishes, the lock is free while the core is still
        //    restarting. The section's guard must therefore read
        //    `manager.state` too (pinned below).
        precondition(busy.claim(.update(a)))
        busy.release(.update(a))
        precondition(busy.isIdle && busy.claim(.update(a)),
                     "after a completed update the lock is free again — the restart it began is not visible here")

        // 4. Whole-list query and add hold the lock the same way, and their
        //    accessors report the states the section renders from.
        var querying = SubscriptionBusy()
        precondition(querying.claim(.queryAll))
        precondition(querying.isQueryingAll && !querying.isAdding && querying.updatingID == nil,
                     "a whole-list query is neither an add nor a per-card update")
        querying.release(.queryAll)
        precondition(querying.claim(.add) && querying.isAdding,
                     "the add path claims the same lock with no subscription id")
        querying.release(.add)
        precondition(querying.isIdle)

        print("PASS: subscription write lock — single claimant, owner-scoped release, straggler rejection")
    }}
}}
'''

# --- the section's wiring ----------------------------------------------------
# The compiled half proves the lock; these pins prove every write in the view
# claims it, at the click, and that `activate` also reads the real restart
# state. `busyID` is the old defect, so its absence is asserted directly.
assert 'busyID' not in section, \
    'the loose busy flags are gone; the lock is the only busy truth'
assert 'queryingAll = true' not in section and 'adding = true' not in section, \
    'no entry point may set its own flag instead of claiming the lock'
assert 'guard busy.claim(owner) else { return }' in section, \
    'the sheet save must claim synchronously, in the click that dismisses the sheet'
assert 'guard busy.claim(owner) else { return }' in braced(section, '    private func startBusy('), \
    'every menu download must claim through startBusy before its Task begins'
assert 'guard busy.isIdle, manager.state != .starting else { return }' in braced(section, '    private func activate('), \
    'activate must refuse while another write holds the lock AND while a restart it began is under way'
alert = section[section.index('.alert("删除订阅？"'):]
alert = alert[:alert.index('\n    }')]
assert 'guard busy.isIdle, manager.state != .starting else { return }' in alert, \
    'the delete confirmation is a write too: it must respect the same lock and the restart state'
assert '.disabled(!busy.isIdle)' in section, \
    'the add button and the menu disable from the lock, not from a local flag'
assert '.disabled(!busy.isIdle || manager.state == .starting)' in section, \
    'the activate button carries both conditions so disabled and the guard cannot drift'

with tempfile.TemporaryDirectory(prefix='claudebar-vpn-reentry-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
