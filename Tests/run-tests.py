#!/usr/bin/env python3
"""Select existing isolated regressions without compiling or launching the app."""
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
known = os.environ.get('TEST_SUITES', '').split()
if not known:
    raise SystemExit('Use make test or make test-fast (suite list lives in Makefile).')
requested = os.environ.get('TEST', '').replace(',', ' ').split() or known
unknown = set(requested) - set(known)
if unknown:
    raise SystemExit('Unknown test suite: ' + ', '.join(sorted(unknown)))
started = time.monotonic()
for suite in dict.fromkeys(requested):
    print(f'RUN {suite}', flush=True)
    subprocess.run([sys.executable, str(root / 'Tests' / (suite + '-regressions.py'))], cwd=root, check=True)
print(f'PASS: {len(set(requested))} suites in {time.monotonic() - started:.2f}s', flush=True)
