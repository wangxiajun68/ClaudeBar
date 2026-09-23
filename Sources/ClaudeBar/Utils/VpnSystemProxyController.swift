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
        let services = networkServices()
        if services.isEmpty {
            return "系统代理：没有可用网络服务"
        }
        var failed = 0
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
                ["-setproxybypassdomains", service] + bypassDomains(),
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
        for service in networkServices() {
            _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setautoproxystate", service, "off"])
            _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setwebproxystate", service, "off"])
            _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setsecurewebproxystate", service, "off"])
            _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setsocksfirewallproxystate", service, "off"])
        }
        VpnTunDnsHelper.restoreSystemDNSNow()
    }

    nonisolated private static func bypassDomains() -> [String] {
        defaultBypass.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
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

/// TUN itself needs no extra config in mihomo (auto-route + the `tun:` block
/// handle it), but on macOS the default-route DNS must be pinned to a public
/// resolver while fake-ip is active — what clash-verge's set_dns.sh does.
/// We reuse the app's existing privileged-helper pattern (setuid fanctl) for
/// this: the helper binary runs networksetup as root.
enum VpnTunDnsHelper {
    static let helperPath = "/usr/local/bin/claudebar-fanctl" // existing setuid helper host
    static let dnsMarker = FilePaths.vpnDir.appendingPathComponent(".original_dns")

    /// Only meaningful when a TUN session is starting. Uses the public
    /// resolvers clash-verge scripts/set_dns.sh sets.
    static func setSystemDNS() {
        guard AppPreferences.shared.vpnTunEnabled else { return }
        Task.detached(priority: .userInitiated) { setSystemDNSNow() }
    }

    nonisolated static func setSystemDNSNow() {
        saveOriginalDNSIfNeeded()
        for service in VpnSystemProxyController.networkServices() {
            _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setdnsservers", service, "223.5.5.5", "119.29.29.29"])
        }
        try? "set".write(to: FilePaths.vpnTunMarker, atomically: true, encoding: .utf8)
    }

    static func restoreSystemDNSIfNeeded() {
        Task.detached(priority: .userInitiated) { restoreSystemDNSNow() }
    }

    nonisolated static func restoreSystemDNSNow() {
        guard FileManager.default.fileExists(atPath: dnsMarker.path) else { return }
        for service in VpnSystemProxyController.networkServices() {
            _ = Process.runAndRead("/usr/sbin/networksetup", args: ["-setdnsservers", service, "Empty"])
        }
        try? FileManager.default.removeItem(at: dnsMarker)
        try? FileManager.default.removeItem(at: FilePaths.vpnTunMarker)
    }

    nonisolated private static func saveOriginalDNSIfNeeded() {
        guard !FileManager.default.fileExists(atPath: dnsMarker.path) else { return }
        let services = VpnSystemProxyController.networkServices()
        guard let first = services.first else { return }
        let result = Process.runAndRead("/usr/sbin/networksetup", args: ["-getdnsservers", first])
        try? result.output.write(to: dnsMarker, atomically: true, encoding: .utf8)
    }
}

// MARK: - Process helper

extension Process {
    struct RunResult {
        let status: Int32
        let output: String
    }

    /// Synchronous, non-injected run capturing stdout+stderr. Small args only
    /// (networksetup calls) — not for large output. Named runAndRead to avoid
    /// clashing with FanHelperInstaller's throwing Process.run.
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return RunResult(
            status: proc.terminationStatus,
            output: String(decoding: data, as: UTF8.self))
    }
}
