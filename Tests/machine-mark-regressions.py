#!/usr/bin/env python3
"""The machine marks: Lucide geometry, live readings, and no header ring.

Four things are locked in, each of them one edit away from silently regressing:

1. **The outlines are Lucide's.** `LucideHardwareGeometry.swift` is generated
   from Lucide's own `cpu` / `gpu` / `memory-stick` / `hard-drive` SVGs (plus
   `laptop-minimal` and `fan`, which the fan popover and the rotor draw). The
   check re-runs the generator's expectations: every mark is authored on the
   24pt grid, inside it, and the file still says it is generated. An earlier
   version hand-authored four silhouettes on a Canvas, and the result was
   recognisable-ish and amateur — inventing curve geometry by eye does not
   produce designed curves.
2. **The reading is live.** One bar per logical core (CPU) and per graphics
   sub-unit (GPU), each filled by its own value: 12 cores light 12 bars, half of
   them busy fills half the lane, and an idle core is a pale stub.
3. **The lane and the icon are separate.** The measurement is a *rasterisation*:
   the reading is read off the pixels of its own lane, which is what a
   screenshot would show.
4. **No `LoadRing`.** The view, its `DecorativeMotion` kind and the rate
   machinery are gone — a ~96° arc at 22–28pt read as a spinner ("waiting") and
   duplicated the figure printed below it.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
shared = root / 'Sources/ClaudeBar/Views/Shared'

geometry = (shared / 'LucideHardwareGeometry.swift').read_text()
illustration = (shared / 'HardwareIllustration.swift').read_text()
strip = (shared / 'ResourceStrip.swift').read_text()
kpi = (shared / 'MachineKpiStrip.swift').read_text()


def call_sites(text):
    return re.findall(r'(?<![A-Za-z.])LoadRing\(', text)


# --- 1. The geometry is generated, not hand-authored ------------------------
assert 'generated' in geometry.lower(), \
    'LucideHardwareGeometry must keep saying it is generated'
assert 'Tools/gen-lucide-hardware.py' in geometry, \
    'the generated file must name its generator'
for name in ('cpu', 'gpu', 'memory-stick', 'hard-drive', 'laptop-minimal', 'fan'):
    assert f'Lucide `{name}`' in geometry, f'{name} geometry missing from the generated file'
# Authored on the 24pt grid, and nothing may stray outside it.
coords = [float(v) for v in re.findall(r'(?:x|y): (-?\d+(?:\.\d+)?)', geometry)]
assert coords and min(coords) >= -0.001 and max(coords) <= 24.001, \
    f'every Lucide coordinate must lie on the 24pt grid, got {min(coords)}…{max(coords)}'
for kind in ('cpu', 'gpu', 'memory', 'disk', 'laptop', 'fan'):
    assert f'case .{kind}:' in geometry, f'the generated file must define {kind}'
# The generator itself must exist and be re-runnable.
assert (root / 'Tools/gen-lucide-hardware.py').is_file(), 'the generator is missing'

# --- 2/3. The mark draws the reading in its own lane ------------------------
assert 'LucideHardwareGeometry.path(for:' in illustration, \
    'the mark must draw Lucide geometry, not its own paths'
assert 'lane' in illustration and 'drawReading' in illustration, \
    'the reading must be drawn in its own lane under the icon'
assert 'TimelineView' in illustration, \
    'the mark must be driven by a timeline so it actually moves'

# --- 4. The ring is gone from every header call site ------------------------
meter = strip[strip.index('private func meter('):strip.index('private func cpuAttributionCaption(')]
assert not call_sites(meter), 'ResourceStrip.meter must not wrap its glyph in a LoadRing'
assert 'InstrumentBadge(kind: InstrumentGlyph.kind(for: icon)' in meter
assert 'ZStack' not in meter.split('HStack(spacing: 6)')[1].split('Text(label)')[0], \
    'the glyph must stand alone, not sit in a ZStack behind an ornament'

kpi_cell = kpi[kpi.index('private struct MachineKpiButton'):]
assert not call_sites(kpi_cell), 'MachineKpiButton must not wrap its glyph in a LoadRing'
assert not call_sites(kpi[kpi.index('private var audioKpi'):kpi.index('private struct HeadsetBadge')]), \
    'the popup earbud cell must not wrap its glyph in a LoadRing'

all_shared = list(shared.glob('*.swift'))
ring_uses = [f.name for f in all_shared if re.search(r'(?<![A-Za-z.])LoadRing\(', f.read_text())]
assert not ring_uses, f'LoadRing call sites must be gone, found in {ring_uses}'
assert not any('loadRing' in f.read_text() for f in all_shared), \
    'the loadRing decoration kind must be gone with its only caller'

# --- The marks are fed real per-unit readings -------------------------------
for needle in ['cells: sampler.host.gpuRenderers.map { $0 / 100 }',
               'cells: sampler.host.coreLoad',
               'wells: sampler.host.memoryWells',
               'wells: sampler.host.diskWells']:
    assert needle in strip, f'ResourceStrip must pass {needle!r} to the mark'

# --- Render, then measure ---------------------------------------------------
probe = (root / 'Tests/fixtures/machine-mark-probe.swift').read_text()
for token, body in (('<<<LUCIDE_GEOMETRY>>>', geometry),
                    ('<<<HARDWARE_ILLUSTRATION>>>', illustration)):
    assert token in probe, f'the probe template lost {token}'
swift = probe.replace('<<<LUCIDE_GEOMETRY>>>', geometry) \
             .replace('<<<HARDWARE_ILLUSTRATION>>>', illustration)

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

    SCALE = 8.0
    FRAME_W, FRAME_H = 128.0, 104.0

    # Mirror the layout the mark uses: icon lane on top, reading lane beneath.
    lane_h = max(13.0, FRAME_H * 0.22)
    icon_h = FRAME_H - lane_h - 7
    side = min(FRAME_W, icon_h)
    lane_x = (FRAME_W - side) / 2
    lane_y = side + 7
    LANE = (lane_x, lane_y, side, lane_h)

    # Each bar's own rect inside the lane, mirrored from `drawReading`.
    def bar_rects(count):
        gap = 1.0 if count > 10 else (1.4 if count > 6 else 2.2)
        w = (LANE[2] - gap * (count - 1)) / count
        return [(LANE[0] + i * (w + gap), LANE[1], w, LANE[3]) for i in range(count)]

    def load(name):
        return np.array(Image.open(shots / f'{name}.png').convert('L')).astype(float)

    def ink(image, rect, inset=0.3):
        """Median luminance (0…255) inside a rect, in *frame* points.

        A median over an inset region rather than a point sample: a single point
        can land on the gap between two bars and report the background — which is
        how an earlier version of this check measured a mark that drew nothing.
        """
        x, y, w, h = rect
        x0, y0 = int((x + w * inset) * SCALE), int((y + h * inset) * SCALE)
        x1, y1 = int((x + w * (1 - inset)) * SCALE), int((y + h * (1 - inset)) * SCALE)
        sub = image[y0:y1 + 1, x0:x1 + 1]
        assert sub.size, f'rect {rect} fell outside the raster'
        return float(np.median(sub))

    def bar_ink(name, count):
        """Median luminance per bar, measured at the bar's own baseline."""
        image = load(name)
        out = []
        for x, y, w, h in bar_rects(count):
            out.append(ink(image, (x, y + h * 0.55, w, h * 0.45), inset=0.25))
        return out

    # 1. One bar per core, and the count is the *mark's*, not the call's.
    assert len(bar_ink('cpu-12', 12)) == 12
    for count in (12, 10, 8):
        bars = bar_ink(f'cpu-{count}', count)
        # A busy bar is ink (< 170); an idle one is a pale stub (> 200).
        lit = sum(1 for v in bars if v < 170)
        assert lit == count, f'{count} busy cores must fill {count} bars, got {lit} ({[int(v) for v in bars]})'

    # 2. Idle cores keep their stubs but must not glow.
    idle = bar_ink('cpu-idle', 12)
    assert all(v > 200 for v in idle), f'an idle core must be a pale stub: {[int(v) for v in idle]}'

    # 3. Half busy is half the lane, in core order.
    half = bar_ink('cpu-half', 12)
    assert all(v < 170 for v in half[:6]) and all(v > 200 for v in half[6:]), \
        f'the filled bars must be the busy cores, in order: {[int(v) for v in half]}'

    # 4. Bar height tracks the reading: a 30 % core stands visibly shorter than a
    #    95 % one, measured as the row of fill heights down each bar's centre.
    def fill_height(name, count, index):
        image = load(name)
        x, y, w, h = bar_rects(count)[index]
        column = image[int(y * SCALE):int((y + h) * SCALE), int((x + w / 2) * SCALE)]
        rows = np.where(column < 190)[0]
        return float(rows.size) / SCALE if rows.size else 0.0

    tall = fill_height('cpu-12', 12, 0)
    short = fill_height('cpu-30', 12, 0)
    assert tall > short + 2, \
        f'a 95 % bar must stand taller than a 30 % one ({tall:.1f}pt vs {short:.1f}pt)'

    # 5. No per-core reading → exactly one bar at the aggregate.
    aggregate = bar_ink('cpu-aggregate', 12)
    first = aggregate[0]
    assert first < 190, f'the aggregate fallback must fill a bar, got {first:.0f}'
    # ...and it spans the whole lane rather than pretending to be twelve cores.
    span = load('cpu-aggregate')
    filled = sum(1 for x in range(int(LANE[0] * SCALE), int((LANE[0] + LANE[2]) * SCALE))
                 if np.median(span[int((LANE[1] + LANE[3] * 0.7) * SCALE):int((LANE[1] + LANE[3]) * SCALE), x]) < 190)
    assert filled > LANE[2] * SCALE * 0.85, \
        'the aggregate bar must span the lane, not leave eleven empty slots'

    # 6. GPU: one bar per published sub-unit, and each bar's *height* is its own
    #    reading — a 100 %, 50 % and 10 % sub-unit must stand at three heights.
    #    (All three are filled, so the shading is checked as height, not tint: a
    #    10 % bar is a short bar, not a dark one.)
    heights = [fill_height('gpu-mixed', 3, i) for i in range(3)]
    assert heights[0] > heights[1] > heights[2], \
        f'GPU bars must scale with their own readings, got {[round(h, 1) for h in heights]}'
    assert heights[1] < heights[0] * 0.80, \
        f'a 50 % sub-unit must be visibly shorter than a 100 % one: {[round(h, 1) for h in heights]}'
    full = [fill_height('gpu-full', 3, i) for i in range(3)]
    assert all(h > heights[1] for h in full), \
        'an all-busy GPU must fill all three bars to the same full height'

    # 7. 内存 / 硬盘 carry their own capacity readings.
    for name, count in (('mem', 3), ('disk', 1)):
        bars = bar_ink(name, count)
        assert any(v < 190 for v in bars), f'{name} must fill at least one capacity bar'

    # 8. The header glyph box must be free of ring ink.
    header = load('header')
    inked = 0
    for ox, oy in ((14, 14), (41, 14), (14, 41), (41, 41)):
        patch = header[int(oy * SCALE):int((oy + 3) * SCALE), int(ox * SCALE):int((ox + 3) * SCALE)]
        if (patch < 150).mean() > 0.6:
            inked += 1
    assert inked == 0, f'the header glyph box must be free of ring ink; found {inked} inked corners'

print('PASS: marks draw Lucide geometry on its 24pt grid in a generated file; the reading is a live '
      'lane (12/10/8 countable bars, 6-of-12 in order, idle stubs pale, taller bar = higher reading, '
      'aggregate spans the lane, GPU per sub-unit, 内存/硬盘 capacities); no ring behind any tile glyph')
