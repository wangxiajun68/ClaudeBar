#!/usr/bin/env python3
"""Production gateway policy/storage/wire tests and real loopback transport.

Only synthetic providers, temporary files and owned fixture processes are used.
"""
from pathlib import Path
import http.client
import json
import socket
import subprocess
import tempfile
import threading
import time
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

common = [utils/'GatewayProviderImport.swift', utils/'GatewayTopologyLayout.swift', models/'FreeModelPool.swift', utils/'GatewayTaskRouter.swift', utils/'FreeModelGateway.swift', utils/'PrivateFileWriter.swift',
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
        var pool = FreeModelPool(); pool.enabled = true; pool.maxConcurrent = 1; pool.maxQueued = 0
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
        await gateway.report(after.candidates[0],plan:after,status:500,latency:0.1,now:later)
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

        let liveGateway = FreeModelGateway()
        var livePool = FreeModelPool(); livePool.enabled = true; livePool.maxConcurrent = 8
        livePool.members = [plain, pool.members[1]]; livePool.catalog = catalog; livePool.discoveredAt = Date()
        await liveGateway.configure(livePool,endpoints:[endpoint,other])
        let stream = await liveGateway.updates()
        var events = stream.makeAsyncIterator()
        precondition((await events.next())?.active == 0)
        let livePlan = try await liveGateway.begin(requirements)
        _ = await events.next()
        let liveCandidate = livePlan.candidates[0]
        let liveNow = Date()
        try await liveGateway.started(liveCandidate,plan:livePlan,now:liveNow)
        precondition((await events.next())?.flights.first?.phase == .connecting)
        await liveGateway.receivedHeaders(liveCandidate,plan:livePlan,now:liveNow)
        precondition((await events.next())?.flights.first?.phase == .waiting)
        await liveGateway.receivedOutput(liveCandidate,plan:livePlan,now:liveNow)
        precondition((await events.next())?.flights.first?.phase == .streaming)
        await liveGateway.receivedOutput(liveCandidate,plan:livePlan,now:liveNow.addingTimeInterval(0.02))
        precondition((await liveGateway.snapshot()).flights.first?.outputPulses == 1)
        await liveGateway.receivedOutput(liveCandidate,plan:livePlan,now:liveNow.addingTimeInterval(0.2))
        precondition((await events.next())?.flights.first?.outputPulses == 2)
        await liveGateway.report(liveCandidate,plan:livePlan,status:429,latency:0.1)
        precondition((await events.next())?.flights.first?.phase == .failed)
        let fallback = livePlan.candidates[1]
        try await liveGateway.started(fallback,plan:livePlan)
        precondition((await events.next())?.flights.first?.memberID == fallback.member.id)
        await liveGateway.report(fallback,plan:livePlan,status:200,latency:0.2)
        await liveGateway.finish(livePlan)
        let completed = await events.next()
        precondition(completed?.active == 0 && completed?.flights.first?.phase == .succeeded)
        precondition(completed?.flights.last?.phase == .failed && completed?.flights.first?.attempt == 2)
        precondition(!String(describing:completed).contains("fixture-a"))
        await liveGateway.resetHealth()
        let abandoned = try await liveGateway.begin(requirements)
        try await liveGateway.started(abandoned.candidates[0],plan:abandoned)
        livePool.maxAttempts = 2
        await liveGateway.configure(livePool,endpoints:[endpoint,other])
        await liveGateway.finish(abandoned)
        precondition((await liveGateway.snapshot()).flights.first?.phase == .cancelled)
        for width: Double in [320,480,520,640,852,1200] {
            for count in 0...9 {
                let g = GatewayTopologyLayout.geometry(width:width,count:count)
                let frames = [g.source] + g.tiers + g.models
                precondition(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= g.size.width && $0.minY >= 0 && $0.maxY <= g.size.height })
                for i in frames.indices { for j in frames.indices where i < j { precondition(!frames[i].intersects(frames[j])) } }
            }
        }
        let many = (0..<200).map { i -> FreeModelPool.Member in var m = plain; m.model = "synthetic-\(i)"; return m }
        let flights = (190..<198).map { i in FreeModelGateway.Flight(requestID:UUID(),memberID:many[i].id,routing:requirements.routing,
            phase:.streaming,attempt:1,startedAt:Date(),updatedAt:Date()) }
        let mapped = GatewayTopologyLayout.visibleIDs(members:many,flights:flights,selected:many[0].id,page:0)
        precondition(mapped.count <= 9 && Set(flights.map(\.memberID)).isSubset(of:Set(mapped)))
        print("PASS: phase push, bounded output pulses, short completion/failover, cancellation/revision cleanup, nonoverlapping topology")

        let importID = UUID()
        let configured = CodexProvider(id:importID,apiKey:"fixture-import-secret",baseURL:"https://example.test/v1",
            models:[.init(name:"manual-a"),.init(name:"manual-b")])
        let manualA = FreeModelPool.Member(providerID:importID,model:"manual-a",name:"A",contextLength:64000,
            supportsTools:true,supportsImages:false,supportsJSON:false,difficulties:[.medium])
        var manualB = manualA; manualB.model = "manual-b"; manualB.name = "B"
        var importPool = FreeModelPool()
        importPool.members = [manualA]; importPool.members[0].enabled = false
        var duplicateA = manualA; duplicateA.difficulties = [.high]
        let merged = try GatewayProviderImport.merge([duplicateA,manualB,manualB],into:importPool,providers:[configured],confirmedFree:true)
        precondition(merged.members.count == 2 && merged.members[0] == importPool.members[0] && !merged.enabled)
        precondition(!String(decoding:try JSONEncoder().encode(merged),as:UTF8.self).contains(configured.apiKey))
        func rejectImport(_ drafts:[FreeModelPool.Member],_ current:FreeModelPool = FreeModelPool(),
                          _ connections:[CodexProvider] = [configured],_ confirmed:Bool = true) {
            do { _ = try GatewayProviderImport.merge(drafts,into:current,providers:connections,confirmedFree:confirmed); fatalError("Expected import rejection") }
            catch { precondition(error is GatewayProviderImport.Failure) }
        }
        rejectImport([manualA],FreeModelPool(),[configured],false)
        rejectImport([manualA],FreeModelPool(),[])
        var missing = manualB; missing.model = "not-configured"
        rejectImport([manualA,missing])
        for base in ["http://example.test/v1","https://127.0.0.1/v1","https://user@example.test/v1"] {
            var invalid = configured; invalid.baseURL = base; rejectImport([manualA],FreeModelPool(),[invalid])
        }
        check(GatewayProviderImport.endpointIssue("https://example.test/v1") == nil)
        check(GatewayProviderImport.endpointIssue("http://example.test/v1")!.contains("HTTPS"))
        check(GatewayProviderImport.endpointIssue("http://127.0.0.1:15721/v1")!.contains("本机"))
        check(!GatewayProviderImport.endpointIssue("https://secret@example.test/v1?token=secret")!.contains("secret"))
        var noKey = configured; noKey.apiKey = ""; rejectImport([manualA],FreeModelPool(),[noKey])
        var invalidLength = manualA; invalidLength.contextLength = 0; rejectImport([invalidLength])
        var full = FreeModelPool(); full.members = (0..<200).map { i in var m=manualA;m.model="existing-\(i)";return m }
        rejectImport([manualB],full)
        var router = configured; router.baseURL = "https://openrouter.ai/api/v1"; router.models = [.init(name:catalog[0].id)]
        var routerPool = FreeModelPool(); routerPool.catalog = catalog; routerPool.discoveredAt = Date()
        var routerDraft = catalog[0].member(providerID:importID); routerDraft.difficulties = [.high]; routerDraft.supportsTools = false
        let routerMerged = try GatewayProviderImport.merge([routerDraft],into:routerPool,providers:[router],confirmedFree:true)
        precondition(routerMerged.members[0].discovered && routerMerged.members[0].supportsTools && routerMerged.members[0].difficulties == [.high])
        routerPool.discoveredAt = Date().addingTimeInterval(-49*3600); rejectImport([routerDraft],routerPool,[router])
        print("PASS: saved-provider batch import, dedup/preserved assignments, atomic validation, free catalog guard and credential privacy")
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

