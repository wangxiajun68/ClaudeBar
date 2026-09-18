import Foundation
import CoreServices

/// Recursive directory watcher for usage transcripts. Debounces bursts of
/// JSONL appends into a single `updateIndex()` so the Usage page is not a
/// pull-to-rescan surface.
enum UsageFSWatcher {
    private static var stream: FSEventStreamRef?
    private static var handler: (() -> Void)?
    private static var debounceWork: DispatchWorkItem?
    private static let queue = DispatchQueue(label: "com.claudebar.usage-fs", qos: .utility)

    /// Guards `stream` / `handler` / `debounceWork`. `start`/`stop` are called
    /// from the main thread, but `schedule()` runs on `queue` (the FSEvents
    /// callback's queue) inside the same tick as a `stop()` — which tore down
    /// the stream while `schedule()` was storing a new `debounceWork` into it.
    /// Both mutating the same optional strong references without a lock is the
    /// same over-release shape that crashed `ProxyAccessLog.scheduleCompact`.
    private static let lock = NSLock()

    static func start(paths: [String], handler: @escaping () -> Void) {
        stop()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        lock.lock()
        self.handler = handler
        lock.unlock()

        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            UsageFSWatcher.schedule()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }
        lock.lock()
        stream = created
        lock.unlock()
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    static func stop() {
        lock.lock()
        let work = debounceWork
        debounceWork = nil
        let existing = stream
        stream = nil
        handler = nil
        lock.unlock()
        work?.cancel()
        if let existing {
            // `stop()` runs on main, `schedule()` on `queue`; FSEvents requires
            // both to agree, so land the teardown on `queue` as well. By the
            // time it runs the fields are already cleared and any in-flight
            // `debounceWork` invocation is cancelled, so it is a no-op there.
            FSEventStreamSetDispatchQueue(existing, queue)
            queue.async {
                FSEventStreamStop(existing)
                FSEventStreamInvalidate(existing)
                FSEventStreamRelease(existing)
            }
        }
    }

    private static func schedule() {
        lock.lock()
        guard stream != nil, let handler else {
            lock.unlock()
            return
        }
        debounceWork?.cancel()
        let work = DispatchWorkItem { handler() }
        debounceWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
