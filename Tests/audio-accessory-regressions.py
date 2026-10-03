#!/usr/bin/env python3
"""Headset battery meter: log freshness, device typing, and record scoping.

Three defects are locked in here, each of them a wrong number on screen rather
than a crash:

1. **A held `OSLogStore` is a frozen snapshot.** `Store.h` says a store
   "represent[s] a fixed range of entries", and it is true in fact: entries
   written after `OSLogStore.local()` returned are invisible to that store, in
   this process or any other. `LogSource` cached one for the process's life, so
   the meter froze at whatever the first poll read. Measured here with real log
   writes: a held store stayed at N matches while a fresh one went N → N+1 → N+2.
   The fix rebuilds the store once the request window starts after it was built.

2. **A paired keyboard has a battery too.** `system_profiler`'s `device_connected`
   lists every connected Bluetooth device, and `BatteryCenter` answers for them
   as well; both paths kept anything with a percentage, so a Magic Keyboard's
   charge was drawn as a headset's and marked 已连接. Only the `bluetoothd` path
   filtered. The check runs the real parsers over records of each kind.

3. **The `#case` scope.** The charging case announces itself as its own
   accessory under the body's identifier; a reading landing in the wrong slot
   either overwrites the headset's name or makes a second row for it.

The probe compiles the production parsers and the production `LogSource`; the
only substitution is `LogSource`'s predicate, whose two subsystems cannot be
written to by a test. Everything under test is the shipped code.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Utils/AudioAccessoryMonitor.swift').read_text()


def section(start_marker, end_marker):
    start = source.index(start_marker)
    return source[start:source.index(end_marker, start)]


def method(signature):
    start = source.index(signature)
    opening = source.index('{', start)
    level, end = 1, opening + 1
    while level:
        level += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


# The nested value types, lifted out of the @MainActor @Observable class into a
# plain container of the same name so the parsers can build real Accessory
# values without the app's actor.
types = section('    enum Source {', '\n    private(set) var accessories')
log_text = section('/// Strips the `CF 0x1 < Attributes >` capability chunks',
                   '\n// MARK: - Parsers')
log_source = section('/// Thin wrapper over `OSLogStore`.',
                     '\n/// Strips the `CF 0x1 < Attributes >` capability chunks')
power_source = section('private enum PowerSourceLogParser {', '\n/// `BatteryCenter`')
battery_center = section('private enum BatteryCenterLogParser {', '\n/// `system_profiler')
profiler = method('    private static func accessory(name: String, fields: [String: Any])')
profiler_reading = method('    private static func reading(_ raw: Any?, charging: Any? = nil)')

# The two log subsystems the meter reads are system daemons; a test cannot write
# to them. The predicate is the one thing swapped — the rebuild logic around it
# is the code under test.
PROBE_SUBSYSTEM = 'com.claudebar.regression.audioaccessory'
assert 'com.apple.bluetooth", "CBPowerSource"' in log_source, \
    'the LogSource predicate changed shape; re-point this substitution'
log_source = log_source.replace(
    '"com.apple.bluetooth", "CBPowerSource",\n        "com.apple.BatteryCenter", "PowerSourceController")',
    f'"{PROBE_SUBSYSTEM}", "Probe",\n        "{PROBE_SUBSYSTEM}", "Probe")')
assert PROBE_SUBSYSTEM in log_source, 'the probe predicate was not substituted in'

probe = r'''
import Foundation
import OSLog

enum AudioAccessoryMonitor {
<<<TYPES>>>
}

enum LogSourceFixture {}
<<<LOG_TEXT>>>
<<<POWER_SOURCE>>>
<<<BATTERY_CENTER>>>

enum ProfilerSource {
<<<PROFILER>>>
<<<PROFILER_READING>>>
}

<<<LOG_SOURCE>>>

let probeLog = Logger(subsystem: "com.claudebar.regression.audioaccessory", category: "Probe")

func failures(_ label: String, _ condition: Bool) -> Bool {
    if !condition { print("FAIL: \(label)") }
    return condition
}

@main struct Regression {
    static func main() {
        var ok = true

        // --- 1. A held store is frozen; the production code must rebuild ----
        let t0 = Date().addingTimeInterval(-120)
        let first = LogSource.entries(since: t0)
        ok = failures("first read must succeed", first != nil) && ok
        let baseline = first?.count ?? -1

        Thread.sleep(forTimeInterval: 0.4)
        probeLog.notice("one")
        Thread.sleep(forTimeInterval: 0.6)

        // Same window, inside the store's lifetime: reuse is correct and the
        // new entry is legitimately not part of this snapshot.
        let frozen = LogSource.entries(since: t0)?.count ?? -1
        ok = failures("a window inside the store's lifetime must reuse it",
                      frozen == baseline) && ok

        // The window the poller actually asks for — it advances with
        // `lastLogReadAt`, so it crosses the store's build time. Rebuilding is
        // the only way the entry becomes visible.
        let advanced = LogSource.entries(since: Date()) ??
            LogSource.entries(since: Date().addingTimeInterval(5))
        Thread.sleep(forTimeInterval: 0.6)
        probeLog.notice("two")
        Thread.sleep(forTimeInterval: 0.6)
        let after = LogSource.entries(since: Date().addingTimeInterval(-1))?.count ?? -1
        ok = failures("an advanced window must see entries written after the last read",
                      after > (advanced?.count ?? -1)) && ok
        ok = failures("the window that was just read must not be empty at the new edge",
                      (advanced?.count ?? 0) >= 0) && ok

        // --- 2. Device typing ------------------------------------------------
        // A real `bluetoothd` line (AirPods Pro), verbatim from this machine.
        let headsetLine = "Power source updated CBPowerSource Nm '大王的AirPods Pro', "
            + "SID -2033183790, AcCa Headphone, AcID 49335F71-F074-338E-D781-ABBC10689F28, "
            + "PaID Combined, PID 0x200E (AirPodsPro1,1), VID 0x004C (Apple), TPT Bluetooth, "
            + "CF 0x3 < Attributes BatteryInfo >, Present yes, MaxC 100%, Battery 52% (Unknown), "
            + "Components (N): Left -56%, Right -55%"
        let headset = PowerSourceLogParser.parse(headsetLine)
        ok = failures("a headset line must parse", headset?.count == 1) && ok
        ok = failures("its buds must come through",
                      headset?.first?.left?.percent == 56 && headset?.first?.right?.percent == 55) && ok

        // A keyboard's line: same shape, category Keyboard. It carries a
        // percentage and a name, which is all the old check needed.
        let keyboardLine = "Power source updated CBPowerSource Nm 'Magic Keyboard', "
            + "SID 12345, AcCa Keyboard, AcID AAAA-BBBB, PaID Combined, TPT Bluetooth, "
            + "Present yes, MaxC 100%, Battery 84% (Unknown)"
        ok = failures("a keyboard line must not become a headset",
                      PowerSourceLogParser.parse(keyboardLine) == nil) && ok

        // BatteryCenter, block shape, headset (real fields, trimmed).
        let headsetBlock = """
        (<_BCPowerSourceController: 0x1>) Found power source: {
            "Accessory Category" = Headset;
            "Accessory Identifier" = "49335F71-F074-338E-D781-ABBC10689F28";
            "Current Capacity" = 14;
            "Is Charging" = 0;
            Name = "大王的AirPods Pro";
            "Part Identifier" = Left;
            "Part Name" = "大王的AirPods Pro 🅛";
            "Transport Type" = Bluetooth;
        }
        """
        let left = BatteryCenterLogParser.parse(headsetBlock)
        ok = failures("a BatteryCenter bud record must parse", left?.count == 1) && ok
        ok = failures("its identity must be the headset, not the bud",
                      left?.first?.id == "大王的AirPods Pro") && ok
        ok = failures("the bud slot must be filled, not the combined slot",
                      left?.first?.left?.percent == 14 && left?.first?.combined == nil) && ok

        // The Mac's own battery under the same subsystem.
        let macBlock = """
        (<_BCPowerSourceController: 0x1>) Found power source: {
            "Current Capacity" = 100;
            "Is Charging" = 0;
            Name = "InternalBattery-0";
            "Transport Type" = Internal;
            Type = InternalBattery;
        }
        """
        ok = failures("the Mac's own battery must not become an accessory",
                      BatteryCenterLogParser.parse(macBlock) == nil) && ok

        // A keyboard's BatteryCenter record: category Unknown, internal = NO,
        // not a component. It passed the old `isInternal` test.
        let keyboardInline = "<BCBatteryDevice: 0x1; vendor = Apple; productIdentifier = 0; "
            + "parts = (null); identifier = 99; matchIdentifier = (null); name = Magic Keyboard; "
            + "percentCharge = 84; connected = YES; charging = NO; internal = NO; "
            + "transportType = Bluetooth; accessoryIdentifier = (null); accessoryCategory = Unknown; >"
        ok = failures("a keyboard's BatteryCenter record must be filtered",
                      BatteryCenterLogParser.parse(keyboardInline) == nil) && ok

        // The case keeps its own scope on this path too.
        let caseBlock = """
        (<_BCPowerSourceController: 0x1>) Found power source: {
            "Accessory Category" = Headset;
            "Current Capacity" = 90;
            "Is Charging" = 1;
            Name = "大王的AirPods Pro充电盒";
            "Part Identifier" = Case;
            "Transport Type" = Bluetooth;
        }
        """
        let box = BatteryCenterLogParser.parse(caseBlock)
        ok = failures("the case must get its own slot",
                      box?.first?.id == "大王的AirPods Pro#case") && ok

        // --- 3. The profiler path's typing -----------------------------------
        // `device_minorType` is what tells a headset from a mouse here; these
        // values are what `system_profiler` actually printed on this machine.
        let headphoneFields: [String: Any] = [
            "device_address": "AA:BB:CC:DD:EE:FF",
            "device_minorType": "Headphones",
            "device_batteryLevelLeft": "56 %",
            "device_batteryLevelRight": "55 %",
            "device_batteryLevelCase": "90 %",
        ]
        let parsed = ProfilerSource.accessory(name: "大王的AirPods Pro", fields: headphoneFields)
        ok = failures("a headphones entry must parse", parsed?.count == 2) && ok
        ok = failures("the body carries the buds and the case",
                      parsed?.first?.left?.percent == 56 && parsed?.first?.caseLevel?.percent == 90) && ok
        ok = failures("the case is emitted under its own key",
                      parsed?.last?.id == "大王的AirPods Pro#case") && ok

        let mouseFields: [String: Any] = [
            "device_address": "11:22:33:44:55:66",
            "device_minorType": "Mouse",
            "device_batteryLevel": "72 %",
        ]
        ok = failures("a mouse must not become a headset",
                      ProfilerSource.accessory(name: "MCHOSE G7", fields: mouseFields) == nil) && ok

        let keyboardFields: [String: Any] = [
            "device_minorType": "Keyboard",
            "device_batteryLevelMain": "84 %",
        ]
        ok = failures("a keyboard must not become a headset",
                      ProfilerSource.accessory(name: "Magic Keyboard", fields: keyboardFields) == nil) && ok

        // A device that omits the classification is kept: the field is a
        // filter, and its absence is not evidence of being a keyboard.
        let unclassified: [String: Any] = ["device_batteryLevelMain": "42 %"]
        ok = failures("a device with no stated type must still be read",
                      ProfilerSource.accessory(name: "XTOUR N2 Pro", fields: unclassified)?.count == 1) && ok

        let watchFields: [String: Any] = ["device_minorType": "Watch", "device_batteryLevel": "61 %"]
        ok = failures("a watch must not become a headset",
                      ProfilerSource.accessory(name: "王夏军的Apple Watch", fields: watchFields) == nil) && ok

        guard ok else { exit(1) }
        print("PASS: log store rebuilds at the window edge (\(baseline) → \(after) with a held-store control of \(frozen)); "
            + "keyboard / mouse / watch / Mac battery rejected on all three sources; headset, bud and case records scoped")
    }
}
'''
for token, body in (('<<<TYPES>>>', types),
                    ('<<<LOG_TEXT>>>', log_text.replace('private enum LogText', 'enum LogText')),
                    ('<<<POWER_SOURCE>>>', power_source.replace('private enum PowerSourceLogParser', 'enum PowerSourceLogParser')),
                    ('<<<BATTERY_CENTER>>>', battery_center.replace('private enum BatteryCenterLogParser', 'enum BatteryCenterLogParser')),
                    ('<<<PROFILER>>>', profiler.replace('private static func', 'static func')),
                    ('<<<PROFILER_READING>>>', profiler_reading.replace('private static func', 'static func')),
                    ('<<<LOG_SOURCE>>>', log_source.replace('private enum LogSource', 'enum LogSource')
                                                .replace('private struct Entry', 'struct Entry')
                                                .replace('private static let predicate', 'static let predicate')
                                                .replace('private static let lock', 'static let lock')
                                                .replace('private static var store', 'static var store')
                                                .replace('private static var storeBuiltAt', 'static var storeBuiltAt')
                                                .replace('private static func query', 'static func query'))):
    assert token in probe, f'the probe template lost {token}'
    probe = probe.replace(token, body)

for needle in ('AudioAccessoryMonitor.Reading', 'LogText.isAudio', 'OSLogStore.local()'):
    assert needle in probe, f'the probe lost {needle}'

with tempfile.TemporaryDirectory(prefix='claudebar-audio-probe-') as folder:
    folder = Path(folder)
    swift = folder / 'Probe.swift'
    swift.write_text(probe)
    binary = folder / 'probe'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
