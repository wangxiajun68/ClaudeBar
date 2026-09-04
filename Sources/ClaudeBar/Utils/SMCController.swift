import Foundation
import IOKit

// Fan control adapted from Stats (exelban/stats) SMC module — in-process reads/writes.
// Protocol note (macOS 26 / Darwin 25): the classic 54-byte struct is gone. The user client
// now takes an 80-byte struct: key@0 (UInt32 LE fourcc), vers@4, pLimitData@12, keyInfo@28
// (dataSize@28, dataType@32, attr@36), result@40, status@41, data8@42, data32@44, bytes@48.

enum FanMode: Int, Codable, CaseIterable {
    case automatic = 0
    case forced = 1
    case auto3 = 3

    var isAutomatic: Bool { self == .automatic || self == .auto3 }

    var label: String {
        switch self {
        case .automatic, .auto3: return "自动"
        case .forced: return "手动"
        }
    }
}

struct FanInfo: Identifiable, Equatable {
    let id: Int
    var name: String
    var rpm: Int
    var minRPM: Int
    var maxRPM: Int
    var mode: FanMode
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
    case writeBytes = 6
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

    func toString() -> String {
        String(describing: UnicodeScalar(rawValue >> 24 & 0xff)!) +
        String(describing: UnicodeScalar(rawValue >> 16 & 0xff)!) +
        String(describing: UnicodeScalar(rawValue >> 8 & 0xff)!) +
        String(describing: UnicodeScalar(rawValue & 0xff)!)
    }
}

private extension Float {
    init?(_ bytes: [UInt8]) {
        guard bytes.count >= MemoryLayout<Float>.size else { return nil }
        self = bytes.withUnsafeBytes { $0.load(as: Float.self) }
    }

    var smcBytes: [UInt8] { withUnsafeBytes(of: self, Array.init) }
}

final class SMCController {
    static let shared = SMCController()

    private var conn: io_connect_t = 0
    private var fanModeKeyIsLower: Bool?

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
           !["FS! ", "F0Md", "F1Md", "F0md", "F1md"].contains(key) {
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
        var readings: [Double] = []
        for key in generic + appleSilicon {
            if let value = getValue(key), value > 0, value < 110 { readings.append(value) }
        }
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }

