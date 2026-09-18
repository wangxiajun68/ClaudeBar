import Foundation
import Combine

/// Live mixed-port rates, isolated from `VpnManager`.
///
/// Mihomo's `/traffic` stream resumes on a URLSession thread and used to
/// hop to the main actor on **every line**, publishing `speedDown` /
/// `speedHistory` on `VpnManager`. `VPNView`, the subscription cards, and
/// the node mosaic all observed that object, so a 1 Hz (or faster) stream
/// rebuilt the whole scroll view — the dominant source of dropped frames
/// while scrolling or switching nodes.
///
/// Views that display rates observe this object. Views that display nodes
/// observe `VpnManager` and are no longer invalidated by traffic ticks.
@MainActor
final class VpnLiveRates: ObservableObject {
    static let shared = VpnLiveRates()

    @Published private(set) var speedDown: Int64 = 0
    @Published private(set) var speedUp: Int64 = 0
    @Published private(set) var speedHistory: [(down: Int64, up: Int64)] = []
    @Published private(set) var traffic = VpnTrafficSnapshot()

    /// 4 Hz ceiling. Faster publishes do not change what the UI can show
    /// and they force SwiftUI to diff the rate strip during scroll.
    private static let minInterval: TimeInterval = 0.25
    private var lastFlush = Date.distantPast
    private var pendingUp: Int64 = 0
    private var pendingDown: Int64 = 0
    private var hasPending = false
    private var flushTask: Task<Void, Never>?

    private init() {}

    func reset() {
        flushTask?.cancel()
        flushTask = nil
        hasPending = false
        lastFlush = .distantPast
        speedDown = 0
        speedUp = 0
        speedHistory = []
        traffic = VpnTrafficSnapshot()
    }

    func applyStream(up: Int64, down: Int64) {
        pendingUp = up
        pendingDown = down
        hasPending = true
        // Do not mutate `traffic` here — `@Published` would fire on every
        // /traffic line and rebuild every rates observer.
        scheduleFlush()
    }

    func applyTotals(totalUp: Int64, totalDown: Int64, connections: Int) {
        var next = traffic
        next.totalUp = totalUp
        next.totalDown = totalDown
        next.activeConnections = connections
        guard next != traffic else { return }
        traffic = next
    }

    private func scheduleFlush() {
        let wait = Self.minInterval - Date().timeIntervalSince(lastFlush)
        if wait <= 0 {
            flush()
            return
        }
        guard flushTask == nil else { return }
        let ns = UInt64(wait * 1_000_000_000)
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    private func flush() {
        flushTask = nil
        guard hasPending else { return }
        hasPending = false
        lastFlush = Date()
        if pendingDown == speedDown && pendingUp == speedUp { return }
        speedDown = pendingDown
        speedUp = pendingUp
        traffic.up = pendingUp
        traffic.down = pendingDown
        speedHistory.append((down: pendingDown, up: pendingUp))
        if speedHistory.count > 60 {
            speedHistory.removeFirst(speedHistory.count - 60)
        }
    }
}
