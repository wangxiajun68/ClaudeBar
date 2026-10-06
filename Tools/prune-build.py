#!/usr/bin/env python3
"""Remove regenerable bulk from `.build/` while keeping every result file.

`.build/` holds two kinds of content: recorded measurements (JSON / LOG / JSONL,
kilobytes each) that the review documents cite, and the raw products of the run
that produced them — Instruments `.trace` bundles, `.xml` exports of those
bundles, compiled probe executables, and rendered PNG frames. The second group
is hundreds of megabytes per audit and is what makes the directory several GB.

Nothing here touches a measurement; it deletes only derived files that come back
by re-running the command recorded in the review document. A size floor refuses
to delete anything under `--keep-bytes` (default 16 KiB) so a small result file
that happens to share an extension is never caught.

Usage:
  python3 Tools/prune-build.py --dry-run
  python3 Tools/prune-build.py
  python3 Tools/prune-build.py --dir .build/greeting-preview
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Extensions of the raw products. `.trace` and `.dSYM` are directories.
BULK_SUFFIXES = {'.trace', '.dSYM', '.xml', '.png', '.otool'}
# Probe executables carry no distinguishing suffix: they are the binaries
# `swiftc` emits next to their `.swift` source inside `.build/`.
BULK_NAMES = {
    'probe', 'bench', 'preview', 'read-probe', 'clock-debug', 'widget-dedup-probe',
    'probe_test', 'ClaudeBar-baseline-symbols', 'baseline-symbols',
}


def is_bulk(path: Path) -> bool:
    return path.suffix in BULK_SUFFIXES or path.name in BULK_NAMES


def measure(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(child.stat().st_size for child in path.rglob('*') if child.is_file())


def remove(path: Path) -> None:
    if path.is_file() or path.is_symlink():
        path.unlink(missing_ok=True)
        return
    # Instruments bundles are read-only; drop the bit so the tree can be walked.
    for child in path.rglob('*'):
        if child.is_dir():
            child.chmod(0o700)
    for child in sorted(path.rglob('*'), key=lambda p: len(p.parts), reverse=True):
        if child.is_file() or child.is_symlink():
            child.unlink(missing_ok=True)
        else:
            child.rmdir()
    path.rmdir()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--dir', type=Path, default=Path('.build'), help='directory to prune (default: .build)')
    parser.add_argument('--dry-run', action='store_true', help='list without deleting')
    parser.add_argument('--keep-bytes', type=int, default=16 * 1024,
                        help='never delete a path smaller than this (guard for result files)')
    args = parser.parse_args()

    target = args.dir if args.dir.is_absolute() else ROOT / args.dir
    build = ROOT / '.build'
    if target != build and build not in target.parents:
        print(f'refusing to prune outside .build: {target}', file=sys.stderr)
        return 1
    if not target.is_dir():
        print(f'no such directory: {target}', file=sys.stderr)
        return 1

    freed = removed = kept_small = 0
    for path in sorted(target.rglob('*'), key=lambda p: len(p.parts), reverse=True):
        if not is_bulk(path) or not path.exists():
            continue
        try:
            size = measure(path)
        except OSError:
            continue
        if size < args.keep_bytes:
            kept_small += 1
            continue
        action = 'would remove' if args.dry_run else 'removing'
        print(f'{action} {path.relative_to(ROOT)} ({size / 1048576:.1f} MiB)')
        freed += size
        removed += 1
        if not args.dry_run:
            try:
                remove(path)
            except OSError as error:
                print(f'  ! {error}', file=sys.stderr)

    verb = 'would free' if args.dry_run else 'freed'
    print(f'\n{removed} paths, {verb} {freed / 1073741824:.2f} GiB (kept {kept_small} below {args.keep_bytes} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
