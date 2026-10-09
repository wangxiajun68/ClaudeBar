#!/usr/bin/env python3
"""Production gateway policy/storage/wire tests and real loopback transport.

Only synthetic providers, temporary files and owned fixture processes are used.
"""
from pathlib import Path
import http.client
import json
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = Path(__file__).resolve().parents[1]
models = root / 'Sources/ClaudeBar/Models'
utils = root / 'Sources/ClaudeBar/Utils'

def declaration(source, marker):
    start = source.index(marker)
    pos = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[pos] == '{') - (source[pos] == '}')
        pos += 1
    return source[start:pos]

def method(source, marker):
    start = source.index(marker)
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end]

common = [models/'FreeModelPool.swift', utils/'GatewayTaskRouter.swift', utils/'FreeModelGateway.swift', utils/'PrivateFileWriter.swift',
          utils/'GatewayWireAdapter.swift', utils/'ConversationMedia.swift', utils/'AgentProtocolBridge.swift',
          utils/'CodexProxyTransform.swift']

policy = r'''
import Foundation
func expect(_ failure: GatewayFailure, _ operation: () async throws -> Void) async {
    do { try await operation(); fatalError("Expected \(failure)") }
    catch { precondition(error as? GatewayFailure == failure, String(describing:error)) }
}
@main struct Policy {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let price: [String:Any] = ["prompt":"0", "completion":"0", "request":"0"]
        let free: [String:Any] = ["id":"fixture/free", "name":"Fixture", "context_length":32000,
            "pricing":price, "architecture":["input_modalities":["text","image"],"output_modalities":["text"]],
            "supported_parameters":["tools","response_format"], "top_provider":["max_completion_tokens":8192]]
        var rows = [free]
        for (id, prices) in [("paid:free",["prompt":"0.1","completion":"0"]),
                              ("unknown",["prompt":"0"]), ("paid-search",["prompt":"0","completion":"0","web_search":"0.01"]),
                              ("malformed",["prompt":"bad","completion":"0"]), ("numeric-prefix",["prompt":"0bad","completion":"0"]),
                              ("negative",["prompt":"-1","completion":"0"])] {
            var row = free; row["id"] = id; row["pricing"] = prices; rows.append(row)
        }
        rows.append(free)
        var booleanPrice = free; booleanPrice["id"] = "boolean"; booleanPrice["pricing"] = ["prompt":false,"completion":false]; rows.append(booleanPrice)
        let catalog = try FreeModelPool.parseCatalog(JSONSerialization.data(withJSONObject:["data":rows]))
        precondition(catalog.count == 1 && catalog[0].supportsTools && catalog[0].supportsImages && catalog[0].supportsJSON)
        precondition(FreeModelPool.isOpenRouter("https://openrouter.ai/api/v1"))
        for base in ["http://openrouter.ai/api/v1","https://openrouter.ai.evil/api/v1","https://user@openrouter.ai/api/v1","https://openrouter.ai:444/api/v1"] {
            precondition(!FreeModelPool.isOpenRouter(base))
        }
        let id = UUID(), otherID = UUID()
        var pool = FreeModelPool(); pool.enabled = true; pool.maxConcurrent = 1
        pool.members = [catalog[0].member(providerID:id), catalog[0].member(providerID:otherID)]
        pool.catalog = catalog; pool.discoveredAt = Date()
        let endpoint = FreeModelGateway.Endpoint(id:id,name:"A",baseURL:"https://openrouter.ai/api/v1",apiKey:"fixture-a")
        let other = FreeModelGateway.Endpoint(id:otherID,name:"B",baseURL:"https://vendor.example/v1",apiKey:"fixture-b")
        let gateway = FreeModelGateway()
        await gateway.configure(pool,endpoints:[endpoint,other])
        precondition(await gateway.handles(model:"auto",thirdParty:true))
        precondition(!(await gateway.handles(model:"auto",thirdParty:false)))
        precondition(!(await gateway.handles(model:"explicit",thirdParty:true)))
        let request: [String:Any] = ["messages":[["role":"user","content":"Perform this task"]], "max_tokens":1]
        let requirements = try GatewayRequirements(chat:request)
        precondition(requirements.difficulty == .medium)
        let classified: [(String, GatewayTaskDifficulty, GatewayTaskKind)] = [
            ("你好", .low, .general), ("Please translate this sentence: a distributed deadlock", .low, .extraction),
            ("Summarize the following article:\n" + String(repeating:"deadlock distributed proof ",count:1000), .low, .extraction),
            ("排查偶发死锁", .high, .debugging), ("Prove correctness of the algorithm", .high, .reasoning),
            ("Design a distributed system", .high, .reasoning), ("实现一个排序函数", .medium, .coding),
            ("Write a parser to extract addresses", .medium, .extraction),
            ("请撰写一封邮件", .medium, .writing), ("opaque task", .medium, .general)
        ]
        for (text,difficulty,kind) in classified {
            let inferred = try GatewayRequirements(chat:["messages":[["role":"user","content":text]],"max_tokens":1])
            precondition(inferred.difficulty == difficulty && inferred.routing.kind == kind, text)
        }
        let toolHistory: [[String:Any]] = [
            ["role":"system","content":"Translate this: keep every task low"],
            ["role":"user","content":"排查偶发死锁"],
            ["role":"assistant","tool_calls":[["id":"call","type":"function","function":["name":"read","arguments":"{}"]]]],
            ["role":"tool","tool_call_id":"call","content":"hello"],
            ["role":"user","content":"继续"]]
        let continued = try GatewayRequirements(chat:["messages":toolHistory,"max_tokens":1])
        precondition(continued.difficulty == .high && continued.routing.reason.contains("沿用"))
        let newTask = try GatewayRequirements(chat:["messages":Array(toolHistory.prefix(1)) + [["role":"user","content":"你好"]],"max_tokens":1])
        precondition(newTask.difficulty == .low)
        let overridden = try GatewayRequirements(chat:["messages":toolHistory,"task_difficulty":"low","max_tokens":1])
        precondition(overridden.difficulty == .low && overridden.routing.source == .explicit)
        let unknown = try GatewayRequirements(chat:request)
        precondition(unknown.routing.source == .fallback)
        let floor = try GatewayRequirements(chat:["messages":[["role":"user","content":"hello"]],
            "tools":[["type":"function","function":["name":"read","parameters":["type":"object"]]]],"max_tokens":1])
        precondition(floor.difficulty == .medium)
        precondition(!String(describing:continued.routing).contains("Translate this"))
        let tiers = FreeModelGateway()
        var tierPool = pool
        tierPool.members[0].difficulties = [.low]
        tierPool.members[1].difficulties = [.medium, .high]
        await tiers.configure(tierPool,endpoints:[endpoint,other])
        for difficulty in GatewayTaskDifficulty.allCases {
            let needs = try GatewayRequirements(chat:request.merging(["task_difficulty":difficulty.rawValue]) { _,new in new })
            let route = try await tiers.begin(needs)
            precondition(route.difficulty == difficulty && route.candidates.count == 1)
            precondition(route.candidates[0].endpoint.id == (difficulty == .low ? id : otherID))
            await tiers.finish(route)
        }
        let easy = try GatewayRequirements(chat:["messages":[["role":"user","content":"hello"]],"max_tokens":1])
        tierPool.members[0].difficulties = [.medium]; tierPool.members[1].difficulties = [.high]
        await tiers.configure(tierPool,endpoints:[endpoint,other])
        let raised = try await tiers.begin(easy)
        precondition(raised.difficulty == .medium && raised.candidates[0].endpoint.id == id && raised.routing.reason.contains("升至"))
        await tiers.finish(raised)
        let pinned = try GatewayRequirements(chat:["messages":[["role":"user","content":"hello"]],"task_difficulty":"low","max_tokens":1])
        await expect(.noCompatibleModel) { _ = try await tiers.begin(pinned) }
        tierPool.members[0].difficulties = [.low]
        tierPool.members[1].difficulties = []
        await tiers.configure(tierPool,endpoints:[endpoint,other])
        await expect(.noCompatibleModel) { _ = try await tiers.begin(requirements) }
        for invalid: Any in ["unknown", "HIGH", 1, NSNull()] {
            do { _ = try GatewayRequirements(chat:request.merging(["task_difficulty":invalid]) { _,new in new }); fatalError() }
            catch { precondition(error as? GatewayFailure == .invalidDifficulty) }
        }
        var legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(pool.members[0])) as! [String:Any]
        legacy.removeValue(forKey:"difficulties")
        let restored = try JSONDecoder().decode(FreeModelPool.Member.self,from:JSONSerialization.data(withJSONObject:legacy))
        precondition(restored.difficulties == GatewayTaskDifficulty.allCases)
        let plan = try await gateway.begin(requirements)
        precondition(plan.candidates.count == 2)
        await expect(.busy) { _ = try await gateway.begin(requirements) }
        try await gateway.started(plan.candidates[0],plan:plan)
        await gateway.report(plan.candidates[0],plan:plan,status:429,latency:0.1,retryAfter:120)
        await gateway.finish(plan)
        let second = try await gateway.begin(requirements)
        precondition(second.candidates.count == 1 && second.candidates[0].endpoint.id == otherID)
        await gateway.report(second.candidates[0],plan:second,status:200,latency:0.2)
        await gateway.finish(second)
        precondition((await gateway.snapshot()).active == 0)
        var client = request
        client["model"] = "paid-model"; client["models"] = ["paid"]; client["plugins"] = [["id":"web"]]
        client["provider"] = ["max_price":["prompt":100]]
        client["task_difficulty"] = "high"
        let outbound = FreeModelGateway.outbound(client,candidate:plan.candidates[0],stream:true)
        precondition(outbound["model"] as? String == "fixture/free" && outbound["models"] == nil && outbound["plugins"] == nil)
        precondition(outbound["task_difficulty"] == nil)
        precondition(outbound["stream_options"] == nil)
        let compatible = FreeModelGateway.outbound(client,candidate:plan.candidates[1],stream:true)
        precondition((compatible["stream_options"] as? [String:Bool])?["include_usage"] == true)
        let provider = outbound["provider"] as! [String:Any]
        precondition((provider["max_price"] as! [String:Int]).values.allSatisfy { $0 == 0 })
        precondition(!String(describing:await gateway.snapshot()).contains("fixture-a"))

        pool.requestsPerMinute = 1; await gateway.resetHealth(); await gateway.configure(pool,endpoints:[endpoint,other])
        await expect(.rateLimited) { _ = try await gateway.begin(requirements) }
        let later = Date().addingTimeInterval(61)
        let after = try await gateway.begin(requirements,now:later)
        try await gateway.started(after.candidates[0],plan:after,now:later)
        await expect(.rateLimited) { try await gateway.started(after.candidates[1],plan:after,now:later) }
        await gateway.finish(after)
        pool.requestsPerMinute = 60; pool.discoveredAt = Date().addingTimeInterval(-49*3600)
        await gateway.configure(pool,endpoints:[endpoint])
        await expect(.noCompatibleModel) { _ = try await gateway.begin(requirements,now:later) }
        pool.enabled = false; await gateway.configure(pool,endpoints:[endpoint])
        precondition(await gateway.handles(model:"auto",thirdParty:true))
        await expect(.disabled) { _ = try await gateway.begin(requirements) }
        let image = try GatewayRequirements(chat:["messages":[["role":"user","content":[["type":"image_url","image_url":["url":"data:image/png;base64,fixture"]]]]],"max_tokens":1])
        var plain = pool.members[0]; plain.supportsImages = false
        precondition(!image.accepts(plain))
        let history = try GatewayRequirements(chat:["messages":[["role":"assistant","tool_calls":[["id":"call","type":"function","function":["name":"read","arguments":"{}"]]]]],"max_tokens":1])
        plain.supportsTools = false; precondition(!history.accepts(plain))
        let adapted = try GatewayWireAdapter.request(["model":"auto","input":"hello","max_output_tokens":8,
            "task_difficulty":"high", "text":["format":["type":"json_object"]]],path:"/v1/responses")
        precondition(adapted.chat["max_tokens"] as? Int == 8 && adapted.chat["response_format"] != nil)
        precondition(try GatewayRequirements(chat:adapted.chat).difficulty == .high)
        for extra: [String:Any] in [["tools":[["type":"openrouter:web_search"]]], ["modalities":["text","audio"]]] {
            do { _ = try GatewayWireAdapter.request(request.merging(extra) { _,new in new },path:"/v1/chat/completions"); fatalError() }
            catch { precondition(error as? GatewayFailure == .invalidRequest) }
        }
        do { _ = try GatewayWireAdapter.request(["input":"ping","tools":[["type":"namespace","name":"hosted","tools":[["type":"web_search"]]]]],path:"/v1/responses"); fatalError() }
        catch { precondition(error as? GatewayFailure == .invalidRequest) }
        do { _ = try GatewayWireAdapter.request(["previous_response_id":"resp-foreign"],path:"/v1/responses"); fatalError() }
        catch { precondition(error as? GatewayFailure == .invalidRequest) }
        for code in [401,402,403,404,408,410,429,500,502,503,504] { precondition(FreeModelGateway.retryable(status:code)) }
        for code in [400,422,200,0] { precondition(!FreeModelGateway.retryable(status:code)) }

        let storage = FreeModelPoolStorage(url:folder.appendingPathComponent("pool.json"))
        precondition(try await storage.load() == FreeModelPool())
        try await storage.save(pool)
        precondition(try await storage.load() == pool)
        let attrs = try FileManager.default.attributesOfItem(atPath:folder.appendingPathComponent("pool.json").path)
        precondition((attrs[.posixPermissions] as! NSNumber).intValue == 0o600)
        pool.version = 99
        do { try await storage.save(pool); fatalError() } catch { }
        precondition(try await storage.load().version == 1)
        print("PASS: zero-price discovery, automatic task classification/continuation/upward selection, explicit tiers/validation/migration, capabilities, cooldown, admission, privacy and private storage")
    }
}
'''

