#!/usr/bin/env python3
"""Derive the ClaudeBar family's white/black marks from the app icon.

The island's usage legend and the provider tallies name four sources: CC,
Codex, Cursor, and **第三方** — the third-party traffic the app proxies. The
first three have brand artwork; the fourth is not a brand, it is *this app*, so
its mark is the app's own icon: the three rings the Dock, the About box and the
menu-bar extra already show.

Deriving it here rather than shipping a fourth pair by hand is the same rule the
generator follows for the other three — the artwork exists, and a hand-drawn
copy of it drifts. But `AppIcon-1024.png` is not shaped like a LobeHub mark, and
three things have to happen before it can stand in the same row:

1. **The ice backdrop has to go.** The icon is a rounded white plate on a square
   sheet of cracked ice that runs to the canvas edge. Left in, the sky would
   draw a *tile inside the tile* — `ProductBrandMark.well` already paints one —
   and on the island, where the mark draws with `well: false` on a black card,
   it would be the very white square the user reported twice.

2. **It has to be a supplied shape, not a trace.** The rings are glass: a lit
   rim, a shaded inner wall, a nearly transparent bore. Thresholding their
   luminance — the obvious approach — keeps the rim and loses the bore, which is
   why a first attempt derived an alpha with `0` opaque pixels. The shape here is
   therefore *authored*: the three-ring arrangement is drawn from the icon's own
   measured layout (see `RINGS`), which is what lets
   `Tests/product-mark-regressions.py` pin it as data. The **plate** is the one
   part taken from the icon itself — its rounded-square silhouette.

3. **It has to read in both inks.** LobeHub ships `-dark` (white ink, for a dark
   page) and `-light` (black ink, for a light page). A two-tone mark would
   survive only one of those, so each variant is a single flat ink and the shape
   carries the whole identity. The rings and bar are punched *out of* the plate,
   the way the icon reads at icon sizes: a white plate with the rings knocked
   out of it.

Run before `Tools/gen-brand-marks.py`, which trims and re-scales the pair like
every other source:

    python3 Tools/make-claudebar-mark.py [--check]
"""
import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Sources/AppIcon-1024.png'
OUTPUT = ROOT / 'Sources/ProviderIcons'

#: The mark is authored with vectors at `SIZE * SS` and box-filtered down to
#: `SIZE`, so a 4pt hairline on a 13pt tile still lands on clean edges.
SIZE = 512
SS = 4

#: The plate, as fractions of the canvas. Deliberately not the whole canvas —
#: `Tools/gen-brand-marks.py` crops to the ink and then reserves `KEEP` (0.90) of
#: its own square, so a plate that filled this canvas would land at 0.90 of the
#: tile and lose the antialiasing room `KEEP` exists to leave.
PLATE = 0.86
PLATE_RADIUS = 0.235
#: Ring bore, as a fraction of the ring's outer diameter: the punch radius is
#: `0.34` of it. `0` would draw filled discs; near `0.5` would draw hairlines.
RING_BORE = 0.34

#: The three rings, from the icon's own layout — (cx, cy, diameter) fractions.
RINGS = (
    (0.300, 0.600, 0.480),   # Claude blue, lower-left
    (0.672, 0.292, 0.380),   # Codex violet, upper-right
    (0.712, 0.712, 0.292),   # success green, lower-right
)
#: The progress bar under the rings, as (cx, cy, width, height) fractions, and
#: the lit bead at its left end, as (cx, cy, diameter).
BAR = (0.300, 0.868, 0.470, 0.052)
BEAD = (0.075, 0.868, 0.050)


def plate_alpha(px: int) -> np.ndarray:
    """The icon's own plate: an antialiased rounded square, as coverage."""
    rows, cols = np.mgrid[0:px, 0:px]
    cx = cols - (px - 1) / 2.0
    cy = rows - (px - 1) / 2.0
    half = PLATE * px / 2.0
    r = PLATE_RADIUS * px
    dx = np.maximum(np.abs(cx) - (half - r), 0.0)
    dy = np.maximum(np.abs(cy) - (half - r), 0.0)
    distance = np.sqrt(dx * dx + dy * dy) - r
    return np.clip(0.5 - distance, 0.0, 1.0)


