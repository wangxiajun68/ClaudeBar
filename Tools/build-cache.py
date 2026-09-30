#!/usr/bin/env python3
"""Small build helpers: conservative input fingerprint and Swift driver output map."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
mode = sys.argv[1]
if mode == 'fingerprint':
    digest = hashlib.sha256()
    digest.update('\0'.join(sys.argv[2:]).encode())
    for tool in ['swiftc', 'clang']:
        digest.update(subprocess.check_output([tool, '--version'], stderr=subprocess.STDOUT))
    inputs = [root / 'VERSION']
    inputs += sorted(path for folder in ['Sources', 'Tools'] for path in (root / folder).rglob('*')
                     if path.is_file() and '__pycache__' not in path.parts and path.name != '.DS_Store')
    for path in inputs:
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    print(digest.hexdigest())
elif mode == 'filemap':
    directory = Path(sys.argv[2])
    directory.mkdir(parents=True, exist_ok=True)
    mapping = {'': {'swift-dependencies': str(directory / 'master.swiftdeps')}}
    for source in sys.argv[3:]:
        # Include full relative path; two files with the same basename must not collide.
        key = hashlib.sha256(source.encode()).hexdigest()[:16]
        mapping[source] = {'object': str(directory / (key + '.o')),
                           'swift-dependencies': str(directory / (key + '.swiftdeps'))}
    destination = directory / 'output-file-map.json'
    contents = json.dumps(mapping, indent=2) + '\n'
    if not destination.exists() or destination.read_text() != contents:
        destination.write_text(contents)
    print(destination)
else:
    raise SystemExit('expected fingerprint or filemap')
