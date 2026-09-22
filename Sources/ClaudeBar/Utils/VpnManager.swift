import Foundation
import Darwin

// MARK: - Mihomo API models

/// Node parsed from mihomo `/proxies` (only leaf nodes are shown; groups are
/// fetched separately for selection).
struct VpnProxy: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let type: String
    let server: String
    let port: Int
    /// ms; nil = not tested / timeout.
    var delay: Int?
    /// Currently selected inside its group.
    var isCurrent: Bool = false
}

struct VpnGroup: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let type: String
    var nodes: [String]
    var current: String
}

struct VpnTrafficSnapshot: Equatable {
    var up: Int64 = 0
    var down: Int64 = 0
    var totalUp: Int64 = 0
    var totalDown: Int64 = 0
    var activeConnections: Int = 0
}

/// Compact byte / rate labels.
///
/// Every variant is a **fixed character count** so digit/unit changes cannot
/// reflow the menu bar or the VPN page. Units are always two letters (KB/MB/GB/TB);
/// sub-KB values render as `  0.0 KB` rather than `12 B`.
enum VpnFormat {
    /// `"   0.0 KB/s"` — always 12 characters.
    static func rate(_ bytesPerSec: Int64) -> String { bytes(bytesPerSec) + "/s" }

    /// `"   0.0 KB"` — always 9 characters (`%6.1f` + space + 2-letter unit).
    /// `%6.1f` covers `1023.9` so KB→MB never adds a digit.
    static func bytes(_ b: Int64) -> String {
        let (n, unit) = scaled(b)
        return String(format: "%6.1f %@", n, unit)
    }

    /// Menu-bar density: `"   0.0K"` — always 7 characters.
    static func compact(_ b: Int64) -> String {
        let (n, unit) = scaled(b)
        return String(format: "%6.1f%@", n, String(unit.prefix(1)))
    }

    /// Connection count `"   0"`…`"9999"` — always 4 characters.
    static func connections(_ n: Int) -> String {
        String(format: "%4d", min(max(n, 0), 9999))
    }

    private static func scaled(_ b: Int64) -> (Double, String) {
        let n = Double(abs(b))
        let kb = 1024.0
        if n < kb * kb { return (n / kb, "KB") }
        if n < kb * kb * kb { return (n / (kb * kb), "MB") }
        if n < kb * kb * kb * kb { return (n / (kb * kb * kb), "GB") }
        return (n / (kb * kb * kb * kb), "TB")
    }
}

// MARK: - Core manager

/// Manages the mihomo (Clash.Meta) kernel process and its REST API, following
/// clash-verge-rev's CoreManager model: generate runtime config → spawn
/// `mihomo -d <dir> -f <config>` → poll `/version` until ready → talk to the
/// external controller for proxies / delays / traffic. The system proxy and
/// TUN lifecycles live in VpnManager; this file is the core only.
@MainActor
final class VpnManager: ObservableObject {
    static let shared = VpnManager()

    enum State: Equatable {
        case idle          // not enabled
        case missingCore   // no mihomo binary
        case starting
        case running
        case failed(String)
    }

    /// Structured VPN errors — `state == .failed(err.logMessage)` always
    /// carries one of these, so the UI never shows a bare "意外退出".
    enum VpnError: Equatable {
        case coreMissing                       // binary not found
        case coreNotExecutable(String)         // chmod needed; carries path
        case coreCrashed(exitCode: Int32, fatalLine: String?)  // abnormal exit
        /// API never answered. `diagnosis` is the last fatal/`listen` error
        /// the core logged, if any — usually "address already in use" from
        /// another proxy app holding our ports.
        case coreStartTimeout(diagnosis: String?)
        case configWriteFailed(String)         // can't write config.yaml
        case spawnFailed(String)               // Process.run threw

        var logMessage: String {
            switch self {
            case .coreMissing:
                return "未找到 mihomo 内核"
            case .coreNotExecutable(let path):
                return "内核无执行权限：\(path)（需 chmod +x）"
            case .coreCrashed(let code, let fatal):
                if let fatal = fatal, !fatal.isEmpty {
                    return "内核意外退出（code=\(code)）：\(fatal)"
                }
                return "内核意外退出（code=\(code)），详见 core.log"
            case .coreStartTimeout(let diagnosis):
                if let diagnosis, !diagnosis.isEmpty {
                    return "内核未响应（15s）：\(diagnosis)"
                }
                return "内核启动超时（15s 内未响应 API）"
            case .configWriteFailed(let msg):
                return "写入配置失败：\(msg)"
            case .spawnFailed(let msg):
                return "启动内核失败：\(msg)"
            }
        }
    }

    @Published var state: State = .idle
    /// Set when `startCore()` refused to launch because another listener owns
    /// a port the core needs; the UI shows an actionable alert for it. Cleared
    /// on the next successful start.
    @Published var portConflict: PortConflict? = nil
    @Published var proxies: [VpnProxy] = []
    @Published var groups: [VpnGroup] = []
    @Published var coreVersion: String? = nil
    /// Nodes currently in a delay test — UI shows a spinner per name.
    @Published private(set) var testingNodes: Set<String> = []

