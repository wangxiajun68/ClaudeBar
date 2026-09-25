#!/usr/bin/env python3
"""Per-core / per-sub-unit machine marks, and the removed tile-header ring.

Three behaviours are locked in, each one line away from silently regressing:

1. `HardwareIllustration(kind: .cpu, cells:)` draws **one readable cell per
   reported core** — 12 cores, 12 lit cells — and the lit cells are the busy
   ones, in core order. An idle core keeps a pale socket, so the die still reads
   as twelve cores at rest.
2. `HardwareIllustration(kind: .gpu, cells:)` draws one column per published
   sub-unit, each filled to that unit's own reading.
3. No `LoadRing` wraps a tile's header glyph. The ~96° arc at 22–28pt read as a
   spinner ("waiting"), and it duplicated the figure printed below it. The view,
   its `DecorativeMotion` kind and the whole rate machinery are gone with it.

The check is a **measurement of the rendered pixels**, not a string match: the
source could keep a `cells` parameter and still draw one plate. Two earlier
versions of this file "passed" by reading `NSBitmapImageRep.colorAt` and by
sampling single points between cells, both of which reported the same value for
a lit and an idle core. So: render to PNG in Swift, decode in Python, and take
the *median* over each cell's own rect.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
shared = root / 'Sources/ClaudeBar/Views/Shared'

illustration = (shared / 'HardwareIllustration.swift').read_text()
strip = (shared / 'ResourceStrip.swift').read_text()
kpi = (shared / 'MachineKpiStrip.swift').read_text()


def call_sites(text):
    """`LoadRing(` call syntax only — explanatory comments name the view."""
    return re.findall(r'(?<![A-Za-z.])LoadRing\(', text)


# --- The ring is gone from both header call sites ---------------------------
meter = strip[strip.index('private func meter('):strip.index('private func toggleFan(')]
assert not call_sites(meter), 'ResourceStrip.meter must not wrap its glyph in a LoadRing'
assert 'InstrumentBadge(kind: InstrumentGlyph.kind(for: icon)' in meter
assert 'ZStack' not in meter.split('HStack(spacing: 6)')[1].split('Text(label)')[0], \
    'the glyph must stand alone, not sit in a ZStack behind an ornament'

kpi_cell = kpi[kpi.index('private struct MachineKpiButton'):]
assert not call_sites(kpi_cell), 'MachineKpiButton must not wrap its glyph in a LoadRing'
# The earbud cell had one too — same spinner, same duplication.
assert not call_sites(kpi[kpi.index('private var audioKpi'):kpi.index('private struct HeadsetBadge')]), \
    'the popup earbud cell must not wrap its glyph in a LoadRing'

# --- The marks are fed real per-unit readings -------------------------------
for needle in ['cells: sampler.host.gpuRenderers.map { $0 / 100 }',
               'cells: sampler.host.coreLoad',
               'wells: sampler.host.memoryWells',
               'wells: sampler.host.diskWells']:
    assert needle in strip, f'ResourceStrip must pass {needle!r} to the mark'

# --- `LoadRing` is gone entirely -------------------------------------------
# The view, the `DecorativeMotion.loadRing` case, the rate machinery and the
# thickness constant that only existed to keep the track and the arc in step.
# A reappearing call site means the spinner reading came back with it.
all_shared = list(shared.glob('*.swift'))
ring_uses = [f.name for f in all_shared if re.search(r'(?<![A-Za-z.])LoadRing\(', f.read_text())]
assert not ring_uses, f'LoadRing call sites must be gone, found in {ring_uses}'
assert not any('loadRing' in f.read_text() for f in all_shared), \
    'the loadRing decoration kind must be gone with its only caller'

# --- Render the marks -------------------------------------------------------
probe = (root / 'Tests/fixtures/machine-mark-probe.swift').read_text()
token = '<<<HARDWARE_ILLUSTRATION>>>'
assert token in probe, 'the probe template lost its substitution slot'
swift = probe.replace(token, illustration)

with tempfile.TemporaryDirectory(prefix='claudebar-machine-mark-') as folder:
    folder = Path(folder)
    source = folder / 'Probe.swift'
    source.write_text(swift)
    binary = folder / 'probe'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    shots = folder / 'shots'
    subprocess.run([str(binary), str(shots)], check=True)

    from PIL import Image
    import numpy as np

    # The probe renders at 8×; the drawing letterboxes a 100×76 grid into the
    # 112×80 frame. Grid units → pixels:
    SCALE = 8.0
    FRAME_W, FRAME_H = 112.0, 80.0
    GRID_W, GRID_H = 100.0, 76.0
    fit = min(FRAME_W / GRID_W, FRAME_H / GRID_H)
    off_x, off_y = (FRAME_W - GRID_W * fit) / 2, (FRAME_H - GRID_H * fit) / 2

    def rect_px(rect):
        x, y, w, h = rect
        return ((off_x + x * fit) * SCALE, (off_y + y * fit) * SCALE,
                (off_x + (x + w) * fit) * SCALE, (off_y + (y + h) * fit) * SCALE)

    def ink(image, rect, inset=0.3):
        """Median luminance (0…255) inside a grid-space rect.

        The median over an inset region, not a point sample: a single point can
        land on the 1.2-unit gap between two cells and report the background —
        which is exactly how an earlier version of this check measured a mark
        that drew nothing and called it a pass.
        """
        x0, y0, x1, y1 = rect_px(rect)
        dx, dy = (x1 - x0) * inset, (y1 - y0) * inset
        sub = image[int(y0 + dy):int(y1 - dy) + 1, int(x0 + dx):int(x1 - dx) + 1]
        assert sub.size, f'grid rect {rect} fell outside the raster'
        return float(np.median(sub))

    def load(name):
        return np.array(Image.open(shots / f'{name}.png').convert('L')).astype(float)

    def core_cells(count):
        """The geometry `HardwareIllustration.drawCoreGrid` lays cells out with.

        Mirrored here on purpose: the check measures the *drawing*, so it has to
        know where the drawing puts things. If that geometry moves, these
        measurements stop agreeing with it and the check fails loudly instead of
        quietly measuring the gaps between cells.
        """
        die = (36, 20, 28, 24)
        columns = max(1, round(count ** 0.5))
        rows = -(-count // columns)
        gap = 1.2
        cw = (die[2] - gap * (columns - 1)) / columns
        ch = (die[3] - gap * (rows - 1)) / rows
        cells = []
        for index in range(count):
            column, row = index % columns, index // columns
            in_row = min(columns, count - row * columns)
            row_w = in_row * cw + gap * (in_row - 1)
            cells.append((die[0] + (die[2] - row_w) / 2 + column * (cw + gap),
                          die[1] + row * (ch + gap), cw, ch))
        return cells

    # The two fills the mark uses are opaque and far apart (busy ≈ 120/255 on
    # the ice canvas, idle socket ≈ 225). A mark that reverted to two
    # translucent tints over the die's gradient plate put them within ~6/255 and
    # lands on one side of this threshold whatever the load says.
    LIT = 170

    def cpu_readings(name):
        image = load(name)
        count = {'cpu-12': 12, 'cpu-10': 10, 'cpu-8': 8, 'cpu-idle': 12,
                 'cpu-half': 12, 'cpu-30': 12, 'cpu-aggregate': 12}[name]
        return [ink(image, cell) for cell in core_cells(count)]

    def lit_count(name):
        return sum(1 for value in cpu_readings(name) if value < LIT)

    # 1. One lit cell per core — the count, and therefore the *mark*, scales
    #    with the core count rather than with a single brightness.
    assert lit_count('cpu-12') == 12, f"12 cores → {lit_count('cpu-12')} lit cells"
    assert lit_count('cpu-10') == 10, f"10 cores → {lit_count('cpu-10')} lit cells"
    assert lit_count('cpu-8') == 8, f"8 cores → {lit_count('cpu-8')} lit cells"

    # 2. An idle core is a socket, not ink: twelve cores stay countable at rest.
    idle = cpu_readings('cpu-idle')
    assert all(value > 200 for value in idle), \
        f'an idle core must be a pale socket, not ink: {[int(v) for v in idle]}'
    assert lit_count('cpu-idle') == 0

    # 3. A partial load is a partial die, and the lit cells are the *busy* ones
    #    in core order — the mark is a sum, not a lamp.
    half = cpu_readings('cpu-half')
    assert lit_count('cpu-half') == 6
    assert all(v < LIT for v in half[:6]) and all(v > 200 for v in half[6:]), \
        f'lit cells must be the busy ones, in core order: {[int(v) for v in half]}'

    # 4. Brightness tracks the reading, by a margin a person can see: 30 % of
    #    load lands ~64/255 paler than 95 %, and still well clear of the idle
    #    socket — the three readings are three distinguishable greys.
    at_30, at_95, at_idle = cpu_readings('cpu-30')[0], cpu_readings('cpu-12')[0], cpu_readings('cpu-idle')[0]
    assert at_30 > at_95 + 45, \
        f'a 30 % core must read visibly paler (higher luminance) than a 95 % core ({at_30:.0f} vs {at_95:.0f})'
    assert at_idle > at_30 + 25, \
        f'an idle socket must stay clear of a 30 % core ({at_idle:.0f} vs {at_30:.0f})'

    # 5. No per-core reading → one aggregate plate, and it covers the die.
    aggregate = load('cpu-aggregate')
    die = (36, 20, 28, 24)
    plate = ink(aggregate, (die[0] + 5, die[1] + 5, die[2] - 10, die[3] - 10))
    assert plate < 200, f'the aggregate fallback must draw a lit plate, got {plate:.0f}'

    # 6. GPU: three sub-units → three columns, each filled from the baseline to
    #    its own reading. The tall bar is the device and the short one the
    #    tiler; a single repeated bar would make them equal.
    slot = (18, 24, 38, 28)
    gap = 2.5
    column_w = (slot[2] - gap * 2) / 3

    def gpu_column(image, index, band_y, band_h):
        x = slot[0] + index * (column_w + gap)
        return ink(image, (x + 2, band_y, column_w - 4, band_h))

    mixed = load('gpu-mixed')
    base_y, base_h = slot[1] + slot[3] - 6, 4
    top_y, top_h = slot[1] + 3, 3
    # Readings 100 % / 50 % / 0 %: every column is filled at its base, and only
    # the full one reaches the top. That is the whole claim — the bars are three
    # readings, not one bar drawn three times.
    # 100 % / 50 % / 0 %: a column is filled from the baseline up to its own
    # reading, so the full one reaches the top, the half one stops in the
    # middle, and the 0 % one keeps only its outline — an empty socket, which
    # says "this unit exists and is idle" rather than "this unit is missing".
    for index, expect in enumerate(('full', 'half', 'empty')):
        base = gpu_column(mixed, index, base_y, base_h)
        top = gpu_column(mixed, index, top_y, top_h)
        if expect == 'empty':
            assert base > 200 and top > 200, \
                f'a 0 % column must be an empty socket ({base:.0f} / {top:.0f})'
            continue
        assert base < LIT, f'the {expect} column must be filled at its base, got {base:.0f}'
        if expect == 'full':
            assert top < LIT, f'the 100 % column must reach the top, got {top:.0f}'
        else:
            assert top > 200, f'the 50 % column must stop short of the top, got {top:.0f}'

    # Full and empty are the extremes of the same shape, so the columns carry
    # the reading rather than a fixed amount of ink.
    full = load('gpu-full')
    empty = load('gpu-empty')
    assert gpu_column(full, 0, top_y, top_h) < LIT < gpu_column(empty, 0, top_y, top_h), \
        'a full sub-unit and an idle one must differ at the top of the column'

    # 7. No published sub-units → one aggregate plate in the slot's middle, not
    #    three empty columns. The plate is inset 6 units, so it is measured at
    #    the slot's centre rather than at a column's top.
    gpu_aggregate = load('gpu-aggregate')
    centre = ink(gpu_aggregate, (slot[0] + 8, slot[1] + 8, slot[2] - 16, slot[3] - 16))
    assert centre < 200, f'the GPU aggregate fallback must draw a lit plate, got {centre:.0f}'

    # 8. The header glyph box must be free of ring ink. A `LoadRing` at 28pt
    #    puts ink in the corners of the glyph's box; this is what "no ring"
    #    looks like as a *measurement* rather than as an absence of source text.
    header = load('header')
    inked_corners = 0
    for ox, oy in ((14, 14), (14 + 27, 14), (14, 14 + 27), (14 + 27, 14 + 27)):
        patch = header[int(oy * SCALE):int((oy + 3) * SCALE), int(ox * SCALE):int((ox + 3) * SCALE)]
        if (patch < 150).mean() > 0.6:
            inked_corners += 1
    assert inked_corners == 0, \
        f'the header glyph box must be free of ring ink at its corners; found {inked_corners}'

print('PASS: CPU mark renders one readable cell per core (12 / 10 / 8, 6-of-12 in core '
      'order, idle cores pale sockets, 30 % visibly paler than 95 %, aggregate fallback); '
      'GPU one column per sub-unit filled by its own reading; no ring behind any tile '
      'glyph and no LoadRing call site left')
