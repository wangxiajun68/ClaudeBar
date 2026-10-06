#!/usr/bin/env python3
"""The counter arithmetic on the VPN surfaces must not trap on hostile input.

Four trapping sites sat behind one another on the same data path, and every one
of them is reachable from a payload this app does not control:

  * `VpnFormat.scaled` did `abs(b)` — and `abs(Int64.min)` **traps**, with
    `Int64.min` reachable from the core's own `/connections` JSON (the counters
    are read as `Int64` straight out of it).
  * The per-connection sums (`down += …`, `up += …`) trap on overflow: Swift's
    `+` traps even under `-O`, and the addends come from the same JSON.
  * The derived-rate fallback's `totalDown - prev.down` traps the same way.
  * `VpnSubscription`'s `upload + download` / `total - used` trap on the
    `subscription-userinfo` header — i.e. on whatever bytes an airport's server
    sends, evaluated while the subscription card renders.

None of these are hypothetical in the sense that matters: each is a *crash on
data*, not a wrong number, and the data is remote. The probe drives the
production functions at their extremes; the subscription half is asserted
textually as well, because its two properties read `VpnFormat` from another
file and compiling that whole file is not what this suite is for.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
manager = (root / 'Sources/ClaudeBar/Utils/VpnManager.swift').read_text()
subscription = (root / 'Sources/ClaudeBar/Utils/VpnSubscriptionStore.swift').read_text()


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


format_source = manager[manager.index('enum VpnFormat {'):]
format_source = format_source[:format_source.index('\n}\n') + 3]
saturating = (braced(manager, '    static func saturatingAdd(')
              + '\n' + braced(manager, '    static func saturatingSub(')
              + '\n' + braced(manager, '    static func rate(_ delta: Int64, over seconds: TimeInterval)'))

swift = f'''
import Foundation

/// The production `VpnFormat` enum, sliced whole: the point of this suite is
/// that the *shipped* arithmetic clamps, so nothing here is re-implemented.
{format_source}

@main struct Regression {{
    static func main() {{
        // 1. The formatting path must survive both extremes rather than
        //    trapping. `Int64.min` is the one that used to crash.
        for value in [Int64.min, Int64.min + 1, -1, 0, 1, Int64.max] {{
            let text = VpnFormat.bytes(value)
            precondition(!text.isEmpty, "bytes(\\(value)) produced nothing")
        }}
        // The magnitude is what is rendered — a negative counter is a broken
        // reading, not a negative amount of traffic.
        precondition(VpnFormat.bytes(Int64.min) == VpnFormat.bytes(Int64.max),
                     "the magnitude must be rendered, not the sign")

        // 2. Sums saturate instead of trapping, in both directions.
        precondition(VpnFormat.saturatingAdd(Int64.max, 1) == Int64.max)
        precondition(VpnFormat.saturatingAdd(Int64.min, -1) == Int64.min)
        precondition(VpnFormat.saturatingAdd(Int64.max, -1) == Int64.max - 1)
        precondition(VpnFormat.saturatingSub(Int64.min, 1) == Int64.min)
        precondition(VpnFormat.saturatingSub(Int64.max, -1) == Int64.max)
        precondition(VpnFormat.saturatingSub(5, 3) == 2)
        // The derived-rate fallback: a counter jump that would overflow the
        // Double→Int64 conversion saturates instead of trapping, and a
        // non-positive interval reads as no rate rather than a division by zero.
        precondition(VpnFormat.rate(Int64.max, over: 0.000001) == Int64.max)
        precondition(VpnFormat.rate(1_000, over: 0.5) == 2_000)
        precondition(VpnFormat.rate(1_000, over: 0) == 0)
        precondition(VpnFormat.rate(-5, over: 1) == 0)

        // 3. Accumulating a hostile connections array neither traps nor turns
        //    the strip into a negative figure.
        var down: Int64 = 0
        for value in [Int64.max, Int64.max, Int64.max] {{
            down = VpnFormat.saturatingAdd(down, value)
        }}
        precondition(down == Int64.max, "a saturating sum must stop at the bound; got \\(down)")
        let delta = VpnFormat.saturatingSub(Int64.min, Int64.max)
        precondition(delta == Int64.min, "a saturating difference must stop at the bound; got \\(delta)")
        let rate = Int64(Double(delta) / 2.0)
        precondition(rate <= 0, "a backwards counter must not read as a positive rate")

        // 4. The fixed-width contract the surfaces lay out against holds across
        //    the range a real counter can reach (up to ~1 EB, where the unit
        //    tops out), and stays bounded past it — an overlong string there is a
        //    display artifact of a corrupt counter, not a crash or a shifted
        //    menu bar.
        for value in [Int64(0), -1, 1024, 1_048_576, 1 << 40, 1 << 50, (1 << 53)] {{
            precondition(VpnFormat.bytes(value).count == 9,
                         "bytes must stay fixed-width at \\(value); got \\(VpnFormat.bytes(value))")
            precondition(VpnFormat.rate(value).count == 11,
                         "rate must stay fixed-width at \\(value); got \\(VpnFormat.rate(value))")
        }}
        for value in [Int64.min, Int64.max, Int64(1) << 60] {{
            precondition(VpnFormat.bytes(value).count <= 13,
                         "bytes must stay bounded at the Int64 bounds; got \\(VpnFormat.bytes(value))")
        }}
        precondition(VpnFormat.connections(Int.min).count == 4 && VpnFormat.connections(Int.max).count == 4,
                     "connections must stay fixed-width at the bounds")

        print("PASS: formatting, sums and differences clamp at the Int64 bounds instead of trapping")
    }}
}}
'''

# --- the subscription half ---------------------------------------------------
# `VpnSubscription.usedBytes` / `remainingBytes` now go through the same
# saturating helpers, and the header values are range-checked where they are
# parsed. Both are asserted here because the properties live in a file that
# reads `VpnFormat` from the one above, and the parse boundary is what keeps a
# negative or absurd header from ever reaching them.
assert 'VpnFormat.saturatingAdd(upload, download)' in subscription and \
    'VpnFormat.saturatingSub(total, usedBytes)' in subscription, \
    'VpnSubscription must do its arithmetic through the saturating helpers'
assert 'guard let value = Int64(text), value >= 0, value <= (1 << 53) else { return nil }' in subscription, \
    'parseUserInfo must refuse a negative or absurd subscription-userinfo value'
assert 't.isFinite, t > 0, t <= 253_402_300_799' in subscription, \
    'parseUserInfo must refuse an unrepresentable subscription expiry'

with tempfile.TemporaryDirectory(prefix='claudebar-vpn-format-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