queue_policy = r'''
import Foundation
func check(_ condition: Bool, _ message: String = "") {
    if !condition { FileHandle.standardError.write(Data(("QUEUE FAILED: " + message + "\n").utf8)); exit(1) }
}
func queued(_ gateway: FreeModelGateway, _ count: Int) async throws {
    for _ in 0..<1000 {
        if (await gateway.snapshot()).queued == count { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    fatalError("Queue did not reach \(count)")
}
func expect(_ failure: GatewayFailure, _ operation: () async throws -> Void) async {
    do { try await operation(); fatalError("Expected \(failure)") }
    catch { check(error as? GatewayFailure == failure, "\(error) expected \(failure)") }
}
func cancelled<T>(_ task: Task<T, Error>) async {
    do { _ = try await task.value; fatalError("Expected cancellation") }
    catch is CancellationError { }
    catch { fatalError("Unexpected \(error)") }
}
@main struct QueuePolicy {
    static func main() async throws {
        let a = UUID(), b = UUID()
        let endpoints = [FreeModelGateway.Endpoint(id:a,name:"A",baseURL:"https://a.example/v1",apiKey:"fixture-a"),
                         FreeModelGateway.Endpoint(id:b,name:"B",baseURL:"https://b.example/v1",apiKey:"fixture-b")]
        func member(_ id: UUID, _ model: String, _ tiers: [GatewayTaskDifficulty]) -> FreeModelPool.Member {
            .init(providerID:id,model:model,name:model,contextLength:64000,supportsTools:true,supportsImages:true,supportsJSON:true,difficulties:tiers)
        }
        var pool = FreeModelPool(); pool.enabled = true; pool.strategy = .priority
        pool.requestsPerMinute = 60; pool.maxConcurrent = 4; pool.defaultProviderConcurrent = 1
        pool.maxQueued = 8; pool.queueTimeoutSeconds = 1
        pool.members = [member(a,"a1",[.low,.medium]), member(a,"a2",[.low]), member(b,"b1",[.medium,.high])]
        func needs(_ tier: String) throws -> GatewayRequirements {
            try .init(chat:["messages":[["role":"user","content":"fixture"]],"max_tokens":1,"task_difficulty":tier])
        }
        let low = try needs("low"), medium = try needs("medium"), high = try needs("high")
        func configured(_ value: FreeModelPool) async -> FreeModelGateway {
            let g = FreeModelGateway(); await g.configure(value,endpoints:endpoints); return g
        }
        let g = await configured(pool)
        let first = try await g.begin(low)
        try await g.started(first.candidates[0],plan:first)
        let blocked = Task { try await g.begin(low) }
        try await queued(g,1)
        let both = try await g.begin(medium)
        check(both.candidates[0].endpoint.id == b,"saturated A must not block ready B")
        try await g.started(both.candidates[0],plan:both)
        let busy = await g.snapshot()
        check(busy.active == 2 && busy.queued == 1 && busy.requests == 2)
        check(busy.providers[a]?.active == 1 && busy.providers[b]?.active == 1)
        check(busy.flights.count == 2,"queued call cannot manufacture a connecting flight")
        await g.finish(first)
        let next = try await blocked.value
        check(next.candidates[0].endpoint.id == a)
        await g.finish(next); await g.finish(both)
        check((await g.snapshot()).active == 0)
        await expect(.interrupted) { _ = try await g.acquireAttempt(first.candidates,plan:first) }

        var partitioned = pool; partitioned.providerQueueCapacity = 1
        let partitions = await configured(partitioned)
        let partitionA = try await partitions.begin(low), partitionB = try await partitions.begin(high)
        let waitingA = Task { try await partitions.begin(low) }; try await queued(partitions,1)
        await expect(.queueFull) { _ = try await partitions.begin(low) }
        let waitingB = Task { try await partitions.begin(medium) }; try await queued(partitions,2)
        check((await partitions.snapshot()).providers[b]?.queued == 1,"full A queue must leave B queue available")
        await partitions.finish(partitionB)
        let unblockedB = try await waitingB.value
        let partitionLoad = await partitions.snapshot()
        check(unblockedB.candidates[0].endpoint.id == b && partitionLoad.queued == 1)
        await partitions.finish(unblockedB); await partitions.finish(partitionA)
        let unblockedA = try await waitingA.value; await partitions.finish(unblockedA)

        let cooled = await configured(pool)
        let offending = try await cooled.begin(low)
        var twoSlots = pool; twoSlots.defaultProviderConcurrent = 2
        await cooled.configure(twoSlots,endpoints:endpoints); await cooled.finish(offending)
        let failing = try await cooled.begin(medium), reserved = try await cooled.begin(medium)
        try await cooled.started(failing.candidates[0],plan:failing)
        await cooled.report(failing.candidates[0],plan:failing,status:401,latency:0.1)
        let alternate = await cooled.preferredAttempt(reserved.candidates,plan:reserved)
        check(alternate?.endpoint.id == b,"unused reservation must transfer after concurrent account cooldown")
        try await cooled.started(alternate!,plan:reserved)
        await cooled.finish(failing);await cooled.finish(reserved)

        var serial = pool; serial.maxConcurrent = 1
        let fifo = await configured(serial)
        let held = try await fifo.begin(low)
        let second = Task { try await fifo.begin(low) }; try await queued(fifo,1)
        let third = Task { try await fifo.begin(low) }; try await queued(fifo,2)
        await fifo.finish(held)
        let secondPlan = try await second.value
        let fifoLoad = await fifo.snapshot()
        check(fifoLoad.active == 1 && fifoLoad.queued == 1)
        await fifo.finish(secondPlan)
        let thirdPlan = try await third.value; await fifo.finish(thirdPlan)
        check((await fifo.snapshot()).requests == 3)

        serial.maxQueued = 1
        let bounded = await configured(serial)
        let owner = try await bounded.begin(low)
        let waiting = Task { try await bounded.begin(low) }; try await queued(bounded,1)
        await expect(.queueFull) { _ = try await bounded.begin(high) }
        waiting.cancel(); await cancelled(waiting); try await queued(bounded,0)
        let expiry = Task { try await bounded.begin(low) }; try await queued(bounded,1)
        await expect(.queueTimedOut) { _ = try await expiry.value }
        let expiredLoad = await bounded.snapshot()
        check(expiredLoad.requests == 1 && expiredLoad.queued == 0)
        check((await bounded.snapshot()).health.isEmpty)
        await bounded.finish(owner)
        serial.maxQueued = 0; let immediate = await configured(serial)
        let occupied = try await immediate.begin(low)
        await expect(.busy) { _ = try await immediate.begin(low) }
        await immediate.finish(occupied)

        let bytes = await configured(pool)
        let byteOwner = try await bytes.begin(low)
        let huge = Task { try await bytes.begin(low,requestBytes:64*1024*1024) }
        try await queued(bytes,1)
        check((await bytes.snapshot()).queuedBytes == 64*1024*1024)
        await expect(.queueFull) { _ = try await bytes.begin(low,requestBytes:1) }
        huge.cancel(); await cancelled(huge); await bytes.finish(byteOwner)

        var fallbackPool = pool; fallbackPool.maxConcurrent = 2
        let switching = await configured(fallbackPool)
        let blockedB = try await switching.begin(high)
        let route = try await switching.begin(medium)
        try await switching.started(route.candidates[0],plan:route)
        await switching.report(route.candidates[0],plan:route,status:500,latency:0.1)
        let retry = Task { try await switching.started(route.candidates[1],plan:route) }
        try await queued(switching,1)
        check((await switching.snapshot()).providers[a]?.active == 0,"failed provider permit must be released before fallback wait")
        check((await switching.snapshot()).providers[b]?.active == 1)
        let independent = try await switching.begin(low)
        check((await switching.snapshot()).active == 2,"fallback wait must not hold a global permit needed by an independent provider")
        await switching.finish(independent)
        await switching.finish(blockedB); try await retry.value
        check((await switching.snapshot()).providers[b]?.active == 1)
        check((await switching.snapshot()).flights.first?.attempt == 2)
        await switching.finish(route)
        check((await switching.snapshot()).providers.values.allSatisfy { $0.active == 0 })

        let c = UUID()
        var multi = pool; multi.maxConcurrent = 3
        multi.members.append(member(c,"c1",[.medium,.high]))
        let alternatives = FreeModelGateway()
        await alternatives.configure(multi,endpoints:endpoints + [.init(id:c,name:"C",baseURL:"https://c.example/v1",apiKey:"fixture-c")])
        let holdB = try await alternatives.begin(high), holdC = try await alternatives.begin(high)
        let failA = try await alternatives.begin(medium)
        try await alternatives.started(failA.candidates[0],plan:failA)
        await alternatives.report(failA.candidates[0],plan:failA,status:500,latency:0.1)
        let alternateWait = Task { try await alternatives.acquireAttempt(Array(failA.candidates.dropFirst()),plan:failA) }
        try await queued(alternatives,1)
        await alternatives.finish(holdC)
        let actualAlternate = try await alternateWait.value
        check(actualAlternate?.endpoint.id == c,"waiting retry must reconsider another provider that became available")
        check((await alternatives.snapshot()).providers[b]?.active == 1)
        await alternatives.finish(failA);await alternatives.finish(holdB)

        let edit = await configured(pool)
        let editOwner = try await edit.begin(low)
        let old = Task { try await edit.begin(low) }; try await queued(edit,1)
        var changed = pool; changed.providerConcurrent[a.uuidString] = 2
        await edit.configure(changed,endpoints:endpoints)
        await expect(.interrupted) { _ = try await old.value }
        await expect(.interrupted) { _ = try await edit.acquireAttempt(editOwner.candidates,plan:editOwner) }
        check((await edit.snapshot()).providers[a]?.active == 1,"configuration must not erase live reservations")
        let more = try await edit.begin(low)
        check((await edit.snapshot()).providers[a]?.active == 2)
        changed.providerConcurrent[a.uuidString] = 1
        await edit.configure(changed,endpoints:endpoints)
        let narrowed = Task { try await edit.begin(low) }; try await queued(edit,1)
        await edit.finish(editOwner)
        check((await edit.snapshot()).queued == 1,"lowered limit must drain below the new limit")
        await edit.finish(more)
        let resumed = try await narrowed.value
        await edit.finish(resumed)
        let stopOwner = try await edit.begin(low)
        let stopWait = Task { try await edit.begin(low) }; try await queued(edit,1)
        await edit.shutdown(); await expect(.disabled) { _ = try await stopWait.value }
        await expect(.disabled) { _ = try await edit.begin(high) }
        await edit.finish(stopOwner)

        var bulk = pool; bulk.maxQueued = 128; bulk.providerQueueCapacity = 128; bulk.queueTimeoutSeconds = 10
        let burst = await configured(bulk)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    let p = try await burst.begin(i.isMultiple(of:2) ? low : high)
                    try await burst.started(p.candidates[0],plan:p)
                    let snapshot = await burst.snapshot()
                    check(snapshot.active <= bulk.maxConcurrent && snapshot.providers.values.allSatisfy { $0.active <= $0.limit },"burst oversubscription")
                    try await Task.sleep(for:.milliseconds(2))
                    await burst.finish(p)
                }
            }
            try await group.waitForAll()
        }
        let done = await burst.snapshot()
        check(done.active == 0 && done.queued == 0 && done.requests == 40)
        check(done.providers.values.allSatisfy { $0.active == 0 })
        check(!String(describing:done).contains("fixture-a"))

        var legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(pool)) as! [String:Any]
        for key in ["defaultProviderConcurrent","providerConcurrent","maxQueued","providerQueueCapacity","queueTimeoutSeconds"] { legacy.removeValue(forKey:key) }
        let loaded = try JSONDecoder().decode(FreeModelPool.self,from:JSONSerialization.data(withJSONObject:legacy))
        check(loaded.maxConcurrent == pool.maxConcurrent && loaded.defaultProviderConcurrent == 2 && loaded.maxQueued == 32 && loaded.queueTimeoutSeconds == 30)
        check(loaded.members == pool.members && loaded.providerConcurrent.isEmpty && loaded.providerQueueCapacity == 8)
        for mutate: (inout FreeModelPool) -> Void in [
            { $0.defaultProviderConcurrent = 0 }, { $0.providerConcurrent[a.uuidString] = 9 },
            { $0.providerConcurrent["not-a-provider"] = 1 }, { $0.maxQueued = 129 },
            { $0.maxQueued = -1 }, { $0.providerQueueCapacity = 0 }, { $0.providerQueueCapacity = 129 }, { $0.queueTimeoutSeconds = 0 }, { $0.queueTimeoutSeconds = 121 }] {
            var invalid = pool; mutate(&invalid); check(invalid.validationError != nil)
        }
        check(GatewayFailure.queueFull.status == 429 && GatewayFailure.queueTimedOut.status == 504)
        print("PASS: per-provider shared permits, free-provider selection, FIFO/global/byte bounds, cancellation, timeout, fallback transfer, live reconfiguration, shutdown, burst isolation and legacy migration")
    }
}
'''

