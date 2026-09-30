#!/usr/bin/env python3
"""
Key the island previews to transparent silhouettes.

`Tools/render-island-preview.py` snapshots the island on a flat light plate,
because that is what a preview wants to show. The film needs the island alone,
so it can sit on its own canvas and hang from a notch drawn at the film's scale.

    python3 Tools/promo/key-island.py

Reads  .build/island-preview/{collapsed,alert,expanded}-{light,dark}.png
Writes .build/promo/assets/island-<state>-<theme>.png

The plate is near-white and the island is near-black, so the key is a luminance
threshold with a soft edge: the anti-aliased rim of the silhouette keeps its
alpha instead of turning into a hard 1-bit cut, which is what stops the island
from showing a light fringe once it is composited over a different background.
"""
from pathlib import Path
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover - environment guard
    sys.exit('Pillow is required: python3 -m pip install Pillow')

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / '.build/island-preview'
OUT = ROOT / '.build/promo/assets'

# The two plates are the app's own canvases: light is `Theme.bgPrimary` (#EEF3F8,
# luminance ~242) and dark is the graphite (#16181C, ~24). The island is black in
# both, so light keys *out* the bright plate and dark keys *out* the dim one —
# the same "keep whatever is not the canvas" rule, read against each background.
PLATES = {
    'light': {'plate': 226, 'full': 214, 'invert': False},
    'dark': {'plate': 15, 'full': 8, 'invert': True},
}


def key(img: 'Image.Image', theme: str) -> 'Image.Image':
    """Alpha from luminance: the canvas goes, the island stays."""
    cfg = PLATES[theme]
    out = Image.new('RGBA', img.size, (0, 0, 0, 0))
    src, dst = img.load(), out.load()
    # Only remove the plate connected to the padded preview's outer corner.
    # Luminance alone deletes white lettering INSIDE the black island as well.
    keep = cfg['full']
    mask = img.convert('L').point(lambda value: 255 if value >= keep else 0)
    if mask.getpixel((0, 0)) != 255:
        raise ValueError('Preview corner is not the plate; background key must be updated')
    ImageDraw.floodfill(mask, (0, 0), 128)
    connected = mask.load()
    for y in range(img.height):
        for x in range(img.width):
            r, g, b, a = src[x, y]
            lum = (r * 299 + g * 587 + b * 114) // 1000
            if connected[x, y] != 128:
                dst[x, y] = (r, g, b, a)
                continue
            if not cfg['invert']:
                # Light: bright plate drops out, dark island stays.
                cut, keep = cfg['plate'], cfg['full']
                if lum <= keep:
                    alpha = 255
                elif lum >= cut:
                    alpha = 0
                else:
                    alpha = int((cut - lum) / (cut - keep) * 255)
            else:
                # Dark: the canvas is *lighter* than the island, so the test
                # flips — anything dimmer than the canvas is the island.
                cut, keep = cfg['plate'], cfg['full']
                if lum <= keep:
                    alpha = 255
                elif lum <= cut:
                    alpha = int(255 - (lum - keep) / (cut - keep) * 90)
                else:
                    alpha = 0
            dst[x, y] = (r, g, b, min(a, alpha))
    return out


def main() -> int:
    if not SRC.is_dir():
        sys.exit(f'{SRC} is missing — run Tools/render-island-preview.py first')
    OUT.mkdir(parents=True, exist_ok=True)
    written = 0
    for state in ('collapsed', 'alert', 'expanded'):
        for theme in ('light', 'dark'):
            src = SRC / f'{state}-{theme}.png'
            if not src.is_file():
                print(f'  ! {src.name} missing — skipping')
                continue
            out = OUT / f'island-{state}-{theme}.png'
            keyed = key(Image.open(src).convert('RGBA'), theme)
            # Trim to the silhouette's real box. The previews carry padding (the
            # island is drawn inside a fixed panel with air around it), and the
            # film positions the island by its own edges — leaving the padding on
            # would offset every composite by those margins.
            box = keyed.getbbox()
            if box is None:
                sys.exit(f'{src.name} keyed to nothing — the plate threshold is wrong')
            keyed = keyed.crop(box)
            keyed.save(out)
            written += 1
            print(f'  {src.name} -> {out.relative_to(ROOT)}  {keyed.size[0]}x{keyed.size[1]}')
    if not written:
        sys.exit('no island previews found — run Tools/render-island-preview.py first')
    print(f'keyed {written} island silhouettes')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
