import Foundation
import AppKit

// MARK: - System proxy controller

/// Writes / clears the macOS system proxy by shelling out to `networksetup`,
/// the same commands sysproxy-rs wraps in clash-verge-rev (sidecar path).
/// The bypass list matches clash-verge's macOS default.
@MainActor
enum VpnSystemProxyController {
    nonisolated static let defaultBypass =
        "127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, localhost, *.local, *.crashlytics.com, <local>"

    /// Single serial lane for every system-proxy mutation.
    ///
    /// The async entry points used to be independent detached tasks: a fast
    /// off→on (or a toggle right before quit) let a slow `apply` finish after
    /// `clear` and leave services pointing at a stopped core's port, with the
    /// guard stopped and nobody left to correct it (finding 177). All callers
    /// share this queue, so the last intent enqueued is the last write on disk,
    /// and a write is never torn by a concurrent one. The serial-lane idiom is
    /// the repo's own (`FanMonitor.commandQueue`, `UsageFSWatcher.queue`).
    nonisolated private static let serialQueue =
        DispatchQueue(label: "com.claudebar.vpn-system-proxy", qos: .userInitiated)

    /// All enabled network services (Wi-Fi, Ethernet, …).
    ///
    /// `nonisolated`: spawns `networksetup` and blocks on its output, so it
    /// must be callable from a background task (the guard loop reads the
    /// current proxy state off-main). Pure process I/O + string parsing, no
    /// shared state.
    nonisolated static func networkServices() -> [String] {
        let result = Process.runAndRead("/usr/sbin/networksetup", args: ["-listallnetworkservices"])
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("*") && !$0.hasPrefix("An asterisk") }
    }

    /// Point HTTP / HTTPS / SOCKS at 127.0.0.1:<port> on every enabled
    /// service. PAC / auto-discovery are cleared first; `-setwebproxy` gets
    /// `off` as the authenticated flag so macOS does not leave a stale PAC URL.
    ///
    /// Spawns many `networksetup` processes. Must not run on the main actor —
    /// that was the start/stop hitch (tens of blocking waits per toggle).
    /// The blocking body runs on `serialQueue`, so apply/clear never interleave
    /// (finding 177).
    static func applySystemProxy(port: Int) {
        serialQueue.async {
            let msg = applySystemProxyNow(port: port)
            Task { @MainActor in VpnManager.shared.log(msg) }
        }
    }

    nonisolated static func applySystemProxyNow(port: Int) -> String {
        guard BuildChannel.allowsSystemIntegration else { return BuildChannel.restrictionMessage }
        let services = networkServices()
        if services.isEmpty {
            return "系统代理：没有可用网络服务"
        }
        var failed = 0
        // Read once: the provider files cannot change mid-loop.
        let bypass = bypassDomains()
        for service in services {
            for args in proxyCommands(for: service, port: port, bypass: bypass) {
                let r = Process.runAndRead("/usr/sbin/networksetup", args: args)
                if r.status != 0 { failed += 1 }
            }
        }
        // A service can appear between the list read and the write (USB NIC);
        // re-assert on anything that missed (finding 178).
        let ok = isOurHTTPProxyEnabledNow(port: port)
        return "系统代理已写入 127.0.0.1:\(port)（\(services.count) 个服务\(failed > 0 ? "，失败 \(failed)" : "")，回读 \(ok ? "成功" : "失败")）"
    }

    /// One service's full write: PAC / auto-discovery off, then HTTP / HTTPS /
    /// SOCKS to us (unauthenticated), then the bypass list.
    nonisolated private static func proxyCommands(for service: String, port: Int, bypass: [String]) -> [[String]] {
        [
            ["-setautoproxystate", service, "off"],
            ["-setproxyautodiscovery", service, "off"],
            ["-setwebproxy", service, "127.0.0.1", "\(port)", "off"],
            ["-setsecurewebproxy", service, "127.0.0.1", "\(port)", "off"],
            ["-setsocksfirewallproxy", service, "127.0.0.1", "\(port)", "off"],
            ["-setwebproxystate", service, "on"],
            ["-setsecurewebproxystate", service, "on"],
            ["-setsocksfirewallproxystate", service, "on"],
            ["-setproxybypassdomains", service] + bypass,
        ]
    }

    /// Every enabled service must point at us — not just the first that does
    /// (finding 178). An empty read (networksetup failed) is not agreement.
    nonisolated static func isOurHTTPProxyEnabledNow(port: Int) -> Bool {
        let portStr = "\(port)"
        let services = networkServices()
        guard !services.isEmpty else { return false }
        return services.allSatisfy { service in
            guard let p = parseWebProxy(service) else { return false }
            return p.enabled && p.host == "127.0.0.1" && p.port == portStr
        }
    }

    nonisolated static func parseWebProxy(_ service: String) -> (host: String, port: String, enabled: Bool)? {
        let result = Process.runAndRead("/usr/sbin/networksetup", args: ["-getwebproxy", service])
        var host: String?, port: String?, enabled = false
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Server": host = parts[1]
            case "Port": port = parts[1]
            case "Enabled": enabled = parts[1] == "Yes"
            default: break
            }
        }
        guard let h = host, let p = port else { return nil }
        return (h, p, enabled)
    }

    /// Clear the proxy on every service and restore DNS if TUN hijacked it.
    /// Quit path stays synchronous so the proxy is gone before the process dies.
    static func clearSystemProxy() {
        clearSystemProxyNow()
    }

    static func clearSystemProxyAsync() {
        serialQueue.async { clearSystemProxyNow() }
    }

    nonisolated static func clearSystemProxyNow() {
        guard BuildChannel.allowsSystemIntegration else { return }
        for service in networkServices() {
            _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setautoproxystate", service, "off"])
            _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setwebproxystate", service, "off"])
            _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setsecurewebproxystate", service, "off"])
            _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setsocksfirewallproxystate", service, "off"])
        }
        VpnTunDnsHelper.restoreSystemDNSNow()
    }

    /// clash-verge's default list, plus the hosts the user's own providers are
    /// served from.
    ///
    /// The defaults are all addresses and IP ranges, so they can never bypass a
    /// *hostname*. That is the gap `VpnProviderDirect` documents: a provider
    /// endpoint on a vanity domain sits in China but matches no geosite, so with
    /// the hostname left to `scutil` the request goes out through a node abroad
    /// and comes straight back. `-setproxybypassdomains` is the one macOS bypass
    /// surface that takes hostnames, so the same list is applied here and to the
    /// rule chain — this one removes the traffic, that one covers TUN and any
    /// app holding its own proxy setting.
    nonisolated private static func bypassDomains() -> [String] {
        defaultBypass.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            + VpnProviderDirect.hosts()
    }

    /// Read back the HTTP proxy on **every** enabled network service — used by
    /// the guard loop. Returning all rows (not the first enabled one) is what
    /// lets the guard re-assert when *any* interface has fallen off our port:
    /// the write side covers every service, so the check has to as well
    /// (finding 178).
    nonisolated static func currentHTTPProxy() -> [(host: String, port: String, enabled: Bool)] {
        networkServices().compactMap { parseWebProxy($0) }
    }

    /// Guard support: read every service and, when any has fallen off our
    /// port, re-write — both on the same serial lane as the explicit apply /
    /// clear calls, so enqueue order is the order of user intent (finding 177,
    /// see `serialQueue`). `completion(nil)` means the proxy was already
    /// correct; otherwise it carries the write's message, whose `回读` result
    /// is what the guard backs off on.
    nonisolated static func reassertProxyIfNeeded(port: Int, completion: @escaping @Sendable (String?) -> Void) {
        serialQueue.async {
            let expected = "127.0.0.1"
            let portStr = "\(port)"
            let current = currentHTTPProxy()
            // Healthy means every enabled service points at us; an empty read
            // (networksetup failed) is not health.
            let healthy = !current.isEmpty && current.allSatisfy {
                $0.enabled && $0.host == expected && $0.port == portStr
            }
            guard !healthy else {
                completion(nil)
                return
            }
            completion(applySystemProxyNow(port: port))
        }
    }
}