server = (utils/'CodexProxyServer.swift').read_text()
selected = ['    private func forwardGateway(', '    private func forwardGatewayCandidate',
            '    private func writeMigration', '    private func chatCompletionsURL',
            '    private func readRequest', '    private func receive', '    private func sseHead',
            '    private func write(', '    private func respond', '    private func isAuthorized',
            '    private static func constantTimeEquals', '    static func loadOrCreateToken',
            '    private final class InterruptWatcher']
transport = r'''
import Foundation
import Network
import Security
import Darwin
enum ProxyLogKind { case anthropic, openaiChat, openaiResponses }
enum ProxyLogSource { case codex }
enum CaptureKind { case openaiChat }
enum CaptureState { case done, error, aborted }
final class CaptureTap {
    func applyChat(_ value:[String:Any]) {}
    func finish(state:CaptureState,status:Int,error:String?) {}
}
final class ProxyLogTap {
    func note(tokens:TokenTotals?) {}
    func finish(status:Int,error:String? = nil,tokens:TokenTotals? = nil) {}
}
class CodexProxyServer: @unchecked Sendable {
    let tokenPath:URL
    static let tokenByteCount = 32
    init(tokenPath:URL) { self.tokenPath = tokenPath }
    struct HTTPRequest { var method:String; var path:String; var headers:[String:String]; var body:Data? }
    static func throwIfInterrupted(_ tap:CaptureTap?) throws { try Task.checkCancellation() }
    static func wasInterrupted() -> Bool { Task.isCancelled }
    static func attachUpstream(_ tap:CaptureTap?,task:URLSessionDataTask) {}
    func bindInterrupt(_ tap:CaptureTap?,connection:NWConnection) {}
    func startLog(_ request:HTTPRequest,source:ProxyLogSource,kind:ProxyLogKind,provider:String) async -> ProxyLogTap { ProxyLogTap() }
    func makeOpenAITap(kind:CaptureKind,request:HTTPRequest,json:[String:Any],rewritten:Data,stream:Bool,upstream:CodexProxyState.UpstreamEndpoint) async -> CaptureTap? { nil }
    METHODS
    func handle(_ connection:NWConnection) async {
        defer { connection.cancel() }
        guard let request = await readRequest(connection) else { return }
        guard isAuthorized(request) else {
            await respond(connection,status:"401 Unauthorized",contentType:"application/json",body:Data("{}".utf8)); return
        }
        guard let data = request.body, let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return }
        await forwardGateway(connection,request:request,json:json,path:request.path)
    }
}
enum CodexProxyState {
    struct UpstreamEndpoint { var baseURL:String; var apiKey:String; var wireAPI:String; var name:String }
}
@main struct Transport {
    static func main() async throws {
        let folder = URL(fileURLWithPath:CommandLine.arguments[1])
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let settings = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let firstID = UUID(), secondID = UUID()
        var pool = FreeModelPool(); pool.enabled = true; pool.strategy = .priority; pool.requestsPerMinute = 60
        pool.members = [FreeModelPool.Member(providerID:firstID,model:"first",name:"First",contextLength:128000,supportsTools:true,supportsImages:false,supportsJSON:true),
                        FreeModelPool.Member(providerID:secondID,model:"second",name:"Second",contextLength:128000,supportsTools:true,supportsImages:false,supportsJSON:true)]
        if let tiers = settings["tiers"] as? [String] {
            for index in pool.members.indices { pool.members[index].difficulties = [GatewayTaskDifficulty(rawValue:tiers[index])!] }
        }
        let base = settings["base"] as! String
        await FreeModelGateway.shared.configure(pool,endpoints:[
            .init(id:firstID,name:"First",baseURL:base+"/first/v1",apiKey:"fixture-upstream-first"),
            .init(id:secondID,name:"Second",baseURL:base+"/second/v1",apiKey:"fixture-upstream-second")])
        let tokenPath = folder.appendingPathComponent("proxy-token")
        _ = try CodexProxyServer.loadOrCreateToken(at:tokenPath)
        let server = CodexProxyServer(tokenPath:tokenPath)
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let listener = try NWListener(using:params)
        listener.newConnectionHandler = { connection in
            connection.start(queue:.global()); Task { await server.handle(connection) }
        }
        listener.start(queue:.global())
        for _ in 0..<300 { if case .ready = listener.state { break }; try await Task.sleep(for:.milliseconds(10)) }
        guard let port = listener.port else { fatalError("No port") }
        print("READY \(port.rawValue)"); fflush(stdout)
        while !Task.isCancelled { try await Task.sleep(for:.seconds(60)) }
    }
}
'''.replace('METHODS', '\n'.join(method(server, marker) for marker in selected))
transport += '\n' + declaration((utils/'StreamAssembler.swift').read_text(), 'struct TokenTotals: Equatable {') + '\n'

