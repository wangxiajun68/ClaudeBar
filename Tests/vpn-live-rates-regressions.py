#!/usr/bin/env python3
"""The live-rate publisher's three load-bearing branches, with a fake clock.

`VpnLiveRates` is what every 速率 surface observes. Two of its guards fight
each other on purpose, and nothing exercised either before this suite:

  * a sample *equal* to the last one is still appended — the chart's x-axis is
    one slot per flush, so skipping an idle stretch would draw a two-minute gap
    as a single step;
  * once the whole 60-slot window is zero, appending stops entirely — the
    steady state of a running-but-idle VPN must not keep firing
    `objectWillChange` ~1 Hz;
  * the 0.25 s ceiling arms at most one in-flight flush, and `reset()` cancels
    it so a stopped VPN cannot publish a late sample.

Any shake-up of those conditions (the 60 threshold, `pendingDown == speedDown`
ordering, the reset/flushTask race) changes the chart rhythm silently — a
whole `make test` run would not notice. The production class is sliced whole
and driven through `testInstance(clock:)`; the armed-flush assertions poll for
the effect rather than assuming wall-clock timing.

No app launch, no network, no VPN.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
live = (root / 'Sources/ClaudeBar/Utils/VpnLiveRates.swift').read_text()
manager = (root / 'Sources/ClaudeBar/Utils/VpnManager.swift').read_text()

# The class observes this snapshot; it is declared beside the manager.
snapshot = manager[manager.index('struct VpnTrafficSnapshot'):
                   manager.index('/// Compact byte / rate labels.')]

# Production text, imports moved to the file head.
live = live.replace('import Foundation\nimport Combine\n', '')

swift = f'''
import Foundation
import Combine

{snapshot}

{live}

@main struct Regression {{
    /// Poll for the effect instead of trusting a wall-clock duration: the
    /// armed flush runs on a real 0.25 s timer, and a loaded runner may delay
    /// it. Returns as soon as the condition holds.
    static func waitUntil(_ condition: () -> Bool) async -> Bool {{
        for _ in 0..<300 {{
            if condition() {{ return true }}
            try? await Task.sleep(nanoseconds: 10_000_000)
        }}
        return condition()
    }}

    @MainActor static func main() async {{
        // A fake clock the harness advances by hand; every production read of
        // "now" goes through it.
        var now = Date(timeIntervalSince1970: 1_700_000_000)

        // 1. The 0.25 s ceiling: the first sample flushes at once (lastFlush
        //    starts at .distantPast), then a further sample inside the window
        //    must wait for the armed flush, and extra samples must not arm a
        //    second task or leak a publish.
        let rates = VpnLiveRates.testInstance(clock: {{ now }})
        rates.applyStream(up: 10, down: 20)
        precondition(rates.speedDown == 20 && rates.speedUp == 10,
                     "the first sample publishes: \\(rates.speedDown)/\\(rates.speedUp)")
        precondition(rates.speedHistory.count == 1)
        rates.applyStream(up: 11, down: 21)
        precondition(rates.speedHistory.count == 1,
                     "a second sample inside the 0.25 s window must not publish")
        precondition(rates.testArmedWait > 0.24,
                     "the pending flush must ride the ceiling: \\(rates.testArmedWait)")
        rates.applyStream(up: 12, down: 22)
        precondition(rates.speedHistory.count == 1, "one window, one armed flush")
        precondition(rates.testArmedWait > 0.24)
        now = now.addingTimeInterval(0.25)
        let armed = await waitUntil {{ rates.speedHistory.count == 2 }}
        precondition(armed, "the armed flush must publish the newest sample")
        precondition(rates.speedDown == 22 && rates.speedUp == 12,
                     "the newest sample wins: \\(rates.speedDown)/\\(rates.speedUp)")

        // 2. An equal sample is still recorded — the chart's slot, not a
        //    value change, is what the x-axis counts.
        rates.applyStream(up: 12, down: 22)
        rates.testFlush()
        precondition(rates.speedHistory.count == 3,
                     "an equal sample must still occupy a slot: \\(rates.speedHistory.count)")
        precondition(rates.speedHistory.last!.down == 22 && rates.speedHistory.last!.up == 12)
        precondition(rates.speedDown == 22 && rates.speedUp == 12)

        // 3. A full all-zero window stops appending: the idle steady state
        //    must not keep writing @Published at ~1 Hz. Every apply below
        //    advances the fake clock past the ceiling, so each one flushes
        //    through the production path without real waiting.
        let flat = VpnLiveRates.testInstance(clock: {{ now }})
        for _ in 0..<60 {{
            now = now.addingTimeInterval(0.25)
            flat.applyStream(up: 0, down: 0)
        }}
        precondition(flat.speedHistory.count == 60
                     && flat.speedHistory.allSatisfy {{ $0.down == 0 && $0.up == 0 }},
                     "the window fills with zero samples: \\(flat.speedHistory.count)")
        now = now.addingTimeInterval(0.25)
        flat.applyStream(up: 0, down: 0)
        precondition(flat.speedHistory.count == 60,
                     "an all-flat window must stop appending: \\(flat.speedHistory.count)")
        now = now.addingTimeInterval(0.25)
        flat.applyStream(up: 5, down: 7)
        precondition(flat.speedHistory.count == 60
                     && flat.speedHistory.last!.down == 7 && flat.speedHistory.last!.up == 5,
                     "a nonzero sample must resume the chart: \\(String(describing: flat.speedHistory.last))")
        precondition(flat.speedDown == 7 && flat.speedUp == 5)

        // 4. reset() cancels the in-flight flush: a stopped VPN must not
        //    publish a sample armed before the stop.
        let stopped = VpnLiveRates.testInstance(clock: {{ now }})
        stopped.applyStream(up: 1, down: 2)
        stopped.applyStream(up: 3, down: 4)
        precondition(stopped.testArmedWait > 0 && stopped.testArmedWait <= 0.25,
                     "a flush is in flight: \\(stopped.testArmedWait)")
        stopped.reset()
        now = now.addingTimeInterval(1)
        // Longer than the armed 0.25 s deadline: if the cancellation did not
        // hold, the sample would land in here.
        _ = await waitUntil {{ false }}
        precondition(stopped.speedHistory.isEmpty && stopped.speedDown == 0 && stopped.speedUp == 0,
                     "reset must cancel the in-flight flush")
        precondition(stopped.testArmedWait == 0)

        print("PASS: 0.25 s ceiling, equal-sample slots, all-flat freeze and reset cancellation")
    }}
}}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-vpn-rates-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
