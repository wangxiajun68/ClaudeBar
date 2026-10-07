#!/usr/bin/env python3
"""SMC fan figures must not trap the app on hostile float bit patterns.

`FanMonitor` polls `SMCController.loadFans()` every 2 s on its read queue, and
the figures come straight from the SMC kext: a `flt ` key that was never
initialised (or a firmware that answers with garbage) can decode to NaN or
±Infinity, and `Int(_: Double)` **traps** on both — on a background queue,
once per poll, taking the whole menu-bar app down. `safeRPM` is the single
conversion every fan and mode figure goes through; it must clamp instead.

The real function is sliced out of the production file and executed — the
assertions below drive the shipped code, not a restatement of it. No SMC
connection, no hardware, no app launch: the slicing never touches IOKit.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
controller = (root / 'Sources/ClaudeBar/Utils/SMCController.swift').read_text()


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


safe_rpm = braced(controller, '    static func safeRPM(')

swift = f'''
import Foundation

/// The production clamp, sliced whole.
enum SMCController {{
{safe_rpm}
}}

func expect(_ value: Double, _ expected: Int, _ label: String) {{
    let got = SMCController.safeRPM(value)
    precondition(got == expected, "\\(label): expected \\(expected), got \\(got)")
}}

@main struct Regression {{
    static func main() {{
        // 1. The trap cases. `Int(nan)` / `Int(inf)` die at runtime; a clamp
        //    that let them through would SIGTRAP the probe here, which is
        //    exactly the failure the fix prevents in the app. A non-finite
        //    reading means "no reading" and reports 0; a finite value past
        //    the clamp still gets its bound, because the bytes did decode.
        expect(.nan, 0, "NaN")
        expect(.infinity, 0, "+Infinity")
        expect(-.infinity, 0, "-Infinity")
        // Values past the Int64 range convert to equally poisonous results —
        // 1e300 is finite but `Int(1e300)` still traps.
        expect(1e300, 1_048_576, "1e300")
        expect(-1e300, -1_048_576, "-1e300")

        // 2. The real readings pass through untouched.
        expect(0, 0, "zero")
        expect(1200, 1200, "idle rpm")
        expect(6800.0, 6800, "full blast")
        expect(-3.7, -3, "negatives truncate toward zero, no trap")

        // 3. The clamp bounds themselves are exact.
        expect(1_048_576, 1_048_576, "bound")
        expect(1_048_577, 1_048_576, "bound + 1")
        expect(-1_048_576, -1_048_576, "-bound")
        expect(-1_048_577, -1_048_576, "-bound - 1")

        print("PASS: SMC fan figures clamp NaN / Infinity / out-of-range floats instead of trapping")
    }}
}}
'''

# The section `safeRPM` sits in is loadFans / fanMode; the pins keep the
# conversion single-sourced — a new `Int(getValue(...))` reintroduced next to
# one of these would be the same trap on a path this suite cannot see.
assert 'Int(getValue(' not in controller, \
    'every SMC float-to-Int conversion must go through safeRPM; a direct Int(...) traps on NaN/inf'
assert 'Int(md)' not in controller and 'Int(count)' in controller, \
    'the mode decode must use safeRPM; only the FNum fan count keeps a plain Int (count > 0 is checked)'

with tempfile.TemporaryDirectory(prefix='claudebar-smc-sampling-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
