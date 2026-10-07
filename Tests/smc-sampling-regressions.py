#!/usr/bin/env python3
"""SMC figures must decode to the right numbers, clamp hostile floats, and be
read once per key.

Two layers, both driving shipped code:

1. `FanMonitor` polls `SMCController.loadFans()` every 2 s on its read queue,
   and the figures come straight from the SMC kext: a `flt ` key that was never
   initialised (or a firmware that answers with garbage) can decode to NaN or
   ±Infinity, and `Int(_: Double)` **traps** on both — on a background queue,
   once per poll, taking the whole menu-bar app down. `safeRPM` is the single
   conversion every fan and mode figure goes through; it must clamp instead.

2. `decode`'s byte arithmetic (ui8/ui16/sp78/sp87/fpe2/flt): a wrong shift or a
   swapped divisor is invisible on screen — `cpuTemperatureCelsius` filters
   `> 0, < 110`, so a constant 0.5-2 °C offset never shows, while threshold
   logic (fans, charging) fails intermittently. `ui8`'s 16-bit little-endian
   fallback was exactly that bug: `UInt8(0x35) << 8 == 0`, so a ` 8iu` key
   ≥ 256 read low-byte-only while `fanctl.c`'s identically-shaped C line
   (integer-promoted) returned the full value.

The methods are sliced out of the production file and executed whole
(`getValue`, `getStringValue`, `fanModeKey`, `fanMode`, `loadFans`, `decode`,
`safeRPM`); the probe's only substitute for IOKit is `read`, which hands back
the canned bytes per key and logs each round trip. No SMC connection, no
hardware, no app launch: slicing never touches IOKit.

The probe substitutes `decode`/`getValue`/`getStringValue`/`loadFans` plumbing
that the production class shares with the IOKit connection, but the bodies of
`decode`, `getStringValue`'s byte window, `fanModeKey`'s probe, `fanMode`'s
fallback and `loadFans`'s assembly are the shipped ones.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
controller = (root / 'Sources/ClaudeBar/Utils/SMCController.swift').read_text()


def braced(text, signature):
    """The whole declaration starting at `signature`, braces balanced.

    Skips braces inside Swift string literals — `SMCDataType` contains
    `FourCharCode("{fds")`, whose `{` would otherwise run the scanner to EOF.
    """
    start = text.index(signature)
    i = text.index('{', start)
    depth, j = 0, i
    in_string = False
    while j < len(text):
        ch = text[j]
        if in_string:
            if ch == '\\':
                j += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
        j += 1
    raise ValueError(f'unbalanced braces after {signature!r}')


safe_rpm = braced(controller, '    static func safeRPM(')
fan_mode_enum = braced(controller, 'enum FanMode:')
fan_info = braced(controller, 'struct FanInfo:')
data_types = braced(controller, 'private enum SMCDataType {')
fourcc = braced(controller, 'private struct FourCharCode:')
float_init = braced(controller, 'private extension Float {')
decode = braced(controller, '    private func decode(')
get_value = braced(controller, '    func getValue(')
get_string = braced(controller, '    func getStringValue(')
fan_mode_key = braced(controller, '    func fanModeKey(')
fan_mode = braced(controller, '    private func fanMode(')
load_fans = braced(controller, '    func loadFans(')

swift = f'''
import Foundation

{fan_mode_enum}

{fan_info}

{data_types}

{fourcc}

{float_init}

/// The production reads, driven through a canned SMC connection.
///
/// `read` is the probe's only substitute for IOKit: it serves the configured
/// bytes for a key and logs every round trip. Everything else below is the
/// shipped method body, sliced verbatim.
final class ProbeSMC {{
    struct Key {{
        var bytes: [UInt8]
        var size: UInt32
        var type: UInt32
    }}
    var keys: [String: Key] = [:]
    private(set) var readLog: [String] = []

    private func read(_ key: String, into outBytes: inout [UInt8], size: inout UInt32, type: UnsafeMutablePointer<UInt32>?) -> kern_return_t {{
        readLog.append(key)
        guard let entry = keys[key], entry.size > 0, entry.size <= UInt32(outBytes.count) else {{ return KERN_FAILURE }}
        for (i, b) in entry.bytes.enumerated() where i < outBytes.count {{ outBytes[i] = b }}
        size = entry.size
        type?.pointee = entry.type
        return KERN_SUCCESS
    }}

    private var fanModeKeyIsLower: Bool?

{decode}

{get_value}

{get_string}

{fan_mode_key}

{fan_mode}

{load_fans}

{safe_rpm}

    /// Reads logged for one key since the last reset.
    func reads(of key: String) -> Int {{ readLog.filter {{ $0 == key }}.count }}
    func resetReads() {{ readLog = [] }}
}}

@main struct Regression {{
    static func main() {{
        // MARK: safeRPM — the clamp

        func expect(_ value: Double, _ expected: Int, _ label: String) {{
            let got = ProbeSMC.safeRPM(value)
            precondition(got == expected, "\\(label): expected \\(expected), got \\(got)")
        }}

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

        // MARK: decode, through the real getValue

        func padded(_ bytes: [UInt8]) -> [UInt8] {{
            var out = [UInt8](repeating: 0, count: 32)
            for (i, b) in bytes.enumerated() where i < out.count {{ out[i] = b }}
            return out
        }}
        func floatBytes(_ value: Float) -> [UInt8] {{
            withUnsafeBytes(of: value) {{ Array($0) }} + [UInt8](repeating: 0, count: 28)
        }}
        func fdsBytes(_ name: String) -> [UInt8] {{
            var out = [UInt8](repeating: 0, count: 32)
            out[0] = 0x46; out[1] = 0x30; out[2] = 0x49; out[3] = 0x44 // "F0ID"
            for (i, b) in name.utf8.enumerated() where i < 12 {{ out[4 + i] = b }}
            return out
        }}

        let smc = ProbeSMC()
        func set(_ key: String, _ bytes: [UInt8], size: UInt32, type: UInt32) {{
            smc.keys[key] = ProbeSMC.Key(bytes: bytes, size: size, type: type)
        }}
        func value(_ key: String) -> Double? {{ smc.getValue(key) }}

        // ui8 " 8iu"-style little-endian pair: the high byte must survive.
        set("L", padded([0x35, 0x01]), size: 2, type: SMCDataType.ui8)
        precondition(value("L") == 309, "ui8 16-bit must be little-endian (0x0135), got \\(String(describing: value("L")))")
        set("O", padded([0x35]), size: 1, type: SMCDataType.ui8)
        precondition(value("O") == 53, "ui8 single byte")
        // ui16 keeps big-endian ordering — the mirror of the ui8 pair.
        set("W", padded([0x35, 0x01]), size: 2, type: SMCDataType.ui16)
        precondition(value("W") == 0x3501, "ui16 is big-endian")
        set("D", padded([0x01, 0x00, 0x00, 0x01]), size: 4, type: SMCDataType.ui32)
        precondition(value("D") == Double(0x01000001), "ui32 is big-endian")

        // sp78 = signed 8.8 (°C), sp87 = 7.9 (fraction in 1/128) — swapping
        // the divisors is the classic silent off-by-a-factor.
        set("T78", padded([0x2D, 0x00]), size: 2, type: SMCDataType.sp78)
        precondition(value("T78") == 45, "sp78 45.0 °C")
        set("T87", padded([0x2D, 0x00]), size: 2, type: SMCDataType.sp87)
        precondition(value("T87") == 90, "sp87 divides by 128, not 256")
        // fpe2 = 14.2 unsigned fixed point: 1200 rpm is {0x12, 0xC0}
        // (0x12C0 >> 2); shifting the high byte by 8 instead of 6 would read
        // this as 4800.
        set("F", padded([0x12, 0xC0]), size: 2, type: SMCDataType.fpe2)
        precondition(value("F") == 1200, "fpe2 shifts the high byte by 6, not 8")
        set("R", floatBytes(6800.0), size: 4, type: SMCDataType.flt)
        precondition(value("R") == 6800, "flt decodes little-endian float bytes")

        // Short and long dataSize must not trap or read out of bounds.
        set("Short", padded([0x12]), size: 1, type: SMCDataType.fpe2)
        precondition(value("Short") != nil, "a single-byte fpe2 still decodes (defined formula, no OOB)")
        set("Long", floatBytes(1200.0), size: 32, type: SMCDataType.flt)
        precondition(value("Long") == 1200, "a 32-byte flt reads its first four bytes")

        // Unknown type → nil, not a guess.
        set("X", padded([0x01]), size: 1, type: FourCharCode("abcd").rawValue)
        precondition(value("X") == nil, "an unknown SMC type must not decode")

        // The all-zero exemption table: an uninitialised mode key reads as 0
        // (real value) instead of nil; every other all-zero key stays nil.
        set("F0md", padded([0]), size: 4, type: SMCDataType.flt)
        precondition(value("F0md") == 0, "an all-zero F0md is a reading, not a dead key")
        set("F0Ac", padded([]), size: 4, type: SMCDataType.flt)
        precondition(value("F0Ac") == nil, "an all-zero rpm key reads as no reading")
        smc.keys["F0Ac"] = nil

        // MARK: getStringValue — the fds fan names

        set("F0ID", fdsBytes("Left Fan    "), size: 12, type: SMCDataType.fds)
        precondition(smc.getStringValue("F0ID") == "Left Fan", "fds names trim trailing padding and start at byte 4")
        set("F0ID", fdsBytes("Right Fan   "), size: 12, type: SMCDataType.fds)
        precondition(smc.getStringValue("F0ID") == "Right Fan", "fds names are read whole, not truncated")
        set("F0ID", fdsBytes("Left Fan    "), size: 12, type: SMCDataType.ui16)
        precondition(smc.getStringValue("F0ID") == nil, "only fds decodes as a string")
        smc.keys["F0ID"] = nil
        precondition(smc.getStringValue("F0ID") == nil, "an unreadable key has no string")

        // MARK: fanMode + loadFans — one read per key, clamped assembly

        func configureFan(mode: [UInt8], modeSize: UInt32 = 4, modeType: UInt32) {{
            smc.keys = [:]
            set("FNum", padded([0x02]), size: 1, type: SMCDataType.ui8)
            set("F0ID", fdsBytes("Left Fan    "), size: 12, type: SMCDataType.fds)
            set("F0Ac", floatBytes(1200.0), size: 4, type: SMCDataType.flt)
            set("F0Mn", floatBytes(-5.0), size: 4, type: SMCDataType.flt)
            set("F0Mx", floatBytes(6800.0), size: 4, type: SMCDataType.flt)
            set("F0md", mode, size: modeSize, type: modeType)
            set("F1Ac", floatBytes(0.0), size: 4, type: SMCDataType.flt)
            set("F1Mn", floatBytes(0.0), size: 4, type: SMCDataType.flt)
            set("F1Mx", floatBytes(0.0), size: 4, type: SMCDataType.flt)
            // The once-per-process key probe on F0md (cached in
            // `fanModeKeyIsLower`) is separate from the per-poll reads the
            // counts below are about.
            _ = smc.fanModeKey(0)
            smc.resetReads()
        }}
        func fanModeFixture(_ label: String, mode: [UInt8], modeSize: UInt32 = 4, modeType: UInt32,
                            expected: FanMode) {{
            configureFan(mode: mode, modeSize: modeSize, modeType: modeType)
            let fans = smc.loadFans()
            precondition(fans.count == 2, "\\(label): FNum 2 must build two fans")
            precondition(fans[0].mode == expected, "\\(label): mode expected \\(expected), got \\(fans[0].mode)")
            // The mode key is read exactly once per fan per poll. The old
            // fallback re-read the identical key whenever `FanMode(rawValue:)`
            // rejected the value — two extra IOConnectCallStructMethod round
            // trips under the lock the temperature sweep contends for.
            precondition(smc.reads(of: "F0md") == 1,
                         "\\(label): F0md read \\(smc.reads(of: "F0md")) times in one loadFans — must be once")
        }}

        // 0 automatic, 1 forced, 3 auto3 (reported as automatic).
        fanModeFixture("automatic", mode: floatBytes(0.0), modeType: SMCDataType.flt, expected: .automatic)
        fanModeFixture("forced", mode: floatBytes(1.0), modeType: SMCDataType.flt, expected: .forced)
        fanModeFixture("auto3", mode: floatBytes(3.0), modeType: SMCDataType.flt, expected: .automatic)
        // A nonstandard value (firmware reporting 2) used to trigger the
        // re-read; it must settle on automatic after one read.
        fanModeFixture("nonstandard 2", mode: floatBytes(2.0), modeType: SMCDataType.flt, expected: .automatic)
        // NaN keeps the documented "no reading" path: 0 → automatic, no trap.
        fanModeFixture("NaN mode", mode: floatBytes(.nan), modeType: SMCDataType.flt, expected: .automatic)

        // loadFans assembly: names, fallback, and the max(1, …) clamps.
        configureFan(mode: floatBytes(0.0), modeType: SMCDataType.flt)
        let fans = smc.loadFans()
        precondition(fans[0].name == "Left Fan", "the fds name is used as-is after trimming")
        precondition(fans[1].name == "右风扇", "a two-fan machine synthesises the right-fan name when F1ID is unreadable")
        precondition(fans[0].rpm == 1200 && fans[0].maxRPM == 6800, "readings must pass through unchanged")
        precondition(fans[0].minRPM == 1, "a min below 1 clamps up (max(1, safeRPM(-5)))")
        precondition(fans[1].minRPM == 1 && fans[1].maxRPM == 1, "a zero min/max clamps to 1, never 0")
        precondition(fans[1].rpm == 0, "a fan with no rpm reading reports 0, not nil-crash")

        // The mode key probe picked F0md, so a machine without it falls back
        // to F1md-style keys rather than giving up.
        smc.keys["F0md"] = nil
        smc.resetReads()
        let unprobed = smc.loadFans()
        precondition(unprobed[0].mode == .automatic, "an unreadable mode key reads as automatic, never forced")
        precondition(smc.reads(of: "F0md") == 1,
                     "an unreadable mode key is read once per fan, not retried; got \\(smc.reads(of: "F0md"))")

        let fresh = ProbeSMC()
        fresh.keys = smc.keys
        precondition(fresh.fanModeKey(0) == "F0Md", "a machine without F0md uses the older F(0)Md keys")
        precondition(fresh.fanModeKey(1) == "F1Md", "the flavour applies to every fan id")

        print("PASS: SMC decode (ui8 LE pair, ui16, sp78/sp87, fpe2, flt, fds names), fan-mode/fan-list assembly and the NaN/inf clamp — one mode-key read per fan")
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
# The Intel `#else` arms were never compiled (`build.sh` targets arm64 only) and
# their `fanModeKeyIsLower` was only ever assigned in the arm64 arm. Keep the
# fan path single-flavour: add an architecture split back only with a real
# target to compile and test it.
assert '#if arch(' not in fan_mode and '#if arch(' not in fan_mode_key, \
    'the fan path must stay single-flavour (arm64); an uncompiled #else silently ships on a new slice'
assert 'FS! ' not in controller, \
    'the FS!-based Intel mode dispatch (and its all-zero read exemption) is gone with the #else arm'

with tempfile.TemporaryDirectory(prefix='claudebar-smc-sampling-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
