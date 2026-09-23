import Foundation

/// A one-shot resident-memory snapshot, read on a utility task when requested.
struct ProcessMemoryRow: Identifiable, Sendable {
    let id: Int
    let name: String
    let bytes: UInt64

    static func read() -> [Self]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,rss=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer { try? output.fileHandleForReading.close() }
        do { try process.run() } catch { return nil }
        guard let data = try? output.fileHandleForReading.readToEnd() else {
            if process.isRunning { process.terminate() }
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> Self? in
            let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 3, let pid = Int(parts[0]), let kb = UInt64(parts[1]) else { return nil }
            let (bytes, overflow) = kb.multipliedReportingOverflow(by: 1024)
            guard !overflow else { return nil }
            return Self(id: pid, name: (String(parts[2]) as NSString).lastPathComponent, bytes: bytes)
        }.sorted { $0.bytes > $1.bytes }
    }
}
