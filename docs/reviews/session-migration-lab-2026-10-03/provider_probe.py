import graft_probe as g,json,subprocess,pathlib,time,hashlib,shutil,sys
source,target=sys.argv[1:3];o=g.load();s=o['sources'][source];sid=s['session_id'];cwd=pathlib.Path(s['cwd']);p=next(pathlib.Path(s['native_home']).joinpath('sessions').glob('**/*'+sid+'.jsonl'));sha=hashlib.sha256(p.read_bytes()).hexdigest();a,e=g.codex_args(cwd,custom=target=='custom')
# Native fork needs transcript + target authentication in the same home. Only
# synthetic transcript is copied; credentials remain in the existing auth home.
if source=='codex-custom':
 dest=g.USER_HOME/'.codex/sessions/2026/10/03'/p.name
 if not dest.exists():shutil.copyfile(p,dest)
e.pop('CODEX_HOME',None);a+=['--json','fork',sid,g.QUESTION];label=source+'-native-fork-to-'+target;start=time.monotonic()
try:r=subprocess.run(a,env=e,cwd=cwd,text=True,capture_output=True,timeout=170)
except subprocess.TimeoutExpired:r=None
if r:
 (g.ROOT/(label+'-stdout.txt')).write_text(r.stdout);(g.ROOT/(label+'-stderr.txt')).write_text(r.stderr);es=[]
 for line in r.stdout.splitlines():
  try:es.append(json.loads(line))
  except ValueError:pass
 answer='\n'.join(v.get('item',{}).get('text','') for v in es if v.get('type')=='item.completed' and v.get('item',{}).get('type')=='agent_message');newid=next((v.get('thread_id') for v in es if v.get('type')=='thread.started'),None)
 result={'label':label,'source':source,'target':'codex-'+target,'method':'native-fork-provider-override','session_id':newid,'parent_session_id':sid,'answer':answer,'exit':r.returncode,'exact_match':g.match(answer,s['expected']),'seconds':round(time.monotonic()-start,2),'source_unchanged':hashlib.sha256(p.read_bytes()).hexdigest()==sha}
else:result={'label':label,'source':source,'target':'codex-'+target,'exact_match':False,'exit':124}
o=g.load();o['checks'].append(result);g.save(o);print(json.dumps(result),flush=True)
