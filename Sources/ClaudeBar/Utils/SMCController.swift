import Foundation
import IOKit

// Fan monitoring adapted from Stats (exelban/stats) SMC module — in-process reads.
// Every *write* goes through the setuid `claudebar-fanctl` helper instead
// (`FanHelperInstaller`), so this file stays read-only and needs no privilege;
// the kernel returns `kIOReturnNotPermitted` to anything but root anyway.
// Protocol note (macOS 26 / Darwin 25): the classic 54-byte struct is gone. The user client
// now takes an 80-byte struct: key@0 (UInt32 LE fourcc), vers@4, pLimitData@12, keyInfo@28
// (dataSize@28, dataType@32, attr@36), result@40, status@41, data8@42, data32@44, bytes@48.

enum FanMode: Int {
    case automatic = 0
    case forced = 1
    case auto3 = 3

    var isAutomatic: Bool { self == .automatic || self == .auto3 }
}

struct FanInfo: Identifiable, Equatable {
    let id: Int
    var name: String
    var rpm: Int
    var minRPM: Int
    var maxRPM: Int
    var mode: FanMode
}

/// Which side of the machine a fan sits on. `loadFans` reads it off the SMC
/// `F{i}ID` name, and synthesises 左风扇 / 右风扇 when that key is unreadable
/// on a two-fan machine — so those are the names this has to parse.
enum FanSide {
    case left, right
}

extension FanInfo {
    /// The one place the left/right wording is parsed: the compact tile's
    /// caption and the detail panel's heading used to test the same two
    /// substrings and then disagree only in their suffix.
    var side: FanSide? {
        if name.localizedCaseInsensitiveContains("left") || name.contains("左") { return .left }
        if name.localizedCaseInsensitiveContains("right") || name.contains("右") { return .right }
        return nil
    }
}

private enum SMCDataType {
    static let ui8  = FourCharCode("ui8 ").rawValue   // 0x75693820
    static let ui16 = FourCharCode("ui16").rawValue
    static let ui32 = FourCharCode("ui32").rawValue
    static let sp78 = FourCharCode("sp78").rawValue   // 0x73703738
    static let sp87 = FourCharCode("sp87").rawValue
    static let fpe2 = FourCharCode("fpe2").rawValue   // 0x66706532
    static let flt  = FourCharCode("flt ").rawValue   // 0x666C7420
    static let fds  = FourCharCode("{fds").rawValue
}

private enum SMCKeys: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case readKeyInfo = 9
}

// 80-byte struct, exact kernel layout. All fields naturally aligned so MemoryLayout.stride == 80.
private struct SMCKeyData {
    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
    var pLimitData = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
    var keyInfo = KeyInfo()
    var padding = (UInt8(0), UInt8(0), UInt8(0))
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var padding2: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = (
        UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
        UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
        UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
        UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0)
    )
}

private struct FourCharCode: ExpressibleByStringLiteral {
    var rawValue: UInt32

    init(_ string: String) {
        precondition(string.count == 4)
        rawValue = string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    init(rawValue: UInt32) { self.rawValue = rawValue }
    init(stringLiteral value: StringLiteralType) { self.init(value) }

}

private extension Float {
    init?(_ bytes: [UInt8]) {
        guard bytes.count >= MemoryLayout<Float>.size else { return nil }
        self = bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }
}

final class SMCController {
    static let shared = SMCController()

    private var conn: io_connect_t = 0
    private var fanModeKeyIsLower: Bool?
    /// Read by `cpuTemperatureCelsius`, which the sampler calls from
    /// `ProcessSampler`'s queue — the fan queue only reads `isConnected` and
    /// `loadFans`.
    private var temperatureKeys: [String]?
    private let cacheLock = NSLock()
    /// Serializes user-client calls: the sampler (temperatures) and the fan
    /// monitor share this connection from different queues.
    private let ioLock = NSLock()

    var isConnected: Bool { conn != 0 }

    private init() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        let device = IOIteratorNext(iterator)
        guard device != 0 else { return }
        var connection: io_connect_t = 0
        let kr = IOServiceOpen(device, mach_task_self_, 0, &connection)
        IOObjectRelease(device)
        if kr == KERN_SUCCESS { conn = connection }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    // MARK: - Public reads

