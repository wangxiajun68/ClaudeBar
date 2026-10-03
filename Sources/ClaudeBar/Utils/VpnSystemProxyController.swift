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

    /// All enabled network services (Wi-Fi, Ethernet, …).
    ///
    /// `nonisolated`: spawns `networksetup` and blocks on its output, so it
    /// must be callable from a background task (the guard loop reads the
    /// current proxy state off-main; see `VpnProxyGuard.check`). Pure process
    /// I/O + string parsing, no shared state.
    nonisolated static func networkServices() -> [String] {
        let result = Process.runAndRead("/usr/sbin/networksetup", args: ["-listallnetworkservices"])
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("*") && !$0.hasPrefix("An asterisk") }
    }

    /// Wi-Fi / Ethernet first. `listallnetworkservices` often lists
    /// Thunderbolt Bridge before the interface the user actually uses, so
    /// the guard must not treat the first row as truth.
    nonisolated static func preferredServices() -> [String] {
        let all = networkServices()
        let hot = all.filter { isPreferredService($0) }
        return hot.isEmpty ? all : hot
    }

    nonisolated static func isPreferredService(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("wi-fi") || n.contains("wifi") || n.contains("airport")
            || n.contains("ethernet") || n.contains("以太网")
            || n.contains("usb") || n.contains("lan")
    }

    /// Point HTTP / HTTPS / SOCKS at 127.0.0.1:<port> on every service.
    /// PAC / auto-discovery are cleared first; `-setwebproxy` gets `off` as
    /// the authenticated flag so macOS does not leave a stale PAC URL.
    ///
    /// Spawns many `networksetup` processes. Must not run on the main actor —
    /// that was the start/stop hitch (tens of blocking waits per toggle).
    static func applySystemProxy(port: Int) {
        Task.detached(priority: .userInitiated) {
            let msg = applySystemProxyNow(port: port)
            await MainActor.run { VpnManager.shared.log(msg) }
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
            let commands: [[String]] = [
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
            for args in commands {
                let r = Process.runAndRead("/usr/sbin/networksetup", args: args)
                if r.status != 0 { failed += 1 }
            }
        }
        if !isOurHTTPProxyEnabledNow(port: port) {
            for service in preferredServices() {
                _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setwebproxy", service, "127.0.0.1", "\(port)", "off"])
                _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setwebproxystate", service, "on"])
            }
        }
        let ok = isOurHTTPProxyEnabledNow(port: port)
        return "系统代理已写入 127.0.0.1:\(port)（\(services.count) 个服务\(failed > 0 ? "，失败 \(failed)" : "")，回读 \(ok ? "成功" : "失败")）"
    }

    nonisolated static func isOurHTTPProxyEnabledNow(port: Int) -> Bool {
        let portStr = "\(port)"
        for service in preferredServices() {
            if let p = parseWebProxy(service), p.enabled, p.host == "127.0.0.1", p.port == portStr {
                return true
            }
        }
        return false
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
        Task.detached(priority: .userInitiated) {
            clearSystemProxyNow()
        }
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

    /// Read back HTTP proxy on Wi-Fi / Ethernet — used by the guard loop.
    nonisolated static func currentHTTPProxy() -> (host: String, port: String)? {
        for service in preferredServices() {
            if let p = parseWebProxy(service), p.enabled {
                return (p.host, p.port)
            }
        }
        return nil
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
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Read the current proxy off the main thread. `networksetup` spawn plus
    /// its blocking read is 15–40 ms of pure main-thread stall every 10 s
    /// (measured 4–6% of main-thread samples); the guard only *acts* when the
    /// value is wrong, which is rare — so only the compare needs the results.
    private func check() {
        let prefs = AppPreferences.shared
        guard prefs.vpnEnabled, prefs.vpnSystemProxyEnabled, prefs.vpnGuardEnabled,
              VpnManager.shared.isRunning else { return }
        let expected = "127.0.0.1"
        let port = "\(prefs.vpnMixedPort)"
        let mixedPort = prefs.vpnMixedPort
        Task.detached(priority: .utility) {
            let current = VpnSystemProxyController.currentHTTPProxy()
            guard current?.host != expected || current?.port != port else { return }
            let msg = VpnSystemProxyController.applySystemProxyNow(port: mixedPort)
            await MainActor.run { VpnManager.shared.log(msg) }
        }
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
        saveOriginalDNSIfNeeded()
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
    nonisolated static func restoreSystemDNSNow() {
        guard BuildChannel.allowsSystemIntegration else { return }
        guard let data = try? Data(contentsOf: dnsMarker) else { return }
        if let snapshot = try? JSONDecoder().decode([OriginalDNS].self, from: data) {
            let live = Set(VpnSystemProxyController.networkServices())
            for entry in snapshot where live.contains(entry.service) {
                let args = entry.servers.isEmpty
                    ? ["-setdnsservers", entry.service, "Empty"]
                    : ["-setdnsservers", entry.service] + entry.servers
                _ = Process.runAndRead("/usr/sbin/networksetup", args: args)
            }
        }
        // Removed even when the marker could not be decoded (e.g. one written
        // by an older build): leaving it would re-run this restore on exit.
        try? FileManager.default.removeItem(at: dnsMarker)
    }

    nonisolated private static func saveOriginalDNSIfNeeded() {
        guard !FileManager.default.fileExists(atPath: dnsMarker.path) else { return }
        let snapshot = VpnSystemProxyController.networkServices().map { service in
            OriginalDNS(service: service, servers: dnsServers(of: service))
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: dnsMarker, options: .atomic)
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