probe_policy = r'''
import Foundation
@main struct ProbePolicy {
    static func main() async throws {
        let id = UUID(), gateway = FreeModelGateway()
        let endpoint = FreeModelGateway.Endpoint(id:id,name:"Fixture",baseURL:"https://example.test/v1",apiKey:"fixture-probe")
        var pool = FreeModelPool(); pool.enabled = false; pool.requestsPerMinute = 60; pool.maxConcurrent = 1
        let names = ["probe-good","probe-invalid","probe-401","probe-redirect","probe-wait","probe-body-wait"]
        pool.members = names.map { .init(providerID:id,model:$0,name:$0,contextLength:32000,supportsTools:false,supportsImages:false,supportsJSON:false,difficulties:[.medium]) }
        await gateway.configure(pool,endpoints:[endpoint])
        let req = try GatewayRequirements(chat:["messages":[["role":"user","content":"OK"]],"task_difficulty":"medium","max_tokens":128])
        await expect(.disabled) { _ = try await gateway.begin(req) }
        let url = URL(string:CommandLine.arguments[1])!
        for (i,member) in pool.members.enumerated() {
            // Account cooldown must not leak into subsequent fixture cases.
            await gateway.resetHealth()
            let plan = try await gateway.begin(req,testingMemberID:member.id)
            precondition(plan.candidates.count == 1 && plan.candidates[0].member.id == member.id && plan.selection.contains("手动测试"))
            try await gateway.started(plan.candidates[0],plan:plan)
            let task = Task { try await GatewayNetwork.shared.probe(plan.candidates[0],url:url,plan:plan,gateway:gateway) }
            if i >= 4 { try await Task.sleep(for:.milliseconds(100)); task.cancel() }
            let cancelledAt = Date()
            do {
                _ = try await task.value
                precondition(i == 0)
            } catch {
                if i >= 4 { precondition(error is CancellationError && Date().timeIntervalSince(cancelledAt) < 3) }
                else { precondition((error as? GatewayNetwork.ProbeFailure)?.status == [0,502,401,307][i]) }
            }
            await gateway.finish(plan)
            let snapshot = await gateway.snapshot()
            precondition(snapshot.active == 0 && snapshot.queued == 0)
            let h = snapshot.health[member.id]
            precondition((h?.successes ?? 0) == (i == 0 ? 1 : 0))
            precondition((h?.failures ?? 0) == ((1...3).contains(i) ? 1 : 0))
            precondition(snapshot.flights.first?.phase == (i == 0 ? .succeeded : (i >= 4 ? .cancelled : .failed)))
        }
        // A pinned test waits for its supplier, never switches to another model.
        await gateway.resetHealth()
        let first = try await gateway.begin(req,testingMemberID:pool.members[0].id)
        let waiting = Task { try await gateway.begin(req,testingMemberID:pool.members[1].id) }
        for _ in 0..<100 where (await gateway.snapshot()).queued == 0 { try await Task.sleep(for:.milliseconds(5)) }
        precondition((await gateway.snapshot()).queued == 1)
        waiting.cancel()
        do { _ = try await waiting.value; fatalError("cancelled queued probe") } catch { precondition(error is CancellationError) }
        await gateway.finish(first)
        let final = await gateway.snapshot()
        precondition(final.active == 0 && final.queued == 0)
        let old = try await gateway.begin(req,testingMemberID:pool.members[0].id)
        try await gateway.started(old.candidates[0],plan:old)
        pool.maxQueued += 1
        await gateway.configure(pool,endpoints:[endpoint])
        precondition(!(await gateway.isCurrent(old)))
        do { _ = try await GatewayNetwork.shared.probe(old.candidates[0],url:url,plan:old,gateway:gateway); fatalError("stale probe must not pass") }
        catch { precondition(error as? GatewayFailure == .interrupted) }
        await gateway.finish(old)
        precondition((await gateway.snapshot()).health[pool.members[0].id]?.successes ?? 0 == 0)
        print("PASS: pinned manual probe with Auto disabled, actual valid/invalid/401/redirect responses, pre-header/body/queue cancellation, stale config rejection and permit/health cleanup")
    }
}
'''

