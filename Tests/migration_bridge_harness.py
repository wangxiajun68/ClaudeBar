"""Extract unchanged production transport methods for isolated loopback labs.

No app is launched; all client stores and proxy tokens belong to the caller's
temporary fixture. Upstream defaults to a local fixture, never a real account.
"""
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[1]

def method(source, marker):
    start = source.index(marker)
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end]

def build(folder, channel='release'):
    folder = Path(folder)
    server = (ROOT/'Sources/ClaudeBar/Utils/CodexProxyServer.swift').read_text()
    state = (ROOT/'Sources/ClaudeBar/Models/CodexProxyState.swift').read_text()
    local = 'enum LocalProxyAddress {\n' + method(state, '    static func isLoopback') + '\n}\n'
    selected = ['    private func forwardMigration', '    private func writeMigration',
                '    private func streamSSE', '    private func joinURL',
                '    private func chatCompletionsURL', '    private func readRequest',
                '    private func receive', '    private func sseHead', '    private func write(',
                '    private func respond', '    private func isAuthorized',
                '    private static func constantTimeEquals', '    static func loadOrCreateToken']
    body = '\n'.join(method(server, marker) for marker in selected)
    body = body.replace('        } catch {\n            // Do not expose', '        } catch {\n            if let failure = error as? AgentProtocolBridge.Failure { _ = folderSummary("BRIDGE " + String(describing:failure) + "\\n") } else { _ = folderSummary("NETWORK " + String((error as NSError).code) + "\\n") }\n            // Do not expose')
    fixture = r'''
import Foundation
import Network
import Security
import Darwin
class CodexProxyServer: @unchecked Sendable {
    let state: CodexProxyState
    let tokenPath: URL
    static let tokenByteCount = 32
    static let upstreamSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 240
        config.urlCache = nil; config.httpCookieStorage = nil
        if CommandLine.arguments.contains("--network-proxy") {
            // Explicit network lab setting, never an app/dev escape hatch.
            config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 17890,
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 17890]
        }
        return URLSession(configuration:config)
    }()
    init(state:CodexProxyState, tokenPath:URL) { self.state = state; self.tokenPath = tokenPath }
    struct HTTPRequest { var method:String; var path:String; var headers:[String:String]; var body:Data? }
    static func attachUpstream(_ ignored: Any?, task:URLSessionDataTask) {}
    static func wasInterrupted() -> Bool { false }
    __METHODS__
    private func folderSummary(_ line:String) -> Data {
        let bytes = Data(line.utf8)
        if CommandLine.arguments.contains("--network-proxy") {
            let url = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("request-summary.log")
            if !FileManager.default.fileExists(atPath:url.path) {
                FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])
            }
            if let file = try? FileHandle(forWritingTo:url) {
                defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf:bytes)
            }
        }
        return bytes
    }
    func handle(_ connection:NWConnection) async {
        guard let request = await readRequest(connection) else { connection.cancel(); return }
        guard isAuthorized(request) else {
            await respond(connection,status:"401 Unauthorized",contentType:"application/json",body:Data("{}".utf8))
            connection.cancel(); return
        }
        if CommandLine.arguments.contains("--network-proxy"), let bytes = request.body,
           let body = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any] {
            func shape(_ value:Any?) -> String {
                if value is String { return "string" }
                guard let blocks = value as? [[String:Any]] else { return String(describing:type(of:value as Any)) }
                return blocks.map { block in
                    (block["type"] as? String ?? "?") + " keys=" + block.keys.sorted().joined(separator:",") + " text=" + String(block["text"] is String)
                }.joined(separator:";")
            }
            let messageShapes = (body["messages"] as? [[String:Any]] ?? []).map { ($0["role"] as? String ?? "?") + " " + shape($0["content"]) }
            _ = folderSummary("SHAPES " + messageShapes.joined(separator:" | ") + " SYSTEM=" + shape(body["system"]) + "\n")
            let maximum = body["max_tokens"] as? Int ?? -1
            _ = folderSummary("MAX TOKENS " + String(maximum) + "\n")
            do {
                _ = try AgentProtocolBridge.request(body,model:"fixture")
                _ = folderSummary("REQUEST VALID\n")
            } catch { _ = folderSummary("REQUEST REJECTED\n") }
            let names = (body["tools"] as? [[String:Any]] ?? []).map { tool in
                (tool["name"] as? String ?? "?") + ":" + (tool["type"] as? String ?? "function") + ":" + String(tool["input_schema"] != nil)
            }
            let summary = folderSummary("TOOL NAMES " + names.joined(separator:",") + "\n")
            FileHandle.standardError.write(summary)
        }
        let path = request.path.split(separator:"?").first.map(String.init) ?? request.path
        await forwardMigration(connection,request:request,path:path)
    }
}
@main struct Lab {
    static func main() async throws {
        let folder = URL(fileURLWithPath:CommandLine.arguments[1])
        let tokenPath = folder.appendingPathComponent("proxy-token")
        let state = CodexProxyState()
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let settings = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let id = UUID(uuidString:settings["id"] as! String)!
        let endpoint = MigrationBridgeEndpoint(baseURL:settings["baseURL"] as! String,
            apiKey:settings["apiKey"] as! String,wireAPI:settings["wireAPI"] as! String,
            model:settings["model"] as! String,name:"Isolated fixture",reasoningEffort:settings["reasoningEffort"] as? String ?? "")
        try await state.setMigrationEndpoint(endpoint,for:id)
        let server = CodexProxyServer(state:state,tokenPath:tokenPath)
        _ = try CodexProxyServer.loadOrCreateToken(at:tokenPath)
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let listener = try NWListener(using:params)
        listener.newConnectionHandler = { connection in
            connection.start(queue:.global())
            Task { await server.handle(connection) }
        }
        listener.start(queue:.global())
        for _ in 0..<300 {
            if case .ready = listener.state { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        guard let port = listener.port else { throw URLError(.cannotConnectToHost) }
        print("READY " + String(port.rawValue)); fflush(stdout)
        // EOF on stdout or parent termination owns this isolated process only.
        while !Task.isCancelled { try await Task.sleep(nanoseconds:1_000_000_000) }
    }
}
'''.replace('__METHODS__',body)
    (folder/'Harness.swift').write_text(fixture)
    catalog = (ROOT/'Sources/ClaudeBar/Models/ProviderCatalog.swift').read_text().split('struct ProviderSetupDraft')[0]
    (folder/'State.swift').write_text('import Foundation\n'+local+catalog+state[state.index('actor CodexProxyState'):])
    sources = [ROOT/'Sources/Shared/BuildChannel.swift', ROOT/'Sources/ClaudeBar/Models/SessionMigration.swift',
        ROOT/'Sources/ClaudeBar/Utils/MigrationBridgeConfiguration.swift',
        ROOT/'Sources/ClaudeBar/Utils/ConversationMedia.swift',
        ROOT/'Sources/ClaudeBar/Utils/AgentProtocolBridge.swift',
        ROOT/'Sources/ClaudeBar/Utils/CodexProxyTransform.swift',folder/'State.swift',folder/'Harness.swift']
    binary = folder/'bridge-server'
    subprocess.run(['swiftc','-D','CLAUDEBAR_'+channel.upper(),'-O','-parse-as-library',*map(str,sources),'-o',str(binary)],check=True)
    return binary