// MARK: - Guard loop

/// Re-asserts the system proxy when something else clears it — clash-verge's
/// `GuardMonitor` (`Sysopt::refresh_guard`), simplified: 10s poll, rewrite
/// when the HTTP proxy no longer points at us.
@MainActor
final class VpnProxyGuard {
    static let shared = VpnProxyGuard()
    private var timer: Timer?

    func start() {
        guard BuildChannel.allowsSystemIntegration else { return }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.check() }
        }
        // Same tolerance rule as every other periodic timer in this app
        // (FanMonitor 0.25, SystemThroughput 0.1, ProviderStore 10%): without
        // it the wake-up cannot be coalesced with other work, and this timer
        // outlives the VPN being on — `check()` early-returns at launch while
        // the module is off, but the 10 s wake-ups continue for the life of
        // the process on a machine where it is never turned on.
        timer?.tolerance = 2
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Read the current proxy off the main thread. `networksetup` spawn plus
    /// its blocking read is 15–40 ms of pure main-thread stall every 10 s
    /// (measured 4–6% of main-thread samples); the guard only *acts* when the
    /// value is wrong, which is rare — so only the compare needs the results.
    ///
    /// Failures back off exponentially (10s → 5min cap): an account that
    /// cannot change network settings used to re-spawn a dozen `networksetup`
    /// processes and append the same log line every 10 seconds for as long as
    /// the VPN ran, with the reason invisible (finding 179). One success
    /// resets the interval.
    private var consecutiveFailures = 0

    private func check() {
        let prefs = AppPreferences.shared
        guard prefs.vpnEnabled, prefs.vpnSystemProxyEnabled, prefs.vpnGuardEnabled,
              VpnManager.shared.isRunning else { return }
        let port = prefs.vpnMixedPort
        // The read / compare / rewrite runs on the controller's serial lane
        // (off the main actor — `networksetup` spawn plus its blocking read was
        // 15–40 ms of main-thread stall per tick, measured 4–6% of samples);
        // the guard only folds the outcome into its poll interval.
        VpnSystemProxyController.reassertProxyIfNeeded(port: port) { [weak self] message in
            guard let message else {
                Task { @MainActor in self?.noteGuard(healthy: true) }
                return
            }
            Task { @MainActor in
                VpnManager.shared.log(message)
                // A re-write whose read-back still fails is the failure worth
                // backing off on, even though each networksetup exited 0.
                self?.noteGuard(healthy: message.contains("回读 成功"))
            }
        }
    }

    /// Fold one guard result into the poll interval. Repeated failures
    /// double it up to 5 minutes; a success restores the 10s cadence. The
    /// log line `check` just wrote carries networksetup's own text, which the
    /// VPN page's console surfaces as the reason.
    private func noteGuard(healthy: Bool) {
        if healthy {
            guard consecutiveFailures > 0 else { return }
            consecutiveFailures = 0
            reschedule(after: 10)
            return
        }
        consecutiveFailures += 1
        reschedule(after: Self.backoffInterval(failures: consecutiveFailures))
    }

    /// 10s doubling per consecutive failure, capped at 5 minutes. Pure
    /// arithmetic, pinned by the regression.
    nonisolated static func backoffInterval(failures: Int) -> TimeInterval {
        min(300, 10 * pow(2, Double(min(failures - 1, 5))))
    }

    /// Rebuild the repeating timer at a new interval. `tolerance` follows the
    /// same rule as `start()` — half the period, capped — so a 5-minute
    /// backoff can still be coalesced with other wake-ups.
    private func reschedule(after interval: TimeInterval) {
        guard let old = timer else { return }
        old.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.check() }
        }
        timer?.tolerance = min(interval / 2, 30)
    }
}

