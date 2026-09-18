import Foundation

/// Registry of proxied calls that are still in flight, keyed by the capture row
/// the traffic page shows.
///
/// The proxy opens a handle when it starts a capture and attaches the upstream
/// `URLSessionDataTask` plus a way to drop the loopback connection as soon as
/// both exist. The traffic page then calls `cancel(captureID:)` to rip one
/// conversation down.
///
/// Interrupting is deliberately **hard**: the upstream task is cancelled and
/// the client socket is closed without a terminal frame. Claude Code / Codex
/// therefore see the turn cut mid-stream instead of a finished response, which
/// is what stops the agent rather than letting it retry onto a clean ending.
final class ProxyInflight {
    static let shared = ProxyInflight()

    /// One in-flight call. Both teardown hooks are optional and attachable in
    /// any order — `cancel` is idempotent and safe to call from any thread,
    /// including before either hook exists, in which case the pending hooks are
    /// run the moment they are attached.
    final class Handle: @unchecked Sendable {
        let captureID: Int64

        private let lock = NSLock()
        private var cancelled = false
        private var abortClient: (() -> Void)?
        private var upstreamCancel: (() -> Void)?

        init(captureID: Int64) {
            self.captureID = captureID
        }

        /// Drop the loopback connection with no terminal frame, so the client
        /// sees the turn cut mid-stream rather than a finished response.
        func attachAbort(_ abort: @escaping () -> Void) {
            runOrStore(cancelled ? abort : nil) { self.abortClient = abort }
        }

        /// Kill the upstream request feeding this call.
        func attachUpstream(_ cancel: @escaping () -> Void) {
            runOrStore(cancelled ? cancel : nil) { self.upstreamCancel = cancel }
        }

        /// Closures run outside the lock, so a cancel racing an attach cannot
        /// deadlock.
        private func runOrStore(_ immediate: (() -> Void)?, store: () -> Void) {
            lock.lock()
            if let immediate {
                lock.unlock()
                immediate()
                return
            }
            store()
            lock.unlock()
        }

        /// Forget the hooks once the call has finished so the closures (and the
        /// `NWConnection` they capture) do not outlive the request.
        func detach() {
            lock.lock()
            abortClient = nil
            upstreamCancel = nil
            lock.unlock()
        }

        @discardableResult
        func cancel() -> Bool {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                return false
            }
            cancelled = true
            let abort = abortClient
            let upstream = upstreamCancel
            abortClient = nil
            upstreamCancel = nil
            lock.unlock()
            // Abort the client first: the upstream task's cancellation throws
            // into `handle()`, which needs the connection already down.
            abort?()
            upstream?()
            return true
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private let lock = NSLock()
    private var live: [Int64: Handle] = [:]

    private init() {}

    /// Register a capture. The handle lives until `close(_:)`.
    func open(captureID: Int64) -> Handle {
        let handle = Handle(captureID: captureID)
        lock.lock()
        live[captureID] = handle
        lock.unlock()
        return handle
    }

    /// The call is over, however it ended. Drops the registry entry and the
    /// teardown hooks — but not the handle's own `cancelled` flag, which the
    /// proxy keeps reading after the call ends (it retires the capture from
    /// `CaptureTap.finish`, i.e. possibly before `handle()` is done deciding
    /// whether the throw it is holding was an interrupt).
    func close(_ handle: Handle) {
        lock.lock()
        if live[handle.captureID] === handle {
            live.removeValue(forKey: handle.captureID)
        }
        lock.unlock()
        handle.detach()
    }

    /// UI entry point. Returns true when a live call was actually interrupted;
    /// false means it had already finished (or is not capturable), so callers
    /// can treat the tap as a no-op.
    @discardableResult
    func cancel(captureID: Int64) -> Bool {
        lock.lock()
        let handle = live[captureID]
        lock.unlock()
        return handle?.cancel() ?? false
    }
}
