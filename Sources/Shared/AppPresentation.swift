import Foundation

/// Presentation policy is independent of compile-time system integration gates.
/// Permission callbacks can arrive off-main, so the read is synchronized.
enum AppPresentation {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var performance = false
    static var performanceMode: Bool {
        get { lock.lock(); defer { lock.unlock() }; return performance }
        set { lock.lock(); performance = newValue; lock.unlock() }
    }
    static var allowsInterface: Bool { !performanceMode }
}
