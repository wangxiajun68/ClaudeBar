#!/usr/bin/env python3
"""Both committed `.icns` files must already be at their minimal lossless form.

`Tools/recompress-icon.py` re-encodes every embedded PNG and only writes when
the pixels come back identical, so "already minimal" is a fact it can prove —
but until now nothing invoked it: the docstring and `docs/technical/09-file-index.md`
both claimed the test suite ran `--check`, and no suite did. The dev icon had
drifted to 336,336 B of untouched savings (it ships in every dev bundle and in
the app zip, where deflate cannot help — the members are already deflated).

This suite runs the tool's real `--check` path against both icons, and proves
the gate discriminates: a temp copy with one member re-inflated must fail and
must be left untouched. In-process, no writes to the repo, no app launch.
"""
from pathlib import Path
import importlib.util
import io
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('recompress_icon',
                                              root / 'Tools/recompress-icon.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

from PIL import Image  # noqa: E402  (after the tool, which the suite drives)


def check(path):
    """`main()` as the command line would call it. Returns the exit status."""
    argv = sys.argv
    sys.argv = ['recompress-icon.py', '--check', str(path)]
    try:
        return tool.main()
    finally:
        sys.argv = argv


for icon in (root / 'Sources/AppIcon.icns', root / 'Sources/AppIcon-Dev.icns'):
    status = check(icon)
    rel = icon.relative_to(root)
    assert status == 0, (
        f'{rel} is not minimal — run python3 Tools/recompress-icon.py {rel}')

# The gate has to be able to say "no": re-inflate one member of a temp copy and
# `--check` must reject it, without touching the file it was pointed at.
with tempfile.TemporaryDirectory(prefix='icon-minimal-') as tmp:
    source = (root / 'Sources/AppIcon.icns').read_bytes()
    elements = bytearray()
    inflated = False
    for kind, body in tool.members(source):
        if not inflated and body[:4] == b'\x89PNG':
            image = Image.open(io.BytesIO(body))
            image.load()
            buffer = io.BytesIO()
            image.save(buffer, 'PNG', compress_level=0)
            body = buffer.getvalue()
            inflated = True
        elements += tool.encode_element(kind, body)
    assert inflated, 'the fixture found no PNG member to re-inflate'
    fixture = Path(tmp) / 'inflated.icns'
    fixture.write_bytes(tool.container(bytes(elements)))
    before = fixture.read_bytes()
    status = check(fixture)
    assert status == 1, f'a re-inflated icon must fail --check, got {status}'
    assert fixture.read_bytes() == before, '--check must never write'

print('PASS: both committed icons are minimal; --check rejects a re-inflated copy without writing')