    func getValue(_ key: String) -> Double? {
        var bytes = [UInt8](repeating: 0, count: 32)
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        guard read(key, into: &bytes, size: &dataSize, type: &dataType) == KERN_SUCCESS, dataSize > 0 else { return nil }
        if bytes.prefix(Int(dataSize)).allSatisfy({ $0 == 0 }),
           !["F0Md", "F1Md", "F0md", "F1md"].contains(key) {
            return nil
        }
        return decode(bytes, dataSize: Int(dataSize), dataType: dataType)
    }

    func getStringValue(_ key: String) -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        guard read(key, into: &bytes, size: &dataSize, type: &dataType) == KERN_SUCCESS, dataSize > 0 else { return nil }
        guard dataType == SMCDataType.fds else { return nil }
        let chars = (4...15).compactMap { idx -> String? in
            guard idx < bytes.count else { return nil }
            return String(UnicodeScalar(bytes[idx]))
        }
        return chars.joined().trimmingCharacters(in: .whitespaces)
    }

    func cpuTemperatureCelsius() -> Double? {
        let appleSilicon = [
            "Te05", "Te0L", "Te0P", "Te0S", "Te09", "Te0H",
            "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
            "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
            "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
        ]
        let generic = ["TC0D", "TC0E", "TC0F", "TC0P", "TC0H"]

        // Only a handful of the candidate keys exist on any one machine.
        // Sweep all of them once, then read just the ones that answered —
        // re-sweeping only if they all stop answering.
        cacheLock.lock()
        let cached = temperatureKeys
        cacheLock.unlock()
        if let cached, let average = averageTemperature(cached).average {
            return average
        }
        let sweep = averageTemperature(generic + appleSilicon)
        cacheLock.lock()
        temperatureKeys = sweep.answered.isEmpty ? nil : sweep.answered
        cacheLock.unlock()
        return sweep.average
    }

    private func averageTemperature(_ keys: [String]) -> (average: Double?, answered: [String]) {
        var readings: [Double] = []
        var answered: [String] = []
        for key in keys {
            if let value = getValue(key), value > 0, value < 110 {
                readings.append(value)
                answered.append(key)
            }
        }
        guard !readings.isEmpty else { return (nil, []) }
        return (readings.reduce(0, +) / Double(readings.count), answered)
    }

    /// The mode key the machine actually answers on: `F{i}md` on current
    /// Apple Silicon, `F{i}Md` on older SMC layouts. Probed once against F0.
    ///
    /// Single-flavour on purpose: the `#if arch(arm64)` arms that used to wrap
    /// this and `fanMode` had never been compiled (the build targets arm64
    /// only, and the x86 arm was unreachable anyway — `fanModeKeyIsLower` is
    /// only ever assigned here). `F{i}Md` naming and the `FS!` cross-frame
    /// reads live in the `claudebar-fanctl` helper (`fanctl.c:unlock_fan`).
    func fanModeKey(_ id: Int) -> String {
        if fanModeKeyIsLower == nil {
            var bytes = [UInt8](repeating: 0, count: 32)
            var dataSize: UInt32 = 0
            var probe: kern_return_t = KERN_FAILURE
            if read("F0md", into: &bytes, size: &dataSize, type: nil) == KERN_SUCCESS, dataSize > 0 {
                probe = KERN_SUCCESS
            }
            fanModeKeyIsLower = (probe == KERN_SUCCESS)
        }
        return fanModeKeyIsLower! ? "F\(id)md" : "F\(id)Md"
    }

    func loadFans() -> [FanInfo] {
        guard let count = getValue("FNum"), count > 0 else { return [] }
        var list: [FanInfo] = []
        for i in 0..<Int(count) {
            var name = getStringValue("F\(i)ID")
            if name == nil, Int(count) == 2 {
                name = i == 0 ? "左风扇" : "右风扇"
            }
            let mode = fanMode(for: i)
            list.append(FanInfo(
                id: i,
                name: name ?? "风扇 #\(i)",
                rpm: Self.safeRPM(getValue("F\(i)Ac") ?? 0),
                minRPM: max(1, Self.safeRPM(getValue("F\(i)Mn") ?? 1)),
                maxRPM: max(1, Self.safeRPM(getValue("F\(i)Mx") ?? 1)),
                mode: mode))
        }
        return list
    }

