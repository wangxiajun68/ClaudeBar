import Foundation
import Darwin

/// Small, Sendable JSON tree. Decoding and document parsing happen off the UI actor.
indirect enum FeishuJSON: Codable, Sendable, Equatable {
    case object([String: FeishuJSON]), array([FeishuJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: FeishuJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([FeishuJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> FeishuJSON {
        if case .object(let v) = self { return v[key] ?? .null }
        return .null
    }
    var text: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return String(format: "%.0f", v)
        default: return ""
        }
    }
    var items: [FeishuJSON] { if case .array(let v) = self { return v }; return [] }
    var flag: Bool { self == .bool(true) }
    func first(_ keys: String...) -> String { keys.lazy.map { self[$0].text }.first { !$0.isEmpty } ?? "" }
    static func payload(_ data: Data) throws -> FeishuJSON {
        let root = try JSONDecoder().decode(FeishuJSON.self, from: data)
        if root["ok"] == .bool(false) || (!root["code"].text.isEmpty && root["code"].text != "0") {
            // CLI errors can include credential-bearing commands. Never echo them.
            throw FeishuCLIError.failed("飞书请求未完成，请检查 CLI 登录、应用权限与资源访问权限。")
        }
        return root["data"] == .null ? root : root["data"]
    }
}

enum FeishuCLIError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
}

/// Cancellation terminates only the child owned by this request, never a global process.
private final class FeishuChild: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ child: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        process = child
        try child.run()
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                lock.lock(); defer { lock.unlock() }
                // SIGKILL is restricted to this exact owned child after its grace period.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    func finish() { lock.lock(); process = nil; lock.unlock() }
}

/// Drains each pipe concurrently and caps retained output while continuing to drain.
private final class FeishuOutput: @unchecked Sendable {
    var data = Data()
    var exceeded = false
    func read(_ handle: FileHandle) {
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            if data.count + chunk.count <= 16 * 1024 * 1024 { data.append(chunk) }
            else { exceeded = true }
        }
    }
}

enum FeishuCLI {
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.bun/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return roots.map { URL(fileURLWithPath: $0).appendingPathComponent("lark-cli") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 90) async throws -> FeishuJSON {
        // Even reads may refresh the CLI's shared credentials. Dev must not touch them.
        guard BuildChannel.allowsSystemIntegration else {
            throw FeishuCLIError.failed("开发版仅预览飞书界面，不读取或修改真实 CLI 凭据及云端文档。")
        }
        let child = FeishuChild()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        guard let executable = executable() else {
                            throw FeishuCLIError.failed("未找到 lark-cli。请按官方说明安装并在终端完成登录。")
                        }
                        let process = Process(), out = Pipe(), err = Pipe()
                        process.executableURL = executable
                        process.arguments = arguments
                        process.standardOutput = out; process.standardError = err
                        process.environment = ProcessInfo.processInfo.environment.merging([
                            "PATH": executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                            "NO_COLOR": "1"
                        ]) { _, new in new }
                        let stdin = Pipe()
                        process.standardInput = stdin
                        // A write to a child that already exited raises SIGPIPE, whose
                        // default disposition terminates the whole app — a CLI that
                        // exits without reading its body would kill ClaudeBar rather
                        // than fail the `try?` below. Same call `MCPToolDiscovery`
                        // makes on its child pipe.
                        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                        let output = FeishuOutput(), errors = FeishuOutput(), group = DispatchGroup()
                        try child.start(process)
                        defer { child.finish() }
                        group.enter()
                        DispatchQueue.global().async { output.read(out.fileHandleForReading); group.leave() }
                        group.enter()
                        DispatchQueue.global().async { errors.read(err.fileHandleForReading); group.leave() }
                        group.enter()
                        DispatchQueue.global().async {
                            if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
                            try? stdin.fileHandleForWriting.close()
                            group.leave()
                        }
                        let deadline = Date().addingTimeInterval(min(600, max(1, timeout)))
                        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
                        if process.isRunning {
                            child.cancel()
                            // Bounded wait; do not hold a worker forever on a stuck child.
                            if group.wait(timeout: .now() + 2) == .timedOut {
                                throw FeishuCLIError.failed("飞书 CLI 超时，请稍后重试。")
                            }
                            throw FeishuCLIError.failed("飞书 CLI 超时，请稍后重试。")
                        }
                        guard group.wait(timeout: .now() + 2) == .success, !output.exceeded else {
                            throw FeishuCLIError.failed("文档输出过大或 CLI 未结束，请在飞书中打开。")
                        }
                        guard process.terminationStatus == 0 else {
                            throw FeishuCLIError.failed("CLI 请求失败，请在终端检查 lark-cli auth status、权限或 CLI 版本。")
                        }
                        continuation.resume(returning: try FeishuJSON.payload(output.data))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { child.cancel() }
    }
}
