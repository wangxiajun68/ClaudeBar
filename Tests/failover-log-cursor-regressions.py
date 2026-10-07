#!/usr/bin/env python3
"""The failover detector's log cursor: whole lines, or no advance at all.

`VpnManager.tickFailover` decides whether to switch the primary proxy from
UTF-8-decoded slices of `core.log`. Three cursor bugs had no test of any kind
(172/173/175), each one silent in production:

  * a read boundary landing inside a multi-byte character made `String(data:)`
    return nil and the whole 2 s chunk — up to hundreds of lines, including the
    `i/o timeout` evidence — was dropped while the offset still advanced past
    it, so it was gone for good;
  * after a rotation the offset was resynced to 0, so the retained tail (up to
    512 KB of *pre-restart* history) was replayed and every stale `i/o timeout`
    stamped `now`, arming an instant switch on minutes-old evidence;
  * an offset past EOF (file replaced under the handle, log deleted) froze the
    detector until the process restarted.

The suite drives the production `readFailoverChunk` — the pure byte arithmetic
extracted from the ticker — against a real file in a temp directory. No core
process, no VPN, no app launch.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
manager = (root / 'Sources/ClaudeBar/Utils/VpnManager.swift').read_text()

start = manager.index('    static func readFailoverChunk(')
end = manager.index('\n    }', start) + len('\n    }')
helper = manager[start:end]
# The helper sits inside `extension VpnManager`; wrap it for the probe.
probe = f'''
import Foundation

enum VpnManager {{
{helper}

    static func chunk(_ url: URL, offset: UInt64, generation: UInt64,
                      current: UInt64) -> (text: String, offset: UInt64, generation: UInt64)? {{
        readFailoverChunk(url: url, offset: offset, generation: generation,
                          currentGeneration: current)
    }}
}}

@main struct Regression {{
    static func main() throws {{
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let log = folder.appendingPathComponent("core.log")

        func write(_ bytes: [UInt8]) throws {{
            try Data(bytes).write(to: log, options: .atomic)
        }}

        // 1. A complete line advances the offset only over its bytes.
        let lineA = Array("time=1 [Dial] i/o timeout to 1.2.3.4\\n".utf8)
        try write(lineA)
        var read = VpnManager.chunk(log, offset: 0, generation: 0, current: 0)!
        precondition(read.text.contains("i/o timeout"), "a whole line must be read")
        precondition(read.offset == UInt64(lineA.count))

        // 2. A partial trailing line (no newline) is left for the next tick —
        //    the offset must NOT advance into it, or the line is lost when it
        //    completes.
        try write(lineA + Array("time=2 [Dial] wait".utf8))
        read = VpnManager.chunk(log, offset: 0, generation: 0, current: 0)!
        precondition(read.offset == UInt64(lineA.count),
                     "the incomplete tail must stay at the offset, got \\(read.offset)")
        precondition(!read.text.contains("wait"), "the partial line must not be reported yet")
        // The same tick on the completed file reads the second line too.
        try write(lineA + Array("time=2 [Dial] wait\\n".utf8))
        read = VpnManager.chunk(log, offset: UInt64(lineA.count), generation: 0, current: 0)!
        precondition(read.text == "time=2 [Dial] wait\\n", "the completed line reads on the next tick")

        // 3. A boundary inside a multi-byte character: the chunk ends
        //    mid-character, and the complete-lines cut must both keep the
        //    evidence and advance by exactly the decoded bytes. 3 bytes of
        //    "东" follow the first newline, so a naive decode drops everything.
        let cjk = Array("ok 1\\n".utf8) + Array("东".utf8).dropLast(2) + [0x20]
        try write(cjk)
        read = VpnManager.chunk(log, offset: 0, generation: 0, current: 0)!
        precondition(read.text == "ok 1\\n", "the complete line survives a mid-character boundary")
        precondition(read.offset == 5, "the offset stops before the torn char, got \\(read.offset)")

        // 4. A rotation resyncs to the *current end*: nothing of the retained
        //    tail may be replayed (that armed the switch on stale evidence).
        let history = Array("old i/o timeout to 1.2.3.4\\n".utf8)
        try write(history)
        read = VpnManager.chunk(log, offset: 0, generation: 0, current: 1)!
        precondition(read.text.isEmpty, "a rotation must not replay the retained tail")
        precondition(read.offset == UInt64(history.count), "the resync lands at EOF")
        precondition(read.generation == 1, "the resync adopts the new generation")
        // …and bytes appended after the rotation are read from that point.
        try write(history + Array("new i/o timeout to 1.2.3.4\\n".utf8))
        read = VpnManager.chunk(log, offset: UInt64(history.count), generation: 1, current: 1)!
        precondition(read.text == "new i/o timeout to 1.2.3.4\\n", "post-rotation bytes are live evidence")

        // 5. An offset past EOF clamps to the end instead of freezing: the
        //    next append is then read normally.
        let short = Array("t=1\\n".utf8)
        try write(short)
        read = VpnManager.chunk(log, offset: 999_999, generation: 0, current: 0)!
        precondition(read.text.isEmpty && read.offset == UInt64(short.count),
                     "an offset past EOF clamps: \\(read.offset)")
        try write(short + Array("t=2 i/o timeout to 5.6.7.8\\n".utf8))
        read = VpnManager.chunk(log, offset: read.offset, generation: 0, current: 0)!
        precondition(read.text == "t=2 i/o timeout to 5.6.7.8\\n",
                     "failover must recover after an off-EOF offset")

        // 6. Invalid UTF-8 inside a complete line is replaced, not dropped
        //    (the old `String(data:encoding:)` threw the whole chunk away).
        try write(Array("bad ".utf8) + [0xFF, 0xFE] + Array(" i/o timeout to 9.9.9.9\\n".utf8))
        read = VpnManager.chunk(log, offset: 0, generation: 0, current: 0)!
        precondition(read.text.contains("i/o timeout to 9.9.9.9"),
                     "a byte sequence that is not valid UTF-8 must not discard the line")

        print("PASS: failover cursor advances by whole lines only, resyncs to EOF on rotation, and survives mid-character and off-EOF boundaries")
    }}
}}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-failover-cursor-') as folder:
    swift = Path(folder) / 'Regression.swift'
    swift.write_text(probe)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary), folder], check=True)
