# Research only: synthetic sessions, pinned clients, real model calls cost quota.
# Set CLAUDEBAR_MIGRATION_LIVE=1 and CLAUDEBAR_MIGRATION_LAB_DIR to a private
# temporary directory; do not run this as a ClaudeBar dev integration.
import os as _research_os
if _research_os.environ.get('CLAUDEBAR_MIGRATION_LIVE') != '1':
    raise SystemExit('Live research disabled. Read README.md before opting in.')
if not _research_os.environ.get('CLAUDEBAR_MIGRATION_LAB_DIR'):
    raise SystemExit('An explicit private temporary lab directory is required.')
"""Isolated live interoperability research. Text-only native history adapters."""
import pathlib,json,os,subprocess,uuid,sys,time,sqlite3,hashlib,datetime,re
ROOT=pathlib.Path(os.environ['CLAUDEBAR_MIGRATION_LAB_DIR']).resolve(); USER_HOME=pathlib.Path.home(); LEDGER=ROOT/'live-ledger.json'
ENV={k:v for k,v in os.environ.items() if k in ['PATH','HOME','TMPDIR','USER','SHELL','LANG']}
ENV.update(HTTPS_PROXY='http://127.0.0.1:17890',HTTP_PROXY='http://127.0.0.1:17890',ALL_PROXY='http://127.0.0.1:17890',NO_PROXY='127.0.0.1,localhost')
def check_versions():
 versions = {'.local/bin/claude': '2.1.288 (Claude Code)',
             '.local/bin/codex': 'codex-cli 0.159.0-alpha.12.1',
             '.local/bin/agent': '2026.06.19-20-24-33-653a7fb'}
 for executable, expected in versions.items():
  actual = subprocess.check_output([str(USER_HOME/executable), '--version'], text=True, timeout=15).strip()
  if actual != expected:
   raise SystemExit('Untested client version; review adapters before running: '+executable+' '+actual)
check_versions()
QUESTION='From our previous conversation, return only a JSON object with keys marker, constraint, next_step, decision and their exact remembered values. Do not use tools or read files. If a fact is absent, use "unknown".'
def load():return json.loads(LEDGER.read_text())
def save(o):LEDGER.write_text(json.dumps(o,indent=2))
def texts(c):
 if isinstance(c,str):return c
 return '\n'.join(b.get('text','') for b in c or [] if b.get('type','').lower() in ['text','input_text','output_text'])
def vi(n):
 out=bytearray()
 while n>127:out.append((n&127)|128);n>>=7
 out.append(n);return bytes(out)
def field(n,v):return vi(n<<3|2)+vi(len(v))+v
def fields(d):
 def read(i):
  n=0;s=0
  while True:
   b=d[i];i+=1;n|=(b&127)<<s
   if b<128:return n,i
   s+=7
 out=[];i=0
 while i<len(d):
  tag,i=read(i);w=tag&7
  if w==2:n,i=read(i);v=d[i:i+n];i+=n
  elif w==0:v,i=read(i)
  elif w==1:v=d[i:i+8];i+=8
  elif w==5:v=d[i:i+4];i+=4
  else:raise ValueError('Unknown protobuf wire')
  out.append((tag>>3,v))
 return out

