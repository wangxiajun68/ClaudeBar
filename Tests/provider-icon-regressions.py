#!/usr/bin/env python3
"""Every bundled brand mark must be legible on the icon well it is drawn in.

`ProviderIdentityMark` paints a bundled PNG on `Theme.bgSecondary`, picking the
`-light` or `-dark` asset from `Theme.isDark`. A brand whose own artwork is
white (Kimi's `-color` variant is pure white on 23% of its canvas) therefore
renders as a blank tile in light mode with no error anywhere: the file exists,
decodes, and draws. Contrast is the only thing that catches it, so measure it.

Parses the PNGs directly (palette + alpha — the one ICO is read through Pillow)
so no bundle or app launch is needed.
"""
from pathlib import Path
import struct
import zlib

# Pillow (pinned in Tests/requirements.txt) is used only for the ICO frame — an
# ICO is a container of BMP/PNG frames behind somewhat involved directory
# entries, and hand-rolling that reader the way `_read_png` does is a parser
# this suite would then own. Everything else stays in `_read_png` so the PNG
# path keeps needing nothing but the stdlib.
from PIL import Image

root = Path(__file__).resolve().parents[1]
icons = root / 'Sources/ProviderIcons'

# Theme.bgSecondary for both themes; keep in sync with Theme.swift.
WELLS = {'light': (0xF7, 0xFA, 0xFC), 'dark': (0x1E, 0x22, 0x28)}
MIN_CONTRAST = 3.0


def _read_png(path):
    """Return (width, height, [(r, g, b, a)], indices) for an 8-bit PNG."""
    data = path.read_bytes()
    pos, idat, palette, trns = 8, b'', None, None
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b'IHDR':
            width, height, depth, color_type = struct.unpack('>IIBB', chunk[:10])
            if depth != 8:
                raise ValueError(f'{path.name}: unsupported bit depth {depth}')
        elif kind == b'PLTE':
            palette = chunk
        elif kind == b'tRNS':
            trns = chunk
        elif kind == b'IDAT':
            idat += chunk
        elif kind == b'IEND':
            break
    if palette is None and color_type != 6:
        raise ValueError(f'{path.name}: only palette or RGBA PNGs are supported')
    raw = zlib.decompress(idat)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    stride = width * channels
    out, prev, p = bytearray(), bytearray(stride), 0
    for _ in range(height):
        filter_type = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = prev[x]
            c = prev[x - channels] if x >= channels else 0
            if filter_type == 1:
                line[x] = (line[x] + a) & 255
            elif filter_type == 2:
                line[x] = (line[x] + b) & 255
            elif filter_type == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif filter_type == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out += line
        prev = line
    if color_type == 6:
        # True-colour with alpha: the pixel bytes are the samples, so there is no
        # palette to expand. It carries an entry per pixel, which is what the
        # palette arm below produces by indexing — same shape, no lookup.
        #
        # This arm exists for the ClaudeBar mark. Every LobeHub file is a palette
        # PNG, so the reader only ever had to handle those; the app's own mark is
        # authored as flat RGBA by `Tools/make-claudebar-mark.py` (one ink plus
        # antialiased alpha cannot be expressed in a palette without going back
        # to the banding the script exists to avoid), and the mark is drawn in
        # the same wells as the others, so it has to clear the same floor.
        entries = [(out[i], out[i + 1], out[i + 2], out[i + 3])
                   for i in range(0, len(out), 4)]
    else:
        entries = [(palette[i * 3], palette[i * 3 + 1], palette[i * 3 + 2],
                    trns[i] if trns and i < len(trns) else 255)
                   for i in range(len(palette) // 3)]
    return width, height, entries, bytes(out)


def _luminance(rgb):
    def channel(v):
        v /= 255.0
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2])


