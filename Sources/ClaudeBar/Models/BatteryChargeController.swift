import Foundation
import Darwin
import Observation

@MainActor
@Observable
final class BatteryChargeController {
    enum Mode: Int, CaseIterable, Identifiable {
        case system, limit, hold, discharge
        var id: Int { rawValue }
        /// Short label for the four buttons, in the order a user reasons about
        /// them: turn management on, charge, discharge, hand it back to macOS.
        ///
        /// `.hold` used to read "暂停充电", which is wrong twice over: the
        /// helper's `BAT_HOLD` means "charge up to the limit and hold there",
        /// not "stop charging", and "暂停" is near-synonymous with `.limit`'s
        /// old "充到上限" — two adjacent buttons a user could not tell apart.
        var label: String {
            switch self {
            case .system: return "还原系统"
            case .limit: return "启动管理"
            case .hold: return "充电"
            case .discharge: return "放电"
            }
        }

        /// Full sentence for the button's tooltip, where the short label's
        /// ambiguity is resolved.
        var title: String {
            switch self {
            case .system: return "还原系统充电管理"
            case .limit: return "启动充电上限管理"
            case .hold: return "充电到上限后保持"
            case .discharge: return "放电到上限"
            }
        }

        var symbol: String {
            switch self {
            case .system: return "arrow.counterclockwise"
            case .limit: return "bolt.fill"
            // A battery filling rather than a pause bar: `.hold` does charge.
            case .hold: return "battery.100percent.bolt"
            case .discharge: return "battery.50percent"
            }
        }
    }
    struct Status: Decodable {
        let revision: UInt64
        let mode: Int
        let limit: Int
        let state: Int
        let percent: Int
        let dischargeSupported: Bool
        let sleeping: Bool
        let error: String
    }
    private struct Capabilities: Decodable { let supported: Bool; let dischargeSupported: Bool }
    static let shared = BatteryChargeController()

    /// Lowest limit the privileged helper accepts — `policy.h` rejects
    /// `limit < 20`. Exposed so the slider cannot offer a value the helper
    /// would refuse, instead of hard-coding 20 in the view.
    static let minLimit: Double = 20
    private(set) var mode = Mode.system
    private(set) var state = 0
    private(set) var supported: Bool?
    private(set) var dischargeSupported = false
    private(set) var pending = false
    private(set) var helperInstalled = false
    private(set) var authorizingHelper = false
    private(set) var sleeping = false
    private(set) var lastError: String?
    var threshold: Double {
        didSet {
            let value = min(100, max(Self.minLimit, threshold.rounded()))
            if threshold != value { threshold = value }
            UserDefaults.standard.set(Int(value), forKey: "batteryChargeLimit")
        }
    }
    private(set) var appliedLimit = 80
    private var process: Process?
    private var input: FileHandle?
    private var timer: Timer?
    private var responseTimeout: Task<Void, Never>?
    private(set) var pendingMessage = "正在应用充电设置…"
    private var revision: UInt64 = 0
    private var generation = UUID()
    private var probing = false
    private var shuttingDown = false
    private var recoveryUnconfirmed = false
    private var restorationConfirmed = false

    private var resumeStarted = false

    private init() {
        let stored = UserDefaults.standard.object(forKey: "batteryChargeLimit") as? Int ?? 80
        threshold = Double(min(100, max(Int(Self.minLimit), stored)))
        if let raw = UserDefaults.standard.object(forKey: "batteryChargeMode") as? Int,
           let saved = Mode(rawValue: raw) {
            mode = saved
        }
    }

    func refreshHelperAuthorization() async {
        helperInstalled = await Task.detached(priority: .utility) {
            BatteryHelperInstaller.isInstalled()
        }.value
    }

