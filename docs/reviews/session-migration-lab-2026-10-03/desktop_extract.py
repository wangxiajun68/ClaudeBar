"""Read only the synthetic desktop conversation explicitly named by UUID."""
import graft_probe as g,uuid,sys,json,sqlite3,pathlib
sid=str(uuid.UUID(sys.argv[1]));p=g.USER_HOME/'Library/Application Support/Cursor/User/globalStorage/state.vscdb';c=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True)
h=c.execute('select value from composerHeaders where composerId=?',(sid,)).fetchone()
if not h:raise SystemExit('No header for this composer')
header=json.loads(h[0]);cwd=pathlib.Path(header['workspaceIdentifier']['uri']['fsPath']).resolve()
try:cwd.relative_to(g.ROOT)
except ValueError:raise SystemExit('Refusing to extract a conversation outside the synthetic lab workspace')
d=json.loads(c.execute('select value from cursorDiskKV where key=?',('composerData:'+sid,)).fetchone()[0]);out=[]
for h in d['fullConversationHeadersOnly']:
 row=c.execute('select value from cursorDiskKV where key=?',('bubbleId:'+sid+':'+h['bubbleId'],)).fetchone()
 if not row:raise SystemExit('Missing message body')
 b=json.loads(row[0]);t=b.get('text','')
 if b.get('type') in [1,2] and t:out.append({'role':'user' if b['type']==1 else 'assistant','text':t})
c.close();expected=None
for m in out:
 if m['role']!='user':continue
 at=m['text'].find('{')
 if at<0:continue
 try:obj,_=json.JSONDecoder().raw_decode(m['text'][at:])
 except ValueError:continue
 if set(obj)=={'marker','constraint','next_step','decision'}:expected=obj;break
if not expected or not expected['marker'].startswith(('GUI-','MIGRATE-')):raise SystemExit('Synthetic continuity facts are required')
(g.ROOT/'cursor-desktop-text.json').write_text(json.dumps(out,indent=2));o=g.load();o['sources']['cursor-desktop']={'session_id':sid,'cwd':str(cwd),'expected':expected,'model':d.get('modelConfig',{}).get('modelName'),'success':any(m['text']=='ACK' for m in out)};g.save(o);print(json.dumps({'session_id':sid,'messages':len(out),'source_ack':o['sources']['cursor-desktop']['success']}))