    private var process: Process?
    private var readinessTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var trafficStreamTask: Task<Void, Never>?
    private var failoverTask: Task<Void, Never>?
    private var failoverLogOffset: UInt64 = 0
    /// Where `core.log` ended when the current core was spawned. `extractFatal`
    /// reads forward from here so a *previous* run's port conflict is never
    /// attributed to this one.
    private static var coreLogTailOffset: UInt64 = 0
    /// Owns the core's stdout/stderr file. Held as a file descriptor rather
    /// than re-opened by path on every write, so the log can be rotated
    /// underneath it (`core.log` reached 86 MB on this machine, appended to
    /// forever, with nothing ever reading more than its last 16 KB).
    private let coreLogFD = CoreLogWriter(url: FilePaths.vpnCoreLogFile)
    private let vpnLogWriter = CoreLogWriter(url: FilePaths.vpnLogFile)
    /// Generation of `coreLogFD` that `failoverLogOffset` was measured
    /// against. A rotation invalidates the offset; the ticker resyncs instead
    /// of seeking past the new end of file forever.
    private var failoverLogGeneration: UInt64 = 0
    private var failoverHits: [Date] = []
    private var lastFailoverAt: Date?
    private var failoverInFlight = false
    private var lastTrafficSampleAt: Date?
    private var lastConnTotals: (up: Int64, down: Int64, at: Date)?
    private var trafficHandshakeLogged = false
    private var stderrPipe: Pipe?
    private var launchTask: Task<Void, Never>?
    /// Config file marker so the core log is traceable, like
    /// clash-verge's `# Generated by Clash Verge` header.
    private(set) var controllerPort = 9097

    /// Ring buffer of recent VPN log lines (events + core stderr), shown in
    /// VPNView and persisted to vpn.log.
    @Published private(set) var logLines: [String] = []
    private static let maxLogLines = 500

    /// Append to the in-app log ring and the on-disk vpn.log. The ring is
    /// capped; the file now is too (see `CoreLogWriter`).
    func log(_ line: String) {
        let stamped = "[\(Self.timestamp(Date()))] \(line)"
        logLines.append(stamped)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
        vpnLogWriter.append(Data((stamped + "\n").utf8))
    }

    /// Log a structured error and reflect it in state.
    private func fail(_ err: VpnError) {
        log("ERROR: \(err.logMessage)")
        state = .failed(err.logMessage)
    }

    private static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private let subscriptions = VpnSubscriptionStore.shared
    private var prefs: AppPreferences { AppPreferences.shared }

    /// Delay of a menu item: leaf history, or the nested group's current leaf.
    func resolvedDelay(_ name: String?) -> Int? {
        guard var cursor = name, !cursor.isEmpty else { return nil }
        var seen = Set<String>()
        while !cursor.isEmpty, !seen.contains(cursor) {
            seen.insert(cursor)
            if let proxy = proxies.first(where: { $0.name == cursor }) {
                return proxy.delay
            }
            if let group = groups.first(where: { $0.name == cursor }) {
                cursor = group.current
            } else {
                break
            }
        }
        return nil
    }

    var isRunning: Bool { state == .running }

    /// Groups that actually take MATCH / default traffic. Airport profiles
    /// (mitce) use `主代理`; clash-verge's template uses GLOBAL.
    static let primaryGroupNames = [
        "主代理", "GLOBAL", "PROXY", "Proxy", "代理", "节点选择", "🚀 节点选择",
    ]

    var primaryGroup: VpnGroup? {
        for name in Self.primaryGroupNames {
            if let g = groups.first(where: { $0.name == name }) { return g }
        }
        return groups.first(where: { $0.type == "Selector" })
    }

    /// Walk Selector/URLTest nesting from the primary group to the leaf.
    /// Only this path is the live outbound — other groups remember a `now`
    /// without carrying default traffic.
    var livePath: [String] {
        guard let start = primaryGroup else { return [] }
        var path = [start.name]
        var seen: Set<String> = [start.name]
        var cursor = start.current
        while !cursor.isEmpty, !seen.contains(cursor) {
            path.append(cursor)
            seen.insert(cursor)
            if let next = groups.first(where: { $0.name == cursor }) {
                cursor = next.current
            } else {
                break
            }
        }
        return path
    }

    var liveLeafName: String? { livePath.last }

    /// Best-effort label for the currently selected outbound node.
    var activeNodeName: String? { liveLeafName }

    /// Port to route profile downloads through (nil unless running).
    var mixedPortIfRunning: Int? { isRunning ? prefs.vpnMixedPort : nil }

    private init() {
        subscriptions.manager = self
    }

    // MARK: Lifecycle

