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

    static func start(paths: [String], handler: @escaping () -> Void) {
        stop()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        self.handler = handler

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
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    static func stop() {
        debounceWork?.cancel()
        debounceWork = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        handler = nil
    }

    private static func schedule() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { handler?() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