class Upstream(BaseHTTPRequestHandler):
    calls = []
    mode = '429'
    def log_message(self, *args):
        pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.calls.append((self.path, dict(self.headers), body))
        first = self.path.startswith('/first/')
        expected = 'fixture-upstream-first' if first else 'fixture-upstream-second'
        assert self.headers['Authorization'] == 'Bearer ' + expected
        assert body['model'] == ('first' if first else 'second')
        assert 'models' not in body and 'plugins' not in body
        assert 'task_difficulty' not in body
        if first and self.mode == 'redirect':
            self.send_response(307); self.send_header('Location', '/unexpected-redirect'); self.end_headers(); return
        if first and self.mode in ('429', '401'):
            code = int(self.mode)
            self.send_response(code); self.send_header('Retry-After', '60'); self.end_headers()
            self.wfile.write(b'{"error":"never forward fixture credential errors"}'); return
        if not body.get('stream'):
            result = {'id': 'chat-fixture', 'model': body['model'], 'choices': [{'message': {'role':'assistant','content':'fixture answer'}, 'finish_reason':'stop'}],
                      'usage': {'prompt_tokens':10,'completion_tokens':2,'total_tokens':12}}
            data = json.dumps(result).encode()
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(data); return
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        if first and self.mode == 'sse-error':
            self.wfile.write(b'data: {"error":{"code":429,"message":"fixture unavailable"}}\n\n'); return
        self.wfile.write(b'data: {"id":"fixture","choices":[{"index":0,"delta":{"role":"assistant","content":"fixture answer"}}]}\n\n')
        if self.mode == 'incomplete':
            return
        self.wfile.write(b'data: {"id":"fixture","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n')
        self.wfile.write(b'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}\n\n')
        self.wfile.write(b'data: [DONE]\n\n')

