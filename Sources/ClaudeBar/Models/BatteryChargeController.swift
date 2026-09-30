import Foundation
import Darwin
import Observation

@MainActor
@Observable
final class BatteryChargeController {
    enum Mode: Int, CaseIterable, Identifiable {
        case system, limit, hold, discharge
        var id: Int { rawValue }
        static var displayOrder: [Mode] { [.limit, .hold, .discharge, .system] }
        var label: String {
            switch self {
            case .system: return "还原系统"
            case .limit: return "启动管理"
            case .hold: return "充电"
            case .discharge: return "放电"
            }
        }
        var title: String {
            switch self {
            case .system: return "恢复系统充电管理并停止辅助进程"
            case .limit: return "高于目标时放电，低于目标时充电，到目标后保持"
            case .hold: return "充电到目标后保持；高于目标时仅停充"
            case .discharge: return "接电放电到目标后转为自动管理；合盖或休眠会暂停主动放电"
            }
        }
        var symbol: String {
            switch self {
            case .system: return "arrow.counterclockwise"
            case .limit: return "bolt.fill"
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
        let notice: String
        let terminal: Bool
    }
    private struct Capabilities: Decodable { let supported: Bool; let dischargeSupported: Bool }
    private struct Request {
        let mode: Mode
        let limit: Int
        let revision: UInt64
    }
    static let shared = BatteryChargeController()
    static let minLimit: Double = 20
    private(set) var mode = Mode.system
    private(set) var savedMode = Mode.system
    private(set) var state = 0
    private(set) var supported: Bool?
    private(set) var dischargeSupported = false
    private(set) var pending = false
    private(set) var helperInstalled = false
    private(set) var authorizingHelper = false
    private(set) var sleeping = false
    private(set) var lastError: String?
    private(set) var probeError: String?
    private(set) var probing = false
    private(set) var notice = ""
    private(set) var measuredText = ""
    private(set) var reportedPercent: Int?
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
    private var inFlight: Request?
    private var desiredMode: Mode?
    private(set) var pendingMessage = "正在应用充电设置…"
    private var revision: UInt64 = 0
    private var generation = UUID()
    private var shuttingDown = false
    private(set) var recoveryUnconfirmed = false
    private var restorationConfirmed = false
    private var lastResponseAt: TimeInterval = 0
    private var stateChangedAt: TimeInterval = 0
    private var measurementGeneration = UUID()
    private var resuming = false

    private init() {
        let stored = UserDefaults.standard.object(forKey: "batteryChargeLimit") as? Int ?? 80
        threshold = Double(min(100, max(Int(Self.minLimit), stored)))
        savedMode = Mode(rawValue: UserDefaults.standard.integer(forKey: "batteryChargeMode")) ?? .system
    }

    func refreshHelperAuthorization() async {
        helperInstalled = await Task.detached(priority: .utility) {
            BatteryHelperInstaller.isInstalled()
        }.value
    }

    func authorizeHelper() {
        guard !authorizingHelper, !pending, !processIsRunning else { return }
        authorizingHelper = true
        lastError = nil
        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                BatteryHelperInstaller.installIfNeeded()
            }.value
            await refreshHelperAuthorization()
            lastError = failure
            authorizingHelper = false
            guard failure == nil, !shuttingDown else { return }
            if supported == nil { probe(retry: true) }
            else { resumePersistedMode() }
        }
    }

    var statusText: String {
        if recoveryUnconfirmed { return "充电状态未确认 · 请检查电池状态" }
        if pending { return pendingMessage }
        if sleeping { return "休眠期间由系统管理" }
        if process == nil && savedMode != .system { return "上次的管理待恢复 · 点击模式重试" }
        switch state {
        case 1: return "已允许充电 · 目标 \(appliedLimit)%"
        case 2: return "已停止充电 · 目标 \(appliedLimit)%"
        case 3: return "已切换电池供电 · 放电至 \(appliedLimit)%"
        default: return "由 macOS 管理充电"
        }
    }

