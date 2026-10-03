#!/usr/bin/env python3
"""The machine marks: Lucide geometry, live readings, and no header ring.

Four things are locked in, each of them one edit away from silently regressing:

1. **The outlines are Lucide's.** `LucideHardwareGeometry.swift` is generated
   from Lucide's own `cpu` / `gpu` / `memory-stick` / `hard-drive` SVGs. The
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
4. **No ring behind the header glyph.** `LoadRing` and the `InstrumentRing`
   that replaced it are gone — a ~96° arc at 22–28pt read as a spinner
   ("waiting") and duplicated the figure printed below it, and a ring drawn
   around the glyph read the same whichever way its ink was laid out. The
   check scans the call sites *and* renders the tile badge at the 26pt frame
   `ResourceStrip.meter` hands it, so an ornament that reappears as drawing
   rather than as a call site still fails.
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
# `ReadingSweepView.setSpeed` retimes its sheens through `CALayer.retime(to:)`,
# declared in `Interaction.swift`; the probe compiles the mark without the rest
# of that file, so the one shared retime is sliced in beside it.
interaction = (shared / 'Interaction.swift').read_text()
retime = interaction[interaction.index('// MARK: - Phase-preserving retiming'):interaction.index('// MARK: - Rolling figures')]


def call_sites(text):
    return re.findall(r'(?<![A-Za-z.])LoadRing\(', text)


# --- 1. The geometry is generated, not hand-authored ------------------------
assert 'generated' in geometry.lower(), \
    'LucideHardwareGeometry must keep saying it is generated'
assert 'Tools/gen-lucide-hardware.py' in geometry, \
    'the generated file must name its generator'
for name in ('cpu', 'gpu', 'memory-stick', 'hard-drive'):
    assert f'Lucide `{name}`' in geometry, f'{name} geometry missing from the generated file'
# Authored on the 24pt grid, and nothing may stray outside it.
coords = [float(v) for v in re.findall(r'(?:x|y): (-?\d+(?:\.\d+)?)', geometry)]
assert coords and min(coords) >= -0.001 and max(coords) <= 24.001, \
    f'every Lucide coordinate must lie on the 24pt grid, got {min(coords)}…{max(coords)}'
for kind in ('cpu', 'gpu', 'memory', 'disk'):
    assert f'case .{kind}:' in geometry, f'the generated file must define {kind}'
# The generator itself must exist and be re-runnable.
assert (root / 'Tools/gen-lucide-hardware.py').is_file(), 'the generator is missing'

# --- 2/3. The mark draws the reading in its own lane ------------------------
assert 'LucideHardwareGeometry.path(for:' in illustration, \
    'the mark must draw Lucide geometry, not its own paths'
assert 'lane' in illustration and 'drawReading' in illustration, \
    'the reading must be drawn in its own lane under the icon'
assert 'TimelineView' not in illustration, \
    'the sweep must not be a TimelineView: a live .animation schedule lays out the whole window every frame'
assert 'CABasicAnimation' in illustration and 'ReadingSweep' in illustration, \
    'the highlight must move on a render-server layer, at the same rate as the old clock'
assert 'sweepRate' in illustration, \
    'the sweep rate (0.35 + load * 1.35 cycles/s) has to stay a named function'

# --- 4. The ring is gone from every header call site ------------------------
meter = strip[strip.index('private func meter('):strip.index('private func cpuAttributionCaption(')]
assert not call_sites(meter), 'ResourceStrip.meter must not wrap its glyph in a LoadRing'
# The badge's `Kind` is stated by the tile's own case (`ResourceKind.glyphKind`
# — a switch, so a new tile is a compile decision), not by looking its SF Symbol
# string back up in `InstrumentGlyph.kind(for:)`.
assert 'InstrumentBadge(kind: kind.glyphKind, tint: tint)' in meter
assert 'var glyphKind: InstrumentGlyph.Kind {' in strip, \
    'the tile must state its glyph kind by case rather than by symbol string'
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
for needle in ['SiliconCells(gpu: true',
               'SiliconCells(gpu: false',
               'cells: gpu ? sampler.cells.gpuRenderers.map { $0 / 100 }',
               ': sampler.cells.cores',
               'wells: sampler.host.memoryWells',
               'wells: sampler.host.diskWells']:
    assert needle in strip, f'ResourceStrip must pass {needle!r} to the mark'

# --- Render, then measure ---------------------------------------------------
# `InstrumentGlyph` is sliced too: the header check below measures the badge the
# meter actually draws, and the mark's bridge names its `Kind`. A stub of the
# glyph would be a stub of the thing under test — the old fixture drew an SF
# Symbol here and no probe could ever touch it. `LucideHardwarePaths` is what
# that badge draws for gpu / vpn.
paths = (shared / 'LucideHardwarePaths.swift').read_text()
glyph = (shared / 'InstrumentGlyph.swift').read_text()

probe = (root / 'Tests/fixtures/machine-mark-probe.swift').read_text()
for token, _ in (('<<<LUCIDE_GEOMETRY>>>', geometry),
                    ('<<<LUCIDE_PATHS>>>', paths),
                    ('<<<INSTRUMENT_GLYPH>>>', glyph),
                    ('<<<HARDWARE_ILLUSTRATION>>>', illustration),
                    ('<<<RETIME>>>', retime)):
    assert token in probe, f'the probe template lost {token}'
swift = probe.replace('<<<LUCIDE_GEOMETRY>>>', geometry) \
             .replace('<<<LUCIDE_PATHS>>>', paths) \
             .replace('<<<INSTRUMENT_GLYPH>>>', glyph) \
             .replace('<<<HARDWARE_ILLUSTRATION>>>', illustration) \
             .replace('<<<RETIME>>>', retime)

with tempfile.TemporaryDirectory(prefix='claudebar-machine-mark-') as folder:
    folder = Path(folder)
    source = folder / 'Probe.swift'
    source.write_text(swift)
    binary = folder / 'probe'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    shots = folder / 'shots'
    rendered = subprocess.run([str(binary), str(shots)], check=True,
                              capture_output=True, text=True)

    from PIL import Image
    import numpy as np

    SCALE = 8.0
    BADGE = 26.0

    # The lane and bar rects come from the probe's own run of
    # `HardwareIllustration.placement(in:)` / `laneBars(...)`, not from a second
    # implementation here. The Python copy of the layout went stale when the
    # lane split changed (aa9ea5a) and the reads stopped landing on the drawing
    # they claimed to measure.
    lane = None
    bars = {}
    for line in rendered.stdout.splitlines():
        parts = line.split()
        if parts[:1] == ['LANE'] and len(parts) == 5:
            lane = tuple(float(v) for v in parts[1:])
        elif parts[:1] == ['BAR'] and len(parts) == 7:
            bars.setdefault(parts[1], []).append(tuple(float(v) for v in parts[3:]))
    assert lane, f'the probe must print the lane it renders, got:\n{rendered.stdout}'
    assert bars, 'the probe must print the bar rects it renders'
    # The lane is a gauge strip under the icon, not a second panel. The layout
    # doc's own complaint about the old split is the proportion to keep: at the
    # tile size it left "the icon a hair under half the slot and the bars a lane
    # thicker than the gap between two DIMM pads" (~0.30 of the icon's side).
    # The numbers are production's (printed above), so the assertion survives a
    # deliberate layout change but fails if the lane stops being a strip.
    assert lane[3] <= lane[2] * 0.30, \
        f'the reading lane must stay a strip under the icon, got {lane[3]:.1f}pt for a {lane[2]:.1f}pt side'

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

    def bar_ink(name):
        """Median luminance per bar, measured at the bar's own baseline."""
        image = load(name)
        return [ink(image, (x, y + h * 0.55, w, h * 0.45), inset=0.25)
                for x, y, w, h in bars[name]]

    # 1. One bar per core, and the count is the *mark's*, not the call's.
    assert len(bars['cpu-12']) == 12, f'twelve cores must lay out twelve bars, got {len(bars["cpu-12"])}'
    for count in (12, 10, 8):
        values = bar_ink(f'cpu-{count}')
        # A busy bar is ink (< 170); an idle one is a pale stub (> 200).
        lit = sum(1 for v in values if v < 170)
        assert lit == count, f'{count} busy cores must fill {count} bars, got {lit} ({[int(v) for v in values]})'

    # 2. Idle cores keep their stubs but must not glow.
    idle = bar_ink('cpu-idle')
    assert all(v > 200 for v in idle), f'an idle core must be a pale stub: {[int(v) for v in idle]}'

    # 3. Half busy is half the lane, in core order.
    half = bar_ink('cpu-half')
    assert all(v < 170 for v in half[:6]) and all(v > 200 for v in half[6:]), \
        f'the filled bars must be the busy cores, in order: {[int(v) for v in half]}'

    # 4. Bar height tracks the reading: a 30 % core stands visibly shorter than a
    #    95 % one, measured as the row of fill heights down each bar's centre.
    def fill_height(name, index):
        image = load(name)
        x, y, w, h = bars[name][index]
        column = image[int(y * SCALE):int((y + h) * SCALE), int((x + w / 2) * SCALE)]
        rows = np.where(column < 190)[0]
        return float(rows.size) / SCALE if rows.size else 0.0

    tall = fill_height('cpu-12', 0)
    short = fill_height('cpu-30', 0)
    assert tall > short + 2, \
        f'a 95 % bar must stand taller than a 30 % one ({tall:.1f}pt vs {short:.1f}pt)'

    # 5. No per-core reading → exactly one bar at the aggregate, and it is the
    #    bar the layout computes — not the icon ink a mis-aimed probe happens to
    #    read. The count is asserted off the layout, and the raster is compared
    #    against the same pixels of `cpu-idle`, so a fallback that draws twelve
    #    pale stubs (the regression this item names) changes the count and a
    #    fallback that draws a pale lane-wide stub changes the raster.
    aggregate_bars = bars['cpu-aggregate']
    assert len(aggregate_bars) == 1, \
        f'the aggregate fallback must lay out one bar, got {len(aggregate_bars)}'
    ax, ay, aw, ah = aggregate_bars[0]
    assert abs(aw - lane[2]) < 0.01, \
        f'the aggregate bar must span the lane ({aw:.1f} vs lane {lane[2]:.1f})'
    assert ah < lane[3] and ah >= lane[3] * 0.3, \
        f'the aggregate bar must be a readable fill of the lane, got {ah:.1f}pt of {lane[3]:.1f}pt'
    aggregate = ink(load('cpu-aggregate'), (ax, ay + ah * 0.25, aw, ah * 0.6), inset=0.0)
    idle_rail = ink(load('cpu-idle'), (ax, ay + ah * 0.25, aw, ah * 0.6), inset=0.0)
    assert aggregate < 190, f'the aggregate fallback must fill a bar, got {aggregate:.0f}'
    assert idle_rail > 200, f'the same rail pixels with no reading must read pale, got {idle_rail:.0f}'
    assert aggregate < idle_rail - 20, \
        f'the aggregate bar must be visibly darker than the empty rail ({aggregate:.0f} vs {idle_rail:.0f})'
    # 5b. ...and it is one lit block, not twelve pale stubs: the *darkest* pixel
    #     in the bar's own rect belongs to the fallback's filled shading, where a
    #     twelve-stub render (or any per-unit breakdown) only reaches the pale
    #     stub tone. The bar rects come from `laneBars`, so this reads the mark's
    #     own geometry, not a Python copy of it.
    aggregate_rect = load('cpu-aggregate')[int(ay * SCALE):int((ay + ah) * SCALE),
                                            int(ax * SCALE):int((ax + aw) * SCALE)]
    stub_rect = load('cpu-idle')[int(ay * SCALE):int((ay + ah) * SCALE),
                                 int(ax * SCALE):int((ax + aw) * SCALE)]
    assert aggregate_rect.min() < 180, \
        f'the aggregate fallback must fill its bar, darkest pixel {aggregate_rect.min():.0f}'
    assert stub_rect.min() > 200, \
        f'a per-unit stub must stay pale, darkest pixel {stub_rect.min():.0f}'

    # 6. GPU: one bar per published sub-unit, and each bar's *height* is its own
    #    reading — a 100 %, 50 % and 10 % sub-unit must stand at three heights.
    #    (All three are filled, so the shading is checked as height, not tint: a
    #    10 % bar is a short bar, not a dark one.)
    heights = [fill_height('gpu-mixed', i) for i in range(3)]
    assert heights[0] > heights[1] > heights[2], \
        f'GPU bars must scale with their own readings, got {[round(h, 1) for h in heights]}'
    assert heights[1] < heights[0] * 0.80, \
        f'a 50 % sub-unit must be visibly shorter than a 100 % one: {[round(h, 1) for h in heights]}'
    full = [fill_height('gpu-full', i) for i in range(3)]
    assert all(h > heights[1] for h in full), \
        'an all-busy GPU must fill all three bars to the same full height'

    # 6b. The GPU's no-sub-unit fallback is the same branch as the CPU's, so its
    #     aggregate gets the same shape of assertion rather than being rendered
    #     and thrown away.
    assert len(bars['gpu-aggregate']) == 1, \
        f'the GPU aggregate fallback must lay out one bar, got {len(bars["gpu-aggregate"])}'
    gax, gay, gaw, gah = bars['gpu-aggregate'][0]
    assert abs(gaw - lane[2]) < 0.01, 'the GPU aggregate bar must span the lane'
    gpu_aggregate = ink(load('gpu-aggregate'), (gax, gay + gah * 0.25, gaw, gah * 0.6), inset=0.0)
    assert gpu_aggregate < 190, f'the GPU aggregate fallback must fill a bar, got {gpu_aggregate:.0f}'
    gpu_rect = load('gpu-aggregate')[int(gay * SCALE):int((gay + gah) * SCALE),
                                      int(gax * SCALE):int((gax + gaw) * SCALE)]
    assert gpu_rect.min() < 180, \
        f'the GPU aggregate fallback must fill its bar, darkest pixel {gpu_rect.min():.0f}'

    # 7. 内存 / 硬盘 carry their own capacity readings.
    for name, count in (('mem', 3), ('disk', 1)):
        assert len(bars[name]) == count, f'{name} must lay out {count} capacity bar(s)'
        values = bar_ink(name)
        assert any(v < 190 for v in values), f'{name} must fill at least one capacity bar'

    # 8. The tile badge must draw its glyph and nothing else. `ResourceStrip.meter`
    #    hands `InstrumentBadge` a 26pt frame, and the glyph is authored on a 24pt
    #    grid centred in it, so its own ink stops ~3pt in from every edge: an
    #    ornament drawn around or behind it (the deleted `LoadRing` /
    #    `InstrumentRing` shape, a plate, an arc) is ink in the frame's own
    #    margin, which the glyph itself never reaches. The margin band is
    #    measured on the badge raster itself — the earlier version probed four
    #    points inside an SF Symbol stand-in's padded box, where no ornament
    #    could ever land.
    margin = int(1.5 * SCALE)
    for kind in ('cpu', 'gpu', 'memory', 'disk'):
        image = load(f'badge-{kind}')
        edge = int(BADGE * SCALE)
        assert image.shape >= (edge, edge), f'badge-{kind} must rasterise the 26pt frame'
        image = image[:edge, :edge]
        band = np.zeros_like(image, dtype=bool)
        band[:margin, :] = band[-margin:, :] = band[:, :margin] = band[:, -margin:] = True
        darkest = image[band].min()
        assert darkest > 250, (
            f'the {kind} tile badge carries ink in its own margin (darkest {darkest:.0f}): '
            'the glyph must stand alone, with no ring or plate around it')
        inner = image[margin:-margin, margin:-margin]
        assert (inner < 200).mean() > 0.05, \
            f'the {kind} tile badge draws no glyph, so the margin check proves nothing'

print('PASS: marks draw Lucide geometry on its 24pt grid in a generated file; the reading is a live '
      'lane (12/10/8 countable bars, 6-of-12 in order, idle stubs pale, taller bar = higher reading, '
      'aggregate bars laid out by the mark itself and visibly filled, GPU per sub-unit, 内存/硬盘 '
      'capacities); the tile badge draws its glyph with an empty margin, so no ring can sit behind it')