    func fanModeKey(_ id: Int) -> String {
        #if arch(arm64)
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
        #else
        return "F\(id)Md"
        #endif
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
                rpm: Int(getValue("F\(i)Ac") ?? 0),
                minRPM: max(1, Int(getValue("F\(i)Mn") ?? 1)),
                maxRPM: max(1, Int(getValue("F\(i)Mx") ?? 1)),
                mode: mode))
        }
        return list
    }

    // MARK: - Fan control

    func setFanMode(_ id: Int, mode: FanMode) {
        #if arch(arm64)
        if mode == .forced {
            guard unlockFanControl(fanId: id) else { return }
        } else {
            let modeKey = fanModeKey(id)
            let targetKey = "F\(id)Tg"
            if getValue(modeKey) != nil {
                var bytes = [UInt8](repeating: 0, count: 32)
                var dataSize: UInt32 = 0
                var dataType: UInt32 = 0
                guard read(modeKey, into: &bytes, size: &dataSize, type: &dataType) == KERN_SUCCESS else { return }
                if bytes[0] != 0 {
                    bytes[0] = 0
                    guard writeWithRetry(modeKey, dataType: dataType, dataSize: Int(dataSize), bytes: bytes) else { return }
                }
            }
            var targetBytes = [UInt8](repeating: 0, count: 32)
            var targetSize: UInt32 = 0
            var targetType: UInt32 = 0
            guard read(targetKey, into: &targetBytes, size: &targetSize, type: &targetType) == KERN_SUCCESS else { return }
            let newBytes = Float(0).smcBytes
            for i in 0..<4 { targetBytes[i] = newBytes[i] }
            guard writeWithRetry(targetKey, dataType: targetType, dataSize: Int(targetSize), bytes: targetBytes) else { return }
        }
        #else
        if getValue("F\(id)Md") != nil {
            var bytes = [UInt8](repeating: 0, count: 32)
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            guard read("F\(id)Md", into: &bytes, size: &dataSize, type: &dataType) == KERN_SUCCESS else { return }
            bytes[0] = UInt8(mode.rawValue)
            guard write("F\(id)Md", dataType: dataType, dataSize: Int(dataSize), bytes: bytes) == KERN_SUCCESS else { return }
        }
        let fansMode = Int(getValue("FS! ") ?? 0)
        var newMode: UInt8 = 0
        switch (fansMode, id, mode) {
        case (0, 0, .forced): newMode = 1
        case (0, 1, .forced): newMode = 2
        case (1, 0, .automatic): newMode = 0
        case (1, 1, .forced): newMode = 3
        case (2, 1, .automatic): newMode = 0
        case (2, 0, .forced): newMode = 3
        case (3, 0, .automatic): newMode = 2
        case (3, 1, .automatic): newMode = 1
        default: break
        }
        guard fansMode != Int(newMode) else { return }
        var value = [UInt8](repeating: 0, count: 32)
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        guard read("FS! ", into: &value, size: &dataSize, type: &dataType) == KERN_SUCCESS else { return }
        value[1] = newMode
        _ = write("FS! ", dataType: dataType, dataSize: Int(dataSize), bytes: value)
        #endif
    }

    func setFanSpeed(_ id: Int, speed: Int) {
        if let maxSpeed = getValue("F\(id)Mx"), speed > Int(maxSpeed) {
            setFanSpeed(id, speed: Int(maxSpeed))
            return
        }
        #if arch(arm64)
        var modeBytes = [UInt8](repeating: 0, count: 32)
        var modeSize: UInt32 = 0
        var modeType: UInt32 = 0
        guard read(fanModeKey(id), into: &modeBytes, size: &modeSize, type: &modeType) == KERN_SUCCESS else { return }
        if modeBytes[0] != 1 {
            guard unlockFanControl(fanId: id) else { return }
        }
        #endif
        var bytes = [UInt8](repeating: 0, count: 32)
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        guard read("F\(id)Tg", into: &bytes, size: &dataSize, type: &dataType) == KERN_SUCCESS else { return }
        if dataType == SMCDataType.flt {
            let newBytes = Float(speed).smcBytes
            for i in 0..<4 { bytes[i] = newBytes[i] }
        } else if dataType == SMCDataType.fpe2 {
            bytes[0] = UInt8(speed >> 6)
            bytes[1] = UInt8((speed << 2) ^ ((speed >> 6) << 8))
        }
        #if arch(arm64)
        _ = writeWithRetry("F\(id)Tg", dataType: dataType, dataSize: Int(dataSize), bytes: bytes)
        #else
        _ = write("F\(id)Tg", dataType: dataType, dataSize: Int(dataSize), bytes: bytes)
        #endif
    }

    #if arch(arm64)
    @discardableResult
    func resetFanControl() -> Bool {
        var bytes = [UInt8](repeating: 0, count: 32)
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        let result = read("Ftst", into: &bytes, size: &dataSize, type: &dataType)
        if result == KERN_SUCCESS, dataSize > 0 {
            if bytes[0] == 0 { return true }
            bytes[0] = 0
            return writeWithRetry("Ftst", dataType: dataType, dataSize: Int(dataSize), bytes: bytes)
        }
        guard let count = getValue("FNum") else { return false }
        var success = true
        for i in 0..<Int(count) {
            let modeKey = fanModeKey(i)
            var modeBytes = [UInt8](repeating: 0, count: 32)
            var modeSize: UInt32 = 0
            var modeType: UInt32 = 0
            guard read(modeKey, into: &modeBytes, size: &modeSize, type: &modeType) == KERN_SUCCESS else { continue }
            if modeBytes[0] == 0 { continue }
            modeBytes[0] = 0
            if !writeWithRetry(modeKey, dataType: modeType, dataSize: Int(modeSize), bytes: modeBytes) { success = false }
        }
        return success
    }
    #endif

    // MARK: - Private

    private func fanMode(for id: Int) -> FanMode {
        if let md = getValue(fanModeKey(id)), let parsed = FanMode(rawValue: Int(md)) {
            return parsed.isAutomatic ? .automatic : parsed
        }
        #if arch(arm64)
        let modeValue = Int(getValue(fanModeKey(id)) ?? 0)
        return modeValue == 1 ? .forced : .automatic
        #else
        let fansMode = Int(getValue("FS! ") ?? 0)
        switch (fansMode, id) {
        case (0, _): return .automatic
        case (3, _): return .forced
        case (1, 0), (2, 1): return .forced
        default: return .automatic
        }
        #endif
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
        let byteTuple = output2.bytes
        let mirrored = Mirror(reflecting: byteTuple).children.compactMap { $0.value as? UInt8 }
        for i in 0..<min(Int(size), outBytes.count) { outBytes[i] = mirrored[i] }
        return KERN_SUCCESS
    }

    static let notPrivileged = kern_return_t(bitPattern: UInt32(0xe00002c1)) // kIOReturnNotPrivileged

    private func write(_ key: String, dataType: UInt32, dataSize: Int, bytes: [UInt8]) -> kern_return_t {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = FourCharCode(key).rawValue
        input.keyInfo.dataSize = UInt32(dataSize)
        input.keyInfo.dataType = dataType
        input.data8 = SMCKeys.writeBytes.rawValue
        var tupleBytes = input.bytes
        withUnsafeMutableBytes(of: &tupleBytes) { buffer in
            for i in 0..<min(dataSize, 32) { buffer[i] = bytes[i] }
        }
        input.bytes = tupleBytes
        let result = call(input: &input, output: &output)
        if result != KERN_SUCCESS { return result }
        return output.result == 0 ? KERN_SUCCESS : KERN_FAILURE
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        precondition(inputSize == 80, "SMCKeyData layout must be 80 bytes")
        return IOConnectCallStructMethod(conn, UInt32(SMCKeys.kernelIndex.rawValue), &input, inputSize, &output, &outputSize)
    }

    private func decode(_ bytes: [UInt8], dataSize: Int, dataType: UInt32) -> Double? {
        switch dataType {
        case SMCDataType.ui8:
            if dataSize == 1 { return Double(bytes[0]) }
            return Double(bytes[0] | (bytes[1] << 8)) // " 8iu"-style LE 16-bit
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

    #if arch(arm64)
    private func writeWithRetry(_ key: String, dataType: UInt32, dataSize: Int, bytes: [UInt8], maxAttempts: Int = 10, delayMicros: UInt32 = 50_000) -> Bool {
        var lastResult: kern_return_t = KERN_SUCCESS
        for attempt in 0..<maxAttempts {
            lastResult = write(key, dataType: dataType, dataSize: dataSize, bytes: bytes)
            if lastResult == KERN_SUCCESS { return true }
            if lastResult == Self.notPrivileged { return false } // 无 root，重试无意义
            if attempt < maxAttempts - 1 { usleep(delayMicros) }
        }
        return false
    }

    private func unlockFanControl(fanId: Int) -> Bool {
        let modeKey = fanModeKey(fanId)
        var modeBytes = [UInt8](repeating: 0, count: 32)
        var modeSize: UInt32 = 0
        var modeType: UInt32 = 0
        guard read(modeKey, into: &modeBytes, size: &modeSize, type: &modeType) == KERN_SUCCESS else { return false }
        modeBytes[0] = 1
        let first = write(modeKey, dataType: modeType, dataSize: Int(modeSize), bytes: modeBytes)
        if first == KERN_SUCCESS { return true }
        if first == Self.notPrivileged { return false } // 无 root，直接放弃，不进入 unlock 长流程

        var ftstBytes = [UInt8](repeating: 0, count: 32)
        var ftstSize: UInt32 = 0
        var ftstType: UInt32 = 0
        guard read("Ftst", into: &ftstBytes, size: &ftstSize, type: &ftstType) == KERN_SUCCESS, ftstSize > 0 else { return false }
        if ftstBytes[0] == 1 { return retryModeWrite(fanId: fanId, maxAttempts: 20) }
        ftstBytes[0] = 1
        guard writeWithRetry("Ftst", dataType: ftstType, dataSize: Int(ftstSize), bytes: ftstBytes, maxAttempts: 100) else { return false }
        usleep(3_000_000)
        return retryModeWrite(fanId: fanId, maxAttempts: 300)
    }

    private func retryModeWrite(fanId: Int, maxAttempts: Int) -> Bool {
        let modeKey = fanModeKey(fanId)
        var modeBytes = [UInt8](repeating: 0, count: 32)
        var modeSize: UInt32 = 0
        var modeType: UInt32 = 0
        guard read(modeKey, into: &modeBytes, size: &modeSize, type: &modeType) == KERN_SUCCESS else { return false }
        modeBytes[0] = 1
        return writeWithRetry(modeKey, dataType: modeType, dataSize: Int(modeSize), bytes: modeBytes, maxAttempts: maxAttempts, delayMicros: 100_000)
    }
    #endif
}