with tempfile.TemporaryDirectory(prefix='claudebar-gateway-') as temporary:
    folder = Path(temporary)
    types = folder/'Catalog.swift'
    catalog = (models/'ProviderCatalog.swift').read_text().split('struct ProviderSetupDraft')[0]
    state = (models/'CodexProxyState.swift').read_text()
    types.write_text(catalog + '\nenum LocalProxyAddress {\n' + method(state, '    static func isLoopback') + '\n}\n')
    common.append(types)
    policy = policy.replace('precondition(', 'check(')
    policy = 'func check(_ value:Bool,_ message:String = "") { if !value { FileHandle.standardError.write(Data(("FAILED: " + message + "\\n").utf8)); exit(1) } }\n' + policy
    policy_file = folder/'Policy.swift'; policy_file.write_text(policy)
    binary = folder/'policy'
    subprocess.run(['swiftc','-O','-parse-as-library',*map(str,common),str(policy_file),'-o',str(binary)],check=True)
    subprocess.run([str(binary),temporary],check=True)
    transport_file = folder/'Transport.swift'; transport_file.write_text(transport)
    bridge_config = utils/'MigrationBridgeConfiguration.swift'
    # chatCompletionsURL is the existing production joiner; its unrelated
    # migration endpoint types are also compiled from production.
    extra = [bridge_config, models/'SessionMigration.swift', root/'Sources/Shared/BuildChannel.swift']
    server_binary = folder/'gateway-server'
    subprocess.run(['swiftc','-O','-parse-as-library',*map(str,common+extra),str(transport_file),'-o',str(server_binary)],check=True)
    upstream = ThreadingHTTPServer(('127.0.0.1',0),Upstream)
    thread = threading.Thread(target=upstream.serve_forever,daemon=True); thread.start()
    def run_case(mode, path, payload, expected_status=200, tiers=None):
        Upstream.mode = mode; Upstream.calls = []
        case = folder/mode; case.mkdir(exist_ok=True)
        process = subprocess.Popen([str(server_binary),str(case)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            process.stdin.write(json.dumps({'base':f'http://127.0.0.1:{upstream.server_port}', 'tiers':tiers})); process.stdin.close()
            line = process.stdout.readline().strip()
            assert line.startswith('READY '), (line, process.stderr.read())
            port = int(line.split()[1]); token = (case/'proxy-token').read_text()
            def send(auth):
                connection = http.client.HTTPConnection('127.0.0.1',port,timeout=20)
                headers = {'Content-Type':'application/json','User-Agent':'fixture-third-party'}
                if auth: headers['Authorization'] = 'Bearer ' + token
                connection.request('POST',path,json.dumps(payload),headers)
                response = connection.getresponse(); data = response.read(); status = response.status; connection.close()
                return status,data
            status,_ = send(False); assert status == 401 and not Upstream.calls
            status,data = send(True)
            assert status == expected_status, (status,data)
            return data, list(Upstream.calls)
        finally:
            process.terminate(); process.wait(timeout=10)
    try:
        chat = {'model':'auto','messages':[{'role':'user','content':'ping'}],'max_tokens':8,
                'models':['paid-fallback'],'plugins':[{'id':'web'}]}
        data,calls = run_case('429','/v1/chat/completions',chat)
        assert json.loads(data)['model'] == 'second' and len(calls) == 2
        data,calls = run_case('401','/v1/chat/completions',chat)
        assert json.loads(data)['model'] == 'second' and len(calls) == 2
        data,calls = run_case('redirect','/v1/chat/completions',chat,400)
        assert len(calls) == 1  # task-specific cancellation delegate still refuses redirects
        for difficulty,model in [('low','first'),('high','second')]:
            data,calls = run_case('tier-'+difficulty,'/v1/chat/completions',dict(chat,task_difficulty=difficulty),tiers=['low','high'])
            assert json.loads(data)['model'] == model and len(calls) == 1
        data,calls = run_case('tier-default','/v1/chat/completions',chat,tiers=['low','high'])
        assert json.loads(data)['model'] == 'first' and len(calls) == 1
        complex_chat = dict(chat,messages=[{'role':'user','content':'排查偶发死锁'}])
        data,calls = run_case('tier-auto-high','/v1/chat/completions',complex_chat,tiers=['low','high'])
        assert json.loads(data)['model'] == 'second' and len(calls) == 1
        data,calls = run_case('tier-unknown','/v1/chat/completions',dict(chat,messages=[{'role':'user','content':'Perform this task'}]),tiers=['low','high'])
        assert json.loads(data)['model'] == 'second' and len(calls) == 1
        data,calls = run_case('tier-auto-raise','/v1/chat/completions',chat,tiers=['medium','high'])
        assert json.loads(data)['model'] == 'first' and len(calls) == 1
        data,calls = run_case('tier-explicit-strict','/v1/chat/completions',dict(chat,task_difficulty='low'),400,tiers=['medium','high'])
        assert not calls
        data,calls = run_case('429','/v1/chat/completions',dict(chat,task_difficulty='high'),429,tiers=['high','low'])
        assert len(calls) == 1  # never escape the tier on failure
        data,calls = run_case('tier-invalid','/v1/chat/completions',dict(chat,task_difficulty='unknown'),400)
        assert not calls and b'task_difficulty' in data
        response = {'model':'auto','input':'ping','max_output_tokens':8,'stream':False}
        data,calls = run_case('responses','/v1/responses',response)
        value = json.loads(data)
        assert value['object'] == 'response' and value['output'][0]['content'][0]['text'] == 'fixture answer'
        assert value['usage']['total_tokens'] == 12 and calls[0][2]['max_tokens'] == 8
        data,calls = run_case('responses-high','/v1/responses',dict(response,task_difficulty='high'),tiers=['low','high'])
        assert calls[0][2]['model'] == 'second' and len(calls) == 1
        message = {'model':'auto','messages':[{'role':'user','content':'ping'}],'max_tokens':8,'stream':False}
        data,calls = run_case('anthropic','/v1/messages',message)
        assert json.loads(data)['content'][0]['text'] == 'fixture answer'
        data,calls = run_case('responses-auto-high','/v1/responses',dict(response,input='排查偶发死锁'),tiers=['low','high'])
        assert calls[0][2]['model'] == 'second' and len(calls) == 1
        data,calls = run_case('anthropic-auto-high','/v1/messages',complex_chat,tiers=['low','high'])
        assert calls[0][2]['model'] == 'second' and len(calls) == 1
        data,calls = run_case('anthropic-low','/v1/messages',dict(message,task_difficulty='low'),tiers=['low','high'])
        assert calls[0][2]['model'] == 'first' and len(calls) == 1
        data,calls = run_case('chat-auto-continuation','/v1/chat/completions',dict(chat,messages=[
            {'role':'user','content':'排查偶发死锁'},
            {'role':'assistant','tool_calls':[{'id':'call','type':'function','function':{'name':'read','arguments':'{}'}}]},
            {'role':'tool','tool_call_id':'call','content':'hello'},
            {'role':'user','content':'继续'}]),tiers=['low','high'])
        assert calls[0][2]['model'] == 'second' and len(calls) == 1
        data,calls = run_case('responses-auto-continuation','/v1/responses',dict(response,input=[
            {'type':'message','role':'user','content':[{'type':'input_text','text':'排查偶发死锁'}]},
            {'type':'function_call','call_id':'call','name':'read','arguments':'{}'},
            {'type':'function_call_output','call_id':'call','output':'hello'},
            {'type':'message','role':'user','content':[{'type':'input_text','text':'继续'}]}]),tiers=['low','high'])
        assert calls[0][2]['model'] == 'second' and len(calls) == 1
        data,calls = run_case('anthropic-auto-continuation','/v1/messages',dict(message,messages=[
            {'role':'user','content':'排查偶发死锁'},
            {'role':'assistant','content':[{'type':'tool_use','id':'call','name':'read','input':{}}]},
            {'role':'user','content':[{'type':'tool_result','tool_use_id':'call','content':'hello'},{'type':'text','text':'继续'}]}]),tiers=['low','high'])
        assert calls[0][2]['model'] == 'second' and len(calls) == 1
        data,calls = run_case('responses-stream','/v1/responses',dict(response,stream=True))
        assert data.count(b'"type":"response.completed"') == 1 and b'fixture answer' in data and b'[DONE]' in data
        data,calls = run_case('anthropic-stream','/v1/messages',dict(message,stream=True))
        assert b'event: message_stop' in data and b'fixture answer' in data
        data,calls = run_case('count-tokens','/v1/messages/count_tokens',dict(message,task_difficulty='high'))
        assert json.loads(data)['input_tokens'] > 0 and not calls
        streaming = dict(chat,stream=True)
        data,calls = run_case('sse-error','/v1/chat/completions',streaming)
        assert b'fixture answer' in data and b'[DONE]' in data and len(calls) == 2
        data,calls = run_case('incomplete','/v1/chat/completions',streaming)
        assert len(calls) == 1 and b'gateway_error' in data and b'[DONE]' in data
        unsupported = dict(chat,messages=[{'role':'user','content':[{'type':'image_url','image_url':{'url':'fixture'}}]}])
        data,calls = run_case('image','/v1/chat/completions',unsupported,400)
        assert not calls and b'error' in data
        print('PASS: real auth, credential injection, three-protocol automatic and explicit difficulty routing, strict tier failover, 429/401 fallback, first-frame fallback and no midstream retry')
    finally:
        upstream.shutdown(); upstream.server_close(); thread.join(timeout=5)
