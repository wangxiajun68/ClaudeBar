#!/usr/bin/env python3
"""`CoreLogWriter`'s rotation contract, driven through the production class.

Both VPN logs are append-only diagnostics, and `core.log` had reached 86 MB on
this machine before the writer started capping itself. The invariants are what
the *readers* depend on:

  * `rotateIfNeeded()` adopts a pre-existing file's size into `written` — so a
    log that grew while the handle was closed is capped at next launch instead
    of doubling its cap;
  * a rotation keeps the tail (~512 KB) rather than truncating to zero, because
    `extractFatal` reads the last 64 KB and a crash report written just before
    the threshold has to survive it;
  * `generation` increments exactly once per rotation — the failover ticker
    resyncs its byte offset by comparing it, and an offset taken before a
    rotation points into unrelated text afterwards (the bug that invariant
    exists to catch);
  * the bytes after rotation are the *tail of what was written*, in order.

A change to the `written` accounting (e.g. not resetting it after rotation)
makes the writer either rotate every append or never — neither shows up in any
existing suite. The class is file-backed but fully drivable against a temp
directory: no core process, no app launch, no network.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
manager = (root / 'Sources/ClaudeBar/Utils/VpnManager.swift').read_text()

start = manager.index('final class CoreLogWriter')
end = manager.index('\nextension VpnManager {', start)
writer = manager[start:end]

swift = f'''
import Foundation

{writer}

@main struct Regression {{
    static func main() throws {{
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let log = folder.appendingPathComponent("core.log")
        let cap = 8 * 1024 * 1024
        let keep = 512 * 1024

        // 1. A pre-existing log above the cap is rotated at adoption time, its
        //    tail kept, and `written` adopted as the kept size: appending one
        //    small chunk afterwards must land below the cap, not trigger
        //    another rotation.
        let oversized = Data(repeating: 0x41, count: cap + 1024)
        try oversized.write(to: log)
        let adopted = CoreLogWriter(url: log)
        adopted.rotateIfNeeded()
        precondition(adopted.generation == 1, "an oversized log rotates on adoption: \\(adopted.generation)")
        var size = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as! NSNumber
        precondition(size.intValue == keep, "rotation keeps the tail: \\(size.intValue)")

        adopted.append(Data(repeating: 0x42, count: 64))
        adopted.append(Data(repeating: 0x43, count: 64))
        size = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as! NSNumber
        precondition(size.intValue == keep + 128,
                     "adopted `written` must not rotate again for a tiny append: \\(size.intValue)")
        precondition(adopted.generation == 1)

        // 2. A log below the cap is adopted without rotating and its size is
        //    picked up (a run that ended just under the cap continues there).
        let small = folder.appendingPathComponent("small.log")
        try Data(repeating: 0x44, count: 4096).write(to: small)
        let resumed = CoreLogWriter(url: small)
        resumed.rotateIfNeeded()
        precondition(resumed.generation == 0, "a small log must not rotate: \\(resumed.generation)")

        // 3. Crossing the cap rotates exactly once, keeps the tail of what was
        //    written, and adopts the kept size — so the appends that follow
        //    land under the cap without another rotation.
        let rolling = folder.appendingPathComponent("rolling.log")
        let fresh = CoreLogWriter(url: rolling)
        fresh.rotateIfNeeded()
        precondition(fresh.generation == 0)
        var writtenBytes: [UInt8] = []
        var index: UInt8 = 0
        while writtenBytes.count < cap {{
            let chunk = Data(repeating: index, count: 64 * 1024)
            fresh.append(chunk)
            writtenBytes.append(contentsOf: chunk)
            index = index &+ 1
        }}
        precondition(fresh.generation == 0,
                     "at the cap exactly, nothing has rotated yet: \\(fresh.generation)")
        let crossing = Data(repeating: 0xFE, count: 1)
        fresh.append(crossing)
        writtenBytes.append(contentsOf: crossing)
        precondition(fresh.generation == 0, "the cap is a strict `>`: \\(fresh.generation)")
        let trigger = Data(repeating: 0xFD, count: 1)
        fresh.append(trigger)
        precondition(fresh.generation == 1,
                     "the append past the cap must rotate once: \\(fresh.generation)")
        var contents = try Data(contentsOf: rolling)
        precondition(contents.count == Int(keep),
                     "rotation must keep exactly the tail: \\(contents.count)")
        // The rotation runs *before* the chunk that tripped it is written, so
        // the kept bytes are the tail of the file as it stood when the
        // oversized append arrived — the tail of everything written so far.
        precondition(Array(contents) == Array(writtenBytes.suffix(Int(keep))),
                     "the kept bytes must be the tail of what was on disk")
        let more = Data(repeating: 0xFC, count: 64 * 1024)
        fresh.append(more)
        contents = try Data(contentsOf: rolling)
        precondition(fresh.generation == 1 && contents.count == Int(keep) + 64 * 1024,
                     "the adopted `written` must keep the next chunks below the cap: "
                     + "\\(fresh.generation)/\\(contents.count)")

        // 4. The offset-resync invariant `tickFailover` relies on: an offset is
        //    valid until the next rotation, and every rotation bumps the
        //    generation a reader compares against.
        let reader = CoreLogWriter(url: folder.appendingPathComponent("reader.log"))
        reader.rotateIfNeeded()
        let seen = reader.generation
        reader.append(Data(repeating: 0x45, count: cap + 1))
        reader.append(Data(repeating: 0x46, count: 1))
        precondition(reader.generation == seen + 1,
                     "one crossing, one generation bump: \\(reader.generation - seen)")

        print("PASS: core log rotation, tail keeping, size adoption and generation resync")
    }}
}}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-corelog-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    with tempfile.TemporaryDirectory(prefix='claudebar-corelog-data-') as data:
        subprocess.run([str(binary), data], check=True)
