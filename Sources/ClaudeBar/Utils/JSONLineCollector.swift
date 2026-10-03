import Foundation

/// Newline-delimited JSON-RPC responses keyed by request id.
///
/// Shared by the two stdio clients — `MCPToolDiscovery`'s child and
/// `CodexAppServerClient`'s `codex app-server` — because the transport is the
/// subtle part: the FileHandle read handler runs on its own queue, so every
/// access is under the lock and `response(id:until:)` waits on the semaphore
/// rather than polling. The deadline is a call parameter so the caller owns the
/// budget, and each client maps `Failure` onto its own error enum.
final class JSONLineCollector: @unchecked Sendable {
    enum Failure: Error {
        case timedOut
        /// The pipe closed before the answer arrived: the child exited.
        case closed
    }

    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var messages: [Int: [String: Any]] = [:]
    private var closed = false

    func finish() {
        lock.lock()
        closed = true
        lock.unlock()
        signal.signal()
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        if buffer.count > 1_048_576 { buffer.removeAll(); lock.unlock(); signal.signal(); return }
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = Data(buffer[start..<newline])
            start = buffer.index(after: newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let id = json["id"] as? Int {
                messages[id] = json
                signal.signal()
            }
        }
        // Remove the consumed prefix once. Removing it for every message
        // repeatedly shifts/copies the remaining bytes of a batched response.
        if start != buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        lock.unlock()
    }

    func response(id: Int, until deadline: Date) throws -> [String: Any] {
        while Date() < deadline {
            lock.lock()
            let value = messages.removeValue(forKey: id)
            let isClosed = closed
            lock.unlock()
            if let value { return value }
            if isClosed { throw Failure.closed }
            // Wake on a response/EOF or the actual request deadline, rather
            // than polling a quiet child five times per second.
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            _ = signal.wait(timeout: .now() + remaining)
        }
        throw Failure.timedOut
    }
}
