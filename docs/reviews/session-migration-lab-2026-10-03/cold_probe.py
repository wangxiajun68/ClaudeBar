import graft_probe as g,pathlib,json,concurrent.futures
base=[x for x in g.load()['checks'] if x.get('native_path') and x['label'] in ['codex-official-to-cc','cc-to-codex','cc-to-cursor','cursor-to-cc','cursor-to-codex','codex-official-to-cursor','codex-custom-to-cc','codex-custom-to-cursor','codex-custom-to-codex']]
def task(x):
 r=g.call(x['target'],x['session_id'],pathlib.Path(x['cwd']),pathlib.Path(x['config_dir']),x['label']+'-cold-resume');r.update(source=x['source'],target=x['target'],session_id=x['session_id'],method='second-native-resume-new-process',exact_match=g.match(r['answer'],g.load()['sources'][x['source']]['expected']));return r
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex:
 for r in ex.map(task,base):
  o=g.load();o['checks'].append(r);g.save(o);print(json.dumps(r),flush=True)
