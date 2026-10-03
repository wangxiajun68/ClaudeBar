"""Pinned Cursor 3.23.12 experiment: INSERT only synthetic new session rows."""
import graft_probe as g,json,pathlib,sqlite3,uuid,time,base64,copy,sys
import plistlib
if plistlib.loads(pathlib.Path('/Applications/Cursor.app/Contents/Info.plist').read_bytes())['CFBundleShortVersionString'] != '3.23.12':
 raise SystemExit('Untested Cursor desktop version')
if g.ENV.get('CLAUDEBAR_ALLOW_DESKTOP_GRAFT') != '1' and __import__('os').environ.get('CLAUDEBAR_ALLOW_DESKTOP_GRAFT') != '1':
 raise SystemExit('Desktop graft requires separate explicit opt-in; read README.md')
source=sys.argv[1];o=g.load();s=o['sources'][source];messages=g.source_messages(s,source);template_sid=o['sources']['cursor-desktop']['session_id'];cwd=pathlib.Path(o['sources']['cursor-desktop']['cwd']);sid=str(uuid.uuid4());config=g.ROOT/('desktop-'+source+'-staging');config.mkdir(exist_ok=True);p=g.write_cursor(messages,sid,cwd,config);st=sqlite3.connect(p);meta=json.loads(bytes.fromhex(st.execute("select value from meta where key='0'").fetchone()[0]));root=st.execute('select data from blobs where id=?',(meta['latestRootBlobId'],)).fetchone()[0]
# Match desktop native agent mode, preserving every other protobuf field.
root=root[:-2]+g.vi(10<<3)+g.vi(1);rootstate='~'+base64.b64encode(root).decode();dbpath=g.USER_HOME/'Library/Application Support/Cursor/User/globalStorage/state.vscdb';db=sqlite3.connect(dbpath);db.execute('pragma busy_timeout=5000');template=json.loads(db.execute('select value from cursorDiskKV where key=?',('composerData:'+template_sid,)).fetchone()[0]);header=json.loads(db.execute('select value from composerHeaders where composerId=?',(template_sid,)).fetchone()[0]);templates={}
for h in template['fullConversationHeadersOnly']:
 b=json.loads(db.execute('select value from cursorDiskKV where key=?',('bubbleId:'+template_sid+':'+h['bubbleId'],)).fetchone()[0])
 if b.get('text'):templates[b['type']]=b
now=int(time.time()*1000);headers=[];rows=[]
for m in messages:
 typ=1 if m['role']=='user' else 2;bid=str(uuid.uuid4());b=copy.deepcopy(templates[typ]);b.update(bubbleId=bid,text=m['text'],conversationState=rootstate,createdAt=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),richText=None);b.pop('thinking',None);b.pop('thinkingDurationMs',None);b.pop('checkpointId',None);b.pop('requestId',None)
 headers.append({'bubbleId':bid,'type':typ,'grouping':{'isRenderable':True,'hasText':True,'textPreview':m['text'][:160]},'createdAt':b['createdAt']});rows.append(('bubbleId:'+sid+':'+bid,json.dumps(b)))
composer=copy.deepcopy(template)
for k in ['speculativeSummarizationEncryptionKey','blobEncryptionKey','latestChatGenerationUUID','promptTokenBreakdown','contextTokensUsed','contextUsagePercent']:composer.pop(k,None)
composer.update(composerId=sid,name='MIGRATION '+source,fullConversationHeadersOnly=headers,conversationMap={},conversationState=rootstate,isNAL=True,status='completed',createdAt=now,lastUpdatedAt=now,conversationCheckpointLastUpdatedAt=now,queueItems=[],text='',richText=None,contextUsagePercent=0);rows.append(('composerData:'+sid,json.dumps(composer)))
header.update(composerId=sid,name=composer['name'],subtitle='Synthetic session migration research',createdAt=now,lastUpdatedAt=now,conversationCheckpointLastUpdatedAt=now,contextUsagePercent=0,agentLocationHistory=[])
# All session identity keys are new. Shared content hashes are deduplicated.
with db:
 for key,value in rows:db.execute('insert into cursorDiskKV(key,value) values(?,?)',(key,value))
 for bid,data in st.execute('select id,data from blobs'):
  key='agentKv:blob:'+bid;existing=db.execute('select value from cursorDiskKV where key=?',(key,)).fetchone()
  if not existing:db.execute('insert into cursorDiskKV(key,value) values(?,?)',(key,data))
  elif bytes(existing[0])!=data:raise RuntimeError('Content hash collision or incompatible store encoding')
 db.execute('insert into composerHeaders(composerId,workspaceId,createdAt,lastUpdatedAt,isArchived,isSubagent,recency,checkpointAt,value,subagentTypeName) values(?,?,?,?,?,?,?,?,?,?)',(sid,header['workspaceIdentifier']['id'],now,now,0,0,now,now,json.dumps(header),''))
db.close();st.close();o=g.load();o.setdefault('desktop_imports',[]).append({'source':source,'session_id':sid,'expected':s['expected'],'message_count':len(messages),'method':'current-desktop-header-bubbles-agentKv-root','name':composer['name'],'success':None});g.save(o);print(json.dumps({'session_id':sid,'name':composer['name'],'message_count':len(messages)}))
