#!/usr/bin/env python3
"""The system-proxy controller's read-back, serialization and DNS snapshot rules.

`VpnSystemProxyController` had no behavioural regression: only the dev-channel
"does nothing" path was covered (finding 651). The rules that were wrong or
untested, and are pinned here:

  * the read-back must cover **every** enabled service — "Wi-Fi points at us"
    used to satisfy the whole check while Ethernet or a freshly plugged USB NIC
    stayed without a proxy, and the guard never re-wrote it (finding 178);
  * apply / clear must share one serial lane, so a fast off→on (or a toggle
    right before quit) cannot leave a late `apply` writing after `clear` and
    parking the services on a stopped core's port (finding 177);
  * a rewrite that read-back still fails must back off exponentially instead
    of re-spawning a dozen networksetup processes every 10 s forever, and one
    success must reset it (finding 179);
  * no DNS snapshot on disk ⇒ no DNS override (an unwritable snapshot used to
    be swallowed while the override proceeded, losing the user's resolvers —
    finding 491); an undecodable marker is kept, not deleted (finding 317).

The suite slices the production files and swaps only the process transport
(`Process.runAndRead`) for a scripted fake that models `networksetup` state;
paths land in a temp home. No real network service is touched, no app launch,
no privileged call.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
shared = (root / 'Sources/Shared/BuildChannel.swift').read_text()
paths = (root / 'Sources/ClaudeBar/Utils/FilePaths.swift').read_text()
paths = paths.replace('FileManager.default.homeDirectoryForCurrentUser', 'fixtureHome')
paths = paths.replace(
    'FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]',
    'fixtureSupport')
proxy = (root / 'Sources/ClaudeBar/Utils/VpnSystemProxyController.swift').read_text()
# Only the transport is replaced; every decision under test is the real code.
proxy = proxy[:proxy.index('// MARK: - Process helper')]
source = shared + '\n' + paths + '\n' + proxy + '\n' + r'''
let fixtureHome = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtureSupport = fixtureHome.appendingPathComponent("Library/Application Support")

struct AppPreferences {
    static let shared = AppPreferences()
    var vpnEnabled: Bool { true }
    var vpnSystemProxyEnabled: Bool { true }
    var vpnGuardEnabled: Bool { true }
    var vpnTunEnabled: Bool { true }
    var vpnMixedPort: Int { BuildChannel.vpnMixedPort }
}

enum VpnProviderDirect { static func hosts() -> [String] { [] } }

/// Scripted `networksetup`: it models per-service web-proxy and DNS state, so
/// a write command changes what the next read returns — exactly the read-back
/// loop under test. `denied` services reject every write with a non-zero exit,
/// the shape of "Command requires admin privileges."
enum FakeSystem {
    static let lock = NSLock()
    nonisolated(unsafe) static var services = ["AX88179A", "Wi-Fi", "Ethernet"]
    nonisolated(unsafe) static var denied: Set<String> = []
    nonisolated(unsafe) static var webproxy: [String: (host: String, port: String, enabled: Bool)] = [
        "AX88179A": ("", "0", false), "Wi-Fi": ("", "0", false), "Ethernet": ("", "0", false),
    ]
    nonisolated(unsafe) static var dns: [String: [String]] = [
        "AX88179A": ["8.8.8.8", "1.1.1.1"], "Wi-Fi": [], "Ethernet": ["1.1.1.1"],
    ]
    nonisolated(unsafe) static var events: [[String]] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        denied = []
        for service in services { webproxy[service] = ("", "0", false) }
        events = []
    }

    static func snapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

@MainActor final class VpnManager {
    static let shared = VpnManager()
    var isRunning: Bool { true }
    nonisolated(unsafe) static var lines: [String] = []
    func log(_ text: String) { Self.lines.append(text) }
}

extension Process {
    struct RunResult { let status: Int32; let output: String }

    static func runAndRead(_ path: String, args: [String]) -> RunResult {
        FakeSystem.lock.lock(); defer { FakeSystem.lock.unlock() }
        FakeSystem.events.append(args)
        let service = args.count > 1 ? args[1] : ""
        if FakeSystem.denied.contains(service), args[0].hasPrefix("-set") {
            return .init(status: 1, output: "Command requires admin privileges.")
        }
        switch args[0] {
        case "-listallnetworkservices":
            return .init(status: 0, output:
                "An asterisk (*) denotes that a network service is disabled.\n"
                + FakeSystem.services.joined(separator: "\n") + "\n")
        case "-getwebproxy":
            let p = FakeSystem.webproxy[service] ?? ("", "0", false)
            return .init(status: 0, output:
                "Enabled: \(p.enabled ? "Yes" : "No")\nServer: \(p.host)\nPort: \(p.port)\n")
        case "-getdnsservers":
            let servers = FakeSystem.dns[service] ?? []
            return .init(status: 0, output: servers.isEmpty
                ? "There aren't any DNS Servers set on \(service).\n"
                : servers.map { $0 + "\n" }.joined())
        case "-setwebproxy", "-setsecurewebproxy", "-setsocksfirewallproxy":
            // [command, service, host, port, authenticated]
            FakeSystem.webproxy[service] = (args[2], args[3], FakeSystem.webproxy[service]?.enabled ?? false)
        case "-setwebproxystate":
            let current = FakeSystem.webproxy[service] ?? ("", "0", false)
            FakeSystem.webproxy[service] = (current.host, current.port, args[2] == "on")
        case "-setdnsservers":
            FakeSystem.dns[service] = args.count == 3 && args[2] == "Empty" ? [] : Array(args.dropFirst(2))
        default:
            break
        }
        return .init(status: 0, output: "")
    }
}

@main struct Regression {
    static func pump(_ condition: () -> Bool, seconds: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    static func events(_ first: String) -> [[String]] {
        FakeSystem.snapshot().filter { $0.first == first }
    }

    static func pointAtUs(_ service: String, port: String = "17890") {
        FakeSystem.webproxy[service] = ("127.0.0.1", port, true)
    }

    @MainActor static func main() throws {
        // 1. Happy path: every service (including the one that matches no
        //    "preferred" name) gets the full write, and the read-back that
        //    reports success really covers all of them.
        FakeSystem.reset()
        let message = VpnSystemProxyController.applySystemProxyNow(port: 17890)
        precondition(message.contains("回读 成功"), message)
        precondition(events("-setproxybypassdomains").count == FakeSystem.services.count,
                     "every service must get the bypass list, got \(FakeSystem.events)")
        precondition(events("-getwebproxy").map { $0[1] }.contains("AX88179A"),
                     "the read-back must include services whose names match no preferred word")
        precondition(VpnSystemProxyController.isOurHTTPProxyEnabledNow(port: 17890))

        // 2. Finding 178: Wi-Fi alone is not health. An Ethernet on a wrong
        //    port must fail the check and trigger a rewrite of *it* too.
        pointAtUs("Wi-Fi")
        pointAtUs("AX88179A")
        FakeSystem.webproxy["Ethernet"] = ("127.0.0.1", "9999", true)
        precondition(!VpnSystemProxyController.isOurHTTPProxyEnabledNow(port: 17890),
                     "one service off our port must fail the whole check")
        precondition(VpnSystemProxyController.currentHTTPProxy().count == FakeSystem.services.count,
                     "the guard reads every service, not the first hit")
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var called = false
            var message: String?
        }
        let box = Box()
        VpnSystemProxyController.reassertProxyIfNeeded(port: 17890) { msg in
            box.lock.lock(); box.called = true; box.message = msg; box.lock.unlock()
        }
        precondition(pump { box.lock.lock(); defer { box.lock.unlock() }; return box.called },
                     "the guard's re-assert never completed")
        box.lock.lock()
        let rewritten = box.message
        box.lock.unlock()
        precondition(rewritten?.contains("回读 成功") == true, "the stale service must be rewritten: \(rewritten ?? "nil")")
        precondition(VpnSystemProxyController.isOurHTTPProxyEnabledNow(port: 17890))

        // …and when everything already points at us, the guard must not write.
        FakeSystem.reset()
        for service in FakeSystem.services { pointAtUs(service) }
        let writes = events("-setwebproxy").count
        let clean = Box()
        VpnSystemProxyController.reassertProxyIfNeeded(port: 17890) { msg in
            clean.lock.lock(); clean.called = true; clean.message = msg; clean.lock.unlock()
        }
        precondition(pump { clean.lock.lock(); defer { clean.lock.unlock() }; return clean.called })
        clean.lock.lock()
        let healthyMessage = clean.message
        clean.lock.unlock()
        precondition(healthyMessage == nil, "a healthy state must not rewrite: \(healthyMessage ?? "nil")")
        precondition(events("-setwebproxy").count == writes, "no proxy write may happen when healthy")

        // 3. Finding 179: a service whose writes are denied keeps the read-back
        //    failing, and the failure is what drives the guard's backoff.
        FakeSystem.reset()
        FakeSystem.denied = ["Ethernet"]
        let failing = VpnSystemProxyController.applySystemProxyNow(port: 17890)
        precondition(failing.contains("回读 失败"), failing)
        precondition(failing.contains("失败"), "the message must surface the failed writes: \(failing)")
        precondition(!VpnSystemProxyController.isOurHTTPProxyEnabledNow(port: 17890))
        FakeSystem.denied = []

        // 4. Finding 179: 10s doubling per consecutive failure, capped at 5min.
        precondition(VpnProxyGuard.backoffInterval(failures: 1) == 10)
        precondition(VpnProxyGuard.backoffInterval(failures: 2) == 20)
        precondition(VpnProxyGuard.backoffInterval(failures: 3) == 40)
        precondition(VpnProxyGuard.backoffInterval(failures: 6) == 300)
        precondition(VpnProxyGuard.backoffInterval(failures: 99) == 300)

        // 5. Finding 177: apply and clear share one serial lane. Enqueue
        //    apply→clear and require the disk order to match: no apply write
        //    may land after the clear began, and the final state is cleared.
        FakeSystem.reset()
        let services = FakeSystem.services.count
        VpnSystemProxyController.applySystemProxy(port: 17890)
        VpnSystemProxyController.clearSystemProxyAsync()
        precondition(pump {
            events("-setsocksfirewallproxystate").filter { $0.last == "off" }.count == services
        }, "the queued clear never finished: \(FakeSystem.events)")
        // Give a racy implementation one more beat to misbehave.
        _ = pump({ false }, seconds: 0.2)
        let log = FakeSystem.snapshot()
        let lastApplyWrite = log.lastIndex { $0.first == "-setproxybypassdomains" }
        let firstClearWrite = log.firstIndex { $0.first == "-setsocksfirewallproxystate" && $0.last == "off" }
        precondition(lastApplyWrite != nil && firstClearWrite != nil)
        precondition(lastApplyWrite! < firstClearWrite!,
                     "an apply write landed after the clear started: \(log)")
        precondition(!VpnSystemProxyController.isOurHTTPProxyEnabledNow(port: 17890),
                     "clear was the last intent, so no service may still point at us")

        // 6. Finding 491: no snapshot, no DNS override. An unwritable VPN
        //    directory (permission denied on the snapshot write) must abort
        //    before any `-setdnsservers`, and say so in the log.
        try? FileManager.default.removeItem(at: VpnTunDnsHelper.dnsMarker)
        let vpnDir = VpnTunDnsHelper.dnsMarker.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: vpnDir.path)
        FakeSystem.reset()
        VpnManager.lines = []
        VpnTunDnsHelper.setSystemDNSNow()
        precondition(events("-setdnsservers").isEmpty,
                     "DNS was overridden without a snapshot to restore from")
        precondition(pump { VpnManager.lines.contains { $0.contains("DNS 快照写入失败") } },
                     "the skip must be visible in the log, got \(VpnManager.lines)")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vpnDir.path)
        try? FileManager.default.removeItem(at: VpnTunDnsHelper.dnsMarker)

        // 7. Finding 317: an undecodable marker is kept (it is the only record
        //    of the pre-override servers) and restore leaves DNS alone.
        try "{".write(to: VpnTunDnsHelper.dnsMarker, atomically: true, encoding: .utf8)
        FakeSystem.reset()
        VpnManager.lines = []
        VpnTunDnsHelper.restoreSystemDNSNow()
        precondition(events("-setdnsservers").isEmpty, "an undecodable marker must not partially restore")
        let kept = try String(contentsOf: VpnTunDnsHelper.dnsMarker, encoding: .utf8)
        precondition(kept == "{", "the marker must be kept for a later restore")
        precondition(pump { VpnManager.lines.contains { $0.contains("无法解析") } },
                     "the retained marker must be diagnosable, got \(VpnManager.lines)")

        // 8. A decodable snapshot restores the per-service servers and is then
        //    consumed; a service that no longer exists is skipped.
        try "[{\"service\":\"Wi-Fi\",\"servers\":[]},{\"service\":\"AX88179A\",\"servers\":[\"8.8.8.8\",\"1.1.1.1\"]},{\"service\":\"Gone\",\"servers\":[\"9.9.9.9\"]}]"
            .write(to: VpnTunDnsHelper.dnsMarker, atomically: true, encoding: .utf8)
        FakeSystem.reset()
        VpnTunDnsHelper.restoreSystemDNSNow()
        precondition(events("-setdnsservers").contains { $0 == ["-setdnsservers", "Wi-Fi", "Empty"] })
        precondition(events("-setdnsservers").contains { $0 == ["-setdnsservers", "AX88179A", "8.8.8.8", "1.1.1.1"] })
        precondition(!events("-setdnsservers").contains { $0[1] == "Gone" },
                     "a service that no longer exists must be skipped")
        precondition(!FileManager.default.fileExists(atPath: VpnTunDnsHelper.dnsMarker.path),
                     "a successful restore consumes the marker")

        // 9. The snapshot is written before the override, so a session that
        //    dies mid-way still restores.
        FakeSystem.reset()
        VpnManager.lines = []
        VpnTunDnsHelper.setSystemDNSNow()
        precondition(FileManager.default.fileExists(atPath: VpnTunDnsHelper.dnsMarker.path),
                     "the snapshot must exist before the override")
        precondition(events("-setdnsservers").filter { $0.contains("223.5.5.5") }.count == services)
        VpnTunDnsHelper.restoreSystemDNSNow()
        precondition(events("-setdnsservers").contains { $0 == ["-setdnsservers", "Wi-Fi", "Empty"] })
        precondition(!FileManager.default.fileExists(atPath: VpnTunDnsHelper.dnsMarker.path))

        print("PASS: read-back covers every service, apply/clear serialize, failures back off, DNS never overrides without a kept snapshot")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-system-proxy-') as folder:
    swift = Path(folder) / 'Regression.swift'
    swift.write_text(source)
    binary = Path(folder) / 'regression'
    # Release defines so `allowsSystemIntegration` is on: the suite is about
    # the real write path, which the dev channel deliberately short-circuits.
    subprocess.run(['/usr/bin/swiftc', '-O', '-parse-as-library', '-D', 'CLAUDEBAR_RELEASE',
                    str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary), folder], check=True)