    /// Copy the mihomo binary bundled in Resources (if any) to the vpn dir.
    /// Done once per app version so users never hand-place the binary —
    /// same as clash-verge-rev shipping the core as a Tauri sidecar.
    nonisolated private static func extractBundledCoreIfNeeded(bundled: URL?, dest: URL) {
        guard let bundled else { return }
        let fm = FileManager.default
        var bundledSize: UInt64 = 0
        if let attr = try? fm.attributesOfItem(atPath: bundled.path),
           let s = attr[.size] as? UInt64 { bundledSize = s }
        var destSize: UInt64 = 0
        if let attr = try? fm.attributesOfItem(atPath: dest.path),
           let s = attr[.size] as? UInt64 { destSize = s }
        guard !fm.fileExists(atPath: dest.path) || destSize != bundledSize else { return }
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: bundled, to: dest)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    /// Called at app start and whenever settings change. Idempotent.
    /// SIGTERM any core still running out of our own VPN directory.
    ///
    /// Matching on the executable path is what makes this safe: it only ever
    /// touches a process started from `~/Library/Application Support/ClaudeBar/
    /// vpn/mihomo` by this app's own earlier instance, never a Clash Verge /
    /// ClashX core with its own data directory. Signals are skipped for our
    /// own pid so a live `process` handle is always the one that stops it.
    nonisolated private static func reapOrphanCore() {
        let me = getpid()
        var pids = [pid_t](repeating: 0, count: 256)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return }
        let mine = Self.corePath
        for pid in pids where pid > 0 {
            guard pid != me, let path = Self.executablePath(of: pid), path == mine else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// `~/Library/Application Support/ClaudeBar/vpn/mihomo` — the path the
    /// bundled core is copied to by `extractBundledCoreIfNeeded`.
    nonisolated private static let corePath: String = FilePaths.vpnCoreBin.path

    /// A listener already holding a port the core needs.
    struct PortConflict: Equatable {
        let port: Int
        /// Human label for whoever holds it (`Clash Verge`, `mihomo`, …), when
        /// we can attribute it. Never a reason to act — see `portConflict`.
        let owner: String?
        /// True when the holder is *our own* core (the path-matched orphan the
        /// reaper already tried to kill). Advisory only.
        let isOurOwnCore: Bool
    }

    /// Is anything already listening on the ports this core needs?
    ///
    /// Ports were previously handed to mihomo blind. When another Clash-family
    /// app owns them (Clash Verge's `verge-mihomo` on 7890/9097 on this
    /// machine) the core still *starts* and still writes its log — it just
    /// fails to bind, keeps running with no API, and the readiness poll
    /// eventually reports a bare "内核启动超时". The user has no way to learn
    /// that a different app is in the way.
    ///
    /// This probes and reports; it deliberately does **not** kill the holder.
    /// An earlier design offered to "顶掉" the occupant, which meant this app
    /// SIGTERM-ing a Clash Verge core it did not start — a cross-app action
    /// the user never asked for, on a process whose traffic they may be
    /// actively using. Reaping stays scoped to our own binary
    /// (`reapOrphanCore`); a foreign listener is the user's call to make.
    nonisolated static func portConflict(mixedPort: Int, controllerPort: Int) -> PortConflict? {
        for port in [mixedPort, controllerPort] where port > 0 {
            guard let pid = listenerPID(on: port) else { continue }
            let path = executablePath(of: pid)
            return PortConflict(port: port,
                                owner: path.map { URL(fileURLWithPath: $0).lastPathComponent },
                                isOurOwnCore: path == corePath)
        }
        return nil
    }

    /// One-line version of `VPNView`'s alert body, for the status line and the
    /// log. The view owns the long-form explanation.
    nonisolated static func conflictMessage(_ conflict: PortConflict) -> String {
        if let owner = conflict.owner {
            return "端口 \(conflict.port) 被「\(owner)」占用，内核未启动"
        }
        return "端口 \(conflict.port) 被占用，内核未启动"
    }

    /// Is nothing listening on `port`? Used to pick a replacement mixed port.
    nonisolated static func isPortFree(_ port: Int) -> Bool {
        listenerPID(on: port) == nil
    }

    /// PID of whoever is listening on `port`, or nil when it is free.    ///
    /// `lsof` rather than a Swift `bind()` probe: a successful bind would tell
    /// us only *that* the port is taken, while the dialog needs to name the
    /// occupant. One `lsof` spawn per start attempt is nothing next to the
    /// core launch that follows it.
    nonisolated private static func listenerPID(on port: Int) -> pid_t? {
        let result = Process.runAndRead("/usr/sbin/lsof",
                                        args: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        guard result.status == 0 else { return nil }
        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .first
    }

    nonisolated private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    func syncRuntime() {
        if prefs.vpnEnabled {
            startCore()
        } else {
            stopCore()
            VpnSystemProxyController.clearSystemProxyAsync()
        }
    }

    func startCore() {
        guard process == nil else { return }
        guard launchTask == nil else { return }
        // A previously crashed or force-quit ClaudeBar leaves the core
        // running with PPID 1: there is no termination hook, so
        // `stopCore()` never runs on quit. `process` is nil in the new
        // instance, so it spawns a second core on the same ports — the new
        // one dies at startup and, because the TUN marker and the system
        // proxy are still applied, traffic keeps flowing through a process
        // nothing controls. Reap the orphan before spawning.
        Self.reapOrphanCore()
        // Only *our* core is reaped. If anything else still holds the ports,
        // spawning is guaranteed to produce a core that boots, fails to bind,
        // and then sits there until the readiness poll gives up — so check
        // first and report it instead of starting a doomed process.
        if let conflict = Self.portConflict(mixedPort: prefs.vpnMixedPort, controllerPort: controllerPort) {
            portConflict = conflict
            let owner = conflict.owner.map { "（\($0)）" } ?? ""
            log("端口被占用：\(conflict.port)\(owner)，未启动内核")
            // The module stays *enabled*: the user asked for it and the reason
            // it is not running is external. Flipping `vpnEnabled` off here
            // would silently rewrite their preference on the next launch.
            state = .failed(Self.conflictMessage(conflict))
            return
        }
        portConflict = nil
        state = .starting
        let profileURL = subscriptions.activeID.map { subscriptions.profileURL($0) }
        let dest = FilePaths.vpnCoreBin
        let bundled = Bundle.main.url(forResource: "mihomo-core", withExtension: nil)
        let configURL = FilePaths.vpnConfigFile
        let vpnDir = FilePaths.vpnDir.path
        let tun = prefs.vpnTunEnabled
        let sysproxy = prefs.vpnSystemProxyEnabled
        let controller = controllerPort
        AppPreferences.ensureVpnControllerSecret()

        launchTask = Task.detached(priority: .userInitiated) { [weak self] in
            Self.extractBundledCoreIfNeeded(bundled: bundled, dest: dest)
            guard FileManager.default.fileExists(atPath: dest.path) else {
                await MainActor.run { [weak self] in
                    self?.fail(.coreMissing)
                    VpnSystemProxyController.clearSystemProxyAsync()
                    self?.launchTask = nil
                }
                return
            }
            guard FileManager.default.isExecutableFile(atPath: dest.path) else {
                await MainActor.run { [weak self] in
                    self?.fail(.coreNotExecutable(dest.path))
                    self?.launchTask = nil
                }
                return
            }
            let profile = profileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let geoNote = await VpnGeodata.ensureGeoSite(profileText: profile)
            let t0 = Date()
            let text = VpnConfigBuilder.build(profileText: profile, prefs: AppPreferences.shared)
            do {
                try text.write(to: configURL, atomically: true, encoding: .utf8)
            } catch {
                await MainActor.run { [weak self] in
                    self?.fail(.configWriteFailed(error.localizedDescription))
                    self?.launchTask = nil
                }
                return
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            await MainActor.run { [weak self] in
                if let geoNote { self?.log(geoNote) }
                self?.log("配置已写入 \(ms)ms · \(text.utf8.count / 1024) KB")
                self?.log("启动内核：\(dest.path) (controller:\(controller), tun:\(tun), sysproxy:\(sysproxy))")
                self?.spawnProcess(bin: dest, dir: vpnDir, config: configURL)
                self?.launchTask = nil
            }
        }
    }

    private func spawnProcess(bin: URL, dir: String, config: URL) {
        guard process == nil else { return }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["-d", dir, "-f", config.path]

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        stderrPipe = errPipe
        // Snapshot where the log ended *before* this core's first byte lands.
        // A core that starts wrong and exits immediately has already closed
        // its pipes by the time `terminationHandler` runs, so the reason is
        // only recoverable by reading the file from this offset — and the
        // reason is the whole point: mihomo reports a port conflict at
        // *error* level and keeps running with no API, which our readiness
        // poll then reports as a bare "启动超时".
        Self.coreLogTailOffset = Self.tailOffset(of: FilePaths.vpnCoreLogFile)
        // The core writes connection failures, retries and DNS errors at
        // whatever `log-level` the profile sets, for the whole time it runs.
        // Nothing reads this file except the tail in `extractFatal` and the
        // failover offset, so an unbounded append is pure disk growth — 86 MB
        // on this machine before this landmine was defused. Rotate at 8 MB,
        // keep the tail, never block the reader.
        coreLogFD.rotateIfNeeded()
        let coreLog = coreLogFD
        for pipe in [outPipe, errPipe] {
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { fh.readabilityHandler = nil; return }
                coreLog.append(data)
            }
        }

        proc.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.process === proc else { return }
                self.readinessTask?.cancel()
                self.process = nil
                self.stopPolling()
                guard self.prefs.vpnEnabled, self.state != .idle else { return }
                let stderr = self.readPipe(self.stderrPipe)
                self.log("内核退出：code=\(code) stderr=\(stderr.isEmpty ? "(空)" : stderr)")
                let fatal = Self.extractFatal(stderr: stderr)
                self.fail(.coreCrashed(exitCode: code, fatalLine: fatal))
            }
        }
        do {
            try proc.run()
        } catch {
            fail(.spawnFailed(error.localizedDescription))
            return
        }
        process = proc

        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            await self?.waitUntilReady()
        }
    }

    private func readPipe(_ pipe: Pipe?) -> String {
        guard let pipe, let data = try? pipe.fileHandleForReading.readDataToEndOfFile(),
              !data.isEmpty else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Last `level=fatal` (or `level=error` "listen") message the core wrote
    /// since `coreLogTailOffset`.
    ///
    /// Errors matter as much as fatals here: the failure this most often has
    /// to explain is "the core is alive but its API never answered", and the
    /// reason for that is an `error` line the core printed seconds earlier —
    /// `listen tcp 127.0.0.1:9097: bind: address already in use` when another
    /// Clash-family app holds the controller / mixed port. Reporting the
    /// timeout alone sent us hunting through an 86 MB log by hand.
    private static func extractFatal(stderr: String) -> String? {
        if let line = fatalLine(in: stderr) { return line }
        let path = FilePaths.vpnCoreLogFile.path
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let end = fh.seekToEndOfFile()
        let start = max(Self.coreLogTailOffset, end > 64_000 ? end - 64_000 : 0)
        guard start < end else { return nil }
        fh.seek(toFileOffset: start)
        let data = fh.readDataToEndOfFile()
        return fatalLine(in: String(decoding: data, as: UTF8.self))
    }

    /// Slice the core's log to what this process breed wrote and hand it to
    /// `fatalLine`. Used when a core dies at startup: the pipes are gone by
    /// then, so the file is the only witness.
    private static func logDiagnosis() -> String? {
        extractFatal(stderr: "")
    }

    /// Byte offset this core's log output starts at. Read once per core
    /// launch, before the first byte of that core lands, so `extractFatal`
    /// never attributes a *previous* run's port conflict to this one.
    private static func tailOffset(of url: URL) -> UInt64 {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return 0 }
        defer { try? fh.close() }
        return fh.seekToEndOfFile()
    }

    private static func fatalLine(in text: String) -> String? {
        let lines = text.split(separator: "\n").map(String.init)
        if let fatal = lines.reversed().first(where: { $0.contains("level=fatal") }) {
            return message(of: fatal)
        }
        // "listen ... address already in use" *is* the fatal condition, even
        // though mihomo logs it at error level (it keeps running with no API
        // and no inbound ports).
        if let bind = lines.reversed().first(where: {
            $0.contains("level=error") && $0.contains("listen")
        }) {
            return message(of: bind)
        }
        return nil
    }

    private static func message(of line: String) -> String {
        guard let msg = line.split(separator: " msg=", maxSplits: 1).last else { return line }
        return String(msg).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Stop the core. Returns the terminated process (nil when none was
    /// running) so a caller that is about to start a replacement can wait for
    /// the ports to come free — see `reloadConfig`.
    /// - Parameters:
    ///   - clearLists: wipe the mosaic. Keep the last groups during a
    ///     subscription reload so the page does not flash empty and hitch.
    ///   - resetProbe: drop the cached exit IP. Keep it across reloads so
    ///     the IP slot does not collapse while the core comes back.
    @discardableResult
    func stopCore(clearLists: Bool = true, resetProbe: Bool = true) -> Process? {
        launchTask?.cancel()
        launchTask = nil
        portConflict = nil
        log("停止内核")
        readinessTask?.cancel()
        stopPolling()
        let old = process
        if let proc = old {
            proc.terminationHandler = nil
            proc.terminate()
            // Give it a moment, then force kill (mihomo handles SIGTERM).
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak proc] in
                if proc?.isRunning == true { proc?.terminate() }
            }
        }
        process = nil
        state = prefs.vpnEnabled ? .failed("已停止") : .idle
        if clearLists {
            proxies = []
            groups = []
        }
        VpnLiveRates.shared.reset()
        lastConnTotals = nil
        lastTrafficSampleAt = nil
        trafficHandshakeLogged = false
        coreVersion = nil
        if resetProbe { VpnNetProbe.shared.reset() }
        return old
    }

    /// Restart the core (port / TUN / subscription change). Safe when idle.
    ///
    /// The replacement must not spawn until the old core has released
    /// `external-controller` (9097) and `mixed-port` (7890): mihomo reports
    /// "address already in use" for both and then sits there bound to
    /// nothing, so `/version` never answers and the page shows 内核启动超时.
    /// Waiting on the main actor here would freeze the UI, so hand the wait
    /// to a task and yield while the process exits.
    /// Retry after the user cleared a port conflict (or fixed whatever caused
    /// it). `startCore` re-probes, so this is just "try again now" — it must
    /// not be routed through `reloadConfig`, which early-returns when
    /// `vpnEnabled` is false (the state a failed start leaves behind).
    func retryStart() {
        guard process == nil, launchTask == nil else { return }
        portConflict = nil
        startCore()
    }

    func reloadConfig() {
        guard prefs.vpnEnabled else { return }
        launchTask?.cancel()
        launchTask = nil
        let old = stopCore(clearLists: false, resetProbe: false)
        state = .starting
        Task { @MainActor [weak self] in
            await Self.awaitExit(old)
            self?.startCore()
        }
    }

    /// Yield until the process is gone (or ~5s, in case it is wedged).
    private static func awaitExit(_ proc: Process?) async {
        guard let proc else { return }
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: Readiness (poll /version, like clash-verge's poll_sidecar_readiness)

    private func waitUntilReady() async {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if Task.isCancelled { return }
            if let v = try? await api("GET", "/version") as [String: Any] {
                coreVersion = v["version"] as? String
                state = .running
                log("内核就绪：version=\(coreVersion ?? "?")")
                startPolling()
                if prefs.vpnSystemProxyEnabled {
                    VpnSystemProxyController.applySystemProxy(port: prefs.vpnMixedPort)
                    if prefs.vpnGuardEnabled { VpnProxyGuard.shared.start() }
                }
                if prefs.vpnTunEnabled { VpnTunDnsHelper.setSystemDNS() }
                await refreshProxies()
                subscriptions.startAutoRefresh()
                Task { await VpnNetProbe.shared.refreshIP() }
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if !Task.isCancelled {
            // Read the core's own log from *this* launch's offset: a core that
            // cannot bind its controller / mixed port logs an error and then
            // sits there silently, which is exactly the state this timeout
            // describes. Without the diagnosis the user sees "启动超时" and has
            // no way to learn that another proxy app owns the port.
            fail(.coreStartTimeout(diagnosis: Self.logDiagnosis()))
        }
    }

    // MARK: External controller API

    private func api(_ method: String, _ path: String,
                     body: Data? = nil, query: [String: String] = [:],
                     timeout: TimeInterval = 20) async throws -> [String: Any] {
        var comps = URLComponents(string: "http://127.0.0.1:\(controllerPort)\(path)")!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if !prefs.vpnControllerSecret.isEmpty {
            req.setValue("Bearer \(prefs.vpnControllerSecret)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await VpnHTTP.session().data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func apiResponse(_ method: String, _ path: String,
                             body: Data? = nil, query: [String: String] = [:],
                             timeout: TimeInterval = 20) async throws -> (status: Int, json: [String: Any], raw: String) {
        var comps = URLComponents(string: "http://127.0.0.1:\(controllerPort)\(path)")!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if !prefs.vpnControllerSecret.isEmpty {
            req.setValue("Bearer \(prefs.vpnControllerSecret)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await VpnHTTP.session().data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let raw = String(decoding: data, as: UTF8.self)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (http.statusCode, json, raw)
    }

    // MARK: Proxies

    /// Load groups + leaf nodes from /proxies, tagging the selected node.
    func refreshProxies() async {
        guard isRunning else { return }
        guard let root = try? await api("GET", "/proxies") else { return }
        let parsed: (groups: [VpnGroup], proxies: [VpnProxy]) = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Self.parseProxyTree(root))
            }
        }
        if proxies != parsed.proxies { proxies = parsed.proxies }
        if groups != parsed.groups { groups = parsed.groups }
    }

    nonisolated private static func parseProxyTree(_ root: [String: Any]) -> (groups: [VpnGroup], proxies: [VpnProxy]) {
        guard let all = root["proxies"] as? [String: Any] else { return ([], []) }
        var groupsOut: [VpnGroup] = []
        var nodeNames = Set<String>()
        var details: [String: (type: String, server: String, port: Int, history: [Int])] = [:]
        let groupTypes = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]
        for (name, raw) in all {
            guard let obj = raw as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            if groupTypes.contains(type) {
                let nodes = (obj["all"] as? [String]) ?? []
                let current = obj["now"] as? String ?? ""
                groupsOut.append(VpnGroup(name: name, type: type, nodes: nodes, current: current))
            } else if type != "Direct" && type != "Reject" && type != "Compatible" && type != "Pass" {
                let server = obj["server"] as? String ?? ""
                let port = obj["port"] as? Int ?? 0
                let history = ((obj["history"] as? [[String: Any]]) ?? []).compactMap { h -> Int? in
                    guard h["delay"] != nil else { return nil }
                    return JSONCoerce.intVal(h["delay"])
                }
                details[name] = (type, server, port, history)
                nodeNames.insert(name)
            }
        }
        groupsOut.sort { $0.name < $1.name }
        var currentNodes = Set<String>()
        for g in groupsOut { currentNodes.insert(g.current) }
        let proxiesOut: [VpnProxy] = nodeNames.sorted().map { name in
            let d = details[name]!
            return VpnProxy(
                name: name, type: d.type, server: d.server, port: d.port,
                delay: d.history.last,
                isCurrent: currentNodes.contains(name))
        }
        return (groupsOut, proxiesOut)
    }

    /// Switch a selector group's node. Optimistic local `current` so the
    /// mosaic moves immediately; then PUT. If the group isn't the primary
    /// selector but the primary can point at it, also switch the primary so
    /// MATCH traffic actually follows (clash-verge "use this node").
    func selectNode(group: String, node: String) async -> Bool {
        setCurrent(group: group, node: node)
        let ok = await putProxy(group: group, node: node)
        if !ok {
            log("切换节点失败：\(group) → \(node)")
            await refreshProxies()
            return false
        }
        if let primary = primaryGroup, primary.name != group, primary.nodes.contains(group) {
            setCurrent(group: primary.name, node: group)
            if !(await putProxy(group: primary.name, node: group)) {
                log("切换主代理失败：\(primary.name) → \(group)")
            }
        }
        // Do not refreshProxies() here: replacing the whole mosaic array is
        // the hitch on every node tap. Optimistic `current` is already set.
        Task { await VpnNetProbe.shared.refreshIP(afterNodeSwitch: true) }
        return true
    }

    private func setCurrent(group: String, node: String) {
        if let i = groups.firstIndex(where: { $0.name == group }) {
            groups[i].current = node
        }
    }

    private func putProxy(group: String, node: String) async -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: ["name": node]) else { return false }
        do {
            _ = try await api("PUT", "/proxies/\(Self.pathEscape(group))", body: body)
            return true
        } catch {
            return false
        }
    }

    /// clash-verge default: Cloudflare generate_204 + 10s. gstatic over HTTPS
    /// with `unified-delay` does two HEAD round-trips; a 5s budget often
    /// returns delay=0 even when the node can browse.
    nonisolated static let delayTestURL = "http://cp.cloudflare.com/generate_204"
    nonisolated static let delayTestTimeoutMs = 10_000

    /// Delay test for one node via a group (mihomo requires a group URL).
    func testDelay(node: String, timeout: Int = 10_000) async -> Int? {
        testingNodes.insert(node)
        defer { testingNodes.remove(node) }
        log("测速开始 node=\(node) url=\(Self.delayTestURL) timeout=\(timeout)ms")
        do {
            let (status, obj, raw) = try await apiResponse(
                "GET", "/proxies/\(Self.pathEscape(node))/delay",
                query: ["timeout": "\(timeout)", "url": Self.delayTestURL],
                timeout: TimeInterval(timeout) / 1000 + 8)
            let delay = JSONCoerce.intVal(obj["delay"])
            let message = (obj["message"] as? String) ?? ""
            if delay > 0 {
                log("测速成功 node=\(node) delay=\(delay)ms http=\(status)")
            } else {
                log("测速超时 node=\(node) http=\(status) delay=\(delay) message=\(message.isEmpty ? "(空)" : message) raw=\(raw)")
            }
            let stored = delay > 0 ? delay : 0
            if let idx = proxies.firstIndex(where: { $0.name == node }) {
                proxies[idx].delay = stored
            }
            return delay > 0 ? delay : nil
        } catch {
            log("测速失败 node=\(node) error=\(error.localizedDescription)")
            if let idx = proxies.firstIndex(where: { $0.name == node }) {
                proxies[idx].delay = 0
            }
            return nil
        }
    }

    /// Test leaf nodes in a group. Large groups (主代理 has 50+ leaves plus
    /// nested url-test/load-balance) cannot share one 10s budget — mihomo
    /// fires every member at once, VLESS/gRPC lose the race, and browsing
    /// through the live node stalls. Batch the leaves instead.
    func testGroupDelay(group: String) async {
        let leaves = leafNames(in: group)
        log("组测速开始 group=\(group) leaves=\(leaves.count) url=\(Self.delayTestURL) timeout=\(Self.delayTestTimeoutMs)ms")
        guard !leaves.isEmpty else {
            log("组测速跳过 group=\(group) 没有叶子节点（组内全是嵌套分组）")
            return
        }

        let batchSize = 6
        if leaves.count <= 12 {
            await testGroupDelayOnce(group: group, expectedLeaves: leaves)
        } else {
            log("组测速分批 group=\(group) batch=\(batchSize) （避免一次打满出口）")
            var i = 0
            while i < leaves.count {
                let chunk = Array(leaves[i..<min(i + batchSize, leaves.count)])
                log("组测速批次 \(i / batchSize + 1)/\((leaves.count + batchSize - 1) / batchSize) nodes=\(chunk.joined(separator: ","))")
                await withTaskGroup(of: Void.self) { tg in
                    for name in chunk {
                        tg.addTask { _ = await self.testDelay(node: name) }
                    }
                }
                i += batchSize
            }
        }
        logGroupDelaySummary(group: group, leaves: leaves)
    }

    private func testGroupDelayOnce(group: String, expectedLeaves: [String]) async {
        testingNodes.formUnion(expectedLeaves)
        defer { testingNodes.subtract(expectedLeaves) }
        do {
            let (status, obj, raw) = try await apiResponse(
                "GET", "/group/\(Self.pathEscape(group))/delay",
                query: ["timeout": "\(Self.delayTestTimeoutMs)", "url": Self.delayTestURL],
                timeout: 180)
            log("组测速结束 group=\(group) http=\(status) keys=\(obj.keys.sorted().count) rawPrefix=\(raw.prefix(240))")
            applyDelayMap(obj, leaves: expectedLeaves)
        } catch {
            log("组测速失败 group=\(group) error=\(error.localizedDescription)")
        }
    }

    private func leafNames(in group: String) -> [String] {
        let names = groups.first(where: { $0.name == group })?.nodes ?? []
        let leaves = Set(proxies.map(\.name))
        return names.filter { leaves.contains($0) }
    }

    private func applyDelayMap(_ map: [String: Any], leaves: [String]) {
        let leafSet = Set(leaves)
        for name in leaves {
            let delay = JSONCoerce.intVal(map[name])
            if let idx = proxies.firstIndex(where: { $0.name == name }) {
                proxies[idx].delay = delay > 0 ? delay : 0
            }
        }
        let extra = map.keys.filter { !leafSet.contains($0) }.sorted()
        if !extra.isEmpty {
            log("组测速含嵌套分组（不计入叶子超时） \(extra.joined(separator: ","))")
        }
    }

    private func logGroupDelaySummary(group: String, leaves: [String]) {
        let members = leaves.compactMap { name in proxies.first(where: { $0.name == name }) }
        let ok = members.filter { ($0.delay ?? 0) > 0 }
        let timedOut = members.filter { ($0.delay ?? 0) == 0 }.map(\.name)
        let okBits = ok.map { "\($0.name)=\($0.delay ?? 0)" }
        log("组测速汇总 group=\(group) 有延迟=\(ok.count) \(okBits.joined(separator: ","))")
        log("组测速汇总 group=\(group) 超时=\(timedOut.count)\(timedOut.isEmpty ? "" : " 节点=\(timedOut.joined(separator: ","))")")
    }

    private static func pathEscape(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Polling (traffic stream + connections snapshot)

    /// mihomo's GET `/traffic` is a never-ending chunked NDJSON stream
    /// (`{"up","down"}` once a second). A regular `URLSession.data` waits for
    /// EOF, hits the 20s timeout, and the UI stays at 0. Consume it as a
    /// persistent line iterator instead; `/connections` is a normal snapshot.
    private func startPolling() {
        stopPolling()
        trafficStreamTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                await self.consumeTrafficStream()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isRunning {
                    await self.pollConnections()
                }
                // The connection list is only rendered on the 流量 / VPN
                // pages and in the popup. With nothing on screen there is no
                // reason to hit the controller every 2s; the /traffic stream
                // (which feeds the menu-bar rates) is a push and keeps its
                // cadence regardless.
                let interval: UInt64 = UIWakePolicy.hasVisibleWindow ? 2 : 10
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
        let sizeNum = try? FileManager.default.attributesOfItem(
            atPath: FilePaths.vpnCoreLogFile.path)[.size] as? NSNumber
        failoverLogOffset = sizeNum?.uint64Value ?? 0
        failoverHits = []
        failoverTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isRunning {
                    await self.tickFailover()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        trafficStreamTask?.cancel()
        trafficStreamTask = nil
        failoverTask?.cancel()
        failoverTask = nil
    }
}

/// Append-only file that keeps itself under `maxBytes`.
///
/// Both VPN logs are diagnostics: the in-app ring shows the last 500 lines,
/// `extractFatal` reads the last 16 KB, and the failover ticker reads forward
/// from an offset. None of them need history, so an unbounded append is pure
/// disk growth — `core.log` had reached 86 MB and `vpn.log` 900 KB on this
/// machine. On rotation the tail is kept so a crash report written just before
/// the threshold survives.
///
/// `append` is called from the core's `readabilityHandler` (a background
/// thread); every mutation goes through `lock`. Rotation bumps `generation`
/// so a reader holding a byte offset can tell that its offset no longer
/// refers to the same file.
final class CoreLogWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    /// Bumped on every rotation — readers holding a byte offset use it to
    /// notice that their offset no longer refers to the same file.
    private var generationStorage: UInt64 = 0

    init(url: URL) {
        self.url = url
    }

    var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generationStorage
    }

    private var written: UInt64 = 0

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let handle = ensureHandle() else { return }
        // Track the byte count here instead of asking the file system on every
        // chunk. The core writes several lines per second, so every one of
        // them used to cost an `fstat` (and a `seekToEnd` syscall on the
        // handle) just to decide whether rotation was due.
        //
        // `rotateIfNeeded()` still stats the file once per core launch, which
        // is what catches a log that grew while this handle was closed — an
        // earlier run of the app, or another core holding the same file.
        if written > Self.maxBytes { rotateLocked() }
        written += UInt64(data.count)
        try? handle.write(contentsOf: data)
    }

    /// Stat the file and adopt its size. Called once before a core starts, so
    /// `written` never begins at zero over a log that is already at the cap.
    func rotateIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard let handle = ensureHandle() else { return }
        let size = (try? handle.seekToEnd()) ?? 0
        if size > Self.maxBytes {
            rotateLocked()
        } else {
            written = size
        }
    }

    // MARK: - Internals

    private static let maxBytes: UInt64 = 8 * 1024 * 1024
    private static let keepBytes: UInt64 = 512 * 1024

    private func ensureHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let opened = try? FileHandle(forWritingTo: url)
        // `handle.write` writes at the current offset, and a freshly opened
        // write handle starts at 0 — without this the log would be rewritten
        // from the top. Appends leave the offset at EOF, so seeking here (once
        // per open) is enough.
        _ = try? opened?.seekToEnd()
        handle = opened
        return opened
    }

    private func rotateLocked() {
        try? handle?.close()
        handle = nil
        let tail: Data = {
            guard let read = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? read.close() }
            let end = (try? read.seekToEnd()) ?? 0
            let start = end > Self.keepBytes ? end - Self.keepBytes : 0
            try? read.seek(toOffset: start)
            return (try? read.readToEnd()) ?? Data()
        }()
        try? tail.write(to: url, options: .atomic)
        written = UInt64(tail.count)
        generationStorage &+= 1
        _ = ensureHandle()
    }
}

