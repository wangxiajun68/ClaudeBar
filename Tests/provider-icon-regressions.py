#!/usr/bin/env python3
"""Every bundled brand mark must be legible on the icon well it is drawn in.

`ProviderIdentityMark` paints a bundled PNG on `Theme.bgSecondary`, picking the
`-light` or `-dark` asset from `Theme.isDark`. A brand whose own artwork is
white (Kimi's `-color` variant is pure white on 23% of its canvas) therefore
renders as a blank tile in light mode with no error anywhere: the file exists,
decodes, and draws. Contrast is the only thing that catches it, so measure it.

Parses the PNGs directly (palette + alpha) so no bundle or app launch is needed.
"""
from pathlib import Path
import struct
import zlib

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
    if palette is None:
        raise ValueError(f'{path.name}: only palette PNGs are supported')
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


def main():
    # Only icons tied to a catalog entry that actually ships both variants.
    marks = sorted({p.name.rsplit('-', 1)[0] for p in icons.glob('*-light.png')})
    assert marks, 'no -light assets found'
    results, failures = [], []
    for icon in marks:
        for variant, well in WELLS.items():
            path = icons / f'{icon}-{variant}.png'
            if not path.exists():
                failures.append(f'{icon}: missing {variant} variant ({path.name})')
                continue
            ink, coverage = _ink_mean(path)
            ratio = _contrast(ink, well)
            results.append((ratio, icon, variant, coverage))
            if ratio < MIN_CONTRAST:
                failures.append(f'{icon}-{variant}: contrast {ratio:.2f}:1 '
                                f'(ink rgb{tuple(round(v) for v in ink)}, coverage {coverage:.1%})')
    assert not failures, (
        'these marks would read as blank tiles on Theme.bgSecondary:\n  ' + '\n  '.join(failures))
    results.sort()
    print(f'PASS: {len(results)} marks clear {MIN_CONTRAST}:1 on their themed icon well; '
          f'lowest {results[0][1]}-{results[0][2]} at {results[0][0]:.2f}:1')


if __name__ == '__main__':
    main()
