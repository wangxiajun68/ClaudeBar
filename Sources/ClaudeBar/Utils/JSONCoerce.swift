import Foundation

/// Numeric JSON counters. Missing, invalid and out-of-range values become zero.
enum JSONCoerce {
    static func int64Val(_ value: Any?) -> Int64 {
        if let number = value as? Int64 { return number }
        if let text = value as? String { return Int64(text) ?? 0 }
        guard let number = value as? Double, number.isFinite,
              number >= Double(Int64.min), number < Double(Int64.max) else { return 0 }
        return Int64(number)
    }

    static func intVal(_ value: Any?) -> Int {
        Int(exactly: int64Val(value)) ?? 0
    }
}
