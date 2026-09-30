import Foundation
import os

/// Where the installed `codex` binary lives.
///
/// One resolver, because two call sites need the same answer for different
/// reasons: `CodexQuotaFetcher` spawns `codex app-server` for rate limits, and
/// `CodexAppServerClient` spawns it to list and clean up stuck threads.
enum CodexRuntime {
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // ChatGPT.app moved the bundled CLI into `codex-cli/bin` (codex
        // 0.158 reads the layout from `codex-package.json`). Older installs
        // still ship it directly under Resources, so try both.
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }
}

/// Lists and cleans up Codex threads through the app-server JSON-RPC API,
/// over a short-lived `codex app-server` child on stdio.
///
/// **Why not `codex delete`.** The CLI's `delete`/`archive` subcommands talk to
/// an app server too, but they surface nothing: on a refused delete they print
/// `Error: failed to delete session` and exit non-zero, which is how a thread
/// with a live fork looked "undeletable" until this client asked the protocol
/// directly and got `cannot delete thread …: forked history still references
/// it`. The RPC also lets one process answer several questions, so listing the
/// candidates and deleting one costs a single spawn.
///
/// **Why not write Codex's SQLite.** The desktop index (`state_*.sqlite`) is
/// Codex's own store, plus a paginated history DB and a writer lock per thread;
/// a delete has to clear all three. `thread/delete` is the API that does.
///
/// A thread is only ever touched by explicit user action — this client never
/// deletes on its own initiative.
enum CodexAppServerClient {

    enum Failure: LocalizedError {
        case unavailable
        case timedOut
        case server(String)
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "未找到 Codex，请先安装或打开 Codex"
            case .timedOut: return "Codex 没有及时回应"
            case .server(let message): return message
            case .refused(let message): return message
            }
        }
    }

    /// What actually happened, so the UI can report it honestly instead of
    /// claiming a deletion that was downgraded.
    enum Removal: Equatable {
        /// The thread and any of its forks are gone.
        case deleted
        /// Codex refused the delete; the thread was archived instead, which
        /// takes it out of every session list without destroying its history.
        case archived(String)
    }

    // MARK: - API

    /// Remove `threadId`, deleting its forks first.
    ///
    /// Codex refuses to delete a thread that forked history still references —
    /// precisely the shape a stuck thread takes when the user once resumed it,
    /// and the refusal (observed against codex-cli 0.159.0) reads
    /// `cannot delete thread …: forked history still references it`. So a fork
    /// of the target is deleted first, then the target; if Codex still refuses
    /// (a fork the scan could not see, a permission), the thread is archived
    /// and the caller is told, rather than being told nothing.
    static func remove(threadId: String, timeout: TimeInterval = 30) throws -> Removal {
        try withServer(timeout: timeout) { server in
            let forks = (try? server.threadIds(forkedFrom: threadId)) ?? []
            for fork in forks { _ = try? server.call("thread/delete", params: ["threadId": fork]) }
            do {
                _ = try server.call("thread/delete", params: ["threadId": threadId])
                return .deleted
            } catch let failure as Failure {
                guard case .refused(let message) = failure else { throw failure }
                _ = try server.call("thread/archive", params: ["threadId": threadId])
                return .archived(message)
            }
        }
    }

    // MARK: - Transport

    private static func withServer<T>(timeout: TimeInterval,
                                      _ body: (Server) throws -> T) throws -> T {
        guard let executable = CodexRuntime.executable() else { throw Failure.unavailable }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let deadline = Date().addingTimeInterval(timeout)
        let collector = LineCollector(deadline: deadline)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; collector.finish() }
            else { collector.append(data) }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        do { try process.run() } catch { throw Failure.unavailable }

        let server = Server(send: { message in
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }, collector: collector)

        _ = try server.call("initialize", params: ["clientInfo": [
            "name": "claudebar", "title": "ClaudeBar",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        ]])
        server.notify("initialized", params: [:])
        return try body(server)
    }

    /// One request at a time: this client has no pipelining and never wants it,
    /// so an id counter and a matching loop are the whole protocol handling.
    private final class Server {
        private let send: ([String: Any]) throws -> Void
        private let collector: LineCollector
        private var nextID = 1

        init(send: @escaping ([String: Any]) throws -> Void, collector: LineCollector) {
            self.send = send
            self.collector = collector
        }

        func notify(_ method: String, params: [String: Any]) {
            try? send(["jsonrpc": "2.0", "method": method, "params": params])
        }

        func call(_ method: String, params: [String: Any]) throws -> [String: Any] {
            let id = nextID
            nextID += 1
            try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            let message = try collector.response(id: id)
            if let error = message["error"] as? [String: Any] {
                let text = error["message"] as? String ?? "Codex 拒绝了该请求"
                // The one refusal that has a documented cause and a documented
                // remedy; every other error is surfaced as-is.
                if text.contains("forked history still references it") { throw Failure.refused(text) }
                throw Failure.server(text)
            }
            return message["result"] as? [String: Any] ?? [:]
        }

        /// Ids of threads forked from `threadId`.
        ///
        /// The archived view first, because that is where a blocking fork
        /// actually lives: the user resumed a stuck thread at some point, and
        /// the fork was archived later. The live thread list is scanned as well
        /// so the two cases are one query shape rather than two code paths —
        /// and it is the *wider* answer, so it runs second.
        func threadIds(forkedFrom threadId: String) throws -> [String] {
            var ids: [String] = []
            var seen = Set<String>()
            for archived in [true, false] {
                var cursor: String?
                for _ in 0..<20 {
                    var params: [String: Any] = ["limit": 200, "archived": archived]
                    if let cursor { params["cursor"] = cursor }
                    let result = try call("thread/list", params: params)
                    for entry in result["data"] as? [[String: Any]] ?? []
                    where (entry["forkedFromId"] as? String) == threadId {
                        if let id = entry["id"] as? String, seen.insert(id).inserted { ids.append(id) }
                    }
                    guard let next = result["nextCursor"] as? String, !next.isEmpty else { break }
                    cursor = next
                }
            }
            return ids
        }
    }

    /// Newline-delimited JSON-RPC responses keyed by request id, with the
    /// deadline owned by the caller. Same shape as `MCPLineCollector`: the read
    /// handler runs on a FileHandle queue, so every access is under the lock and
    /// `response(id:)` waits on the semaphore rather than polling.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let signal = DispatchSemaphore(value: 0)
        private let deadline: Date
        private var buffer = Data()
        private var messages: [Int: [String: Any]] = [:]
        private var closed = false

        init(deadline: Date) { self.deadline = deadline }

        func finish() {
            lock.lock(); closed = true; lock.unlock()
            signal.signal()
        }

        func append(_ data: Data) {
            lock.lock()
            buffer.append(data)
            if buffer.count > 1_048_576 { buffer.removeAll(); lock.unlock(); signal.signal(); return }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let id = json["id"] as? Int {
                    messages[id] = json
                    signal.signal()
                }
            }
            lock.unlock()
        }

        func response(id: Int) throws -> [String: Any] {
            while Date() < deadline {
                lock.lock()
                let value = messages.removeValue(forKey: id)
                let isClosed = closed
                lock.unlock()
                if let value { return value }
                if isClosed { throw Failure.server("Codex 服务已退出") }
                _ = signal.wait(timeout: .now() + 0.2)
            }
            throw Failure.timedOut
        }
    }
}