    /// A fan figure from an SMC float, clamped before it becomes an `Int`.
    ///
    /// `Int(_: Double)` **traps** on NaN or anything outside `Int64` — and
    /// this data is whatever bytes the SMC kext returned: a `flt ` key that
    /// was never initialised can hold an Infinity or NaN bit pattern (no
    /// machine has been observed sending one, but the read path accepts any
    /// bit pattern by construction). The trap would be on `readQueue`, once
    /// per 2 s fan poll, taking the whole app with it. These are display
    /// figures for a rotor gauge, so the honest bound is "something no fan
    /// reaches": clamp into ±2^20 RPM instead of trapping.
    static func safeRPM(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(1_048_576, max(-1_048_576, value)))
    }

    // MARK: - Private

    private func fanMode(for id: Int) -> FanMode {
        // One read, reused: the old shape read the very same key a second time
        // whenever the first read succeeded but decoded to a mode outside
        // `FanMode` (e.g. an SMC reporting 2), paying another keyInfo+readBytes
        // pair — two more IOConnectCallStructMethod round trips under `ioLock`,
        // the lock ProcessSampler's temperature sweep contends for.
        let raw = getValue(fanModeKey(id))
        if let raw, let parsed = FanMode(rawValue: Self.safeRPM(raw)) {
            return parsed.isAutomatic ? .automatic : parsed
        }
        return Self.safeRPM(raw ?? 0) == 1 ? .forced : .automatic
    }

    /// Reads a key: first fetches keyInfo (data8=9), then the bytes (data8=5),
    /// echoing the keyInfo blob (dataSize+dataType+attr) back into the second call —
    /// required on macOS 26 or many keys return 0x84.
    private func read(_ key: String, into outBytes: inout [UInt8], size: inout UInt32, type: UnsafeMutablePointer<UInt32>?) -> kern_return_t {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = FourCharCode(key).rawValue
        input.data8 = SMCKeys.readKeyInfo.rawValue
        guard call(input: &input, output: &output) == KERN_SUCCESS else { return KERN_FAILURE }
        guard output.result == 0 else {
            if getenv("CLAUDEBAR_SMC_DEBUG") != nil {
                fputs("SMC keyInfo \(key) result=\(output.result)\n", stderr)
            }
            return KERN_FAILURE
        }
        size = output.keyInfo.dataSize
        type?.pointee = output.keyInfo.dataType
        guard size > 0 else { return KERN_FAILURE }
        var input2 = SMCKeyData()
        var output2 = SMCKeyData()
        input2.key = input.key
        // 关键：keyInfo 三元组原样回传（C 探针验证过，只回传 dataSize 会 0x84）
        input2.keyInfo = output.keyInfo
        input2.data8 = SMCKeys.readBytes.rawValue
        guard call(input: &input2, output: &output2) == KERN_SUCCESS else { return KERN_FAILURE }
        guard output2.result == 0 else {
            if getenv("CLAUDEBAR_SMC_DEBUG") != nil {
                fputs("SMC read \(key) result=\(output2.result) size=\(size)\n", stderr)
            }
            return KERN_FAILURE
        }
        let count = min(Int(size), outBytes.count, 32)
        withUnsafeBytes(of: output2.bytes) { raw in
            for i in 0..<count { outBytes[i] = raw[i] }
        }
        return KERN_SUCCESS
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        precondition(inputSize == 80, "SMCKeyData layout must be 80 bytes")
        ioLock.lock()
        defer { ioLock.unlock() }
        return IOConnectCallStructMethod(conn, UInt32(SMCKeys.kernelIndex.rawValue), &input, inputSize, &output, &outputSize)
    }

    private func decode(_ bytes: [UInt8], dataSize: Int, dataType: UInt32) -> Double? {
        switch dataType {
        case SMCDataType.ui8:
            if dataSize == 1 { return Double(bytes[0]) }
            // " 8iu"-style LE 16-bit. Both sides must be widened *before* the
            // shift: `bytes[1] << 8` on `UInt8` is `0` for every value, which
            // is what used to drop the high byte here while fanctl.c's C
            // (integer-promoted) version of the same line returned the full
            // number.
            return Double(UInt16(bytes[0]) | (UInt16(bytes[1]) << 8))
        case SMCDataType.ui16:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case SMCDataType.ui32:
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case SMCDataType.sp78:
            return Double(Int(bytes[0]) * 256 + Int(bytes[1])) / 256
        case SMCDataType.sp87:
            return Double(Int(bytes[0]) * 256 + Int(bytes[1])) / 128
        case SMCDataType.fpe2:
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        case SMCDataType.flt:
            return Double(Float(bytes) ?? 0)
        default:
            return nil
        }
    }
}
