import Foundation

/// Shared JSON coercion helpers. `Any` values read from `JSONSerialization`
/// can arrive as `Int`, `NSNumber`, or numeric `String` depending on the
/// source document, so every consumer needs the same fallback chain.
enum JSONCoerce {
    /// Coerce a JSON number (Int / NSNumber / numeric String) to Int.
    static func intVal(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let n = Int(s) { return n }
        return 0
    }
}
