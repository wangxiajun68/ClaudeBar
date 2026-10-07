#!/usr/bin/env python3
"""The popup / island preview tools stay buildable, and stay copies of production.

Both renderers slice their views out of `Sources/` and compile the result with
`swiftc`. Nothing ran that compile until now: the popup probe had been broken
for an unknown number of commits (its stubs lagged production —
`AppPreferences.costDisplay`, `ExchangeRate`, `TokenMagnitude`, the real
`FilePaths`), while `--check` passed whenever it was run by hand because
nobody ran it, and the promo pipeline would only discover it at film time
(finding 746). The island tool's crop was also re-implementing the three
`islandSize` branches, so a changed `IslandStyle` constant would crop the PNG to
the old rectangle while `--check` still passed (finding 747), and the popup's
action bar hand-copied its bell / theme icons, already drifted (finding 571).

Three locks, each one edit away from regressing:

1. Both tools' `--check` paths exit 0 — every declaration lookup and the
   `swiftc` compile of the generated probe, stopped before the launch.
2. The island crop comes from the production `state.islandSize`, not a copy of
   the geometry constants.
3. The popup action bar's state-dependent faces come from the production
   `ActionBarFaces`, not restated literals.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]

popup_tool = (root / 'Tools/render-popup-preview.py').read_text()
island_tool = (root / 'Tools/render-island-preview.py').read_text()

# --- 2. The island crop is the state's own size -----------------------------
assert 'state.islandSize' in island_tool, \
    'the island crop must read the production state.islandSize (finding 747)'
assert 'islandTargetSize' not in island_tool, \
    'the island tool must not re-implement the island-size formulas (finding 747)'
for constant in ('minAlertWidth', 'minExpandedWidth', 'topFlare', 'wingWidth'):
    assert constant not in island_tool, \
        f'the island tool restates IslandStyle.{constant} — the drift finding 747 removed'

# --- 3. The popup action bar is the production selection ---------------------
assert 'ActionBarFaces' in popup_tool, \
    'the popup action bar must slice ActionBarFaces out of MenuBarView (finding 571)'
for literal in ('"bell.fill"', '"bell.slash"', '"sun.max"', '"moon"'):
    assert literal not in popup_tool, \
        f'the popup tool restates the action-bar literal {literal} (finding 571)'
assert 'MenuBarView.swift' in popup_tool, \
    'ActionBarFaces must be sliced from MenuBarView.swift'

# --- 1. Both probes compile --------------------------------------------------
for script in ('render-popup-preview.py', 'render-island-preview.py'):
    result = subprocess.run([sys.executable, str(root / 'Tools' / script), '--check'],
                            cwd=root, capture_output=True, text=True)
    assert result.returncode == 0, (
        f'{script} --check failed — a declaration moved or the probe no longer '
        f'compiles:\n{result.stdout}\n{result.stderr}')

print('PASS: popup and island preview probes compile; crop and action-bar faces come from production')
