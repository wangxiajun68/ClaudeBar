#!/usr/bin/env python3
"""Re-encode the embedded PNGs of `Sources/AppIcon.icns`, losslessly.

An `.icns` is a small container of independent PNGs — one per size, each drawn
for a different purpose (16pt up to 512pt@2x) — and the ones in this file were
written by an encoder that left a third of the bytes on the table: the 1024
member alone is 1,177,354 B where the same *pixels* fit in 956,743. That matters
because the icon is shipped twice, once in the bundle and once inside the app
zip, and deflate cannot help with either — the members are already deflated.

Nothing here re-renders or resamples the artwork. Every member is decoded,
re-encoded, decoded again and compared **pixel for pixel** before it is written;
a member that does not come back identical aborts the whole file, so this can
never trade a disk byte for a pixel. It is the same check the regression test
runs, which is why `--check` can be trusted to say "already minimal".

    python3 Tools/recompress-icon.py            # rewrite in place
    python3 Tools/recompress-icon.py --check    # fail if it is not minimal

Run it after replacing the icon with `iconutil` (or with any tool that does not
compress well); the build calls `--check` only in the test suite, not on every
build, because re-encoding is deterministic and there is nothing to recompute.
"""
import argparse
import io
import struct
import sys
from pathlib import Path

from PIL import Image
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
ICNS = ROOT / 'Sources/AppIcon.icns'


def members(data: bytes):
    """Yield `(type, body)` for every chunk in the container.

    The header is an 8-byte magic plus total length; each element is a 4-byte
    type, a big-endian length that **includes** those 8 bytes, and the body.
    """
    offset = 8
    while offset < len(data):
        kind = data[offset:offset + 4]
        length = struct.unpack('>I', data[offset + 4:offset + 8])[0]
        yield kind, data[offset + 8:offset + length]
        offset += length


def encode_element(kind: bytes, body: bytes) -> bytes:
    return kind + struct.pack('>I', len(body) + 8) + body


def container(elements: bytes) -> bytes:
    """The 8-byte file header plus the concatenated elements.

    A container's own length is the **whole file**, so it has to be written after
    the members are known: copying the source's header verbatim leaves it
    announcing the old, larger size, and `iconutil` rejects the file outright
    rather than reading the members it can find.
    """
    return b'icns' + struct.pack('>I', 8 + len(elements)) + elements


def recompress(body: bytes) -> bytes:
    """The same image, fewer bytes, or `body` unchanged for a non-PNG member."""
    if body[:4] != b'\x89PNG':
        return body
    image = Image.open(io.BytesIO(body))
    image.load()
    buffer = io.BytesIO()
    image.save(buffer, 'PNG', optimize=True, compress_level=9)
    return buffer.getvalue()


def identical(a: bytes, b: bytes) -> bool:
    def pixels(data):
        image = Image.open(io.BytesIO(data))
        image.load()
        return np.array(image.convert('RGBA'))

    return pixels(a).shape == pixels(b).shape and np.array_equal(pixels(a), pixels(b))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true',
                        help='report whether the committed icon is already minimal')
    args = parser.parse_args()

    if not ICNS.is_file():
        print(f'missing {ICNS.relative_to(ROOT)}', file=sys.stderr)
        return 1

    source = ICNS.read_bytes()
    elements = bytearray()
    saved = 0
    changed = []
    for kind, body in members(source):
        packed = recompress(body)
        if len(packed) < len(body):
            if not identical(body, packed):
                print(f'{kind.decode("ascii", "replace")}: re-encode changed the '
                      'pixels — refusing to write', file=sys.stderr)
                return 1
            changed.append((kind.decode('ascii', 'replace'), len(body), len(packed)))
            saved += len(body) - len(packed)
        else:
            packed = body
        elements += encode_element(kind, packed)
    out = container(bytes(elements))

    if not changed:
        print(f'PASS: {ICNS.relative_to(ROOT)} is minimal ({len(source):,} B)')
        return 0
    if args.check:
        print(f'{ICNS.relative_to(ROOT)} is not minimal — run '
              'Tools/recompress-icon.py to save '
              f'{saved:,} B:\n  ' +
              '\n  '.join(f'{name}: {before:,} -> {after:,}'
                          for name, before, after in changed), file=sys.stderr)
        return 1

    ICNS.write_bytes(bytes(out))
    print(f'{ICNS.relative_to(ROOT)}: {len(source):,} -> {len(out):,} B '
          f'(saved {saved:,}); ' +
          ', '.join(f'{name} {before:,}->{after:,}'
                    for name, before, after in changed))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
