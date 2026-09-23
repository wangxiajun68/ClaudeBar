#!/usr/bin/env python3
"""Print the CHANGELOG section for one version, for the GitHub Release body.

Lives in a file rather than inline in release.yml: a `<<'PY'` heredoc body has
to sit at column 0 to reach python unindented, which breaks the surrounding
YAML block scalar and makes the whole workflow unparseable.
"""
import os
import re
import sys

version = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("VERSION", "")
if not version:
    sys.exit("usage: extract-changelog.py <version>")

pattern = re.compile(rf"^## \[{re.escape(version)}\]")
out = []
found = False
for line in open("docs/CHANGELOG.md", encoding="utf-8"):
    if pattern.match(line):
        found = True
        out.append(line)
        continue
    if found and line.startswith("## ["):
        break
    if found:
        out.append(line)

if not found:
    sys.exit(f"no `## [{version}]` section in docs/CHANGELOG.md")

print("".join(out).rstrip())
