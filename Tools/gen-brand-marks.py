#!/usr/bin/env python3
"""Normalise the CC / Codex brand marks into their tile glyph.

`ProductBrandMark` draws the two client families in a light rounded well, the
way the panel header, the island and the dashboard tiles show them. The LobeHub
PNGs it used to draw raw are *canvas-sized*, not glyph-sized: each one carries
its own margin to the edge of a square 640pt canvas, and the two margins differ.
Measured on the four bundled files, the ink of `anthropic-light` sits at 33.5pt
of a 13pt header tile and `openai-light` at 32.5pt — i.e. both marks were drawn
at ~65% of an already-small tile, which reads as a smudge rather than a brand.

This generator trims each mark to its own ink and writes it back at `KEEP` of a
square canvas, so the mark's size stops depending on whichever margin its source
happened to ship with. It is the same normalisation `Sources/MenuBarIcon.png`
already had applied by hand — glyph at ~70% of the canvas — moved into a script
so a new asset cannot quietly reintroduce the discrepancy.

Reserving one shared *side* (rather than fitting each mark's own box) is the part
that matters for the UI: Anthropic's mark is nearly twice as wide as it is tall
and OpenAI's is square, so fitting each to 80% of the canvas would stand the
Anthropic "A\\" 80% wide and the OpenAI knot 80% tall and *smaller*, and a CC
chip beside a Codex chip in one row would show two different sizes.

    python3 Tools/gen-brand-marks.py [--check]

`--check` re-runs the normalisation and fails if a committed asset does not
match, which is what the regression test calls.
"""
import argparse
import sys
from pathlib import Path

from PIL import Image
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Sources/ProviderIcons'
OUTPUT = ROOT / 'Sources/BrandAssets'
MARKS = ('anthropic', 'openai')
VARIANTS = ('light', 'dark')

#: Fraction of the square canvas the ink spans.
#:
#: 0.90, not 1.0: a mark that touches its own canvas edge has no antialiasing
#: room and clips against the well's inside corner on the small tiles, and the
#: tile already insets the artwork (17% of the side), so 0.90 lands the ink at
#: 0.90 x 0.66 = ~60% of the *well* at every size — wide enough to read at 13pt,
#: clear of the corner radius (14% of the side) at the diagonal.
KEEP = 0.90
#: Big enough for the 38pt dashboard tile at 2x, with room to spare.
SIZE = 1024


def normalise(image: Image.Image) -> Image.Image:
    """Trim to the mark's own ink and place it at `KEEP` of a square canvas."""
    alpha = np.array(image.convert('RGBA'))[:, :, 3]
    ys, xs = np.where(alpha > 8)
    if not xs.size:
        raise ValueError('mark has no visible pixels')
    tight = image.convert('RGBA').crop((int(xs.min()), int(ys.min()),
                                        int(xs.max()) + 1, int(ys.max()) + 1))
    scale = (SIZE * KEEP) / max(tight.size)
    resized = tight.resize((max(1, round(tight.width * scale)),
                            max(1, round(tight.height * scale))), Image.LANCZOS)
    canvas = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    canvas.paste(resized, ((SIZE - resized.width) // 2, (SIZE - resized.height) // 2))
    return canvas


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true',
                        help='verify the committed assets instead of writing them')
    args = parser.parse_args()

    OUTPUT.mkdir(parents=True, exist_ok=True)
    stale = []
    for name in MARKS:
        for variant in VARIANTS:
            source = SOURCE / f'{name}-{variant}.png'
            if not source.is_file():
                print(f'missing source {source.relative_to(ROOT)}', file=sys.stderr)
                return 1
            expected = normalise(Image.open(source))
            target = OUTPUT / f'{name}-{variant}.png'
            if args.check:
                if not target.is_file():
                    stale.append(f'{target.name}: not generated')
                    continue
                committed = Image.open(target).convert('RGBA')
                if committed.size != expected.size or \
                        np.abs(np.array(committed, dtype=int) -
                               np.array(expected, dtype=int)).max() > 2:
                    stale.append(f'{target.name}: does not match {source.name}')
                continue
            expected.save(target)
            print(f'{target.relative_to(ROOT)}  '
                  f'(ink {expected.getbbox()[2] - expected.getbbox()[0]}x'
                  f'{expected.getbbox()[3] - expected.getbbox()[1]} of {SIZE})')

    if args.check:
        if stale:
            print('brand marks are stale — run Tools/gen-brand-marks.py:\n  ' +
                  '\n  '.join(stale), file=sys.stderr)
            return 1
        print(f'PASS: {len(MARKS) * len(VARIANTS)} brand marks match their sources')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
