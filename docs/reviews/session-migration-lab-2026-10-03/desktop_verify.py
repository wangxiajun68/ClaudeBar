"""Read-only fact checks. These do not substitute for observed UI results."""
import graft_probe as g,sqlite3,json
p=g.USER_HOME/'Library/Application Support/Cursor/User/globalStorage/state.vscdb';c=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True);o=g.load()
for item in o.get('desktop_imports',[]):
 row=c.execute('select value from cursorDiskKV where key=?',('composerData:'+item['session_id'],)).fetchone()
 if not row:continue
 d=json.loads(row[0]);answers=[]
 for h in d['fullConversationHeadersOnly']:
  row=c.execute('select value from cursorDiskKV where key=?',('bubbleId:'+item['session_id']+':'+h['bubbleId'],)).fetchone()
  if row:
   b=json.loads(row[0]);t=b.get('text','')
   if b.get('type')==2 and t:answers.append(t)
 answer=answers[-1] if answers else '';item.update(answer=answer,success=g.match(answer,item['expected']),history_readable=True)
 print(json.dumps({'source':item['source'],'session_id':item['session_id'],'fact_match':item['success'],'answer':answer}))
c.close();g.save(o)