def source_messages(s,kind):
 if kind=='cursor-desktop':
  return json.loads((ROOT/'cursor-desktop-text.json').read_text())
 if kind=='cc':
  p=next(pathlib.Path(s['config_dir']).joinpath('projects').glob('**/'+s['session_id']+'.jsonl'))
  out=[]
  for line in p.read_text().splitlines():
   e=json.loads(line);m=e.get('message',{})
   if e.get('type') in ['user','assistant'] and m.get('role') in ['user','assistant']:
    t=texts(m.get('content'))
    if t:out.append({'role':m['role'],'text':t})
  return out
 if kind.startswith('codex'):
  p=next(pathlib.Path(s['native_home']).joinpath('sessions').glob('**/*'+s['session_id']+'.jsonl'))
  out=[]
  for line in p.read_text().splitlines():
   e=json.loads(line);d=e.get('payload',{})
   if e.get('type')=='event_msg' and d.get('type')=='item_completed':
    m=d['item'];role={'UserMessage':'user','AgentMessage':'assistant'}.get(m.get('type'))
    if role and texts(m.get('content')):out.append({'role':role,'text':texts(m['content'])})
  if out:return out
  for line in p.read_text().splitlines():
   e=json.loads(line);m=e.get('payload',{})
   if e.get('type')=='response_item' and m.get('type')=='message' and m.get('role') in ['user','assistant']:
    t=texts(m.get('content'))
    if t and not t.startswith(('<environment_context>','<user_instructions>','<INSTRUCTIONS>')):out.append({'role':m['role'],'text':t})
  return out
 if kind=='cursor':
  p=next(pathlib.Path(s['config_dir']).joinpath('chats').glob('**/'+s['session_id']+'/store.db'));c=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True)
  meta=json.loads(bytes.fromhex(c.execute("select value from meta where key='0'").fetchone()[0]));root=c.execute('select data from blobs where id=?',(meta['latestRootBlobId'],)).fetchone()[0];out=[]
  for n,v in fields(root):
   if n!=1:continue
   m=json.loads(c.execute('select data from blobs where id=?',(v.hex(),)).fetchone()[0]);role=m.get('role');t=texts(m.get('content'))
   if role not in ['user','assistant'] or not t:continue
   # Drop Cursor-generated environment/rules; retain actual user query text.
   if '<user_query>' in t:t=t.split('<user_query>',1)[1].split('</user_query>',1)[0].strip()
   elif role=='user' and t.startswith('<user_info>'):continue
   elif role=='user':t=re.sub(r'\s*<system_reminder>.*?</system_reminder>\s*','',t,flags=re.S).strip()
   if t:out.append({'role':role,'text':t})
  c.close();return out
 raise ValueError(kind)

