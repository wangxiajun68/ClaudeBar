import Foundation
import Darwin

struct CLIControlFailure: Error {
    var message: String
    var code: Int32 = 5
}

/// Same-user local control protocol. No bearer/API credentials cross this socket.
enum CLIControl {
    static let version = 1
    static let maxRequestBytes = 64 * 1024
    static let maxResponseBytes = 4 * 1024 * 1024
    struct Request: Codable {
        var version = CLIControl.version
        var id = UUID().uuidString
        var channel = BuildChannel.name
        var command: String
        var arguments: [String]
        var agent: String?
        var provider: String?
        var model: String?
        var group: String?
        var project: String?
        var confirmed: Bool? = nil
    }
    struct Response: Codable {
        var id: String
        var channel = BuildChannel.name
        var ok: Bool
        var code: Int32
        var message: String
        /// JSON result rather than a raw business object; credential-bearing models are never encoded.
        var result: String?
    }
    static func socketURL(home: URL, appName: String) -> URL {
        CLISnapshot.fileURL(home: home, appName: appName).deletingLastPathComponent()
            .appendingPathComponent("cli", isDirectory: true).appendingPathComponent("control.sock")
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else {
            throw CLIControlFailure(message: "CLI socket path exceeds the system limit")
        }
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { target in target.copyBytes(from: bytes) }
        return value
    }
    static func connect(_ path: String, timeout: Int = 30) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIControlFailure(message: "Cannot create CLI socket") }
        do {
            configure(fd, timeout: timeout)
            var target = try address(path)
            let status = withUnsafePointer(to: &target) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard status == 0 else { throw CLIControlFailure(message: "Application control is offline. Use start first; older apps need rebuilding.", code: 3) }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    static func configure(_ fd: Int32, timeout: Int) {
        var seconds = timeval(tv_sec: timeout, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    static func read(_ fd: Int32, limit: Int, timeout: TimeInterval = 30) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let started = DispatchTime.now().uptimeNanoseconds
        while data.count <= limit {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            let remaining = timeout - elapsed
            guard remaining > 0 else { throw CLIControlFailure(message: "Control connection timed out") }
            var interval = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
            let count = recv(fd, &buffer, min(buffer.count, limit + 1 - data.count), 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CLIControlFailure(message: "Control connection closed or timed out; check status before retrying") }
            let chunk = buffer.prefix(count)
            if let end = chunk.firstIndex(of: 10) {
                data.append(contentsOf: chunk.prefix(upTo: end))
                guard data.count <= limit else { break }
                return data
            }
            data.append(contentsOf: chunk)
        }
        throw CLIControlFailure(message: "Control message exceeds size limit")
    }
    static func write(_ data: Data, to fd: Int32) throws {
        let payload = data + Data([10])
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CLIControlFailure(message: "Cannot send control message") }
                offset += count
            }
        }
    }
    static func send(_ request: Request, to url: URL) throws -> Response {
        let fd = try connect(url.path)
        defer { Darwin.close(fd) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            throw CLIControlFailure(message: "CLI server does not belong to this user")
        }
        let encoded = try JSONEncoder().encode(request)
        guard encoded.count <= maxRequestBytes else { throw CLIControlFailure(message: "Control request exceeds size limit") }
        try write(encoded, to: fd)
        let response = try JSONDecoder().decode(Response.self, from: read(fd, limit: maxResponseBytes))
        guard response.id == request.id, response.channel == request.channel else {
            throw CLIControlFailure(message: "Control response identity mismatch")
        }
        return response
    }
    static func response(_ request: Request, message: String, result: Any? = nil) -> Response {
        let data = result.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
        return .init(id: request.id, ok: true, code: 0, message: message,
                     result: data.flatMap { String(data: $0, encoding: .utf8) })
    }
}

/// The host repeats this policy; command-line validation is not a security boundary.
enum CLIControlPolicy {
    static func isMutation(_ request: CLIControl.Request) -> Bool {
        let action = request.arguments.first ?? "status"
        switch request.command {
        case "providers", "models": return ["use", "official", "capture"].contains(action)
        case "vpn": return !["status", "nodes", "groups", "preview"].contains(action)
        case "connectors": return ["enable", "disable", "remove"].contains(action)
        case "mode": return ["desktop", "performance"].contains(action)
        case "config": return action == "set"
        case "proxy": return ["start", "stop", "on", "off"].contains(action)
        default: return false
        }
    }
    static func needsSystemIntegration(_ request: CLIControl.Request) -> Bool {
        (request.command == "vpn" && isMutation(request))
            || (request.command == "connectors" && isMutation(request))
            || (request.command == "config" && request.arguments.first == "set"
                && request.arguments.dropFirst().first?.hasPrefix("vpn-") == true)
    }
    static func validate(_ request: CLIControl.Request) throws {
        guard request.channel == BuildChannel.name, request.version == CLIControl.version else {
            throw CLIControlFailure(message: "Control channel/protocol mismatch")
        }
        guard !needsSystemIntegration(request) || BuildChannel.allowsSystemIntegration else {
            throw CLIControlFailure(message: BuildChannel.restrictionMessage)
        }
    }
    static func select(_ selector: String, from entries: [(id: String, name: String)]) throws -> String {
        let matches = entries.filter { $0.id.lowercased() == selector.lowercased() || $0.name == selector }
        guard matches.count == 1 else {
            throw CLIControlFailure(message: matches.isEmpty ? "Target not found; list available IDs first" : "Name is ambiguous; use its full ID")
        }
        return matches[0].id
    }
}
