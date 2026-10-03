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
    # Everything under `Sources/` is a build input: Swift sources, copied
    # resources, the icons, and the build scripts themselves. `Tools/` mostly
    # is not — the preview, profile and promo drivers never touch the app, and
    # hashing them made an edit to `render-*.py` force a re-link, re-sign and
    # re-verify of a bundle whose bytes cannot change (~4.3 s measured, zero
    # objects recompiled). Only the two scripts `Sources/build.sh` actually
    # invokes are fingerprinted; `Tools/check-bundle.py` is the reuse gate
    # itself, so changing it must invalidate. If build.sh starts invoking
    # another Tools script, add it here.
    inputs = [root / 'VERSION']
    inputs += sorted(path for path in (root / 'Sources').rglob('*')
                     if path.is_file() and '__pycache__' not in path.parts and path.name != '.DS_Store')
    inputs += [path for path in [root / 'Tools' / name for name in ('build-cache.py', 'check-bundle.py')]
               if path.is_file()]
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
    # The map is the exact input list for the compile that is about to run, so
    # an object or swiftdeps keyed to a source that is no longer in it (deleted
    # or renamed file) can never be reused. Without this the cache only grows:
    # each rename strands one pair permanently, and copying the repo strands
    # every pair built under the old root path. Only `.o`/`.swiftdeps` are
    # touched — swiftmodule/swiftdoc/priors/abi.json are not keyed by source
    # and are left alone. Shallow sweep needs no directory walk (the rest of
    # the cache is elsewhere, e.g. `<module>.build/`), it targets only the
    # files the map itself names, and it runs before the compile, so it can
    # never delete what the current build has just produced.
    live = set()
    for entry in mapping.values():
        for key in ('object', 'swift-dependencies'):
            if key in entry:
                live.add(Path(entry[key]).name)
    stale = [path for path in directory.iterdir()
             if path.suffix in ('.o', '.swiftdeps') and path.name not in live]
    for path in stale:
        path.unlink()
    if stale:
        print(f'pruned {len(stale)} stale object/dependency files from {directory}', file=sys.stderr)
    print(destination)
else:
    raise SystemExit('expected fingerprint or filemap')
