#!/usr/bin/env python3
"""Exercise the production controller with in-memory transport and isolated defaults.

No helper is executed and no SMC is touched. Only installation, process launch,
transport and sensor dependencies are replaced; request/reply/lifecycle logic is real.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Models/BatteryChargeController.swift').read_text()
source = source.replace('private(set) ', '').replace('private ', '')
source = source.replace('UserDefaults.standard', 'testDefaults')
source = source.replace('import Observation', '''import Observation
let testDefaults = UserDefaults(suiteName: "claudebar.battery.tests." + UUID().uuidString)!''')
a = source.index('    func start() throws {')
b = source.index('    func disconnect(', a)
source = source[:a] + '''    func start() throws {
        process = Process(); input = FileHandle.nullDevice
        generation = UUID(); restorationConfirmed = false
        lastResponseAt = ProcessInfo.processInfo.systemUptime
    }
''' + source[b:]
a = source.index('    func send(_ message: String) {')
b = source.index('    func receive(', a)
source = source[:a] + '''    var sent: [String] = []
    func send(_ message: String) {
        guard input != nil else { disconnect("disconnected"); return }
        sent.append(message)
    }
''' + source[b:]
source += r'''
enum BatteryHelperInstaller {
    static let path = "/nonexistent"
    static var bundledURL: URL? { nil }
    static var installed = true
    static func isInstalled() -> Bool { installed }
    static func installIfNeeded() -> String? { installed = true; return nil }
}
enum HardwareSensors {
    struct BatteryStatus {
        var installed = true
        var percent = 80
        var batteryWatts: Double? = 0
    }
}
@MainActor final class ProcessSampler {
    static let shared = ProcessSampler()
    var refreshCount = 0
    var battery = HardwareSensors.BatteryStatus()
    func refreshBattery(completion: (@MainActor (HardwareSensors.BatteryStatus) -> Void)? = nil) {
        refreshCount += 1; completion?(battery)
    }
}
@main struct Regression {
    @MainActor static func main() async {
        func waitUntil(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<2000 {
                if condition() { return }
                try! await Task.sleep(for: .milliseconds(1))
            }
            preconditionFailure("asynchronous operation did not finish")
        }
        func fixture(running: Bool = true) -> BatteryChargeController {
            let c = BatteryChargeController()
            c.mode = running ? .limit : .system; c.savedMode = .system
            c.threshold = 80; c.appliedLimit = 80
            c.supported = true; c.dischargeSupported = true
            if running { try! c.start() }
            return c
        }
        func reply(_ c: BatteryChargeController, mode: Int = 1, limit: Int = 80,
                   state: Int = 2, revision: UInt64? = nil, error: String = "",
                   sleeping: Bool = false, terminal: Bool = false) {
            c.receive(.init(revision: revision ?? c.revision, mode: mode, limit: limit,
                            state: state, percent: 90, dischargeSupported: true,
                            sleeping: sleeping, error: error, notice: "", terminal: terminal), token: c.generation)
        }
        let off = fixture(running: false)
        off.setLimit(55)
        precondition(off.sent.isEmpty && off.threshold == 55 && !off.managesLimit)
        let c = fixture()
        c.setLimit(60); c.setLimit(80)
        precondition(c.sent == ["set 1 60 1\n"] && c.pending && c.responseTimeout != nil)
        reply(c, limit: 60)
        precondition(c.sent == ["set 1 60 1\n", "set 1 80 2\n"] && c.pending)
        reply(c)
        precondition(c.limitConfirmed && c.threshold == 80 && !c.pending)

        let mode = fixture()
        mode.apply(.discharge); mode.setLimit(70)
        precondition(mode.sent == ["set 3 80 1\n"])
        reply(mode, mode: 3, state: 3)
        precondition(mode.sent.last == "set 3 70 2\n")
        reply(mode, mode: 3, limit: 70, state: 3)
        precondition(mode.mode == .discharge && mode.limitConfirmed)

        let restore = fixture()
        restore.setLimit(60); restore.apply(.system); restore.setLimit(70)
        reply(restore, limit: 60)
        precondition(restore.sent == ["set 1 60 1\n", "set 0 70 2\n"])
        restore.setLimit(90)
        reply(restore, mode: 0, limit: 70, state: 0)
        precondition(restore.sent.count == 2 && restore.savedMode == .system && !restore.managesLimit)
        precondition(!restore.canApply(.limit)) // wait for child exit
        reply(restore, mode: 0, state: 0, terminal: true)
        restore.ended(token: restore.generation, code: 0)
        precondition(!restore.recoveryUnconfirmed && restore.canApply(.limit))

        let authorization = fixture(running: false)
        authorization.apply(.limit); authorization.setLimit(60)
        await waitUntil { !authorization.sent.isEmpty }
        precondition(authorization.sent == ["set 1 60 1\n"])
        reply(authorization, limit: 60)
        precondition(authorization.limitConfirmed)
        let cancel = fixture(running: false)
        cancel.apply(.limit); cancel.apply(.system); cancel.setLimit(60)
        await waitUntil { !cancel.pending }
        precondition(cancel.sent.isEmpty && !cancel.pending && cancel.savedMode == .system)

        let stale = fixture()
        stale.setLimit(70)
        reply(stale, revision: 0, error: "adapter_required")
        precondition(stale.lastError == nil && stale.pending)
        reply(stale, limit: 70, error: "adapter_required")
        precondition(stale.lastError != nil)
        reply(stale, limit: 70)
        precondition(stale.lastError == nil)

        let lost = fixture()
        lost.lastResponseAt = ProcessInfo.processInfo.systemUptime - 9
        lost.heartbeat()
        precondition(lost.recoveryUnconfirmed && !lost.managesLimit && lost.input == nil)
        lost.setLimit(60)
        precondition(lost.sent.isEmpty)
        reply(lost) // late nonterminal success cannot claim recovery
        precondition(lost.recoveryUnconfirmed)
        reply(lost, mode: 0, state: 0, terminal: true)
        precondition(!lost.recoveryUnconfirmed)

        let failed = fixture()
        failed.setLimit(60)
        reply(failed, mode: 0, state: 3, revision: 0, error: "restore_failed", terminal: true)
        precondition(failed.recoveryUnconfirmed && !failed.pending)
        failed.ended(token: failed.generation, code: 1)
        failed.apply(.system)
        precondition(failed.recoveryUnconfirmed) // no false restoration claim
        precondition(failed.canApply(.limit)) // helper may safely recheck hardware

        let quitting = fixture()
        quitting.apply(.hold); reply(quitting, mode: 2, state: 1)
        precondition(quitting.savedMode == .hold)
        quitting.shutdown()
        reply(quitting, mode: 0, state: 0, terminal: true)
        precondition(testDefaults.integer(forKey: "batteryChargeMode") == 2)

        let sleep = fixture()
        sleep.setLimit(60)
        reply(sleep, limit: 80, state: 0, revision: 0, sleeping: true)
        precondition(sleep.pending && !sleep.managesLimit)
        sleep.lastResponseAt = ProcessInfo.processInfo.systemUptime - 100
        sleep.heartbeat()
        precondition(!sleep.recoveryUnconfirmed)
        reply(sleep, limit: 60)
        precondition(sleep.limitConfirmed)

        let automatic = fixture()
        automatic.apply(.discharge)
        reply(automatic, mode: 1, state: 2) // already at target
        precondition(automatic.mode == .limit && automatic.sent.count == 1)
        precondition(ProcessSampler.shared.refreshCount > 0)

        let resumed = fixture(running: false)
        resumed.savedMode = .limit
        BatteryHelperInstaller.installed = false
        resumed.resumePersistedMode()
        await waitUntil { !resumed.resuming }
        precondition(resumed.sent.isEmpty && !resumed.pending)
        resumed.authorizeHelper()
        await waitUntil { !resumed.sent.isEmpty }
        precondition(resumed.sent == ["set 1 80 1\n"])
        reply(resumed)
        precondition(resumed.mode == .limit)

        let bounds = fixture()
        bounds.setLimit(0); reply(bounds, limit: 20)
        precondition(bounds.appliedLimit == 20)
        bounds.setLimit(140); reply(bounds, limit: 100)
        precondition(bounds.limitConfirmed && bounds.threshold == 100)
        let detecting = fixture(running: false)
        detecting.supported = nil
        detecting.probe(retry: true)
        await waitUntil { !detecting.probing }
        precondition(detecting.supported == nil && detecting.probeError != nil)
        precondition(!detecting.canApply(.limit) && detecting.canApply(.system))

        let telemetry = fixture()
        ProcessSampler.shared.battery.batteryWatts = 10
        reply(telemetry, state: 2)
        precondition(telemetry.measuredText.contains("等待电流变化"))
        telemetry.stateChangedAt = ProcessInfo.processInfo.systemUptime - 11
        reply(telemetry, state: 2)
        precondition(telemetry.measuredText.contains("请检查电源状态"))
        ProcessSampler.shared.battery.batteryWatts = 0
        reply(telemetry, state: 2)
        precondition(telemetry.measuredText.contains("实测"))
        precondition(!telemetry.measuredText.contains("请检查"))

        let timeout = fixture()
        timeout.setLimit(70)
        // The watchdog is an 8 s `Task.sleep`; wait for its *effect* against a
        // generous deadline rather than sleeping a fixed 8.2 s. The fixed
        // sleep left a 200 ms margin, and under load the watchdog's own timer
        // resumes late — measured 1 failure in 6 runs on an idle machine.
        var waited = 0
        while !(timeout.recoveryUnconfirmed && !timeout.pending && timeout.input == nil), waited < 30_000 {
            try! await Task.sleep(for: .milliseconds(50))
            waited += 50
        }
        precondition(timeout.recoveryUnconfirmed && !timeout.pending && timeout.input == nil,
                     "the response watchdog must disconnect after 8 s of silence; waited \(waited) ms")
        precondition(timeout.lastError?.contains("响应超时") == true)
        print("PASS: latest intent, mode/restore ordering, authorization changes, response watchdog, stale replies, sleep, recovery and persistence")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-charge-tests-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(source)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    c_binary = Path(folder) / 'battery-control'
    subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', str(root / 'Tests/battery-control.c'),
                    '-framework', 'IOKit', '-framework', 'CoreFoundation', '-o', str(c_binary)], check=True)
    subprocess.run([str(c_binary)], check=True)
