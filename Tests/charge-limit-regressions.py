#!/usr/bin/env python3
"""Dragging the charge-limit slider may only take effect once management runs.

The gate is the whole point of the confirmed behaviour: with charge management
off, a drag is a stored preference, and silently starting a privileged helper
from a slider would be a surprise. With it on, release applies immediately.

The gate is pure state (is the helper up, and is the mode one that owns a
limit), so the production predicate can be evaluated directly — no helper, no
app launch.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Models/BatteryChargeController.swift').read_text()

mode_enum = source[source.index('    enum Mode: Int, CaseIterable, Identifiable {'):
                   source.index('    struct Status: Decodable {')]
manages = source[source.index('    var managesLimit: Bool {'):
                 source.index('    /// Re-send the current mode')]
set_limit = source[source.index('    func setLimit(_ value: Int) {'):
                   source.index('    func apply(_ requested: Mode) {')]

swift = r'''
import Foundation

@MainActor
final class BatteryChargeController {
MODE_ENUM
    static let minLimit: Double = 20
    private(set) var mode = Mode.system
    private(set) var appliedLimit = 80
    var revision: UInt64 = 0
    /// Stand-ins for the two dependencies the gate reads.
    var process: Process? = nil
    var shuttingDown = false
    var sent: [String] = []

    init(mode: Mode, applied: Int, running: Bool) {
        self.mode = mode
        self.appliedLimit = applied
        self.process = running ? Process() : nil
    }

    /// Test hook: the production setter is `private(set)`, so the harness needs
    /// its own way to move the controller into a managing mode.
    func enter(_ next: Mode) { mode = next }

MANAGES

    private func send(_ message: String) { sent.append(message) }

SET_LIMIT
}

@main struct Regression {
    @MainActor static func main() {
        // 1. With management off, a drag must send nothing and keep the value.
        for mode in [BatteryChargeController.Mode.system] {
            let c = BatteryChargeController(mode: mode, applied: 80, running: false)
            c.setLimit(55)
            precondition(c.sent.isEmpty, "\(mode) with no helper must not send")
            precondition(c.appliedLimit == 80, "the applied limit must not move")
        }
        // Even with the helper up, system mode owns no limit.
        let systemUp = BatteryChargeController(mode: .system, applied: 80, running: true)
        systemUp.setLimit(55)
        precondition(systemUp.sent.isEmpty, "system mode has no limit to set")

        // 2. With management on, release applies immediately.
        for mode in [BatteryChargeController.Mode.limit, .hold, .discharge] {
            let c = BatteryChargeController(mode: mode, applied: 80, running: true)
            precondition(c.managesLimit, "\(mode) must accept limit changes")
            c.setLimit(55)
            precondition(c.sent.count == 1, "\(mode) should send exactly one command")
            precondition(c.sent[0] == "set \(mode.rawValue) 55 1\n",
                         "wrong command for \(mode): \(c.sent[0])")
        }

        // 3. A no-op drag must stay silent — re-sending the same limit would
        //    churn the helper for nothing.
        let steady = BatteryChargeController(mode: .hold, applied: 80, running: true)
        steady.setLimit(80)
        precondition(steady.sent.isEmpty, "an unchanged limit must not be sent")

        // 4. Out-of-range drags clamp to what `policy.h` accepts, in both
        //    directions, rather than sending a value the helper would reject.
        let low = BatteryChargeController(mode: .hold, applied: 80, running: true)
        low.setLimit(0)
        precondition(low.sent == ["set 2 20 1\n"], "the floor is 20, not 0: \(low.sent)")
        let high = BatteryChargeController(mode: .hold, applied: 80, running: true)
        high.setLimit(140)
        precondition(high.sent == ["set 2 100 1\n"], "the ceiling is 100: \(high.sent)")

        // 5. Shutting down must not send into a closed pipe.
        let quitting = BatteryChargeController(mode: .hold, applied: 80, running: true)
        quitting.shuttingDown = true
        quitting.setLimit(55)
        precondition(quitting.sent.isEmpty, "a shutting-down controller must not send")

        // 6. The gate must be false before management starts, and true after —
        //    this is the exact transition the user described.
        let c = BatteryChargeController(mode: .system, applied: 80, running: false)
        precondition(!c.managesLimit, "off by default")
        c.setLimit(70)
        precondition(c.sent.isEmpty)
        c.process = Process(); c.enter(.limit)
        precondition(c.managesLimit, "starting management turns the slider live")
        c.setLimit(70)
        precondition(c.sent.count == 1, "and then a drag applies")

        print("PASS: slider gate — silent while off, applies on release while managing, "
              + "clamps to 20-100, no-op and shutdown-safe")
    }
}
'''.replace('MODE_ENUM', mode_enum).replace('MANAGES', manages).replace('SET_LIMIT', set_limit)
with tempfile.TemporaryDirectory(prefix='claudebar-charge-tests-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
