import Foundation
import Network

/// An ephemeral HTTP origin for the official SDK. No credential endpoints,
/// filesystem access, or writes; the listener is restricted to IPv4 loopback.
@MainActor final class FeishuComponentHost {
    private var listener: NWListener?
    private var pending: CheckedContinuation<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "\(BuildChannel.bundleID).feishu-component")
    private let path = "/" + UUID().uuidString + "/index.html"
    private var stopped = false

    func start() async throws -> URL {
        guard BuildChannel.allowsSystemIntegration else {
            throw FeishuCLIError.failed("开发版不启动飞书组件宿主。")
        }
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.receive(connection) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                pending = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, let pending = self.pending else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port,
                                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(self.path)") else { self.stop(); return }
                            self.pending = nil
                            pending.resume(returning: url)
                        case .failed:
                            self.pending = nil
                            pending.resume(throwing: FeishuCLIError.failed("无法启动飞书文档视图。"))
                            self.stop()
                        default: break
                        }
                    }
                }
                listener.start(queue: queue)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }

    func stop() {
        stopped = true
        pending?.resume(throwing: CancellationError()); pending = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func receive(_ connection: NWConnection) {
        guard !stopped, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        read(connection, id: id, buffer: Data())
        // Bound idle/partial requests as well as the number of sockets.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.connections.removeValue(forKey: id)?.cancel()
        }
    }

    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard error == nil, buffer.count <= 8192 else { self.close(id); return }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    let request = String(decoding: buffer, as: UTF8.self)
                    let ok = request.hasPrefix("GET \(self.path) HTTP/1.1\r\n")
                        && request.lowercased().contains("\r\nhost: 127.0.0.1:\(self.listener?.port?.rawValue ?? 0)\r\n")
                    let body = Data((ok ? FeishuComponentPage.html : "Not found").utf8)
                    let header = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
                        Task { @MainActor in self?.close(id) }
                    })
                } else if complete { self.close(id) }
                else { self.read(connection, id: id, buffer: buffer) }
            }
        }
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}

enum FeishuComponentPage {
    // Version and constructor match the current official component documentation.
    static let html = #"""
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>html,body,#document{margin:0;width:100%;height:100%;overflow:hidden}body{background:#fff}</style>
    </head><body><div id="document"></div><script>
    let component;
    const report = event => window.webkit.messageHandlers.feishuComponent.postMessage(event);
    window.mountDocument = (auth, src, theme) => {
      if (component) component.destroy();
      component = new window.DocComponentSdk({src, mount:document.getElementById('document'), auth, theme,
        size:{width:'100%',height:window.innerHeight},
        config:{extensions:{suiteNavBar:{disable:true},content:{mode:'default',readonly:true,
          titleVisible:true,hyperlinkHandler:'outer'},like:{disable:true}}},
        onAuthError:()=>report('authError'), onError:()=>report('error'),
        onMountSuccess:()=>report('mounted'), onMountTimeout:()=>report('timeout')});
      component.start().catch(()=>report('error'));
    };
    // Fixed viewport, including after a native split-view/window resize.
    new ResizeObserver(()=>{
      const frame=document.querySelector('#document iframe');
      if(frame){frame.style.height=window.innerHeight+'px';frame.style.width='100%';}
      document.getElementById('document').style.height=window.innerHeight+'px';
    }).observe(document.documentElement);
    window.addEventListener('pagehide',()=>{if(component)component.destroy();});
    const sdk=document.createElement('script');
    sdk.src='https://sf1-scmcdn-cn.feishucdn.com/obj/feishu-static/docComponentSdk/lib/1.0.13.js';
    sdk.onload=()=>report('ready'); sdk.onerror=()=>report('error'); document.head.appendChild(sdk);
    </script></body></html>
    """#
}