def write_cc(messages,sid,cwd,config):
 project=re.sub(r'[^a-zA-Z0-9]','-',str(cwd.resolve()));p=config/'projects'/project/(sid+'.jsonl');p.parent.mkdir(parents=True,exist_ok=True);rows=[];parent=None
 for m in messages:
  eid=str(uuid.uuid4());msg={'role':m['role'],'content':m['text'] if m['role']=='user' else [{'type':'text','text':m['text']}]}
  if m['role']=='assistant':msg.update(type='message',id='msg_migration_'+uuid.uuid4().hex,model='imported-text',stop_reason='end_turn',stop_details=None,usage={'input_tokens':0,'output_tokens':0})
  rows.append({'type':m['role'],'uuid':eid,'parentUuid':parent,'isSidechain':False,'sessionId':sid,'cwd':str(cwd.resolve()),'version':'2.1.288','timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'message':msg,'userType':'external'})
  parent=eid
 p.write_text(''.join(json.dumps(e)+'\n' for e in rows));return p

def write_codex(messages,sid,cwd,home,provider):
 now=datetime.datetime.now(datetime.timezone.utc);stamp=now.isoformat(timespec='milliseconds').replace('+00:00','Z');p=home/'sessions'/now.strftime('%Y/%m/%d')/('rollout-'+now.strftime('%Y-%m-%dT%H-%M-%S')+'-'+sid+'.jsonl');p.parent.mkdir(parents=True,exist_ok=True)
 rows=[{'timestamp':stamp,'type':'session_meta','payload':{'id':sid,'timestamp':stamp,'cwd':str(cwd),'originator':'migration_probe','cli_version':'0.159.0-alpha.12.1','source':'cli','model_provider':provider}}]
 for m in messages:
  rows.append({'timestamp':stamp,'type':'response_item','payload':{'type':'message','role':m['role'],'content':[{'type':'input_text' if m['role']=='user' else 'output_text','text':m['text']}],**({'phase':'final_answer'} if m['role']=='assistant' else {})}})
  rows.append({'timestamp':stamp,'type':'event_msg','payload':{'type':'user_message' if m['role']=='user' else 'agent_message','message':m['text'],**({'images':[]} if m['role']=='user' else {'phase':'final_answer'})}})
 p.write_text(''.join(json.dumps(e)+'\n' for e in rows));return p

def write_cursor(messages,sid,cwd,config):
 blobs={}
 def store(b):h=hashlib.sha256(b).digest();blobs[h.hex()]=b;return h
 hashes=[store(json.dumps({'role':m['role'],'content':[{'type':'text','text':m['text']}]},separators=(',',':')).encode()) for m in messages];turns=[];pending=None;steps=[]
 def flush():
  if pending is None:return
  user=store(field(1,pending.encode())+field(2,str(uuid.uuid4()).encode()));step_hashes=[store(field(1,field(1,s.encode()))) for s in steps]
  turn=field(1,user)+b''.join(field(2,h) for h in step_hashes)+field(3,str(uuid.uuid4()).encode());turns.append(store(field(1,turn)))
 for m in messages:
  if m['role']=='user':flush();pending=m['text'];steps=[]
  elif pending is not None:steps.append(m['text'])
 flush();root=b''.join(field(1,h) for h in hashes)+b''.join(field(8,h) for h in turns)+field(9,('file://'+str(cwd)).encode())+vi(10<<3)+vi(2);h=store(root)
 p=config/'chats'/hashlib.md5(str(cwd.resolve()).encode()).hexdigest()/sid/'store.db';p.parent.mkdir(parents=True,exist_ok=True);c=sqlite3.connect(p);c.executescript('PRAGMA user_version=1; CREATE TABLE blobs(id TEXT PRIMARY KEY,data BLOB); CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT);');c.executemany('insert into blobs values(?,?)',blobs.items());meta={'agentId':sid,'latestRootBlobId':h.hex(),'name':'Synthetic imported continuity','mode':'search','isRunEverything':False,'createdAt':int(time.time()*1000)};c.execute('insert into meta values(?,?)',('0',json.dumps(meta,separators=(',',':')).encode().hex()));c.commit();c.close();return p

def cc_env(config):
 e=ENV.copy();s=json.loads((USER_HOME/'.claude/settings.json').read_text())['env'];e.update(CLAUDE_CONFIG_DIR=str(config),ANTHROPIC_BASE_URL=s['ANTHROPIC_BASE_URL'],ANTHROPIC_API_KEY=s.get('ANTHROPIC_API_KEY') or s['ANTHROPIC_AUTH_TOKEN'],ANTHROPIC_AUTH_TOKEN=s.get('ANTHROPIC_AUTH_TOKEN') or s['ANTHROPIC_API_KEY'],CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',DISABLE_TELEMETRY='1',DISABLE_ERROR_REPORTING='1');return e,s['ANTHROPIC_MODEL']
def cursor_env(config):
 c=sqlite3.connect((USER_HOME/'Library/Application Support/Cursor/User/globalStorage/state.vscdb').as_uri()+'?mode=ro',uri=True);token=c.execute("select value from ItemTable where key='cursorAuth/accessToken'").fetchone()[0];c.close();e=ENV.copy();e.update(CURSOR_CONFIG_DIR=str(config),CURSOR_DATA_DIR=str(config),AGENT_CLI_CREDENTIAL_STORE='memory',CURSOR_AUTH_TOKEN=token);return e

def codex_args(cwd,custom=False):
 a=[str(USER_HOME/'.local/bin/codex'),'exec','--ignore-user-config','--ignore-rules','--skip-git-repo-check','-C',str(cwd),'-s','read-only','-c','approval_policy="never"','-c','model_reasoning_effort="low"','-c','features.memories=false','-c','features.hooks=false','-c','features.shell_tool=false','-c','features.multi_agent=false'];env=ENV.copy()
 if not custom:
  a+=['-c','model_provider="migration_official_http"','-c','model_providers.migration_official_http.name="Official ChatGPT HTTP research"','-c','model_providers.migration_official_http.requires_openai_auth=true','-c','model_providers.migration_official_http.supports_websockets=false','-c','model_providers.migration_official_http.wire_api="responses"','-m','gpt-6.1-sol']
 else:
  obj=json.loads((USER_HOME/'.claude/claude-bar-codex-providers.json').read_text());providers=obj['providers'];p=providers[int(os.environ.get('CLAUDEBAR_MIGRATION_PROVIDER_INDEX','6'))];model=next((m['name'] for m in p['models'] if m['id']==p.get('activeModelID')),p['models'][0]['name']);assert p.get('wireAPI') == 'responses', 'Selected provider must support Responses';custom_home=ROOT/'custom-codex-config';custom_home.mkdir(exist_ok=True);env.update(CODEX_HOME=str(custom_home),MIGRATION_PROVIDER_KEY=p['apiKey']);a+=['-c','model_provider="migration_custom"','-c','model_providers.migration_custom.name="Custom research"','-c','model_providers.migration_custom.requires_openai_auth=false','-c','model_providers.migration_custom.supports_websockets=false','-c','model_providers.migration_custom.wire_api="responses"','-c','model_providers.migration_custom.env_key="MIGRATION_PROVIDER_KEY"','-c','model_providers.migration_custom.base_url='+json.dumps(p['baseURL']),'-m',model]
 return a,env

def call(kind,sid,cwd,config,label,custom=False,prompt=QUESTION):
 if kind=='cc':
  env,model=cc_env(config);args=[str(USER_HOME/'.local/bin/claude'),'--bare','--restricted','-p','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','','--system-prompt','Synthetic session continuity test. No tools.','--model',model,'--output-format','json','--resume',sid,prompt]
 elif kind=='cursor':
  env=cursor_env(config);args=[str(USER_HOME/'.local/bin/agent'),'-p','--mode','ask','--workspace',str(cwd),'--trust','--output-format','json','--model','auto','--resume',sid,prompt]
 else:
  args,env=codex_args(cwd,custom);args+=['--json','resume',sid,prompt]
 start=time.monotonic()
 try:r=subprocess.run(args,cwd=cwd,env=env,text=True,capture_output=True,timeout=170)
 except subprocess.TimeoutExpired as exc:
  (ROOT/(label+'-stderr.txt')).write_text('Timeout');return {'exit':124,'answer':'','seconds':round(time.monotonic()-start,2),'label':label}
 (ROOT/(label+'-stdout.txt')).write_text(r.stdout);(ROOT/(label+'-stderr.txt')).write_text(r.stderr)
 if kind in ['cc','cursor']:
  try:d=json.loads(r.stdout);answer=d.get('result','');is_error=d.get('is_error',False)
  except ValueError:answer='';is_error=True
 else:
  es=[]
  for line in r.stdout.splitlines():
   try:es.append(json.loads(line))
   except ValueError:pass
  answer='\n'.join(e.get('item',{}).get('text','') for e in es if e.get('type')=='item.completed' and e.get('item',{}).get('type')=='agent_message');is_error=any(e.get('type')=='error' for e in es)
 return {'exit':r.returncode,'is_error':is_error,'answer':answer,'seconds':round(time.monotonic()-start,2),'label':label}
def match(answer,expected):
 try:
  j=json.loads(answer.strip().removeprefix('```json').removesuffix('```').strip());return all(j.get(k)==v for k,v in expected.items())
 except ValueError:return all(v in answer for v in expected.values())

def main():
 source,target=sys.argv[1:3];o=load();s=o['sources'][source];messages=source_messages(s,source);label=source+'-to-'+target;cwd=ROOT/('workspace-'+label);cwd.mkdir(exist_ok=True);sid=str(uuid.uuid4());config=ROOT/(label+'-config');config.mkdir(exist_ok=True)
 if target=='cc':p=write_cc(messages,sid,cwd,config)
 elif target=='cursor':p=write_cursor(messages,sid,cwd,config)
 else:p=write_codex(messages,sid,cwd,USER_HOME/'.codex','migration_official_http')
 before=hashlib.sha256(p.read_bytes()).hexdigest();result=call(target,sid,cwd,config,label);result.update(source=source,target=target,session_id=sid,cwd=str(cwd),config_dir=str(config),native_path=str(p),message_count=len(messages),exact_match=match(result['answer'],s['expected']),import_sha256=before)
 o=load();o['checks'].append(result);save(o);print(json.dumps(result),flush=True)
if __name__=='__main__':main()
