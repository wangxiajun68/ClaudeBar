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
match, which is what the regression test calls. `Tests/product-mark-regressions.py`
renders every family through the real view and measures the PNG, so the *width*
invariant above is enforced against what a user sees, not against these numbers.
"""
import argparse
import sys
from pathlib import Path

from PIL import Image
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Sources/ProviderIcons'
OUTPUT = ROOT / 'Sources/BrandAssets'
#: Cursor's mark joined on 2026-09-27: it is the third *client* the app
#: watches, and it had no artwork at all — every surface drew the
#: `cursorarrow.motionlines` glyph instead, which is a pointer, not the
#: product. LobeHub ships it (verified against the package's own file list),
#: so it takes the same normalisation and the same licence as the other two.
#: ClaudeBar's *own* mark joined the same day, for the fourth family the
#: island names: `UsageSource.thirdParty`, the 第三方 chip that had text and no
#: artwork. It is not a LobeHub asset and not a third party's brand, so it is
#: the app icon (`Sources/AppIcon-1024.png`) trimmed to its own sky — see
#: `Tools/make-claudebar-mark.py`, which derives both variants from that one
#: source and runs before this normalisation, the same way the LobeHub files
#: are fetched before it.
MARKS = ('anthropic', 'openai', 'cursor', 'claudebar')
VARIANTS = ('light', 'dark')

#: Fraction of the square canvas the ink spans, per axis.
#:
#: 0.90, not 1.0: a mark that touches its own canvas edge has no antialiasing
#: room and clips against the well's inside corner on the small tiles, and the
#: tile already insets the artwork (17% of the side), so 0.90 lands the ink at
#: 0.90 x 0.66 = ~60% of the *well* at every size — wide enough to read at 13pt,
#: clear of the corner radius (14% of the side) at the diagonal.
#:
#: **Measured on the width, not on a shared side.** The first version reserved
#: one *longest* side, on the reasoning that a shared side stops a wide mark and
#: a square one reading different sizes. That is true for the two marks it was
#: written for (Anthropic is 1.45x wider than tall, OpenAI is square, so both
#: end up 0.90 wide) and false for Cursor, whose cube is 0.88x — *taller* than
#: it is wide. Reserving a side put Cursor's ink at 0.79 wide against its
#: neighbours' 0.90, i.e. 52% of the tile, and
#: `Tests/product-mark-regressions.py` caught it as a real mismatch rather than a
#: rounding artefact: a Cursor chip beside a CC chip was 12% smaller.
#:
#: The invariant that matters is the *width*, because the row is horizontal:
#: chips sit side by side, so what a reader compares is how wide each mark
#: stands. One factor for both axes (the artwork keeps its own aspect ratio — a
#: cube must stay a cube) sized so the width lands at `KEEP`.
#:
#: With one shared factor there are two ways a mark can be drawn, and the tile
#: only has 0.90 of its side to spend on ink:
#:
#: - `width >= height` (the common case): the factor is `KEEP / width`, so the
#:   ink is exactly `KEEP` wide and shorter than that.
#: - `height > width`: the same factor puts the ink `KEEP` wide and *taller* than
#:   `KEEP`. `MAX_HEIGHT` bounds that height, and it is deliberately looser than
#:   `KEEP` — a portrait mark is allowed to use more of the tile vertically than
#:   the width budget would give it, because the alternative (scaling by the
#:   height, i.e. the old shared-side rule) made Cursor's cube 12 % narrower than
#:   the CC mark beside it. At 1.0 — the tile itself — Cursor's 0.877 aspect
#:   lands the ink 0.90 wide and *1.00 tall*, i.e. the full canvas on its own
#:   axis, and the row reads as one size.
#:
#: Only a mark past `KEEP / MAX_HEIGHT` in aspect (0.90 — a tall wordmark, say)
#: reaches the clamp, and it trades a little width for the room to be drawn at
#: all. Measured on the three shipped marks, none reaches it and all three stand
#: `KEEP` wide.
KEEP = 0.90
#: The tallest ink, as a fraction of the canvas. See the note above.
MAX_HEIGHT = 1.0
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
    # One factor for both axes — the mark keeps its own aspect ratio — sized so
    # the *width* lands at KEEP. Only a mark whose height would then exceed
    # MAX_HEIGHT trades width for room to be drawn at all; see that constant.
    scale = (SIZE * KEEP) / tight.width
    if tight.height * scale > SIZE * MAX_HEIGHT:
        scale = (SIZE * MAX_HEIGHT) / tight.height
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
            expected.save(target, optimize=True, compress_level=9)
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
