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

    /// Narrow an existing file to owner-only, in place.
    ///
    /// `write` needs no help: the staged file is created at 0600 and `rename`
    /// carries the staged inode's mode onto the destination, so every write
    /// lands owner-only whatever the destination was before (measured — a
    /// 0o644 destination is 0o600 after a write).
    ///
    /// This is for the copies `write` does not make. `FileManager.copyItem`
    /// preserves the *source* file's mode, so backing up a `config.toml` an
    /// older build left at 0644 would produce a 0644 backup of a file holding a
    /// live bearer token. No-op when the mode is already narrow.
    static func harden(_ destination: URL) {
        let manager = FileManager.default
        guard let attrs = try? manager.attributesOfItem(atPath: destination.path),
              let mode = attrs[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 != 0 else { return }
        try? manager.setAttributes([.posixPermissions: 0o600],
                                   ofItemAtPath: destination.path)
    }
}
