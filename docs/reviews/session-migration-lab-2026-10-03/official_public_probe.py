import graft_probe as g
import json,pathlib,base64,urllib.request,urllib.error,socket
socket.setdefaulttimeout(15)
r=g.ROOT;auth=json.loads((pathlib.Path.home()/'.codex/auth.json').read_text());token=auth['tokens']['access_token'];payload=json.loads(base64.urlsafe_b64decode(token.split('.')[1]+'==='));scope=payload.get('scope',[]);scopes=scope.split() if isinstance(scope,str) else scope
out={'case':'existing-native-codex-token-public-models','new_oauth_registration':False,'native_scope_mentions_subscription_sharing':any('subscription' in x or 'sharing' in x for x in scopes),'native_scope_mentions_responses':any('responses' in x for x in scopes)}
req=urllib.request.Request('https://api.openai.com/v1/models',headers={'Authorization':'Bearer '+token});op=urllib.request.build_opener(urllib.request.ProxyHandler({'http':'http://127.0.0.1:17890','https':'http://127.0.0.1:17890'}))
try:
 with op.open(req,timeout=15) as response:
  d=json.load(response);out.update(http_status=response.status,catalog_received=True,response_shape=list(d),model_count=len(d.get('models',d.get('data',[]))))
except urllib.error.HTTPError as exc:
 out.update(http_status=exc.code,catalog_received=False)
 try:
  body=json.loads(exc.read());out['error_type']=body.get('error',{}).get('type');out['error_code']=body.get('error',{}).get('code')
 except Exception:pass
except Exception as exc:out.update(catalog_received=False,error_type=type(exc).__name__)
(r/'official-public-probe.json').write_text(json.dumps(out,indent=2));print(json.dumps(out),flush=True)