// MARK: - TUN / DNS helper

/// One service's DNS answer from before the TUN override. Empty `servers`
/// means the service had no manual servers, so putting it back is
/// `-setdnsservers <service> Empty` (DHCP).
private struct OriginalDNS: Codable {
    let service: String
    let servers: [String]
}

/// TUN itself needs no extra config in mihomo (auto-route + the `tun:` block
/// handle it), but on macOS the default-route DNS must be pinned to a public
/// resolver while fake-ip is active — what clash-verge's set_dns.sh does.
/// The calls below shell straight to `/usr/sbin/networksetup` under the
/// user's own identity; the setuid fanctl helper has no networksetup mode.
enum VpnTunDnsHelper {
    /// Per-service snapshot written before the first override; its presence
    /// is what tells restore there is something to undo.
    static let dnsMarker = FilePaths.vpnDir.appendingPathComponent(".original_dns")

    /// Only meaningful when a TUN session is starting. Uses the public
    /// resolvers clash-verge scripts/set_dns.sh sets.
    static func setSystemDNS() {
        guard AppPreferences.shared.vpnTunEnabled else { return }
        Task.detached(priority: .userInitiated) { setSystemDNSNow() }
    }

    nonisolated static func setSystemDNSNow() {
        guard BuildChannel.allowsSystemIntegration else { return }
        // No marker, no override: restoring the user's per-service servers is
        // keyed entirely on this snapshot existing, so a snapshot that could
        // not be written must abort the override rather than leave the
        // resolvers changed with nothing to put back (finding 491).
        guard saveOriginalDNSIfNeeded() else {
            Task { @MainActor in VpnManager.shared.log("DNS 快照写入失败，本次不改动系统 DNS") }
            return
        }
        for service in VpnSystemProxyController.networkServices() {
            _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setdnsservers", service, "223.5.5.5", "119.29.29.29"])
        }
    }