    func authorizeHelper() {
        guard !authorizingHelper, !pending else { return }
        authorizingHelper = true
        lastError = nil
        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                BatteryHelperInstaller.installIfNeeded()
            }.value
            helperInstalled = await Task.detached(priority: .utility) {
                BatteryHelperInstaller.isInstalled()
            }.value
            lastError = failure
            authorizingHelper = false
        }
    }

    var statusText: String {
        if recoveryUnconfirmed { return "充电状态未确认 · 请检查电池状态" }
        if pending { return pendingMessage }
        if sleeping { return "休眠期间由系统管理" }
        if mode != .system && process == nil {
            return helperInstalled ? "正在恢复上次的充电管理…" : "上次的充电管理待恢复 · 点当前模式重新授权"
        }
        switch state {
        case 1: return "允许充电 · 上限 \(appliedLimit)%"
        case 2: return mode == .hold ? "已暂停充电" : "上限保持中 · 暂停充电"
        case 3: return "正在使用电池 · 放电至 \(appliedLimit)%"
        default: return "由 macOS 管理充电"
        }
    }

    func probe() {
        guard !probing, supported == nil else { return }
        probing = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> Data? in
                guard let url = BatteryHelperInstaller.bundledURL else { return nil }
                let process = Process(), output = Pipe()
                process.executableURL = url; process.arguments = ["--probe"]
                process.standardOutput = output; process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return process.terminationStatus == 0 ? data : nil
            }.value
            probing = false
            if let result, let capabilities = try? JSONDecoder().decode(Capabilities.self, from: result) {
                supported = capabilities.supported; dischargeSupported = capabilities.dischargeSupported
            } else { supported = false }
            resumePersistedMode()
        }
    }

    /// The last confirmed mode is the one the user left on. Quitting closes the
    /// helper, which hands the battery back to macOS; the next launch puts that
    /// mode back instead of leaving the controls on「还原系统」.
    private func resumePersistedMode() {
        guard !resumeStarted, mode != .system, supported == true else { return }
        resumeStarted = true
        Task {
            await refreshHelperAuthorization()
            guard helperInstalled, !shuttingDown, process == nil else { return }
            apply(mode)
        }
    }

    /// Whether dragging the limit slider should take effect immediately.
    ///
    /// True only once charge management is actually running: the helper owns a
    /// limit only in a managing mode, and system mode has no limit to change.
    /// Before the helper is up, a drag is just a stored preference — it must
    /// not silently start a privileged process.
    var managesLimit: Bool {
        process != nil && (mode == .limit || mode == .hold || mode == .discharge)
    }

    /// Whether the privileged helper is up at all, in any mode.
    var processIsRunning: Bool { process != nil }

    /// Re-send the current mode with a new limit, for a slider that applies as
    /// the user lets go. Unlike `apply(_:)` this never installs or starts the
    /// helper — that is the explicit "启动充电管理" action — and it drops the
    /// send while a previous one is still in flight, because the helper applies
    /// commands in revision order and a mid-drag flood would queue behind them.
    func setLimit(_ value: Int) {
        guard managesLimit, !shuttingDown else { return }
        let target = min(100, max(Int(Self.minLimit), value))
        guard target != appliedLimit else { return }
        // `pending` is not set here: the drag is continuous, and flipping the
        // busy state on every release would strobe the toolbar. The reply
        // updates `appliedLimit`, which is what the slider reads back.
        revision += 1
        send("set \(mode.rawValue) \(target) \(revision)\n")
    }

    func apply(_ requested: Mode) {
        guard !pending, !authorizingHelper, !shuttingDown else { return }
        // A disconnected child must finish recovery before another command.
        guard process == nil || input != nil else { return }
        if requested == .system && process == nil {
            mode = .system; state = 0; lastError = nil
            UserDefaults.standard.set(Mode.system.rawValue, forKey: "batteryChargeMode")
            return
        }
        guard requested == .system || supported == true else { return }
        guard requested != .discharge || dischargeSupported else { return }
        let target = Int(threshold)
        pending = true; lastError = nil
        pendingMessage = process == nil ? "正在检查辅助工具与系统授权…" : "正在应用充电设置…"
        Task {
            if process == nil {
                let failure = await Task.detached(priority: .userInitiated) { BatteryHelperInstaller.installIfNeeded() }.value
                guard !shuttingDown else { return }
                helperInstalled = failure == nil
                if let failure { lastError = failure; pending = false; return }
                pendingMessage = "正在连接电池控制…"
                do { try start() } catch { lastError = "无法启动电池控制：\(error.localizedDescription)"; pending = false; return }
            }
            revision += 1
            send("set \(requested.rawValue) \(target) \(revision)\n")
            if pending { awaitResponse() }
        }
    }

    /// Authorization can take as long as the user needs; only time the helper
    /// response after it has launched and received a command.
    private func awaitResponse() {
        responseTimeout?.cancel()
        let token = generation
        responseTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.generation == token, self.pending else { return }
            self.lastError = "电池控制响应超时，已断开控制连接；请检查充电状态后重试。"
            self.recoveryUnconfirmed = true
            self.pending = false
            self.timer?.invalidate(); self.timer = nil
            // EOF asks the helper to restore the original settings. Never
            // kill it while it may be performing that restoration.
            try? self.input?.close(); self.input = nil
        }
    }

    private func start() throws {
        let child = Process(), incoming = Pipe(), outgoing = Pipe()
        child.executableURL = URL(fileURLWithPath: BatteryHelperInstaller.path)
        child.arguments = ["--serve"]
        child.standardInput = incoming; child.standardOutput = outgoing
        child.standardError = FileHandle.nullDevice
        let token = UUID(); generation = token
        try child.run()
        // A failed helper must throw an I/O error, never SIGPIPE the app.
        _ = fcntl(incoming.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        incoming.fileHandleForReading.closeFile()
        outgoing.fileHandleForWriting.closeFile()
        input = incoming.fileHandleForWriting; process = child
        restorationConfirmed = false
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send("ping\n") }
        }
        let handle = outgoing.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                // POSIX read returns the bytes currently available in a pipe.
                // Foundation's length-based reads can wait to fill the buffer,
                // delaying small status lines across many two-second reports.
                let count = chunk.withUnsafeMutableBytes { bytes in
                    Darwin.read(handle.fileDescriptor, bytes.baseAddress!, bytes.count)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.append(contentsOf: chunk.prefix(count))
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    if let status = try? JSONDecoder().decode(Status.self, from: line) {
                        Task { @MainActor in self?.receive(status, token: token) }
                    }
                }
                if buffer.count > 65536 { break }
            }
            try? handle.close()
            child.waitUntilExit()
            Task { @MainActor in self?.ended(token: token, code: child.terminationStatus) }
        }
    }

    private func send(_ message: String) {
        do { try input?.write(contentsOf: Data(message.utf8)) }
        catch {
            lastError = "控制连接中断，辅助工具将恢复系统管理。"
            pending = false
            recoveryUnconfirmed = true
            responseTimeout?.cancel(); responseTimeout = nil
            timer?.invalidate(); timer = nil
            try? input?.close(); input = nil
        }
    }

    private func receive(_ status: Status, token: UUID) {
        guard generation == token else { return }
        dischargeSupported = status.dischargeSupported
        if !status.error.isEmpty { lastError = Self.message(for: status.error) }
        if status.error == "restore_failed" { recoveryUnconfirmed = true }
        restorationConfirmed = status.mode == 0 && status.state == 0 && status.error != "restore_failed"
        guard status.revision >= revision else { return }
        mode = Mode(rawValue: status.mode) ?? .system
        state = status.state; appliedLimit = status.limit; sleeping = status.sleeping
        pending = false
        responseTimeout?.cancel(); responseTimeout = nil
        if status.error.isEmpty {
            recoveryUnconfirmed = false
            UserDefaults.standard.set(mode.rawValue, forKey: "batteryChargeMode")
        }
    }

    private func ended(token: UUID, code: Int32) {
        guard generation == token else { return }
        responseTimeout?.cancel(); responseTimeout = nil
        timer?.invalidate(); timer = nil
        try? input?.close(); input = nil; process = nil
        mode = .system; state = 0; sleeping = false; pending = false
        if code != 0 && !restorationConfirmed { recoveryUnconfirmed = true }
        if code != 0 && lastError == nil { lastError = "电池控制异常停止（\(code)），请检查充电状态后重新启用。" }
    }

    /// Closing the pipe is the helper's recovery signal, even if the app crashes.
    func shutdown() {
        shuttingDown = true
        responseTimeout?.cancel(); responseTimeout = nil
        timer?.invalidate(); timer = nil
        try? input?.close(); input = nil
    }

    private static func message(for error: String) -> String {
        switch error {
        case "unsupported": return "此机型暂不支持充电控制。"
        case "external_control": return "检测到其他工具已修改充电状态，请先在 AlDente 等工具中恢复系统管理。"
        case "already_running": return "已有一个电池控制进程，请关闭其他 ClaudeBar 实例后重试。"
        case "discharge_unsupported": return "此机型不支持接电放电。"
        case "adapter_required": return "放电操作需要先连接电源，已切换为充电上限管理。"
        case "battery_unavailable": return "无法读取电池，已停止控制并尝试恢复系统管理。"
        case "write_failed": return "SMC 写入或回读失败，已停止控制并尝试恢复系统管理。"
        case "restore_failed": return "恢复系统充电状态失败，请退出其他电池工具并重启 Mac。"
        case "sleep_monitor_failed": return "无法建立休眠保护，未启用充电控制。"
        case "heartbeat_lost": return "应用响应超时，辅助工具已尝试恢复系统管理。"
        default: return "充电设置未能应用（\(error)）。"
        }
    }
}
