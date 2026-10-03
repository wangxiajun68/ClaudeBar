#!/usr/bin/env python3
"""Production wire state machines and isolated native loopback transport."""
from pathlib import Path
import http.server, json, subprocess, tempfile, threading, time, urllib.request, urllib.error, sys
from migration_bridge_harness import build
ROOT=Path(__file__).resolve().parents[1]

SWIFT=r'''
import Foundation
@main struct Regression {
    static func main() throws {
        let request:[String:Any] = ["max_tokens":2048,"system":[["type":"text","text":"system"]],
            "tools":[["name":"Read","input_schema":["type":"object","properties":["path":["type":"string"]]]]],
            "tool_choice":["type":"auto","disable_parallel_tool_use":true],
            "messages":[["role":"user","content":"hello"],
                ["role":"assistant","content":[["type":"tool_use","id":"call_one","name":"Read","input":["path":"a"]]]],
                ["role":"user","content":[["type":"tool_result","tool_use_id":"call_one","is_error":true,"content":"permission denied"]]]]]
        let out = try AgentProtocolBridge.request(request,model:"frozen-model")
        precondition(out["model"] as? String == "frozen-model" && out["instructions"] as? String == "system")
        let input = out["input"] as! [[String:Any]]
        precondition(input.count == 3 && input[1]["call_id"] as? String == "call_one")
        precondition((input[2]["output"] as! String).contains("permission denied") && (input[2]["output"] as! String).contains("true"))
        precondition(out["parallel_tool_calls"] as? Bool == false)
        var priced = request
        priced["temperature"] = 0.2
        priced["top_p"] = 0.9
        priced["previous_response_id"] = "resp_previous"
        mustFail { _ = try AgentProtocolBridge.siwcRequest(priced, model:"gpt") }
        priced.removeValue(forKey: "previous_response_id")
        let siwc = try AgentProtocolBridge.siwcRequest(priced, model:"gpt")
        precondition(siwc["store"] as? Bool == false && siwc["stream"] as? Bool == true)
        precondition(siwc["max_output_tokens"] == nil && siwc["temperature"] == nil && siwc["top_p"] == nil)
        precondition(siwc["model"] as? String == "gpt")
        var runtimeSystem = request
        var nativeMessages = request["messages"] as! [[String:Any]]
        nativeMessages.append(["role":"system","content":"runtime system"])
        runtimeSystem["messages"] = nativeMessages
        let mappedSystem = try AgentProtocolBridge.request(runtimeSystem,model:"m")
        precondition(mappedSystem["instructions"] as? String == "system\nruntime system")
        var invalid = request; invalid["messages"] = [["role":"user","content":[["type":"document"]]]]
        mustFail { _ = try AgentProtocolBridge.request(invalid,model:"m") }
        mustFail { _ = try AgentProtocolBridge.image(["source":["type":"base64","data":"invalid","media_type":"image/png"]]) }
        let image = try AgentProtocolBridge.image(["source":["type":"base64","data":"eA==","media_type":"image/png"]])
        precondition(image == "data:image/png;base64,eA==")
        var stream = AgentProtocolBridge.Stream(model:"frozen-model")
        var accumulator = AgentProtocolBridge.MessageAccumulator()
        let events:[[String:Any]] = [
            ["type":"response.created","response":[:]],
            ["type":"response.output_item.added","output_index":1,"item":["type":"function_call","call_id":"c1","name":"Read"]],
            ["type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"path\":\"a\"}"],
            ["type":"response.output_item.added","output_index":2,"item":["type":"function_call","call_id":"c2","name":"Write"]],
            ["type":"response.function_call_arguments.delta","output_index":2,"delta":"{\"path\":\"b\",\"content\":\"中文\"}"],
            ["type":"response.completed","response":["output":[],"usage":["input_tokens":20,"input_tokens_details":["cached_tokens":5],"output_tokens":3]]]]
        var delivered:[[String:Any]] = []
        for event in events { for item in try stream.apply(event) { delivered.append(item); try accumulator.apply(item) } }
        let result = try accumulator.result(), blocks = result["content"] as! [[String:Any]]
        precondition(stream.terminal && blocks.count == 2 && result["stop_reason"] as? String == "tool_use")
        precondition((blocks[1]["input"] as! [String:Any])["content"] as? String == "中文")
        precondition((result["usage"] as! [String:Int])["input_tokens"] == 15)
        precondition(delivered.first?["type"] as? String == "message_start" && delivered.last?["type"] as? String == "message_stop")
        mustFail { _ = try stream.apply(events[0]) }
        var broken = AgentProtocolBridge.Stream(model:"m")
        _ = try broken.apply(events[1]); _ = try broken.apply(["type":"response.function_call_arguments.delta","output_index":1,"delta":"{"])
        mustFail { _ = try broken.apply(events.last!) }
        var failed = AgentProtocolBridge.Stream(model:"m")
        mustFail { _ = try failed.apply(["type":"response.failed"]) }
        var chat = AgentProtocolBridge.ChatStream(stream:.init(model:"m"))
        var chatAccum = AgentProtocolBridge.MessageAccumulator()
        for chunk:[String:Any] in [
            ["choices":[["delta":["content":"text"]]]],
            ["choices":[["delta":["tool_calls":[["index":0,"id":"c1","function":["name":"Read","arguments":"{}"]],
                ["index":1,"id":"c2","function":["name":"Write","arguments":"{}"]]]]]]],
            ["choices":[["delta":[:],"finish_reason":"tool_calls"]]],
            ["choices":[],"usage":["prompt_tokens":9,"completion_tokens":2]]] {
            for event in try chat.apply(chunk) { try chatAccum.apply(event) }
        }
        for event in try chat.finish() { try chatAccum.apply(event) }
        let chatMessage = try chatAccum.result()
        precondition((chatMessage["content"] as! [[String:Any]]).count == 3)
        precondition((chatMessage["usage"] as! [String:Int])["input_tokens"] == 9)
        var fragmented = AgentProtocolBridge.ChatStream(stream:.init(model:"m"))
        _ = try fragmented.apply(["choices":[["delta":["tool_calls":[["index":0,"id":"call_x","function":["name":"get_","arguments":"{"]]]]]]])
        _ = try fragmented.apply(["choices":[["delta":["tool_calls":[["index":0,"function":["name":"weather","arguments":"}"]]]],"finish_reason":"tool_calls"]]])
        let fragmentedEvents = try fragmented.finish()
        precondition(fragmentedEvents.contains(where: { ($0["content_block"] as? [String:Any])?["name"] as? String == "get_weather" }))
        var truncated = AgentProtocolBridge.ChatStream(stream:.init(model:"m"))
        mustFail { _ = try truncated.finish() }
        var length = AgentProtocolBridge.ChatStream(stream:.init(model:"m"))
        _ = try length.apply(["choices":[["delta":["content":"partial"],"finish_reason":"length"]]])
        let lengthEvents = try length.finish()
        precondition(lengthEvents.contains(where: { ($0["delta"] as? [String:Any])?["stop_reason"] as? String == "max_tokens" }))
        print("PASS: text, images, tool errors, parallel calls, incremental JSON, usage, malformed and truncated streams")
    }
    static func mustFail(_ block:() throws -> Void) { do { try block(); preconditionFailure("must fail") } catch {} }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-agent-bridge-') as folder:
    folder=Path(folder)
    main=folder/'Regression.swift';main.write_text(SWIFT)
    binary=folder/'regression'
    subprocess.run(['swiftc','-O','-parse-as-library',str(ROOT/'Sources/ClaudeBar/Utils/ConversationMedia.swift'),str(ROOT/'Sources/ClaudeBar/Utils/AgentProtocolBridge.swift'),str(main),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
    # Use a synthetic HTTP upstream. Captures are memory-only and contain no real credentials.
    received=[]
    disconnected=threading.Event()
    class Upstream(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));received.append((self.path,self.headers.get('Authorization'),body))
            self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
            if body.get('input',[{}])[0].get('content',[{}])[0].get('text') == 'slow':
                try:
                    for i in range(60):
                        event={'type':'response.output_text.delta','output_index':0,'delta':'x'*100}
                        self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode());self.wfile.flush();time.sleep(.05)
                except (BrokenPipeError,ConnectionResetError):disconnected.set()
                return
            if body.get('input',[{}])[0].get('content',[{}])[0].get('text') == 'truncate':
                events=[{'type':'response.created','response':{}}]
            else:
                events=[{'type':'response.created','response':{}},
                    {'type':'response.output_text.delta','output_index':0,'delta':'FIXTURE-ANSWER'},
                    {'type':'response.completed','response':{'output':[],'usage':{'input_tokens':7,'output_tokens':2}}}]
            for event in events:self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode())
        def log_message(self,*args):pass
    upstream=http.server.ThreadingHTTPServer(('127.0.0.1',0),Upstream)
    thread=threading.Thread(target=upstream.serve_forever,daemon=True);thread.start()
    native=build(folder)
    route='cd658eb1-77ac-46cc-b132-16895885d07f'
    process=subprocess.Popen([str(native),str(folder)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        process.stdin.write(json.dumps({'id':route,'baseURL':f'http://127.0.0.1:{upstream.server_port}/v1',
            'apiKey':'UPSTREAM-FIXTURE-KEY','wireAPI':'responses','model':'frozen-model'}));process.stdin.close()
        line=process.stdout.readline().strip();assert line.startswith('READY '),process.stderr.read()
        port=int(line.split()[1]);token=(folder/'proxy-token').read_text()
        def call(path,body,auth=token):
            req=urllib.request.Request(f'http://127.0.0.1:{port}{path}',data=json.dumps(body).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+auth})
            try:
                with urllib.request.urlopen(req,timeout=10) as res:return res.status,res.read().decode()
            except urllib.error.HTTPError as exc:return exc.code,exc.read().decode()
        body={'max_tokens':100,'stream':True,'model':'client-cannot-switch','messages':[{'role':'user','content':'fixture'}]}
        path=f'/migration/{route}/v1/messages'
        assert call(path,body,'wrong')[0]==401 and not received
        assert call(path.replace(route,'95c1e3d1-440a-4fa5-9fbf-92f72eab5b73'),body)[0]==404 and not received
        status,response=call(path,body);assert status==200 and 'FIXTURE-ANSWER' in response and 'message_stop' in response
        assert received[0][0]=='/v1/responses' and received[0][1]=='Bearer UPSTREAM-FIXTURE-KEY' and received[0][2]['model']=='frozen-model'
        assert token not in json.dumps(received) and 'UPSTREAM-FIXTURE-KEY' not in response
        incompatible=dict(body);incompatible['messages']=[{'role':'user','content':[{'type':'document'}]}]
        assert call(path,incompatible)[0]==400
        body['stream']=False;status,response=call(path,body);assert status==200 and json.loads(response)['content'][0]['text']=='FIXTURE-ANSWER'
        body['stream']=True;body['messages'][0]['content']='truncate';status,response=call(path,body)
        assert status==200 and 'api_error' in response and 'message_stop' not in response and 'HTTP/1.1 502' not in response
        assert call(path+'/count_tokens',body)[0]==200
        body['messages'][0]['content']='slow'
        req=urllib.request.Request(f'http://127.0.0.1:{port}{path}',data=json.dumps(body).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+token})
        response=urllib.request.urlopen(req,timeout=10);response.read(100);response.close()
        assert disconnected.wait(3),'client disconnect must cancel active upstream stream'

        print('PASS: production native HTTP transport, auth-before-route, frozen model/key isolation, JSON/SSE, EOF error, non-retrying format failures, disconnect cancellation and token estimate')
    finally:
        process.terminate();process.wait(timeout=10);upstream.shutdown();upstream.server_close()