    static func restoreSystemDNSIfNeeded() {
        Task.detached(priority: .userInitiated) { restoreSystemDNSNow() }
    }

    /// Undo in the reverse order: put the recorded servers back first, then
    /// drop the markers. A service that had manual servers gets them back;
    /// one that had none was on DHCP and is reset to `Empty`. Services that
    /// appeared after the snapshot are skipped — they were never touched.
    ///
    /// A snapshot that exists but cannot be decoded is **kept**: it is the
    /// only record of the pre-override servers, and on this machine it may be
    /// the one a hand-edit or an older format left. Deleting it would turn
    /// "restore will happen later" into "nothing to restore" (finding 317);
    /// the skip is logged so the state is diagnosable. A **successful**
    /// restore consumes the marker, as does a clean outage after the servers
    /// were put back.
    nonisolated static func restoreSystemDNSNow() {
        guard BuildChannel.allowsSystemIntegration else { return }
        guard let data = try? Data(contentsOf: dnsMarker) else { return }
        guard let snapshot = try? JSONDecoder().decode([OriginalDNS].self, from: data) else {
            Task { @MainActor in
                VpnManager.shared.log("DNS 标记无法解析，保留以便诊断：\(dnsMarker.path)")
            }
            return
        }
        let live = Set(VpnSystemProxyController.networkServices())
        for entry in snapshot where live.contains(entry.service) {
            let args = entry.servers.isEmpty
                ? ["-setdnsservers", entry.service, "Empty"]
                : ["-setdnsservers", entry.service] + entry.servers
            _ = Process.runAndRead("/usr/sbin/networksetup", args: args)
        }
        try? FileManager.default.removeItem(at: dnsMarker)
    }

    /// Write the per-service snapshot if there is none yet. Returns whether a
    /// snapshot is present afterwards — including one written by an earlier
    /// session — because that presence is exactly the precondition for
    /// overriding DNS. `false` means nothing could be recorded (unwritable
    /// VPN directory, unencodable state), and the caller must not proceed.
    nonisolated private static func saveOriginalDNSIfNeeded() -> Bool {
        if FileManager.default.fileExists(atPath: dnsMarker.path) { return true }
        let snapshot = VpnSystemProxyController.networkServices().map { service in
            OriginalDNS(service: service, servers: dnsServers(of: service))
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try data.write(to: dnsMarker, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// `networksetup` answers "There aren't any DNS Servers set on <service>."
    /// for a service that follows DHCP; every other output line is one server.
    nonisolated private static func dnsServers(of service: String) -> [String] {
        let result = Process.runAndRead("/usr/sbin/networksetup", args: ["-getdnsservers", service])
        return result.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("There aren") }
    }
}

// MARK: - Process helper

extension Process {
    struct RunResult {
        let status: Int32
        let output: String
    }

    /// Synchronous, non-injected run capturing stdout+stderr, read to EOF
    /// before waiting on the child. Small args only (networksetup calls) —
    /// not for large output.
    static func runAndRead(_ path: String, args: [String]) -> RunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return RunResult(status: -1, output: "")
        }
        // Read before waiting: `readToEnd()` drains the child's stdout, so it
        // only returns once the child closed it — at which point a wait adds
        // nothing but a second syscall.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        proc.waitUntilExit()
        return RunResult(
            status: proc.terminationStatus,
            output: String(decoding: data, as: UTF8.self))
    }
}
