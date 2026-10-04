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
p.add_argument('--all-views',action='store_true',help='Keep every observed project view, rather than the top 25.')
p.add_argument('--bin-seconds',type=float,default=0,help='Also summarize sampled CPU and project body work by trace-relative time bins.')
p.add_argument('--cpu-stacks',action='store_true',help='Aggregate symbolic sampled stacks; inclusive weights overlap and are not additive.')
a=p.parse_args()
if a.bin_seconds<0:p.error('--bin-seconds must be nonnegative')
cache={}
stack=[]
node=0
kind=''
groups=collections.defaultdict(list)
counts=collections.Counter()
hitches=[]
weights=collections.Counter()
unknown=0
bins=collections.defaultdict(lambda:{'sampled_cpu_ms':0,'project_body_ms':0,'project_body_count':0})
schemas={}
symbols={}
binary_names={}
backtraces={}
cpu_self=collections.Counter()
cpu_inclusive=collections.Counter()
cpu_project=collections.Counter()
cpu_quality=collections.Counter()
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
 if a.cpu_stacks:
  if e.tag=='binary' and e.get('id'):
   binary_names[e.get('id')]=e.get('name','unknown')
  elif e.tag=='frame' and e.get('id'):
   binary=e.find('binary')
   module=binary_names.get(binary.get('ref') or binary.get('id'),'unknown') if binary is not None else 'unknown'
   symbols[e.get('id')]=(e.get('name','unknown'),module)
  elif e.tag=='tagged-backtrace' and e.get('id'):
   backtraces[e.get('id')]=tuple(symbols.get(f.get('ref') or f.get('id'),('unknown','unknown')) for f in e.findall('frame'))
 if e.tag=='schema':
  kind=e.get('name','')
  schemas[kind]=[c.findtext('name') for c in e.findall('col')]
 if e.tag=='row':
  cells=list(e)
  # Tables may omit schema on export; the row types identify the data.
  if len(cells)>=10 and cells[0].tag=='start-time' and cells[3].tag=='swiftui-update':
   typ=value(cells[3])[1]
   dur=number(cells[1])/1e6
   name=value(cells[9])[1]
   module=value(cells[8])[1]
   counts[typ]+=1
   if typ=='View Body Updates':
    groups[(module,name)].append(dur)
    if a.bin_seconds and module in ('ClaudeBar','ClaudeBarDev'):
     b=int(number(cells[0])/1e9/a.bin_seconds)
     bins[b]['project_body_ms']+=dur
     bins[b]['project_body_count']+=1
  elif len(cells)>=8 and cells[0].tag=='start-time' and cells[3].tag=='boolean':
   hitches.append({'start_ms':number(cells[0])/1e6,'duration_ms':number(cells[1])/1e6,'cause':value(cells[7])[1]})
  elif len(cells)>=6 and cells[0].tag=='sample-time':
   weight=number(cells[5])/1e6
   weights[value(cells[1])[1]]+=weight
   if a.cpu_stacks and len(cells)>6:
    bt=cells[6]
    frames=backtraces.get(bt.get('ref') or bt.get('id'),())
    if frames:
     cpu_self[frames[0]]+=weight
     for module in set(m for _,m in frames):cpu_inclusive[module]+=weight
     project=next((n for n,m in frames if m in ('ClaudeBar','ClaudeBarDev','ClaudeBarWidget','mihomo')),None)
     if project:
      cpu_project[project]+=weight
      quality=('project_frame_unsymbolicated_ms' if project.startswith('0x') else
               'project_entry_point_only_ms' if project=='main' else 'project_frame_symbolicated_ms')
      cpu_quality[quality]+=weight
    else:cpu_quality['missing_backtrace_ms']+=weight
   if a.bin_seconds:
    b=int(number(cells[0])/1e9/a.bin_seconds)
    bins[b]['sampled_cpu_ms']+=number(cells[5])/1e6
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
rank=sorted(rank,key=lambda x:x['total_ms'],reverse=True)
result={'input_file':a.xml.name,'update_counts':dict(counts),'project_view_bodies_by_total':rank if a.all_views else rank[:25],
 'hitches_table':{'row_count':len(hitches),'p50_ms':quantile([x['duration_ms'] for x in hitches],.5),'p95_ms':quantile([x['duration_ms'] for x in hitches],.95),'max_ms':max((x['duration_ms'] for x in hitches),default=None),'causes':dict(collections.Counter(x['cause'] for x in hitches)),'longest':sorted(hitches,key=lambda x:x['duration_ms'],reverse=True)[:5]},
 'time_profile_weight_ms_by_thread':dict(weights),'unresolved_references':unknown,
 'export_schemas':schemas}
if a.bin_seconds:
 result['time_bins']=[{'start_seconds':b*a.bin_seconds,'bin_seconds':a.bin_seconds,**v} for b,v in sorted(bins.items())]
if a.cpu_stacks:
 result['sampled_cpu_stacks']={
  'self_by_symbol':[{'symbol':n,'binary':m,'weight_ms':w} for (n,m),w in cpu_self.most_common(40)],
  'inclusive_by_binary_ms':dict(cpu_inclusive.most_common()),
  'first_project_frame':[{'symbol':n,'weight_ms':w} for n,w in cpu_project.most_common(40)],
  'quality':dict(cpu_quality)}
if a.output:a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(result,ensure_ascii=False,indent=2))
