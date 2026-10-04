#!/usr/bin/env python3
"""Read-only inventory of Swift performance review entry points.

These markers locate code to inspect; they do not measure runtime costs or
prove that a file is fast. No app, network, user stores or hardware is opened.
"""
from pathlib import Path
import argparse
from datetime import date
import hashlib
import json
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--date', default=date.today().isoformat())
parser.add_argument('--include-native-build', action='store_true', help='Include C, headers, shell and standalone Metal sources.')
parser.add_argument('--json-output', type=Path, help='Save exact source hashes and marker locations; no runtime claims.')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
patterns = {
    '调度': r'Timer\(|scheduledTimer|TimelineView|asyncAfter|Task\.sleep|makeTimerSource|usleep\(|nanosleep\(|poll\(',
    '观察/发布': r'@Published|@ObservedObject|@EnvironmentObject|objectWillChange|\.sink\s*[({]',
    '同步 I/O/等待': r'Data\(contentsOf|String\(contentsOf|waitUntilExit|\.wait\(timeout:|sqlite3_step|readToEnd\(|waitpid\(|fopen\(',
    '异步/后台': r'Task\s*[({]|Task\.detached|DispatchQueue|withChecked.*Continuation|URLSession',
    '派生/解析': r'\.filter\s*[({]|\.sorted\s*[({]|JSONSerialization|JSONDecoder|NSRegularExpression',
    '缓存/去重': r'\bcache\b|Cache|NSCache|deduplicat|guard\s+.*!=',
    '原生绘制/桥接': r'CALayer|Canvas\s*[({]|NSViewRepresentable|CAMetalLayer|MTLCommand',
}
extensions = {'.swift', '.c', '.h', '.sh', '.metal'} if args.include_native_build else {'.swift'}
files = sorted(path for path in (root / 'Sources').rglob('*') if path.is_file() and path.suffix in extensions)
records = []
print(f'# 性能源码入口清单 · {args.date}\n')
command = 'python3 Tools/performance-inventory.py --date ' + args.date + (' --include-native-build' if args.include_native_build else '')
print(f'生成命令：`{command}`。只扫描源码中的入口标记；'
      '不代表逐文件运行测量或 Instruments 验证。空标记也不代表没有性能成本。\n')
print(f'共 {len(files)} 个源码路径，其中 {sum(path.suffix == ".swift" for path in files)} 个 Swift 路径（包括 Widget 快照符号链接）。\n')
print('| 文件 | 行数 | 检查入口 |')
print('| --- | ---: | --- |')
for path in files:
    source = path.read_text()
    markers = [label for label, pattern in patterns.items() if re.search(pattern, source)]
    relative = str(path.relative_to(root))
    records.append({'path': relative, 'lines': len(source.splitlines()),
                    'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                    'symlink_target': str(path.readlink()) if path.is_symlink() else None,
                    'entrypoints': {label: [index for index, line in enumerate(source.splitlines(), 1) if re.search(pattern, line)]
                                    for label, pattern in patterns.items() if re.search(pattern, source)},
                    'review_scope': 'Static entrypoint scan; see module report for focused reviews, measurements and runtime gaps'})
    print(f'| `{relative}` | {len(source.splitlines())} | {"、".join(markers) or "输入/事件/纯值路径"} |')

if args.json_output:
    args.json_output.write_text(json.dumps({'date': args.date, 'files': records}, ensure_ascii=False, indent=2) + '\n')
