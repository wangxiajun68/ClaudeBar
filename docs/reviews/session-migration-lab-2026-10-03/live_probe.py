# Research only: synthetic sessions, pinned clients, real model calls cost quota.
# Set CLAUDEBAR_MIGRATION_LIVE=1 and CLAUDEBAR_MIGRATION_LAB_DIR to a private
# temporary directory; do not run this as a ClaudeBar dev integration.
import os as _research_os
if _research_os.environ.get('CLAUDEBAR_MIGRATION_LIVE') != '1':
    raise SystemExit('Live research disabled. Read README.md before opting in.')
if not _research_os.environ.get('CLAUDEBAR_MIGRATION_LAB_DIR'):
    raise SystemExit('An explicit private temporary lab directory is required.')
import pathlib,json,os,subprocess,uuid,sys,time
ROOT=pathlib.Path(os.environ['CLAUDEBAR_MIGRATION_LAB_DIR']).resolve()
USER_HOME=pathlib.Path.home()
LEDGER=ROOT/'live-ledger.json'
ENV={k:v for k,v in os.environ.items() if k in ['PATH','HOME','TMPDIR','USER','SHELL','LANG']}
ENV.update({'HTTPS_PROXY':'http://127.0.0.1:17890','HTTP_PROXY':'http://127.0.0.1:17890','ALL_PROXY':'http://127.0.0.1:17890','NO_PROXY':'127.0.0.1,localhost'})
def ledger():return json.loads(LEDGER.read_text()) if LEDGER.exists() else {'sources':{},'checks':[]}
def save(o):LEDGER.write_text(json.dumps(o,indent=2))
def run(cmd,env,cwd,label,timeout=100):
 started=time.monotonic();r=subprocess.run(cmd,cwd=cwd,env=env,text=True,capture_output=True,timeout=timeout)
 # Outputs only contain synthetic task data. Credentials are never logged.
 (ROOT/(label+'-stdout.txt')).write_text(r.stdout);(ROOT/(label+'-stderr.txt')).write_text(r.stderr)
 print(json.dumps({'label':label,'exit':r.returncode,'seconds':round(time.monotonic()-started,2),'output_bytes':len(r.stdout)}),flush=True)
 return r
from graft_probe import check_versions
check_versions()
kind=sys.argv[1];o=ledger();cwd=ROOT/('workspace-'+kind);cwd.mkdir(exist_ok=True)
marker='MIGRATE-'+uuid.uuid4().hex[:12];expected={'marker':marker,'constraint':'never edit VERSION','next_step':'verify parser regression','decision':'keep original session'}
prompt='This is an isolated session continuity research task. Do not use tools, read files, or edit anything. Remember these facts for a later question: '+json.dumps(expected)+'. Reply only ACK.'
if kind=='cc':
 config=ROOT/'cc-config';config.mkdir(exist_ok=True)
 settings=json.loads((USER_HOME/'.claude/settings.json').read_text()).get('env',{})
 env=ENV.copy();env.update({'CLAUDE_CONFIG_DIR':str(config),'ANTHROPIC_BASE_URL':settings['ANTHROPIC_BASE_URL'],'ANTHROPIC_API_KEY':settings.get('ANTHROPIC_API_KEY') or settings.get('ANTHROPIC_AUTH_TOKEN'),'ANTHROPIC_AUTH_TOKEN':settings.get('ANTHROPIC_AUTH_TOKEN') or settings.get('ANTHROPIC_API_KEY'),'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1','DISABLE_TELEMETRY':'1','DISABLE_ERROR_REPORTING':'1'})
 sid=str(uuid.uuid4());cmd=[str(USER_HOME/'.local/bin/claude'),'--bare','--restricted','-p','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','','--system-prompt','You are taking part in a synthetic session continuity test. No tools.','--model',settings['ANTHROPIC_MODEL'],'--output-format','json','--session-id',sid,prompt]
 r=run(cmd,env,cwd,'source-cc')
 try:result=json.loads(r.stdout);sid=result['session_id'];success=not result['is_error']
 except Exception:success=False
 o['sources'][kind]={'session_id':sid,'cwd':str(cwd),'config_dir':str(config),'expected':expected,'success':success,'model':settings['ANTHROPIC_MODEL']}
 if success:print(json.dumps({'source':kind,'answer':result.get('result')}))
 save(o)

if kind=='codex-official':
 # Authentication stays in the user's native store; configuration is ignored.
 # Only this new, synthetic research thread is created; existing threads are never resumed.
 env=ENV.copy()
 cmd=[str(USER_HOME/'.local/bin/codex'),'exec','--ignore-user-config','--ignore-rules','--skip-git-repo-check','-C',str(cwd),'-s','read-only','-c','approval_policy="never"','-c','model_provider="migration_official_http"','-c','model_providers.migration_official_http.name="Official ChatGPT HTTP research"','-c','model_providers.migration_official_http.requires_openai_auth=true','-c','model_providers.migration_official_http.supports_websockets=false','-c','model_providers.migration_official_http.wire_api="responses"','-c','model_reasoning_effort="low"','-c','features.memories=false','-c','features.hooks=false','-c','features.shell_tool=false','-c','features.multi_agent=false','-m','gpt-6.1-sol','--json',prompt]
 r=run(cmd,env,cwd,'source-codex-official',timeout=140)
 events=[]
 for line in r.stdout.splitlines():
  try:events.append(json.loads(line))
  except ValueError:pass
 sid=next((e.get('thread_id') for e in events if e.get('type')=='thread.started'),None)
 answer='\n'.join(e.get('item',{}).get('text','') for e in events if e.get('type')=='item.completed' and e.get('item',{}).get('type')=='agent_message')
 success=r.returncode==0 and bool(answer)
 o['sources'][kind]={'session_id':sid,'cwd':str(cwd),'expected':expected,'success':success,'model':'gpt-6.1-sol','provider':'migration_official_http','native_home':str(USER_HOME/'.codex')}
 print(json.dumps({'source':kind,'answer':answer,'success':success}))
 save(o)

if kind=='cursor':
 import sqlite3
 config=ROOT/'cursor-config';config.mkdir(exist_ok=True)
 db_path=USER_HOME/'Library/Application Support/Cursor/User/globalStorage/state.vscdb'
 db=sqlite3.connect(db_path.as_uri()+'?mode=ro',uri=True)
 row=db.execute("select value from ItemTable where key='cursorAuth/accessToken'").fetchone();db.close()
 if not row:raise RuntimeError('No existing Cursor account token')
 env=ENV.copy();env.update({'CURSOR_CONFIG_DIR':str(config),'CURSOR_DATA_DIR':str(config),'AGENT_CLI_CREDENTIAL_STORE':'memory','CURSOR_AUTH_TOKEN':row[0]})
 # Ask mode; no hooks, project MCP configuration or task files in this workspace.
 cmd=[str(USER_HOME/'.local/bin/agent'),'-p','--mode','ask','--workspace',str(cwd),'--trust','--output-format','json','--model','auto',prompt]
 r=run(cmd,env,cwd,'source-cursor',timeout=140)
 try:result=json.loads(r.stdout);success=r.returncode==0;sid=result.get('session_id') or result.get('sessionId') or result.get('chat_id')
 except Exception:success=False;sid=None;result={}
 o['sources'][kind]={'session_id':sid,'cwd':str(cwd),'config_dir':str(config),'expected':expected,'success':success,'model':'auto'}
 print(json.dumps({'source':kind,'success':success,'output_keys':list(result),'answer':result.get('result')}))
 save(o)