store_completion = r'''
import Foundation
import Combine

enum FilePaths {
    static var freeModelPoolFile: URL {
        URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("store/pool.json")
    }
}
struct Provider { var id = UUID() }
@MainActor final class CodexProviderStore: ObservableObject {
    @Published var providers: [CodexProvider] = []
}
@MainActor final class ProviderStore: ObservableObject {
    @Published var providers: [Provider] = []
}
enum ProviderBridge {
    static func toCodex(_ provider: Provider) -> CodexProvider {
        .init(id: provider.id, apiKey: "fixture-only", baseURL: "https://fixture.example/v1", models: [])
    }
}
@main struct StoreCompletion {
    @MainActor static func main() async throws {
        let storage = FreeModelPoolStorage(url: FilePaths.freeModelPoolFile)
        var initial = FreeModelPool(); initial.discoveryEnabled = false
        try await storage.save(initial)
        let providers = CodexProviderStore(), claude = ProviderStore()
        let id = UUID()
        providers.providers = [.init(id:id,apiKey:"fixture-only",baseURL:"https://fixture.example/v1",models:[.init(name:"fixture/free")])]
        let store = FreeModelGatewayStore()
        store.start(providers:providers,claude:claude)
        for _ in 0..<500 where store.loading || store.connections.isEmpty {
            try await Task.sleep(for:.milliseconds(10))
        }
        precondition(store.canEdit && store.connections.count == 1)
        let member = FreeModelPool.Member(providerID:id,model:"fixture/free",name:"Fixture",contextLength:32000,
            supportsTools:false,supportsImages:false,supportsJSON:false)
        var calls = 0
        let imported: Bool = await withCheckedContinuation { continuation in
            precondition(store.importModels([member],confirmedFree:true) { succeeded in
                calls += 1
                precondition(!store.saving)
                continuation.resume(returning:succeeded)
            })
            // The existing write gate must reject another import immediately.
            var rejected = false
            precondition(!store.importModels([member],confirmedFree:true) { succeeded in
                precondition(!succeeded); rejected = true
            })
            precondition(rejected)
        }
        let saved = try await storage.load()
        precondition(imported && calls == 1 && saved.members == [member] && store.pool.members == [member])
        let encoded = try Data(contentsOf:FilePaths.freeModelPoolFile)
        precondition(!saved.enabled && !String(decoding:encoded,as:UTF8.self).contains("fixture-only"))
        var rejected = false
        precondition(!store.importModels([member],confirmedFree:false) { succeeded in
            precondition(!succeeded); rejected = true
        })
        precondition(rejected && store.canEdit)
        var invalid = false
        store.change(completion:{ succeeded in precondition(!succeeded); invalid = true }) { $0.maxAttempts = 0 }
        precondition(invalid && store.pool.maxAttempts == initial.maxAttempts && store.canEdit)
        // A failed private write reports failure and keeps the original state.
        let parent = FilePaths.freeModelPoolFile.deletingLastPathComponent()
        try FileManager.default.removeItem(at:parent)
        try Data("blocked-directory".utf8).write(to:parent)
        let failed: Bool = await withCheckedContinuation { continuation in
            store.change(completion:{ succeeded in
                precondition(!store.saving); continuation.resume(returning:succeeded)
            }) { $0.enabled = true }
        }
        precondition(!failed && !store.pool.enabled && store.canEdit && store.error != nil)
        store.stop()
        var stopped = false
        store.change(completion:{ succeeded in precondition(!succeeded); stopped = true }) { $0.enabled = true }
        precondition(stopped)
        print("PASS: production store import completion follows durable save without UI-frame observation; rejection and write failure retain state")
    }
}
'''

