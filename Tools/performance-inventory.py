#!/usr/bin/env python3
"""Read-only inventory of Swift performance review entry points.

These markers locate code to inspect; they do not measure runtime costs or
prove that a file is fast. No app, network, user stores or hardware is opened.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
patterns = {
    '调度': r'Timer\(|scheduledTimer|TimelineView|asyncAfter|Task\.sleep|makeTimerSource',
    '观察/发布': r'@Published|@ObservedObject|@EnvironmentObject|objectWillChange|\.sink\s*[({]',
    '同步 I/O/等待': r'Data\(contentsOf|String\(contentsOf|waitUntilExit|\.wait\(timeout:|sqlite3_step|readToEnd\(',
    '异步/后台': r'Task\s*[({]|Task\.detached|DispatchQueue|withChecked.*Continuation|URLSession',
    '派生/解析': r'\.filter\s*[({]|\.sorted\s*[({]|JSONSerialization|JSONDecoder|NSRegularExpression',
    '缓存/去重': r'\bcache\b|Cache|NSCache|deduplicat|guard\s+.*!=',
    '原生绘制/桥接': r'CALayer|Canvas\s*[({]|NSViewRepresentable|CAMetalLayer|MTLCommand',
}
files = sorted((root / 'Sources').rglob('*.swift'))
print('# Swift 性能入口清单 · 2026-10-03\n')
print('生成命令：`python3 Tools/performance-inventory.py`。只扫描源码中的入口标记；'
      '不代表逐文件运行测量或 Instruments 验证。空标记也不代表没有性能成本。\n')
print(f'共 {len(files)} 个 Swift 路径（包括 Widget 快照符号链接）。\n')
print('| 文件 | 行数 | 检查入口 |')
print('| --- | ---: | --- |')
for path in files:
    source = path.read_text()
    markers = [label for label, pattern in patterns.items() if re.search(pattern, source)]
    relative = str(path.relative_to(root))
    print(f'| `{relative}` | {len(source.splitlines())} | {"、".join(markers) or "输入/事件/纯值路径"} |')
