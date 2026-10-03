"""Real Responses -> Anthropic text-only relay, for an isolated CC invocation."""
import graft_probe as g,http.server,threading,urllib.request,json,gzip,uuid,pathlib,time,subprocess
provider=json.loads((g.USER_HOME/'.claude/claude-bar-codex-providers.json').read_text())['providers'][int(__import__('os').environ.get('CLAUDEBAR_MIGRATION_PROVIDER_INDEX','6'))];upstream=provider['baseURL'].rstrip('/')+'/responses';key=provider['apiKey'];model=g.load()['sources']['codex-custom']['model'];evidence=[]
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):self.send_response(200);self.end_headers();self.wfile.write(b'{}')
 def do_POST(self):
  raw=self.rfile.read(int(self.headers.get('Content-Length','0')))
  if self.headers.get('Content-Encoding')=='gzip':raw=gzip.decompress(raw)
  body=json.loads(raw)
  if 'count_tokens' in self.path:self.send_response(200);self.end_headers();self.wfile.write(b'{"input_tokens":100}');return
  if body.get('tools') or any(b.get('type') not in ['text'] for m in body.get('messages',[]) for b in (m.get('content',[]) if isinstance(m.get('content'),list) else [])):
   self.send_response(400);self.end_headers();self.wfile.write(b'{"type":"error","error":{"type":"invalid_request_error","message":"Research relay supports text-only messages without tools"}}');return
  inputs=[]
  for m in body.get('messages',[]):
   t=g.texts(m.get('content'));inputs.append({'role':m['role'],'content':[{'type':'input_text' if m['role']=='user' else 'output_text','text':t}]})
  payload={'model':model,'input':inputs,'instructions':g.texts(body.get('system')),'stream':False,'store':False,'max_output_tokens':min(body.get('max_tokens',512),1024)}
  try:
   req=urllib.request.Request(upstream,data=json.dumps(payload).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+key});op=urllib.request.build_opener(urllib.request.ProxyHandler({'http':'http://127.0.0.1:17890','https':'http://127.0.0.1:17890'}));res=json.load(op.open(req,timeout=80));answer='\n'.join(g.texts(v.get('content')) for v in res.get('output',[]) if v.get('type')=='message');usage=res.get('usage',{})
  except Exception as exc:
   self.send_response(502);self.end_headers();self.wfile.write(json.dumps({'type':'error','error':{'type':'api_error','message':'Upstream request failed: '+type(exc).__name__}}).encode());return
  evidence.append({'model':model,'roles':[v['role'] for v in inputs],'answer':answer,'tools_present':bool(body.get('tools')),'real_upstream':True})
  response={'id':'msg_relay_'+uuid.uuid4().hex,'type':'message','role':'assistant','model':model,'content':[{'type':'text','text':answer}],'stop_reason':'end_turn','stop_sequence':None,'usage':{'input_tokens':usage.get('input_tokens',0),'output_tokens':usage.get('output_tokens',0)}};self.send_response(200)
  if not body.get('stream'):self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(json.dumps(response).encode());return
  self.send_header('Content-Type','text/event-stream');self.end_headers();start={**response,'content':[],'stop_reason':None,'usage':{'input_tokens':response['usage']['input_tokens'],'output_tokens':0}};events=[('message_start',{'type':'message_start','message':start}),('content_block_start',{'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}}),('content_block_delta',{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':answer}}),('content_block_stop',{'type':'content_block_stop','index':0}),('message_delta',{'type':'message_delta','delta':{'stop_reason':'end_turn','stop_sequence':None},'usage':{'output_tokens':response['usage']['output_tokens']}}),('message_stop',{'type':'message_stop'})]
  for typ,data in events:self.wfile.write(('event: '+typ+'\ndata: '+json.dumps(data)+'\n\n').encode())
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),H);threading.Thread(target=server.serve_forever,daemon=True).start();o=g.load();s=o['sources']['codex-custom'];cwd=g.ROOT/'workspace-same-kimi-cc';cwd.mkdir(exist_ok=True);config=g.ROOT/'same-kimi-cc-config';config.mkdir(exist_ok=True);sid=str(uuid.uuid4());g.write_cc(g.source_messages(s,'codex-custom'),sid,cwd,config);env=g.ENV.copy();env.update(CLAUDE_CONFIG_DIR=str(config),ANTHROPIC_BASE_URL='http://127.0.0.1:'+str(server.server_port),ANTHROPIC_API_KEY='local-synthetic-relay-only',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',DISABLE_TELEMETRY='1',DISABLE_ERROR_REPORTING='1');a=[str(g.USER_HOME/'.local/bin/claude'),'--bare','--restricted','-p','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','','--system-prompt','Synthetic continuity test. No tools.','--model',model,'--output-format','json','--resume',sid,g.QUESTION];start=time.monotonic();r=subprocess.run(a,env=env,cwd=cwd,capture_output=True,text=True,timeout=120);(g.ROOT/'same-kimi-relay-stdout.txt').write_text(r.stdout);(g.ROOT/'same-kimi-relay-stderr.txt').write_text(r.stderr)
try:d=json.loads(r.stdout);answer=d.get('result','')
except ValueError:answer=''
result={'label':'codex-custom-to-cc-same-kimi-via-relay','source':'codex-custom','target':'cc','method':'text-only-responses-anthropic-relay','model':model,'exit':r.returncode,'answer':answer,'seconds':round(time.monotonic()-start,2),'exact_match':g.match(answer,s['expected']),'upstream_requests':evidence};o=g.load();o['checks'].append(result);g.save(o);server.shutdown();print(json.dumps(result),flush=True)