server = (utils/'CodexProxyServer.swift').read_text()
selected = ['    private func forwardGateway(', '    private func runGateway(',
            '    private final class GatewayConnectionLifetime', '    private func forwardGatewayCandidate',
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
    static func attachUpstream(_ tap:CaptureTap?,task:URLSessionDataTask) { gatewayLifetime?.attach(task) }
    @TaskLocal private static var gatewayLifetime: GatewayConnectionLifetime?
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
        if request.path == "/fixture/telemetry" {
            let value = await FreeModelGateway.shared.snapshot()
            let body: [String:Any] = ["active":value.active,"queued":value.queued,"requests":value.requests,
                "failures":value.health.values.reduce(0) { $0 + $1.failures },
                "providers":Dictionary(uniqueKeysWithValues:value.providers.map { ($0.key.uuidString,["active":$0.value.active,"limit":$0.value.limit,"queued":$0.value.queued]) }),
                "flights":value.flights.map {
                ["phase":$0.phase.rawValue,"memberID":$0.memberID,"attempt":$0.attempt,"pulses":$0.outputPulses,"request":$0.requestID.uuidString]
            }]
            await respond(connection,status:"200 OK",contentType:"application/json",body:try! JSONSerialization.data(withJSONObject:body)); return
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
        if settings["queue"] as? Bool == true {
            pool.maxConcurrent = 2; pool.defaultProviderConcurrent = 1
            pool.maxQueued = 2; pool.queueTimeoutSeconds = 5
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
    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError,ConnectionResetError):
            pass  # Expected only when an owned disconnect fixture aborts a stream.
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
        if self.mode == 'preheaders':
            self.release['first' if first else 'second'].wait(timeout=10)
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        if self.mode == 'slow':
            # A comment opens URLSession's bytes delivery without model output.
            self.wfile.write(b': heartbeat\n\n'); self.wfile.flush(); time.sleep(0.3)
        if first and self.mode == 'sse-error':
            self.wfile.write(b'data: {"error":{"code":429,"message":"fixture unavailable"}}\n\n'); return
        self.wfile.write(b'data: {"id":"fixture","choices":[{"index":0,"delta":{"role":"assistant","content":"fixture answer"}}]}\n\n')
        if self.mode == 'slow':
            self.wfile.flush(); time.sleep(0.6)
        if self.mode == 'queue':
            self.wfile.flush(); self.release['first' if first else 'second'].wait(timeout=10)
        if self.mode == 'incomplete':
            return
        self.wfile.write(b'data: {"id":"fixture","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n')
        self.wfile.write(b'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}\n\n')
        self.wfile.write(b'data: [DONE]\n\n')

class ProbeUpstream(BaseHTTPRequestHandler):
    calls = []
    def log_message(self, *args):
        pass
    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.calls.append(body['model'])
        assert self.headers.get('Authorization') == 'Bearer fixture-probe'
        assert body['max_tokens'] == 128 and body['stream'] is False
        model = body['model']
        if model == 'probe-wait':
            time.sleep(5)
        status = 401 if model == 'probe-401' else (307 if model == 'probe-redirect' else 200)
        data = json.dumps({'choices':[{'message':{'content':'OK'}}]} if model != 'probe-invalid' else {'choices':[]}).encode()
        self.send_response(status)
        if status == 307:
            self.send_header('Location', '/must-not-follow')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if model == 'probe-body-wait':
            self.wfile.write(data[:1]); self.wfile.flush(); time.sleep(5); self.wfile.write(data[1:])
        else:
            self.wfile.write(data)

with tempfile.TemporaryDirectory(prefix='claudebar-gateway-') as temporary:
    folder = Path(temporary)
    types = folder/'Catalog.swift'
    catalog = (models/'ProviderCatalog.swift').read_text().split('struct ProviderSetupDraft')[0]
    state = (models/'CodexProxyState.swift').read_text()
    types.write_text(catalog + '\nenum LocalProxyAddress {\n' + method(state, '    static func isLoopback') + '\n}\n')
    types.write_text(types.read_text() + '\nstruct CodexModelConfig: Equatable { var name:String; var contextWindow = \"32000\" }\nstruct CodexProvider: Equatable { var id:UUID; var name = \"Fixture\"; var apiKey:String; var baseURL:String; var models:[CodexModelConfig] }\n')
    common.append(types)
    policy = policy.replace('precondition(', 'check(')
    policy = 'func check(_ value:Bool,_ message:String = "") { if !value { FileHandle.standardError.write(Data(("FAILED: " + message + "\\n").utf8)); exit(1) } }\n' + policy
    policy_file = folder/'Policy.swift'; policy_file.write_text(policy)
    binary = folder/'policy'
    subprocess.run(['swiftc','-O','-parse-as-library',*map(str,common),str(policy_file),'-o',str(binary)],check=True)
    subprocess.run([str(binary),temporary],check=True)
    queue_file = folder/'QueuePolicy.swift'; queue_file.write_text(queue_policy)
    queue_binary = folder/'queue-policy'
    subprocess.run(['swiftc','-O','-parse-as-library',*map(str,common),str(queue_file),'-o',str(queue_binary)],check=True)
    subprocess.run([str(queue_binary)],check=True,timeout=30)
    probe_file = folder/'ProbePolicy.swift'
    probe_file.write_text('func expect(_ failure:GatewayFailure,_ op:() async throws -> Void) async { do { try await op(); fatalError("expected failure") } catch { precondition(error as? GatewayFailure == failure) } }\n'+probe_policy.replace('precondition(', 'check(').replace('import Foundation\n', 'import Foundation\nfunc check(_ value:Bool,_ message:String = "") { if !value { fatalError(message) } }\n'))
    probe_binary = folder/'probe-policy'
    subprocess.run(['swiftc','-O','-parse-as-library',*map(str,common),str(probe_file),'-o',str(probe_binary)],check=True)
    probe_server = ThreadingHTTPServer(('127.0.0.1',0),ProbeUpstream)
    threading.Thread(target=probe_server.serve_forever,daemon=True).start()
    try:
        subprocess.run([str(probe_binary),f'http://127.0.0.1:{probe_server.server_address[1]}/v1/chat/completions'],check=True,timeout=20)
        assert ProbeUpstream.calls == ['probe-good','probe-invalid','probe-401','probe-redirect','probe-wait','probe-body-wait','probe-good']
    finally:
        probe_server.shutdown(); probe_server.server_close()
    extra = [utils/'MigrationBridgeConfiguration.swift', models/'SessionMigration.swift', root/'Sources/Shared/BuildChannel.swift']
    store_file = folder/'StoreCompletion.swift'; store_file.write_text(store_completion)
    store_binary = folder/'store-completion'
    subprocess.run(['swiftc','-O','-parse-as-library',*map(str,common+extra),str(models/'FreeModelGatewayStore.swift'),str(store_file),'-o',str(store_binary)],check=True)
    subprocess.run([str(store_binary),temporary],check=True,timeout=20)
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
            def telemetry():
                connection = http.client.HTTPConnection('127.0.0.1',port,timeout=5)
                connection.request('GET','/fixture/telemetry',headers={'Authorization':'Bearer '+token})
                response = connection.getresponse(); value = json.loads(response.read()); connection.close()
                return value
            if mode == 'slow':
                answers = []
                worker = threading.Thread(target=lambda: answers.append(send(True)))
                worker.start()
                seen = set()
                deadline = time.monotonic()+5
                while worker.is_alive() and time.monotonic() < deadline:
                    _t=telemetry()['flights']
                    seen.update(f['phase'] for f in _t)
                    time.sleep(0.025)
                worker.join(timeout=5)
                assert not worker.is_alive() and answers
                status,data = answers[0]
                assert {'waiting','streaming'}.issubset(seen), seen
            else:
                status,data = send(True)
            assert status == expected_status, (status,data)
            observed = telemetry()
            deadline = time.monotonic() + 1
            while observed['active'] and time.monotonic() < deadline:
                time.sleep(0.01)
                observed = telemetry()
            assert observed['active'] == 0 and all(f['phase'] not in ('connecting','waiting','streaming') for f in observed['flights']), observed
            if mode == 'slow':
                assert observed['flights'][0]['phase'] == 'succeeded' and observed['flights'][0]['pulses'] > 0
            if mode in ('429','401','sse-error') and len(Upstream.calls) == 2:
                assert [f['phase'] for f in observed['flights']] == ['succeeded','failed']
                assert observed['flights'][0]['request'] == observed['flights'][1]['request']
            return data, list(Upstream.calls)
        finally:
            process.terminate(); process.wait(timeout=10)
    def run_queue_case():
        Upstream.mode = 'queue'; Upstream.calls = []
        Upstream.release = {'first':threading.Event(), 'second':threading.Event()}
        case = folder/'queue'; case.mkdir()
        process = subprocess.Popen([str(server_binary),str(case)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        sockets = []; workers = []
        try:
            process.stdin.write(json.dumps({'base':f'http://127.0.0.1:{upstream.server_port}','tiers':['low','high'],'queue':True})); process.stdin.close()
            line = process.stdout.readline().strip()
            assert line.startswith('READY '), (line,process.stderr.read())
            port = int(line.split()[1]); token = (case/'proxy-token').read_text()
            def payload(tier, stream=True):
                return {'model':'auto','messages':[{'role':'user','content':'fixture'}],'max_tokens':8,'task_difficulty':tier,'stream':stream}
            def telemetry():
                connection = http.client.HTTPConnection('127.0.0.1',port,timeout=5)
                connection.request('GET','/fixture/telemetry',headers={'Authorization':'Bearer '+token})
                response = connection.getresponse(); result = json.loads(response.read()); connection.close()
                return result
            def load(active,queued):
                deadline = time.monotonic()+5
                while time.monotonic()<deadline:
                    value = telemetry()
                    assert all(p['active'] <= p['limit'] for p in value['providers'].values()), value
                    if value['active']==active and value['queued']==queued: return value
                    time.sleep(.01)
                raise AssertionError((active,queued,telemetry()))
            def streams(count):
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    value=telemetry()
                    if sum(f['phase']=='streaming' for f in value['flights'])==count:return
                    time.sleep(.01)
                raise AssertionError(telemetry())
            def raw(tier):
                data = json.dumps(payload(tier)).encode()
                client = socket.create_connection(('127.0.0.1',port),timeout=5); sockets.append(client)
                head = f'POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n'.encode()
                client.sendall(head+data); return client
            def send(tier,stream=True):
                client = http.client.HTTPConnection('127.0.0.1',port,timeout=8)
                client.request('POST','/v1/chat/completions',json.dumps(payload(tier,stream)),{'Authorization':'Bearer '+token,'Content-Type':'application/json'})
                response = client.getresponse(); answer=(response.status,response.read(),dict(response.getheaders()));client.close();return answer
            a = raw('low'); load(1,0); streams(1)
            abandoned = raw('low'); load(1,1)
            b = raw('high'); load(2,1); streams(2)
            assert len(Upstream.calls)==2,Upstream.calls
            abandoned.shutdown(socket.SHUT_RDWR); abandoned.close()
            load(2,0)
            answers = []
            for expected in [1,2]:
                worker = threading.Thread(target=lambda:answers.append(send('low'))); workers.append(worker);worker.start()
                load(2,expected)
            status,data,headers = send('low')
            assert status==429 and json.loads(data)['error']['code']=='gateway_queue_full' and headers['Retry-After']=='1',(status,data,headers)
            assert len(Upstream.calls)==2
            for worker in workers: worker.join(timeout=7);assert not worker.is_alive()
            assert len(answers)==2
            for status,data,headers in answers:
                assert status==504 and json.loads(data)['error']['code']=='gateway_queue_timeout' and headers['Retry-After']=='1',(status,data,headers)
            value = load(2,0)
            assert value['requests']==2 and len(Upstream.calls)==2, value
            # Disconnect a streaming client while it has both headers/output.
            a.shutdown(socket.SHUT_RDWR); a.close()
            value = load(1,0)
            assert any(f['phase']=='cancelled' for f in value['flights']) and value['failures']==0,value
            Upstream.release['first'].set();Upstream.release['second'].set()
            data = b''
            while True:
                chunk=b.recv(65536)
                if not chunk:break
                data+=chunk
            b.close();load(0,0)
            assert b'[DONE]' in data
            status,data,_ = send('low',False)
            assert status==200 and json.loads(data)['model']=='first'
            assert load(0,0)['requests']==3 and len(Upstream.calls)==3
            Upstream.mode = 'preheaders'; Upstream.release['first'].clear()
            before = len(Upstream.calls)
            early = raw('low'); load(1,0)
            deadline = time.monotonic()+5
            while len(Upstream.calls)==before and time.monotonic()<deadline: time.sleep(.01)
            assert len(Upstream.calls)==before+1
            assert any(f['phase']=='connecting' for f in telemetry()['flights'])
            early.shutdown(socket.SHUT_RDWR);early.close()
            assert load(0,0)['failures']==0
            Upstream.release['first'].set()
            print('PASS: real HTTP provider isolation, bounded queue/Retry-After, queue timeout without upstream debit, queued socket withdrawal, pre-header and streaming-disconnect permit release')
        finally:
            for gate in Upstream.release.values(): gate.set()
            for client in sockets: client.close()
            for worker in workers: worker.join(timeout=10)
            process.terminate();process.wait(timeout=10)
    try:
        run_queue_case()
        chat = {'model':'auto','messages':[{'role':'user','content':'ping'}],'max_tokens':8,
                'models':['paid-fallback'],'plugins':[{'id':'web'}]}
        data,calls = run_case('slow','/v1/chat/completions',dict(chat,stream=True))
        assert len(calls) == 1
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