    func probe(retry: Bool = false) {
        guard BuildChannel.allowsSystemIntegration else {
            probeError = BuildChannel.restrictionMessage
            return
        }
        guard !probing, retry || (supported == nil && probeError == nil) else { return }
        probing = true; probeError = nil
        Task {
            let result = await Task.detached(priority: .utility) { () -> Data? in
                guard let url = BatteryHelperInstaller.bundledURL else { return nil }
                let child = Process(), output = Pipe()
                child.executableURL = url; child.arguments = ["--probe"]
                child.standardOutput = output; child.standardError = FileHandle.nullDevice
                guard (try? child.run()) != nil else { return nil }
                let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
                defer { deadline.cancel() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                return child.terminationStatus == 0 ? data : nil
            }.value
            probing = false
            guard !shuttingDown else { return }
            if let result, let capabilities = try? JSONDecoder().decode(Capabilities.self, from: result) {
                supported = capabilities.supported; dischargeSupported = capabilities.dischargeSupported
                resumePersistedMode()
            } else {
                supported = nil
                probeError = "无法检测电池控制能力，请重试；若辅助工具缺失，请重新安装应用。"
            }
        }
    }

    private func resumePersistedMode() {
        guard !resuming, savedMode != .system, supported == true,
              !pending, !authorizingHelper, process == nil, !shuttingDown else { return }
        resuming = true
        Task {
            await refreshHelperAuthorization()
            resuming = false
            guard helperInstalled, !pending, process == nil, !shuttingDown else { return }
            apply(savedMode)
        }
    }

    var managesLimit: Bool {
        process != nil && input != nil && !recoveryUnconfirmed && !sleeping && mode != .system
    }
    var processIsRunning: Bool { process != nil }
    var isRestoring: Bool { desiredMode == .system || (process != nil && input == nil) }
    var limitConfirmed: Bool { managesLimit && !pending && appliedLimit == Int(threshold) }

    func canApply(_ requested: Mode) -> Bool {
        guard BuildChannel.allowsSystemIntegration else { return false }
        guard !shuttingDown, !authorizingHelper, !sleeping else { return false }
        guard process == nil || input != nil else { return false }
        if requested == .system { return !isRestoring }
        return supported == true && !pending && (!recoveryUnconfirmed || process == nil)
            && (requested != .discharge || dischargeSupported)
    }

    // The slider changes the latest intent, never the mode of an older command.
    // A single in-flight command is acknowledged before the latest intent is sent.
    func setLimit(_ value: Int) {
        threshold = Double(min(100, max(Int(Self.minLimit), value)))
        guard !shuttingDown, !isRestoring else { return }
        if pending { return } // Authorization and replies use the latest threshold.
        guard managesLimit, Int(threshold) != appliedLimit else { return }
        desiredMode = mode
        dispatchRequest()
    }

    func apply(_ requested: Mode) {
        guard canApply(requested) else { return }
        desiredMode = requested
        if requested == .system {
            savedMode = .system
            UserDefaults.standard.set(savedMode.rawValue, forKey: "batteryChargeMode")
        }
        if pending {
            pendingMessage = "正在结束当前操作并还原系统…"
            return
        } // Allow system restoration to supersede an in-flight operation.
        if requested == .system && process == nil {
            savedMode = .system
            UserDefaults.standard.set(savedMode.rawValue, forKey: "batteryChargeMode")
            desiredMode = nil
            if !recoveryUnconfirmed { mode = .system; state = 0; lastError = nil }
            return
        }
        pending = true; lastError = nil
        if process != nil { dispatchRequest(); return }
        pendingMessage = "正在检查辅助工具与系统授权…"
        Task {
            let failure = await Task.detached(priority: .userInitiated) { BatteryHelperInstaller.installIfNeeded() }.value
            guard !shuttingDown else { return }
            helperInstalled = failure == nil
            if let failure { lastError = failure; pending = false; desiredMode = nil; return }
            // A restore requested during authorization cancels enabling management.
            if desiredMode == .system {
                pending = false; desiredMode = nil; savedMode = .system
                UserDefaults.standard.set(savedMode.rawValue, forKey: "batteryChargeMode")
                return
            }
            do { try start() }
            catch { lastError = "无法启动电池控制：\(error.localizedDescription)"; pending = false; desiredMode = nil; return }
            dispatchRequest()
        }
    }

    private func dispatchRequest() {
        guard inFlight == nil, let desiredMode, input != nil, !shuttingDown else { return }
        revision += 1
        let request = Request(mode: desiredMode, limit: Int(threshold), revision: revision)
        inFlight = request; pending = true
        measurementGeneration = UUID(); measuredText = ""
        pendingMessage = desiredMode == .system ? "正在恢复系统充电管理…" : "正在应用目标 \(request.limit)%…"
        send("set \(request.mode.rawValue) \(request.limit) \(request.revision)\n")
        if pending { awaitResponse() }
    }

    private func awaitResponse() {
        responseTimeout?.cancel()
        let token = generation
        responseTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.generation == token, self.pending else { return }
            if self.sleeping { self.awaitResponse(); return }
            self.disconnect("电池控制响应超时，已断开连接并请求恢复系统管理。")
        }
    }

