import Foundation

/// Shared JSON coercion helpers. `Any` values read from `JSONSerialization`
/// can arrive as `Int`, `NSNumber`, or numeric `String` depending on the
/// source document, so every consumer needs the same fallback chain.
///
/// Missing/uncoercible values intentionally coerce to 0: token counters and
/// line indices are additive, and treating absence as zero preserves the
/// running sums; an optional-based API would just push the defaulting onto
/// every caller.
enum JSONCoerce {
    /// Coerce a JSON number (Int / NSNumber / numeric String) to Int.
    static func intVal(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let n = Int(s) { return n }
        return 0
    }
}
