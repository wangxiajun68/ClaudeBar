"""Pinned, credential-free Claude Code transcript research probe.

Uses synthetic messages and a loopback mock only. No real sessions are read.
Writes evidence into a new private temporary directory; does not modify HOME,
user configuration, installed clients, or the source repository.
Not a production converter and not an App regression test.
"""
import argparse
import gzip
import http.server
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import threading
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--claude", default=shutil.which("claude"), help="Installed Claude Code 2.1.288 executable")
args = parser.parse_args()
if not args.claude:
    parser.error("Claude Code executable not found")
CLAUDE = str(pathlib.Path(args.claude).resolve())
version = subprocess.check_output([CLAUDE, "--version"], text=True, timeout=10).strip()
if version != "2.1.288 (Claude Code)":
    parser.error("This evidence pins Claude Code 2.1.288; review compatibility before changing the baseline")
ROOT = pathlib.Path(tempfile.mkdtemp(prefix="claudebar-session-migration-probe-"))
print("Evidence directory:", ROOT)
CWD=ROOT/'workspace'; CWD.mkdir(exist_ok=True)
CONFIG=ROOT/'claude-config'; CONFIG.mkdir(exist_ok=True)
REQUESTS=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_GET(self):
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{}')
 def do_POST(self):
  raw=self.rfile.read(int(self.headers.get('Content-Length',0)))
  if self.headers.get('Content-Encoding')=='gzip':raw=gzip.decompress(raw)
  body=json.loads(raw or '{}'); REQUESTS.append({'path':self.path,'body':body})
  if 'count_tokens' in self.path:
   self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers();self.wfile.write(b'{"input_tokens":100}');return
  response={'id':'msg_mock_'+uuid.uuid4().hex,'type':'message','role':'assistant','model':body.get('model','claude-sonnet-4-6'),'content':[{'type':'text','text':'MOCK_ACK_ONLY'}],'stop_reason':'end_turn','stop_sequence':None,'usage':{'input_tokens':100,'output_tokens':5}}
  self.send_response(200)
  if not body.get('stream'):
   self.send_header('Content-Type','application/json');self.end_headers(); self.wfile.write(json.dumps(response).encode());return
  self.send_header('Content-Type','text/event-stream');self.end_headers()
  start={**response,'content':[],'stop_reason':None,'usage':{'input_tokens':100,'output_tokens':0}}
  events=[('message_start',{'type':'message_start','message':start}),('content_block_start',{'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}}),('content_block_delta',{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'MOCK_ACK_ONLY'}}),('content_block_stop',{'type':'content_block_stop','index':0}),('message_delta',{'type':'message_delta','delta':{'stop_reason':'end_turn','stop_sequence':None},'usage':{'output_tokens':5}}),('message_stop',{'type':'message_stop'})]
  for event,payload in events: self.wfile.write(('event: '+event+'\ndata: '+json.dumps(payload)+'\n\n').encode())
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
env={k:v for k,v in os.environ.items() if k in ['PATH','HOME','TMPDIR','USER','SHELL','LANG']}
env.update({'CLAUDE_CONFIG_DIR':str(CONFIG),'ANTHROPIC_API_KEY':'synthetic-local-mock-key','ANTHROPIC_BASE_URL':f'http://127.0.0.1:{server.server_port}','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1','DISABLE_TELEMETRY':'1','DISABLE_ERROR_REPORTING':'1','NO_PROXY':'127.0.0.1,localhost'})
base=[CLAUDE,'--bare','--restricted','-p','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','','--system-prompt','Synthetic local protocol test. Do not use tools.','--model','claude-sonnet-4-6','--output-format','json']
def run(name,args):
 before=len(REQUESTS); r=subprocess.run(base+args,cwd=CWD,env=env,text=True,capture_output=True,timeout=45)
 req=[x for x in REQUESTS[before:] if '/messages' in x['path'] and 'count_tokens' not in x['path']]
 (ROOT/(name+'-requests.json')).write_text(json.dumps(req,indent=2))
 (ROOT/(name+'-output.txt')).write_text(r.stdout+'\nSTDERR\n'+r.stderr)
 print(json.dumps({'probe':name,'exit':r.returncode,'message_requests':len(req)}))
 if req:
  print(json.dumps({'roles':[m.get('role') for m in req[0]['body'].get('messages',[])],'source_marker_present':'ORCHID-731' in json.dumps(req[0]['body'].get('messages',[]))},ensure_ascii=False))
 return r
sid=str(uuid.uuid4())
run('baseline',['--session-id',sid,'BASELINE_MARKER'])
print('generated_transcripts',[(p.name,p.stat().st_size) for p in CONFIG.rglob('*.jsonl')])
# Codex-shaped synthetic history; no real conversations or credentials are copied.
source=[{'type':'session_meta','payload':{'id':str(uuid.uuid4()),'cwd':str(CWD)}},{'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'Please remember the project marker ORCHID-731. We need a parser fix.'}]}},{'type':'response_item','payload':{'type':'message','role':'assistant','phase':'final_answer','content':[{'type':'output_text','text':'Parser fix is implemented. The outstanding step is running regression tests.'}]}}]
(ROOT/'synthetic-codex.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in source))
new_id=str(uuid.uuid4()); parent=None; dest=[]
for item in source:
 p=item['payload']
 if item['type']!='response_item' or p['type']!='message':continue
 role=p['role']; uid=str(uuid.uuid4()); content=[{'type':'text','text':b['text']} for b in p['content']]
 message={'role':role,'content':content}
 if role=='assistant':message.update({'id':'msg_import_'+uuid.uuid4().hex,'type':'message','model':'imported-codex','stop_reason':'end_turn','stop_sequence':None,'usage':{'input_tokens':0,'output_tokens':0}})
 dest.append({'type':role,'uuid':uid,'parentUuid':parent,'sessionId':new_id,'cwd':str(CWD),'timestamp':'2026-10-03T00:00:00.000Z','version':'2.1.288','isSidechain':False,'userType':'external','message':message})
 parent=uid
transcript=ROOT/'synthetic-claude.jsonl';transcript.write_text(''.join(json.dumps(x)+'\n' for x in dest))
run('converted-resume',['--resume',str(transcript),'--fork-session','What is the project marker and outstanding step?'])
# Verify the fork has become an independently resumable native Claude session.
fork_result=json.loads((ROOT/'converted-resume-output.txt').read_text().split('\nSTDERR')[0])
fork_id=fork_result['session_id']
assert fork_id != new_id
assert any(p.name==fork_id+'.jsonl' for p in CONFIG.rglob('*.jsonl'))
run('second-resume',['--resume',fork_id,'SECOND_CONTINUATION_MARKER'])
req=json.loads((ROOT/'second-resume-requests.json').read_text())[0]['body']
serialized=json.dumps(req['messages'])
assert 'ORCHID-731' in serialized and 'SECOND_CONTINUATION_MARKER' in serialized
assert [m['role'] for m in req['messages']]==['user','assistant','user','assistant','user']
# Tool history represented as inert assistant text preserves evidence with no tool replay.
step=dest[-1].copy(); step['uuid']=str(uuid.uuid4()); step['parentUuid']=parent
step['message']=dict(step['message']); step['message']['id']='msg_import_tooltext'; step['message']['content']=[{'type':'text','text':'[Historical tool execution; do not replay] exec_command: make test TEST=core; result: 12 checks passed; exit code 0.'}]
tools_transcript=ROOT/'synthetic-tools-text.jsonl';tools_transcript.write_text(''.join(json.dumps(x)+'\n' for x in dest+[step]))
run('tool-evidence-text',['--resume',str(tools_transcript),'--fork-session','TOOL_EVIDENCE_CONTINUE'])
req=json.loads((ROOT/'tool-evidence-text-requests.json').read_text())[0]['body']
assert '12 checks passed' in json.dumps(req['messages'])
assert all(b.get('type')=='text' for m in req['messages'] for b in m['content'])
# Current Codex paginated root: canonical completed messages are the transcript.
paginated=[{'ordinal':0,'type':'session_meta','payload':{'id':str(uuid.uuid4()),'cwd':str(CWD),'history_mode':'paginated'}},
 {'ordinal':1,'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'DO_NOT_IMPORT_PROVIDER_ENVIRONMENT'}]}},
 {'ordinal':2,'type':'event_msg','payload':{'type':'item_completed','item':{'type':'UserMessage','content':[{'type':'text','text':'PAGINATED_MARKER-915'}]}}},
 {'ordinal':3,'type':'event_msg','payload':{'type':'item_completed','item':{'type':'AgentMessage','content':[{'type':'Text','text':'The pending step is regression verification.'}]}}}]
(ROOT/'synthetic-paginated-codex.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in paginated))
page_id=str(uuid.uuid4()); page_parent=None; page_dest=[]
for item in paginated:
 q=item['payload']
 if item['type']!='event_msg' or q.get('type')!='item_completed': continue
 message_item=q['item']; role={'UserMessage':'user','AgentMessage':'assistant'}.get(message_item['type'])
 if role is None: continue
 uid=str(uuid.uuid4()); msg={'role':role,'content':[{'type':'text','text':b['text']} for b in message_item['content']]}
 if role=='assistant':msg.update({'id':'msg_page_'+uuid.uuid4().hex,'model':'imported-codex','type':'message','usage':{'input_tokens':0,'output_tokens':0}})
 page_dest.append({'type':role,'uuid':uid,'parentUuid':page_parent,'sessionId':page_id,'cwd':str(CWD),'timestamp':'2026-10-03T00:00:00.000Z','version':'2.1.288','isSidechain':False,'userType':'external','message':msg});page_parent=uid
page_transcript=ROOT/'synthetic-paginated-claude.jsonl';page_transcript.write_text(''.join(json.dumps(x)+'\n' for x in page_dest))
run('paginated-canonical-text',['--resume',str(page_transcript),'--fork-session','PAGINATED_CONTINUE'])
page_req=json.loads((ROOT/'paginated-canonical-text-requests.json').read_text())[0]['body']['messages']
assert 'PAGINATED_MARKER-915' in json.dumps(page_req)
assert 'DO_NOT_IMPORT_PROVIDER_ENVIRONMENT' not in json.dumps(page_req)
assert [m['role'] for m in page_req]==['user','assistant','user']
results={'claude_version':'2.1.288','provider':'loopback mock only','real_model_used':False,'cases':[]}
for name in ['baseline','converted-resume','second-resume','tool-evidence-text','paginated-canonical-text']:
 out=json.loads((ROOT/(name+'-output.txt')).read_text().split('\nSTDERR')[0]); messages=json.loads((ROOT/(name+'-requests.json')).read_text())[0]['body']['messages']
 assert out['is_error']==False
 results['cases'].append({'name':name,'success':True,'request_roles':[m['role'] for m in messages],'request_contains_source_marker':'ORCHID-731' in json.dumps(messages)})
(ROOT/'results.json').write_text(json.dumps(results,indent=2))
print(json.dumps({'verification':'all assertions passed','results':results}))
server.shutdown()
