import Foundation
import Observation

@MainActor
@Observable
final class BatteryChargeController {
    enum Mode: Int, CaseIterable, Identifiable {
        case system, limit, hold, discharge
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .system: return "系统管理"
            case .limit: return "充电至上限"
            case .hold: return "暂停充电"
            case .discharge: return "放电至上限"
            }
        }
        var symbol: String {
            switch self {
            case .system: return "arrow.counterclockwise"
            case .limit: return "bolt.fill"
            case .hold: return "pause.fill"
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
    private(set) var mode = Mode.system
    private(set) var state = 0
    private(set) var supported: Bool?
    private(set) var dischargeSupported = false
    private(set) var pending = false
    private(set) var sleeping = false
    private(set) var lastError: String?
    var threshold: Double {
        didSet {
            let value = min(100, max(20, threshold.rounded()))
            if threshold != value { threshold = value }
            UserDefaults.standard.set(Int(value), forKey: "batteryChargeLimit")
        }
    }
    private(set) var appliedLimit = 80
    private var process: Process?
    private var input: FileHandle?
    private var timer: Timer?
    private var revision: UInt64 = 0
    private var generation = UUID()
    private var probing = false
    private var shuttingDown = false
    private var recoveryUnconfirmed = false
    private var restorationConfirmed = false

    private init() {
        let stored = UserDefaults.standard.object(forKey: "batteryChargeLimit") as? Int ?? 80
        threshold = Double(min(100, max(20, stored)))
    }

    var statusText: String {
        if recoveryUnconfirmed { return "充电状态未确认 · 请检查电池状态" }
        if pending { return "正在应用充电设置…" }
        if sleeping { return "休眠期间由系统管理" }
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
        }
    }

    func apply(_ requested: Mode) {
        guard !pending, !shuttingDown else { return }
        if requested == .system && process == nil { mode = .system; state = 0; lastError = nil; return }
        guard requested == .system || supported == true else { return }
        guard requested != .discharge || dischargeSupported else { return }
        let target = Int(threshold)
        pending = true; lastError = nil
        Task {
            if process == nil {
                let failure = await Task.detached(priority: .userInitiated) { BatteryHelperInstaller.installIfNeeded() }.value
                guard !shuttingDown else { return }
                if let failure { lastError = failure; pending = false; return }
                do { try start() } catch { lastError = "无法启动电池控制：\(error.localizedDescription)"; pending = false; return }
            }
            revision += 1
            send("set \(requested.rawValue) \(target) \(revision)\n")
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
            while let data = try? handle.read(upToCount: 4096), !data.isEmpty {
                buffer.append(data)
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
        if status.error.isEmpty { recoveryUnconfirmed = false }
    }

    private func ended(token: UUID, code: Int32) {
        guard generation == token else { return }
        timer?.invalidate(); timer = nil
        try? input?.close(); input = nil; process = nil
        mode = .system; state = 0; sleeping = false; pending = false
        if code != 0 && !restorationConfirmed { recoveryUnconfirmed = true }
        if code != 0 && lastError == nil { lastError = "电池控制异常停止（\(code)），请检查充电状态后重新启用。" }
    }

    /// Closing the pipe is the helper's recovery signal, even if the app crashes.
    func shutdown() {
        shuttingDown = true
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
