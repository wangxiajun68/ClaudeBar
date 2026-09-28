import Foundation
import Compression

/// Streams an `.xz` archive to a file.
///
/// It exists for one payload — the mihomo core, which the build packages
/// compressed rather than as a 54 MB binary (see `VpnManager.installCore`).
/// Apple's `libcompression` decodes LZMA natively, so this needs no dependency
/// and no helper process; measured on the shipped core the whole decode is
/// **0.6 s**, and because it streams, peak memory is the 16 MiB LZMA dictionary
/// plus two 1 MiB buffers rather than the 54 MB the binary occupies.
///
/// The framing is worth stating because `COMPRESSION_LZMA` sounds like it takes
/// a bare LZMA stream and does not: Apple's LZMA is the **`.xz` container**
/// (magic `fd 37 7a 58 5a 00`), with the `.lzma`-alone and raw-LZMA1 framings
/// both rejected at the first block header. That is the useful direction here —
/// it is what `xz -9` writes, so the archive the build produces is the archive
/// this reads, and the same file opens with `xz -d` anywhere else.
enum XZArchive {
    enum Failure: Error {
        /// `compression_stream_init` refused the algorithm, or the stream hit a
        /// block it could not decode. Neither is recoverable in place.
        case undecodable
        case cannotWrite(String)
    }

    /// Decode `source` into `destination`, replacing whatever was there.
    ///
    /// `destination` is written directly and only ever published by the caller's
    /// own `chmod` + rename once it is complete, so a decode that fails
    /// half-way cannot leave a truncated binary at a path something will try to
    /// execute.
    static func extract(_ source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let capacity = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: capacity,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA)
                != COMPRESSION_STATUS_ERROR else { throw Failure.undecodable }
        defer { compression_stream_destroy(&stream) }

        // Refill `src_ptr` only once the library has drained what it was handed:
        // it advances `src_ptr`/`src_size` itself as it consumes the block.
        var chunk = Data()
        var sourceDrained = false
        while true {
            if stream.src_size == 0 && !sourceDrained {
                chunk = input.readData(ofLength: capacity)
                if chunk.isEmpty {
                    sourceDrained = true
                } else {
                    chunk.withUnsafeBytes { raw in
                        stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
                        stream.src_size = raw.count
                    }
                }
            }
            stream.dst_ptr = buffer
            stream.dst_size = capacity
            // FINALIZE only once there is nothing left to hand it, or the
            // decoder treats the still-unread tail as the end of the archive.
            let flags: Int32 = (sourceDrained && stream.src_size == 0)
                ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(&stream, flags)
            let produced = capacity - stream.dst_size
            if produced > 0 {
                do {
                    try output.write(contentsOf: Data(bytes: buffer, count: produced))
                } catch {
                    throw Failure.cannotWrite(error.localizedDescription)
                }
            }
            if status == COMPRESSION_STATUS_END { return }
            if status == COMPRESSION_STATUS_ERROR { throw Failure.undecodable }
        }
    }
}
