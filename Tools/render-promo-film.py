#!/usr/bin/env python3
"""
Render the ClaudeBar promo film.

The film is not a screen recording: it is a timeline animation rendered one
deterministic frame at a time and encoded with ffmpeg. Per frame Chrome is handed
a `t` and a CSS 3D scene is positioned as a function of it — nothing reads the clock,
the network or a file at draw time, so a re-render reproduces a frame rather than
merely resembling it.

    python3 Tools/render-promo-film.py              render frames, then encode
    python3 Tools/render-promo-film.py --frames     frames only
    python3 Tools/render-promo-film.py --encode     encode from frames already
                                                    on disk
    python3 Tools/render-promo-film.py --check      verify the inputs, no render

Outputs (docs/promo/ is committed; `.build/` is not):

    docs/promo/claudebar.mp4    1920x1080, 30 fps, H.264, yuv420p, +faststart
    docs/promo/claudebar.gif    800 wide, for the README's autoplay preview

The scene list, the camera grammar and the copy all live in
`docs/promo/prompt.md`, which is the film's single specification; the modules in
`Tools/promo/` implement it. That document is the place to change what the film
says — this script only runs it.

Requirements: Node (for the driver), `playwright-core` and Google Chrome (the
frame capture), and ffmpeg (the encode).
"""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FILM = ROOT / 'Tools/promo'
BUILD = ROOT / '.build/promo'
NODE_MODULES = BUILD / 'node_modules'

# `playwright-core` is the only runtime dependency, and it is small: a few
# hundred KB of client that drives the Chrome already installed on the machine,
# rather than a Playwright-managed browser download. It lives in `.build/` so a
# clone that never renders the film carries no `node_modules` at all.
PLAYWRIGHT_VERSION = '1.63.0'


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def need(tool: str, hint: str) -> None:
    if shutil.which(tool) is None:
        sys.exit(f'{tool} not found — {hint}')


def check(check_only: bool = False) -> None:
    """Fail before a render starts, not 2000 frames into one."""
    need('node', 'install Node 20+ (or `brew install node`)')
    need('ffmpeg', 'install it with `brew install ffmpeg`')

    chrome = Path('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
    if not chrome.exists():
        # The driver launches Playwright's `channel: 'chrome'`, which resolves
        # this same install; there is no browser-path argument to point at a
        # different Chromium, so do not offer one.
        sys.exit('Google Chrome (the stable channel) is required for frame capture — '
                 'install it from google.com/chrome.')

    for module in ('film.mjs', 'scenes.mjs', 'page.mjs', 'driver.mjs'):
        if not (FILM / module).is_file():
            sys.exit(f'Tools/promo/{module} is missing — the film cannot be rendered')

    spec = ROOT / 'docs/promo/prompt.md'
    if not spec.is_file():
        sys.exit('docs/promo/prompt.md is missing — it is the film\'s specification')

    if check_only:
        print('film inputs OK '
              f'({", ".join(sorted(p.name for p in FILM.glob("*.mjs")))})')


def require_surfaces() -> None:
    """The film composites the real surface renders; refresh them from source.

    This is the hard rule in prompt.md §5: every panel in the film is drawn from
    the current source by a preview tool, never a checked-in screenshot. Running
    them here means a fresh clone gets a film that matches the app.
    """
    # Refresh from production on every full render, not only on missing files.
    for script in ('render-popup-preview.py', 'render-mainwindow-preview.py',
                   'render-greeting-preview.py', 'render-island-preview.py'):
        print(f'  rendering current surfaces with Tools/{script}…', flush=True)
        run([sys.executable, str(ROOT / 'Tools' / script)])
    run([sys.executable, str(ROOT / 'Tools/promo/key-island.py')])


def install_deps() -> None:
    if (NODE_MODULES / 'playwright-core').is_dir():
        return
    print(f'  installing playwright-core@{PLAYWRIGHT_VERSION} into {BUILD}…')
    BUILD.mkdir(parents=True, exist_ok=True)
    run(['npm', 'install', '--no-audit', '--no-fund', '--silent',
         f'playwright-core@{PLAYWRIGHT_VERSION}'], cwd=BUILD)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--frames', action='store_true', help='render PNG frames only')
    parser.add_argument('--encode', action='store_true', help='encode from existing frames')
    parser.add_argument('--check', action='store_true', help='validate inputs and exit')
    parser.add_argument('--storyboard', action='store_true', help='render all chapter proof frames')
    parser.add_argument('--reuse-surfaces', action='store_true', help='reuse already refreshed surfaces')
    parser.add_argument('--only', type=int, metavar='N',
                        help='render one scene; with --preview, a contact strip')
    parser.add_argument('--preview', action='store_true',
                        help='with --only, 12 frames instead of the whole scene')
    args = parser.parse_args()

    check(args.check)
    if args.check:
        return 0

    if args.storyboard:
        install_deps()
        if not args.reuse_surfaces:
            require_surfaces()
        run(['node', str(FILM / 'driver.mjs'), '--storyboard'], cwd=BUILD)
        return 0

    if args.only:
        install_deps()
        if not args.reuse_surfaces:
            require_surfaces()
        run(['node', str(FILM / 'driver.mjs'), '--only', str(args.only)]
            + (['--preview'] if args.preview else []), cwd=BUILD)
        return 0

    if not args.encode:
        install_deps()
        if not args.reuse_surfaces:
            require_surfaces()
        run(['node', str(FILM / 'driver.mjs'), '--frames'], cwd=BUILD)
    if not args.frames:
        run(['node', str(FILM / 'driver.mjs'), '--encode'], cwd=BUILD)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
