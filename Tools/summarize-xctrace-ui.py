#!/usr/bin/env python3
"""Summarize Xcode 27 exported SwiftUI update tables with streaming XML reads.

Only project view types and aggregate durations are reported; raw trace data is
kept local. hitches_table rows are not converted into FPS or hitch-time ratio.
The private export layout may change in later Instruments versions.
"""
import argparse, collections, json, xml.etree.ElementTree as E
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('xml',type=Path)
p.add_argument('--output',type=Path)
a=p.parse_args()
cache={}
stack=[]
node=0
kind=''
groups=collections.defaultdict(list)
counts=collections.Counter()
hitches=[]
weights=collections.Counter()
unknown=0
keep={'duration','start-time','string','swiftui-update','process','thread','sample-time','weight','boolean','display-name'}
def value(e):
 global unknown
 ref=e.get('ref')
 if ref:
  if ref not in cache: unknown+=1
  return cache.get(ref,('', ''))
 return e.text or '', e.get('fmt',e.text or '')
def number(e):
 try:return int(value(e)[0])
 except ValueError:return 0
for event,e in E.iterparse(a.xml,events=('start','end')):
 if event=='start':
  stack.append(e)
  if e.tag=='node':
   node+=1
   kind=''
  continue
 if e.tag in keep and e.get('id'):
  cache[e.get('id')]=(e.text or '',e.get('fmt',e.text or ''))
 if e.tag=='schema':
  kind=e.get('name','')
 if e.tag=='row':
  cells=list(e)
  # Tables may omit schema on export; the row types identify the data.
  if len(cells)>=10 and cells[0].tag=='start-time' and cells[3].tag=='swiftui-update':
   typ=value(cells[3])[1]
   dur=number(cells[1])/1e6
   name=value(cells[9])[1]
   module=value(cells[8])[1]
   counts[typ]+=1
   if typ=='View Body Updates':groups[(module,name)].append(dur)
  elif len(cells)>=8 and cells[0].tag=='start-time' and cells[3].tag=='boolean':
   hitches.append({'start_ms':number(cells[0])/1e6,'duration_ms':number(cells[1])/1e6,'cause':value(cells[7])[1]})
  elif len(cells)>=6 and cells[0].tag=='sample-time':
   weights[value(cells[1])[1]]+=number(cells[5])/1e6
  parent=stack[-2]
  parent.remove(e)
  e.clear()
 stack.pop()
def quantile(values,q):
 if not values:return None
 s=sorted(values)
 x=(len(s)-1)*q;lo=int(x);hi=min(lo+1,len(s)-1)
 return s[lo]+(s[hi]-s[lo])*(x-lo)
rank=[]
for (module,name),v in groups.items():
 if module not in ('ClaudeBar','ClaudeBarDev'):continue
 rank.append({'module':module,'view':name,'count':len(v),'total_ms':sum(v),'p50_ms':quantile(v,.5),'p95_ms':quantile(v,.95),'max_ms':max(v),'over_0_5_ms':sum(x>.5 for x in v),'over_1_ms':sum(x>1 for x in v)})
result={'input_file':a.xml.name,'update_counts':dict(counts),'project_view_bodies_by_total':sorted(rank,key=lambda x:x['total_ms'],reverse=True)[:25],
 'hitches_table':{'row_count':len(hitches),'p50_ms':quantile([x['duration_ms'] for x in hitches],.5),'p95_ms':quantile([x['duration_ms'] for x in hitches],.95),'max_ms':max((x['duration_ms'] for x in hitches),default=None),'causes':dict(collections.Counter(x['cause'] for x in hitches)),'longest':sorted(hitches,key=lambda x:x['duration_ms'],reverse=True)[:5]},
 'time_profile_weight_ms_by_thread':dict(weights),'unresolved_references':unknown}
if a.output:a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(result,ensure_ascii=False,indent=2))
