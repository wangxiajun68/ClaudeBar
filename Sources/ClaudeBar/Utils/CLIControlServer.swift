import Foundation
import Darwin

/// Bounded local transport; the app's main actor owns all mutations.
final class CLIControlServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "claudebar.cli.accept")
    private let workers = DispatchQueue(label: "claudebar.cli.clients", attributes: .concurrent)
    private var source: DispatchSourceRead?
    private var clients: Set<Int32> = [] // confined to queue
    private var tasks: [Int32: Task<Void, Never>] = [:] // confined to queue
    private var socketIdentity: (dev_t, ino_t)?
    private var endpoint: URL?

    func start(at url: URL, handler: @escaping @Sendable (CLIControl.Request) async -> CLIControl.Response) throws {
        guard source == nil else { return }
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = stat()
        guard lstat(parent.path, &directory) == 0, directory.st_uid == geteuid(), directory.st_mode & S_IFMT == S_IFDIR else {
            throw CLIControlFailure(message: "CLI directory ownership/type mismatch")
        }
        guard chmod(parent.path, 0o700) == 0 else { throw CLIControlFailure(message: "Cannot secure CLI directory") }
        var previous = stat()
        if lstat(url.path, &previous) == 0 {
            guard previous.st_uid == geteuid(), previous.st_mode & S_IFMT == S_IFSOCK else {
                throw CLIControlFailure(message: "Refusing to replace a foreign CLI socket")
            }
            if let active = try? CLIControl.connect(url.path, timeout: 1) {
                Darwin.close(active)
                throw CLIControlFailure(message: "This channel already has a live CLI server")
            }
            guard unlink(url.path) == 0 else { throw CLIControlFailure(message: "Cannot remove stale CLI socket") }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIControlFailure(message: "Cannot create control listener") }
        var committed = false
        defer { if !committed { Darwin.close(fd) } }
        var address = try CLIControl.address(url.path)
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw CLIControlFailure(message: "Cannot bind CLI socket") }
        guard chmod(url.path, 0o600) == 0, listen(fd, 8) == 0 else {
            unlink(url.path)
            throw CLIControlFailure(message: "Cannot secure/start CLI listener")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var info = stat(); _ = lstat(url.path, &info)
        socketIdentity = (info.st_dev, info.st_ino); endpoint = url
        let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setEventHandler { [weak self] in
            guard let self else { return }
            // At most eight outstanding clients, including handlers waiting for the main actor.
            while self.clients.count < 8 {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                // Darwin inherits O_NONBLOCK from the listener. Client workers need
                // blocking IO with bounded deadlines, including before the first byte arrives.
                let flags = fcntl(client, F_GETFL)
                guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
                    Darwin.close(client); continue
                }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { Darwin.close(client); continue }
                self.clients.insert(client)
                self.workers.async {
                    CLIControl.configure(client, timeout: 3)
                    do {
                        let request = try JSONDecoder().decode(CLIControl.Request.self,
                            from: CLIControl.read(client, limit: CLIControl.maxRequestBytes, timeout: 3))
                        self.queue.async {
                            guard self.source != nil else { self.finish(client); return }
                            self.tasks[client] = Task {
                                let response: CLIControl.Response
                                if request.channel != BuildChannel.name || request.version != CLIControl.version {
                                    response = .init(id: request.id, ok: false, code: 5, message: "Control channel/protocol mismatch")
                                } else { response = await handler(request) }
                                self.workers.async {
                                    if let bytes = try? JSONEncoder().encode(response), bytes.count <= CLIControl.maxResponseBytes {
                                        try? CLIControl.write(bytes, to: client)
                                    }
                                    self.finish(client)
                                }
                            }
                        }
                    } catch { self.finish(client) }
                }
            }
            // Drain excess pending connections rather than spin on a readable full backlog.
            if self.clients.count >= 8 {
                while true { let excess = accept(fd, nil, nil); if excess < 0 { break }; Darwin.close(excess) }
            }
        }
        listener.setCancelHandler { Darwin.close(fd) }
        source = listener
        listener.resume(); committed = true
    }
    private func finish(_ fd: Int32) {
        queue.async { [self] in
            guard clients.remove(fd) != nil else { return }
            tasks.removeValue(forKey: fd)
            Darwin.close(fd)
        }
    }
    func stop() {
        queue.sync {
            source?.cancel(); source = nil
            for task in tasks.values { task.cancel() }
            // Shutdown unblocks reads/writes. Each client retains ownership until its completion.
            for fd in clients { _ = Darwin.shutdown(fd, SHUT_RDWR) }
            if let endpoint, let identity = socketIdentity {
                var current = stat()
                if lstat(endpoint.path, &current) == 0, current.st_dev == identity.0, current.st_ino == identity.1 {
                    unlink(endpoint.path)
                }
            }
            endpoint = nil; socketIdentity = nil
        }
    }
}