    private func heartbeat() {
        guard input != nil, !shuttingDown else { return }
        if !sleeping && ProcessInfo.processInfo.systemUptime - lastResponseAt > 8 {
            disconnect("电池状态超过 8 秒未更新，已断开连接并请求恢复系统管理。")
            return
        }
        send("ping\n")
    }

    private func start() throws {
        guard BuildChannel.allowsSystemIntegration else {
            throw NSError(domain: BuildChannel.bundleID, code: 1,
                          userInfo: [NSLocalizedDescriptionKey: BuildChannel.restrictionMessage])
        }
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
        lastResponseAt = ProcessInfo.processInfo.systemUptime
        let heartbeatTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        RunLoop.main.add(heartbeatTimer, forMode: .common)
        timer = heartbeatTimer
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
                        DispatchQueue.main.async { self?.receive(status, token: token) }
                    }
                }
                if buffer.count > 65536 { break }
            }
            try? handle.close()
            child.waitUntilExit()
            DispatchQueue.main.async { self?.ended(token: token, code: child.terminationStatus) }
        }
    }

    private func disconnect(_ error: String) {
        lastError = error; recoveryUnconfirmed = true
        pending = false; inFlight = nil; desiredMode = nil
        responseTimeout?.cancel(); responseTimeout = nil
        timer?.invalidate(); timer = nil
        measurementGeneration = UUID(); measuredText = ""
        try? input?.close(); input = nil
    }

    private func send(_ message: String) {
        guard let input else { disconnect("控制连接已断开，等待恢复系统管理。"); return }
        do { try input.write(contentsOf: Data(message.utf8)) }
        catch { disconnect("控制连接中断，辅助工具将恢复系统管理。") }
    }

    private func receive(_ status: Status, token: UUID) {
        guard generation == token else { return }
        // Terminal reports describe recovery, not a new user preference. They
        // can have revision 0 when startup fails before accepting a command.
        if status.terminal {
            restorationConfirmed = status.state == 0 && status.error != "restore_failed"
            recoveryUnconfirmed = !restorationConfirmed
            if !status.error.isEmpty { lastError = Self.message(for: status.error) }
            pending = false; inFlight = nil; desiredMode = nil
            responseTimeout?.cancel(); responseTimeout = nil
            timer?.invalidate(); timer = nil
            try? input?.close(); input = nil
            mode = .system; state = status.state; sleeping = false
            measurementGeneration = UUID(); measuredText = ""
            ProcessSampler.shared.refreshBattery()
            return
        }
        guard !shuttingDown, input != nil else { return }
        lastResponseAt = ProcessInfo.processInfo.systemUptime
        sleeping = status.sleeping
        // A sleep notification may precede acceptance of our newest command.
        // Track connectivity/sleep without treating that older revision as an ack.
        if sleeping { measurementGeneration = UUID(); measuredText = ""; return }
        guard status.revision == revision else { return }
        dischargeSupported = status.dischargeSupported
        lastError = status.error.isEmpty ? nil : Self.message(for: status.error)
        if state != status.state { stateChangedAt = lastResponseAt }
        mode = Mode(rawValue: status.mode) ?? .system
        state = status.state; appliedLimit = status.limit; sleeping = status.sleeping
        reportedPercent = status.percent >= 0 ? status.percent : nil
        notice = Self.noticeText(status.notice)
        recoveryUnconfirmed = status.error == "restore_failed"
        if let request = inFlight, request.revision == status.revision {
            inFlight = nil
            responseTimeout?.cancel(); responseTimeout = nil
            // Respect helper transitions (e.g. completed manual discharge), unless
            // the user explicitly superseded this request with system restoration.
            if desiredMode == request.mode { desiredMode = mode }
            if desiredMode != mode || (desiredMode != .system && Int(threshold) != request.limit) {
                dispatchRequest()
                return
            }
            pending = false; desiredMode = nil
            if mode == .system {
                timer?.invalidate(); timer = nil
                try? input?.close(); input = nil
            }
            if status.error.isEmpty {
                savedMode = mode
                UserDefaults.standard.set(mode.rawValue, forKey: "batteryChargeMode")
            }
        } else if mode != .system && status.error.isEmpty {
            savedMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "batteryChargeMode")
        }
        refreshMeasurement()
    }

    private func refreshMeasurement() {
        let token = UUID(); measurementGeneration = token
        if measuredText.isEmpty { measuredText = "指令已确认 · 正在读取实际电池状态…" }
        ProcessSampler.shared.refreshBattery { [weak self] battery in
            guard let self, self.measurementGeneration == token, !self.shuttingDown else { return }
            guard battery.installed, let watts = battery.batteryWatts else {
                self.measuredText = "指令已确认 · 暂无实际电池读数"
                return
            }
            let description = watts > 0.5 ? "充电中" : watts < -0.5 ? "电池供电中" : "电池基本空闲"
            let mismatch = (self.state == 3 && watts >= -0.5) || (self.state == 2 && watts > 0.5)
            if mismatch {
                self.measuredText = ProcessInfo.processInfo.systemUptime - self.stateChangedAt < 10
                    ? "指令已确认 · 等待电流变化（实测\(description)）"
                    : "指令已确认，但实测仍为\(description) · 请检查电源状态"
            } else {
                self.measuredText = "实测 \(battery.percent)% · \(description)"
            }
        }
    }

    private func ended(token: UUID, code: Int32) {
        guard generation == token else { return }
        responseTimeout?.cancel(); responseTimeout = nil
        timer?.invalidate(); timer = nil
        try? input?.close(); input = nil; process = nil
        mode = .system; state = 0; sleeping = false; pending = false
        inFlight = nil; desiredMode = nil; notice = ""
        measurementGeneration = UUID(); measuredText = ""
        recoveryUnconfirmed = !restorationConfirmed
        if !restorationConfirmed && lastError == nil {
            lastError = "电池控制已停止（\(code)），未收到恢复确认；请检查充电状态。"
        }
    }

    func shutdown() {
        shuttingDown = true
        responseTimeout?.cancel(); responseTimeout = nil
        timer?.invalidate(); timer = nil
        measurementGeneration = UUID()
        try? input?.close(); input = nil
    }

    private static func noticeText(_ value: String) -> String {
        switch value {
        case "discharge_unsupported": return "此机型仅支持限充，无法主动降到目标电量。"
        case "adapter_required": return "未检测到电源输入，使用电池自然放电；接电后继续管理。"
        case "lid_closed": return "合盖期间暂停主动放电。"
        case "discharge_paused": return "合盖或休眠后已暂停主动放电；点击「启动管理」可恢复。"
        default: return ""
        }
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
