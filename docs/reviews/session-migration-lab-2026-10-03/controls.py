import graft_probe as g,pathlib,json,uuid,subprocess,time,concurrent.futures
def task(kind):
 cwd=g.ROOT/('control-'+kind);cwd.mkdir(exist_ok=True);config=g.ROOT/('control-'+kind+'-config');config.mkdir(exist_ok=True)
 if kind=='cc':
  e,m=g.cc_env(config);a=[str(g.USER_HOME/'.local/bin/claude'),'--bare','--restricted','-p','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','','--system-prompt','Synthetic continuity test. No tools.','--model',m,'--output-format','json',g.QUESTION]
 elif kind=='cursor':e=g.cursor_env(config);a=[str(g.USER_HOME/'.local/bin/agent'),'-p','--mode','ask','--workspace',str(cwd),'--trust','--output-format','json','--model','auto',g.QUESTION]
 else:a,e=g.codex_args(cwd);a+=['--json',g.QUESTION]
 start=time.monotonic();r=subprocess.run(a,env=e,cwd=cwd,text=True,capture_output=True,timeout=160);(g.ROOT/('control-'+kind+'-stdout.txt')).write_text(r.stdout);(g.ROOT/('control-'+kind+'-stderr.txt')).write_text(r.stderr)
 if kind in ['cc','cursor']:
  try:answer=json.loads(r.stdout).get('result','')
  except ValueError:answer=''
 else:
  es=[json.loads(x) for x in r.stdout.splitlines() if x.startswith('{')];answer='\n'.join(v.get('item',{}).get('text','') for v in es if v.get('type')=='item.completed' and v.get('item',{}).get('type')=='agent_message')
 return {'label':'negative-control-'+kind,'target':kind,'method':'fresh-session-without-history','answer':answer,'exit':r.returncode,'pass':bool(answer) and 'MIGRATE-' not in answer and answer.count('unknown')>=4,'seconds':round(time.monotonic()-start,2)}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex:
 for r in ex.map(task,['cc','codex','cursor']):
  o=g.load();o.setdefault('controls',[]).append(r);g.save(o);print(json.dumps(r),flush=True)