extension VpnManager {
    /// Consecutive `i/o timeout` on the live leaf's server → switch 主代理
    /// to the lowest-delay HY2 / KR leaf. Cooldown 60s so a bad airport
    /// cannot flap every few seconds.
    private func tickFailover() async {
        guard !failoverInFlight else { return }
        let path = FilePaths.vpnCoreLogFile.path
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        // A rotation rewrites the file from its tail, so the byte offset we
        // were holding now points into the middle of unrelated text (or past
        // EOF). Resync instead of silently reading garbage forever.
        if failoverLogGeneration != coreLogFD.generation {
            failoverLogGeneration = coreLogFD.generation
            failoverLogOffset = 0
        }
        _ = try? fh.seek(toOffset: failoverLogOffset)
        let data = fh.readDataToEndOfFile()
        failoverLogOffset += UInt64(data.count)
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }

        let liveServer = proxies.first(where: { $0.name == liveLeafName })?.server ?? ""
        guard !liveServer.isEmpty else { return }

        let now = Date()
        for line in chunk.split(separator: "\n") {
            guard line.contains("i/o timeout") else { continue }
            guard line.contains(liveServer) else { continue }
            failoverHits.append(now)
        }
        failoverHits.removeAll { now.timeIntervalSince($0) > 25 }
        guard failoverHits.count >= 6 else { return }
        if let last = lastFailoverAt, now.timeIntervalSince(last) < 60 { return }

