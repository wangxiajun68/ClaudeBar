#!/usr/bin/env python3
"""The greeting must name the *person*, and never the machine's model.

Two failures this pins down, both of which shipped:

1. The card read `kern.hostname`, which the LAN rewrites — on a router that
   leases by address it is `192.168.10.102`, and the card greeted the user with
   their own IP.
2. The name it derives must be the person. `王夏军的MacBook Pro` is a machine
   name; a card that says "Hello 王夏军的MacBook Pro" is saying hello to a
   laptop.

Extracts `MachineIdentity`'s rule from the production source, no app launch, no
network, no preference writes.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Utils/MachineIdentity.swift').read_text()
body = source[source.index('enum MachineIdentity {'):]

swift = r'''
import Foundation
import SystemConfiguration

IDENTITY

@main struct Regression {
    static func main() {
        // `person(in:)` is the pure rule; `greetingName` is that rule applied
        // to the live machine name, and is asserted at the end.
        typealias Case = (input: String, want: String)
        let cases: [Case] = [
            // The shape this user's Mac has: the CJK possessive, then the model.
            ("王夏军的MacBook Pro", "王夏军"),
            ("王大锤的MacBook Pro", "王大锤"),
            ("李雷的iMac", "李雷"),
            // The Latin possessive, including the typographic apostrophe that
            // macOS actually writes.
            ("Sam's MacBook Pro", "Sam"),
            ("Sam\u{2019}s MacBook Pro", "Sam"),
            ("Chris\u{2019}s iMac", "Chris"),
            // A name that concatenated the model with a host-name joiner: the
            // `de` is the pinyin 的, the `s` is the plural joiner. Both are the
            // OS's characters, not the person's.
            ("wangxiajundeMacBook-Pro-8", "wangxiajun"),
            ("wangxiajuns-MacBook-Pro", "wangxiajun"),
            ("Sams-MacBook-Pro", "Sam"),
            // Nothing to take: keep the whole string rather than inventing a
            // fragment or returning empty.
            ("MacBook Pro", "MacBook Pro"),
            ("Mac", "Mac"),
            ("王夏军", "王夏军"),
            // A bare marker is not a name — do not hand back the leftover.
            ("的MacBook Pro", "的MacBook Pro"),
        ]

        var failures = 0
        for c in cases {
            let got = MachineIdentity.person(in: c.input)
            if got != c.want {
                print("FAIL: \\(c.input) -> \\(got), want \\(c.want)", to: &failures)
            }
        }

        // The live machine must produce a non-empty greeting that is not an
        // address: whatever this Mac is called, the card cannot print an IP.
        let live = MachineIdentity.greetingName
        precondition(!live.isEmpty, "the greeting must never be empty")
        let isAddress = live.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        precondition(!isAddress, "the greeting must not be a bare address; got \(live)")

        guard failures == 0 else { fatalError("\(failures) greeting-name case(s) failed") }
        print("PASS: possessive and host-name shapes resolve to the person; a model-only or address-like name is kept whole, never fragmented; live name \(live)")
    }
}

private func print(_ message: String, to failures: inout Int) {
    Swift.print(message)
    failures += 1
}
'''
with tempfile.TemporaryDirectory(prefix='greeting-name-') as tmp:
    path = Path(tmp) / 'Regression.swift'
    path.write_text(swift.replace('IDENTITY', body))
    binary = Path(tmp) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', '-framework', 'SystemConfiguration',
                    str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
