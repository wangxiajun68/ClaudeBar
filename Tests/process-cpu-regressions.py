#!/usr/bin/env python3
"""Per-process CPU is a fraction of one core, measured against real processes.

`ProcessSampler.cpuPercent` reads `proc_taskinfo.pti_total_user/system` and
turns a delta into a percentage. Those fields are in **mach absolute-time
ticks**, not nanoseconds: on this machine `mach_timebase_info` reports 125/3,
so 1 tick = 41.67 ns. Dividing by 1e9 — correct only where the timebase is 1:1
— under-reported every process by 41.7×, which is why the session chips, the
claudeBar share and the attribution strip read as idle while a child was
pegged.

The check drives the *production* method (sliced out of the source, not
re-implemented) against two real children of this test binary: one burning CPU
in a loop, one asleep. The busy child must read as a core's worth of work, the
sleeping one as nothing. A magnitude assertion rather than an exact one — the
point is that the scale is right, not that a scheduler handshakes at 99.9%.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sampler = (root / 'Sources/ClaudeBar/Utils/ProcessSampler.swift').read_text()


def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    level, end = 1, opening + 1
    while level:
        level += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')


# The timebase constant and the sampler are taken together: the constant is
# what the method reads, and slicing one without the other would silently
# substitute a fixture's own idea of a tick.
timebase_start = sampler.index('    private static let nanosecondsPerTick: Double = {')
timebase_end = sampler.index('    private func cpuPercent(pid: pid_t, now: TimeInterval) -> Double {')
timebase = sampler[timebase_start:timebase_end].replace('private static let', 'static let')
cpu_percent = method(sampler, '    private func cpuPercent(pid: pid_t, now: TimeInterval) -> Double {')

probe = r'''
import Darwin
import Foundation

final class CPUSampler {
    var lastCPU: [pid_t: (ticks: UInt64, at: TimeInterval)] = [:]
<<<TIMEBASE>>>
<<<CPU_PERCENT>>>
}

/// `now` is supplied rather than read from a clock: two samples 0.6 s apart,
/// stamped by the caller, so the ratio the method computes is the only thing
/// under test.
func sampled(_ sampler: CPUSampler, pid: pid_t) -> Double {
    _ = sampler.cpuPercent(pid: pid, now: 0)
    Thread.sleep(forTimeInterval: 0.6)
    return sampler.cpuPercent(pid: pid, now: 0.6)
}

@main struct Regression {
    static func main() {
        // The burn child is this same binary, so nothing else has to exist on
        // the system for the test to run.
        if CommandLine.arguments.contains("--burn") {
            let until = Date().addingTimeInterval(60)
            var acc = 0.0
            while Date() < until { acc += 1.0; if acc > 1e30 { acc = 0 } }
            exit(0)
        }

        let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: me)
        busy.arguments = ["--burn"]
        busy.standardOutput = FileHandle.nullDevice
        busy.standardError = FileHandle.nullDevice
        try! busy.run()
        defer { busy.terminate(); busy.waitUntilExit() }

        let idle = Process()
        idle.executableURL = URL(fileURLWithPath: "/bin/sleep")
        idle.arguments = ["60"]
        try! idle.run()
        defer { idle.terminate(); idle.waitUntilExit() }

        let sampler = CPUSampler()

        // A hot loop needs a moment to actually be running before the baseline
        // sample, or the first delta covers process startup only.
        Thread.sleep(forTimeInterval: 0.3)
        let busyCPU = sampled(sampler, pid: busy.processIdentifier)
        let idleCPU = sampled(sampler, pid: idle.processIdentifier)

        precondition(CPUSampler.nanosecondsPerTick > 1,
                     "Apple silicon's timebase is 41.67 ns/tick; a 1.0 here means mach_timebase_info failed")
        precondition(busyCPU > 40,
                     "a pegged child read \(busyCPU)% — the tick-to-time conversion is wrong by the timebase")
        precondition(busyCPU < 200,
                     "a single-threaded child cannot use \(busyCPU)% of one core")
        precondition(idleCPU < 10, "a sleeping child read \(idleCPU)%")
        precondition(busyCPU > idleCPU * 10,
                     "busy \(busyCPU)% must separate from idle \(idleCPU)%")

        print(String(format: "PASS: busy %.1f%%, idle %.1f%%, %.2f ns/tick",
                     busyCPU, idleCPU, CPUSampler.nanosecondsPerTick))
    }
}
'''
probe = probe.replace('<<<TIMEBASE>>>', timebase).replace('<<<CPU_PERCENT>>>', cpu_percent)
assert 'nanosecondsPerTick' in probe and 'proc_pidinfo' in probe, \
    'the probe lost the production slice it is supposed to compile'

with tempfile.TemporaryDirectory(prefix='claudebar-process-cpu-') as folder:
    folder = Path(folder)
    source = folder / 'Probe.swift'
    source.write_text(probe)
    binary = folder / 'probe'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
