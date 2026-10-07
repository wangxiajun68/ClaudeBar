#!/usr/bin/env python3
"""The cancel/attach ordering `ProxyInflight.Handle` documents, executed.

Interrupting a captured call is deliberately hard: the upstream task is
cancelled *and* the loopback socket is dropped without a terminal frame, which
is what stops Claude Code / Codex instead of letting them retry onto a clean
ending. Either teardown can be attached before or after the user's interrupt
tap, so the one rule the whole file turns on is the one its comment spells out:

    "The cancelled check happens *inside* the lock — read outside it, an
    attach that lost the race by nanoseconds would store a hook on a handle
    whose `cancel()` already copied the two hooks and unlocked, leaving the
    abort client alive."

Move that check outside the lock (or take the `immediate()` call inside it) and
nothing in the app fails loudly: the capture row reads 已中断, `isInterrupted`
is true, and the client keeps waiting on a stream that will never end. This
suite slices `Handle` (and the registry around it) and drives both orders, the
detach path, and a threaded race, so the mutant dies here instead of on the
user's turn.

No app, no network, no sockets: the hooks are closures that count.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
inflight = (root / 'Sources/ClaudeBar/Utils/ProxyInflight.swift').read_text()


def declaration(text, marker):
    start = text.index(marker)
    end = text.index('{', start)
    depth = 0
    while True:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
        if depth == 0:
            break
    return text[start:end]


handle = declaration(inflight, '    final class Handle: @unchecked Sendable {')
registry = declaration(inflight, 'final class ProxyInflight {')
registry = registry.replace('    private init() {}', '    init() {}')
# The parts whose *absence* would make the fixture vacuous: without the lock
# discipline there is nothing to test, and without the registry the detach case
# cannot be reached the way production reaches it.
assert 'private var cancelled = false' in handle
assert 'lock.lock()' in handle
assert 'func open(captureID: Int64) -> Handle' in registry
assert 'if live[handle.captureID] === handle' in registry

swift = r'''
import Foundation

HANDLE

REGISTRY

@main struct Regression {
    static func main() {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message); print("FAIL: \(message)") }
        }

        // 1. cancel() before the abort hook exists: the hook has nowhere to
        //    wait, so attaching it must run it on the spot — exactly once.
        var aborts = 0
        let first = ProxyInflight.Handle(captureID: 1)
        check(first.cancel(), "the first cancel must report that it interrupted")
        first.attachAbort { aborts += 1 }
        check(aborts == 1, "an abort attached to an already-cancelled handle must run immediately; got \(aborts)")
        check(first.isCancelled, "…and the handle stays cancelled")

        // 2. Same for the upstream teardown: it is a second, independent hook.
        var upstream = 0
        let second = ProxyInflight.Handle(captureID: 2)
        _ = second.cancel()
        second.attachUpstream { upstream += 1 }
        check(upstream == 1, "an upstream cancel attached late must run immediately; got \(upstream)")

        // 3. attach first, then cancel: the hook runs from cancel(), once, and
        //    a second interrupt is a no-op the caller can identify.
        var order: [String] = []
        let third = ProxyInflight.Handle(captureID: 3)
        third.attachAbort { order.append("abort") }
        third.attachUpstream { order.append("upstream") }
        check(third.cancel(), "cancel on a live handle must return true")
        check(order == ["abort", "upstream"],
              "the client is dropped before the upstream is cancelled; got \(order)")
        check(!third.cancel(), "a second cancel must report that nothing was interrupted")
        check(order.count == 2, "…and must not run the hooks again; got \(order)")

        // 4. Attaching *after* a cancel that already ran its hooks must still
        //    fire once — a hook that loses the race cannot be lost.
        third.attachAbort { order.append("late-abort") }
        check(order == ["abort", "upstream", "late-abort"], "a late abort must still run; got \(order)")
        check(!third.cancel(), "the late attach must not make the handle cancellable again")

        // 5. The finished-call path: `close` detaches the hooks and drops the
        //    registry entry, so a stale interrupt tap finds nothing to run and
        //    a late attach has no owner — but the handle itself still reports
        //    cancelled for the proxy's post-call read.
        var detached = 0
        let fourth = ProxyInflight.shared.open(captureID: 4)
        fourth.attachAbort { detached += 1 }
        ProxyInflight.shared.close(fourth)
        check(!ProxyInflight.shared.cancel(captureID: 4),
              "an interrupt after close must report no live call")
        check(detached == 0, "the detached handle must not have run an abort; got \(detached)")
        fourth.attachAbort { detached += 1 }
        check(detached == 0, "a hook attached after close has no owner and must stay unrun")
        _ = fourth.cancel()
        check(detached == 1, "…until something cancels the handle itself; got \(detached)")

        // 6. The registry identity guard: a re-opened capture id must not be
        //    retired by the *old* handle's close.
        let old = ProxyInflight.shared.open(captureID: 5)
        let fresh = ProxyInflight.shared.open(captureID: 5)
        ProxyInflight.shared.close(old)
        check(ProxyInflight.shared.cancel(captureID: 5),
              "closing a replaced handle must not retire the current one")
        check(fresh.isCancelled && !old.isCancelled,
              "…and the interrupt must land on the live handle, not the replaced one")

        // 7. The race, driven for real: one thread cancels while another
        //    attaches. Whichever order the lock hands out, the abort runs
        //    exactly once — zero means the client was left connected, two
        //    means a double teardown.
        for _ in 0..<200 {
            var raced = 0
            let handle = ProxyInflight.Handle(captureID: 6)
            let ready = DispatchSemaphore(value: 0)
            let start = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                ready.signal()
                start.wait()
                handle.attachAbort { raced += 1 }
            }
            ready.wait()
            DispatchQueue.global().async { start.signal() }
            _ = handle.cancel()
            // A cancel that ran before the attach has already fired the hook
            // by the time `cancel` returns; one that ran after needs the
            // attach to land, which is what this barrier waits for.
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { done.signal() }
            done.wait()
            Thread.sleep(forTimeInterval: 0.0005)
            check(raced == 1, "the racing abort must run exactly once; got \(raced)")
        }

        print("\(checks - failures.count)/\(checks) proxy-inflight checks passed")
        if !failures.isEmpty { exit(1) }
    }
}
'''.replace('HANDLE', handle).replace('REGISTRY', registry)

with tempfile.TemporaryDirectory(prefix='claudebar-proxy-inflight-') as folder:
    folder = Path(folder)
    source = folder / 'Regression.swift'
    source.write_text(swift)
    binary = folder / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
