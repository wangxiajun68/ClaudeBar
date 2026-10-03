import Foundation
import Darwin

/// Machine-wide network throughput, for the menu bar's ↓/↑ strip.
///
/// The VPN's own `/traffic` stream is the right source while a tunnel is up —
/// it is what mihomo is actually carrying — but it is the *proxy's* reading,
/// and it only exists while the proxy does. The strip is on screen all day, so
/// the reading that is always true is the machine's own: the byte counters
/// every interface keeps in the kernel.
///
/// `getifaddrs` with `AF_LINK` gives each interface's `if_data` — the same
/// counters `netstat -ib` prints. `ifi_ibytes` / `ifi_obytes` are **32-bit**
/// there, so two samples are subtracted per interface with wrapping `UInt32`
/// arithmetic and *then* summed: a signed subtraction, or a sum taken before
/// the subtraction, reads an interface's wrap as a ~4 GB drop and clamps to
/// zero once every 35 minutes of a busy link.
///
/// Interfaces are summed rather than filtered by name. The alternative is an
/// allowlist of prefixes (`en` for hardware, `utun`/`ppp`/`ipsec` for tunnels)
/// that has to be kept in step with every way macOS can carry traffic — a
/// dock, an iPhone bridge, a corporate tunnel — and a new one silently reads
/// as zero. Loopback is the one exception, and it is excluded by its
/// `IFF_LOOPBACK` flag rather than by the name `lo0`: the kernel does count
/// it, and this machine is routinely both endpoints — the in-process Codex
/// proxy relays every turn over `127.0.0.1` — so summing it in would report
/// each proxied byte on the strip twice, once as down and once as up.
@MainActor
final class SystemThroughput: ObservableObject {
    static let shared = SystemThroughput()

    @Published private(set) var down: Int64 = 0
    @Published private(set) var up: Int64 = 0

    /// Last tick's raw counters per interface, kept off the published path: a
    /// tick that changes nothing must not invalidate an observer, and a
    /// per-interface map is required for the wrapping subtraction to be right.
    private var lastCounters: [String: (bytesIn: UInt32, bytesOut: UInt32)]?
    private var lastAt: Date?

    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.1
        // `.common` mode: the default mode is suspended while a menu tracks or
        // a scroll runs, which is exactly when a rate is worth reading. (The
        // same reason the battery heartbeat in `BatteryChargeController` uses
        // it.)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Seed the counters now, so the first published rate is a real
        // one-second delta rather than a second of priming.
        sample()
    }

    /// The strip is the only always-on surface, so this sampler has no owner to
    /// tear down; `stop()` exists for the app's own shutdown path.
    func stop() {
        timer?.invalidate()
        timer = nil
        lastCounters = nil
        lastAt = nil
    }

    private func sample() {
        let now = Date()
        let counters = Self.interfaceCounters()
        defer {
            lastCounters = counters
            lastAt = now
        }
        // A first tick, or a machine that was just asleep: no delta is a *rate*.
        // `Timer` does not fire while suspended, so the gap after a wake is the
        // whole sleep, and dividing by it would report a long nap's background
        // traffic as one instantaneous burst.
        guard let previous = lastCounters, let previousAt = lastAt else { return }
        let elapsed = now.timeIntervalSince(previousAt)
        guard elapsed >= 0.25, elapsed <= 5 else { return }

        var deltaIn: UInt64 = 0, deltaOut: UInt64 = 0
        for (name, current) in counters {
            // An interface that just appeared has no baseline; its lifetime
            // total would otherwise arrive as one enormous first sample.
            guard let before = previous[name] else { continue }
            deltaIn += UInt64(current.bytesIn &- before.bytesIn)
            deltaOut += UInt64(current.bytesOut &- before.bytesOut)
        }
        let down = Int64(Double(deltaIn) / elapsed)
        let up = Int64(Double(deltaOut) / elapsed)
        if down != self.down { self.down = down }
        if up != self.up { self.up = up }
    }

    /// Per-interface byte counters, loopback excluded. Keyed by BSD name
    /// (`en0`, `utun3`), which is what makes the next tick able to subtract the
    /// right pair.
    private static func interfaceCounters() -> [String: (bytesIn: UInt32, bytesOut: UInt32)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var counters: [String: (bytesIn: UInt32, bytesOut: UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = entry.pointee.ifa_data,
                  let name = entry.pointee.ifa_name else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters[String(cString: name)] = (stats.ifi_ibytes, stats.ifi_obytes)
        }
        return counters
    }
}