        guard let group = primaryGroup else { return }
        let current = liveLeafName ?? ""
        let leaves = leafNames(in: group.name)
        let ranked = leaves.compactMap { name -> (String, Int, Int)? in
            guard name != current, let p = proxies.first(where: { $0.name == name }) else { return nil }
            let delay = p.delay ?? 0
            guard delay > 0 else { return nil }
            let pref: Int
            if name.localizedCaseInsensitiveContains("HY2") { pref = 0 }
            else if name.localizedCaseInsensitiveContains("KR") { pref = 1 }
            else { pref = 2 }
            return (name, pref, delay)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }
        guard let next = ranked.first?.0 else { return }

        failoverInFlight = true
        lastFailoverAt = now
        failoverHits = []
        log("出口超时过多，自动切换 \(current) → \(next)")
        _ = await selectNode(group: group.name, node: next)
        failoverInFlight = false
    }

    private func consumeTrafficStream() async {
        let comps = URLComponents(string: "http://127.0.0.1:\(controllerPort)/traffic")!
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 86_400
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !prefs.vpnControllerSecret.isEmpty {
            req.setValue("Bearer \(prefs.vpnControllerSecret)", forHTTPHeaderField: "Authorization")
        }
        // Shared session (see VpnHTTP.session) — explicitly NOT invalidated
        // here: `invalidateAndCancel` on a cached session tears it down for
        // every other caller and forces the next poll to rebuild the pool.
        let session = VpnHTTP.session()
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                if !trafficHandshakeLogged {
                    log("流量流握手失败")
                    trafficHandshakeLogged = true
                }
                return
            }
            trafficHandshakeLogged = false
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                // bytes.lines can resume off the main actor; hop back so
                // @Published speeds actually refresh the menu bar + page.
                await MainActor.run { applyTrafficLine(line) }
            }
        } catch is CancellationError {
            return
        } catch {
            // Reconnect loop in startPolling; don't spam the log every second.
        }
    }

    private func applyTrafficLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let up = JSONCoerce.int64Val(obj["up"])
        let down = JSONCoerce.int64Val(obj["down"])
        lastTrafficSampleAt = Date()
        VpnLiveRates.shared.applyStream(up: up, down: down)
    }

    private func pollConnections() async {
        guard let c = try? await api("GET", "/connections") else { return }
        let conns = c["connections"] as? [[String: Any]] ?? []
        let activeConnections = conns.count

        // Root totals survive closed connections; summing the live array
        // drops to 0 whenever the pipe is idle.
        let hasRootTotals = c["downloadTotal"] != nil || c["uploadTotal"] != nil
        let totalDown: Int64
        let totalUp: Int64
        if hasRootTotals {
            totalDown = JSONCoerce.int64Val(c["downloadTotal"])
            totalUp = JSONCoerce.int64Val(c["uploadTotal"])
        } else {
            var up: Int64 = 0, down: Int64 = 0
            for conn in conns {
                down += JSONCoerce.int64Val(conn["download"])
                up += JSONCoerce.int64Val(conn["upload"])
            }
            totalDown = down
            totalUp = up
        }
        VpnLiveRates.shared.applyTotals(
            totalUp: totalUp, totalDown: totalDown, connections: activeConnections)

        // Fallback rate if the stream has gone silent (core without /traffic).
        let streamStale = Date().timeIntervalSince(lastTrafficSampleAt ?? .distantPast) > 3
        if streamStale, let prev = lastConnTotals {
            let dt = Date().timeIntervalSince(prev.at)
            if dt >= 0.5 {
                let derivedDown = Int64(Double(totalDown - prev.down) / dt)
                let derivedUp = Int64(Double(totalUp - prev.up) / dt)
                VpnLiveRates.shared.applyStream(
                    up: max(0, derivedUp), down: max(0, derivedDown))
            }
        }
        lastConnTotals = (up: totalUp, down: totalDown, at: Date())
    }
}
