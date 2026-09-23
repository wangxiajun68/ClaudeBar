import Foundation
import Darwin

/// Stage sensitive data with mode 0600, then atomically replace the destination.
/// A failed write leaves the existing file intact and removes the staged file.
enum PrivateFileWriter {
    static func write(_ data: Data, to destination: URL) throws {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: staged)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