def punch_mask(px: int) -> np.ndarray:
    """The rings, bar and bead as a coverage mask to punch out of the plate."""
    mask = Image.new('L', (px, px), 0)
    draw = ImageDraw.Draw(mask)
    for cx, cy, diameter in RINGS:
        outer = diameter * px / 2.0
        width = max(1, round(outer * (1.0 - RING_BORE)))
        box = (cx * px - outer, cy * px - outer, cx * px + outer, cy * px + outer)
        draw.ellipse(box, outline=255, width=width)
    half_w = BAR[2] * px / 2.0
    half_h = BAR[3] * px / 2.0
    draw.rounded_rectangle((BAR[0] * px - half_w, BAR[1] * px - half_h,
                            BAR[0] * px + half_w, BAR[1] * px + half_h),
                           radius=half_h, fill=255)
    r_bead = BEAD[2] * px / 2.0
    draw.ellipse((BEAD[0] * px - r_bead, BEAD[1] * px - r_bead,
                  BEAD[0] * px + r_bead, BEAD[1] * px + r_bead), fill=255)
    return np.asarray(mask, dtype=np.float64) / 255.0


def coverage() -> np.ndarray:
    """Final alpha: the plate with the authored rings knocked out of it."""
    px = SIZE * SS
    plate = plate_alpha(px)
    punch = np.asarray(
        Image.fromarray((punch_mask(px) * 255).astype(np.uint8))
             .filter(ImageFilter.GaussianBlur(SS * 0.35)),
        dtype=np.float64) / 255.0
    # `x - punch * x` keeps the plate's own edge: the punch can only remove
    # coverage where the plate already had some.
    alpha = np.clip(plate - punch * plate, 0.0, 1.0)
    return np.asarray(
        Image.fromarray((alpha * 255).astype(np.uint8)).resize((SIZE, SIZE), Image.LANCZOS),
        dtype=np.float64) / 255.0


def encode(alpha: np.ndarray, ink: int) -> Image.Image:
    out = np.zeros((alpha.shape[0], alpha.shape[1], 4), dtype=np.uint8)
    out[:, :, :3] = ink
    out[:, :, 3] = np.round(np.clip(alpha, 0.0, 1.0) * 255).astype(np.uint8)
    return Image.fromarray(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()

    if not SOURCE.is_file():
        print(f'missing {SOURCE.relative_to(ROOT)}', file=sys.stderr)
        return 1

    OUTPUT.mkdir(parents=True, exist_ok=True)
    alpha = coverage()
    ink_share = float((alpha > 0.5).mean())
    if ink_share < 0.10:
        print(f'the derived mark covers only {ink_share:.0%} of its canvas — '
              'check the plate and ring geometry', file=sys.stderr)
        return 1

    stale = []
    for variant, ink in (('dark', 255), ('light', 0)):
        target = OUTPUT / f'claudebar-{variant}.png'
        # `-dark` is the W H I T E ink: LobeHub names the pair for the page it is
        # drawn on, not for its own luminance. See `ProductBrandMark.dark`.
        expected = encode(alpha, ink)
        if args.check:
            if not target.is_file():
                stale.append(f'{target.name}: not generated')
                continue
            committed = Image.open(target).convert('RGBA')
            if committed.size != expected.size or \
                    np.abs(np.array(committed, dtype=int) -
                           np.array(expected, dtype=int)).max() > 2:
                stale.append(f'{target.name}: does not match AppIcon-1024.png')
            continue
        expected.save(target, optimize=True, compress_level=9)
        print(f'{target.relative_to(ROOT)}  ink {ink_share:.0%} of the canvas '
              f'({int((alpha > 0.5).sum())}px of {alpha.size})')

    if args.check and stale:
        print('the ClaudeBar mark is stale — run Tools/make-claudebar-mark.py:\n  '
              + '\n  '.join(stale), file=sys.stderr)
        return 1
    if args.check:
        print('PASS: the ClaudeBar mark matches the app icon')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