def _contrast(a, b):
    la, lb = _luminance(a), _luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def _ink_mean(path):
    """Mean colour of the opaque pixels — the mark as the user sees it."""
    width, height, entries, indices = _read_png(path)
    tally = [0.0, 0.0, 0.0]
    opaque = 0
    if len(indices) == len(entries) * 4:
        # RGBA samples, one entry per pixel — see `_read_png`.
        for offset in range(0, len(indices), 4):
            r, g, b, a = entries[offset // 4]
            if a > 128:
                tally[0] += r
                tally[1] += g
                tally[2] += b
                opaque += 1
    else:
        for index in indices:
            r, g, b, a = entries[index]
            if a > 128:
                tally[0] += r
                tally[1] += g
                tally[2] += b
                opaque += 1
    if opaque == 0:
        raise AssertionError(f'{path.name} has no opaque pixels')
    return tuple(v / opaque for v in tally), opaque / (width * height)


def _ink_mean_ico(path):
    """Mean opaque-pixel colour of an ICO, using its largest frame. An ICO has
    no `-light`/`-dark` variants and no fixed frame size, so the rule is "the
    biggest frame the asset carries" — the one `NSImage` picks when the mark is
    drawn at 14–36pt. Returns (ink, coverage), the same shape `_ink_mean` has."""
    image = Image.open(path)
    width, height = max(image.ico.sizes(), key=lambda size: size[0] * size[1])
    frame = image.ico.getimage((width, height)).convert('RGBA')
    tally = [0.0, 0.0, 0.0]
    opaque = 0
    for r, g, b, a in frame.getdata():
        if a > 128:
            tally[0] += r
            tally[1] += g
            tally[2] += b
            opaque += 1
    if opaque == 0:
        raise AssertionError(f'{path.name} has no opaque pixels')
    return tuple(v / opaque for v in tally), opaque / (width * height)


def main():
    # Every bundled mark, keyed by the stem a catalog entry names. The suffix
    # split keeps `foo-light.png` and `foo-dark.png` as one mark (the pair is
    # checked below); an `.ico` is its own mark with no variants, which is the
    # one the old `*-light.png` glob missed entirely — LiteLLM's asset ships
    # only as an ICO and is drawn in the same well as the PNGs.
    #
    # The one recorded exception is LiteLLM: the mark is the vendor's own
    # favicon and its mid-grey ink measures 2.86–2.97:1 across the frames
    # (marginally under the floor), so redrawing or inverting it would stop it
    # being the brand. It is accepted only down to `ACCEPTED_BELOW_FLOOR` —
    # a replacement that measured white-on-light (1.00:1) is a blank tile and
    # must still fail, or "accepted exception" would just mean "unmeasured".
    # The assets' README carries the same note, so widening this band is a
    # deliberate, visible edit rather than something a looser threshold grants.
    ACCEPTED_BELOW_FLOOR = {'litellm': 2.8}
    marks = sorted({p.stem.rsplit('-', 1)[0] if p.suffix == '.png' else p.stem
                    for p in icons.iterdir() if p.suffix in ('.png', '.ico')})
    assert marks, 'no bundled marks found'

    def floor_for(icon):
        return ACCEPTED_BELOW_FLOOR.get(icon, MIN_CONTRAST)

    results, failures = [], []
    for icon in marks:
        ico = icons / f'{icon}.ico'
        if ico.exists():
            ink, coverage = _ink_mean_ico(ico)
            ratio = _contrast(ink, WELLS['light'])
            results.append((ratio, icon, 'ico', coverage))
            if ratio < floor_for(icon):
                failures.append(f'{icon}.ico: contrast {ratio:.2f}:1 '
                                f'(ink rgb{tuple(round(v) for v in ink)}, coverage {coverage:.1%})')
            continue
        for variant, well in WELLS.items():
            path = icons / f'{icon}-{variant}.png'
            if not path.exists():
                failures.append(f'{icon}: missing {variant} variant ({path.name})')
                continue
            ink, coverage = _ink_mean(path)
            ratio = _contrast(ink, well)
            results.append((ratio, icon, variant, coverage))
            if ratio < floor_for(icon):
                failures.append(f'{icon}-{variant}: contrast {ratio:.2f}:1 '
                                f'(ink rgb{tuple(round(v) for v in ink)}, coverage {coverage:.1%})')
    assert not failures, (
        'these marks would read as blank tiles on Theme.bgSecondary:\n  ' + '\n  '.join(failures))
    results.sort()
    accepted = sorted(name for name in ACCEPTED_BELOW_FLOOR
                      if (icons / f'{name}.ico').exists()
                      or any((icons / f'{name}-{variant}.png').exists() for variant in WELLS))
    exception_note = (f' ({", ".join(accepted)} accepted down to '
                      + ', '.join(f'{ACCEPTED_BELOW_FLOOR[name]:g}:1' for name in accepted) + ')'
                      ) if accepted else ''
    print(f'PASS: {len(results)} marks clear {MIN_CONTRAST}:1 on their themed icon well; '
          f'lowest {results[0][1]}-{results[0][2]} at {results[0][0]:.2f}:1{exception_note}')


if __name__ == '__main__':
    main()
