"""Derive `Sources/ClaudeBar/Resources/fan-blade.tsv` from Lucide's `fan`.

Lucide's `fan` is a hub dot at (12, 12) plus one closed blade path:

    M 10.827 16.379
    a 6.082 6.082 0 0 1 -8.618 -7.002   l  5.412  1.45
    a 6.082 6.082 0 0 1  7.002 -8.618   l -1.45   5.412
    a 6.082 6.082 0 0 1  8.618  7.002   l -5.412 -1.45
    a 6.082 6.082 0 0 1 -7.002  8.618   l  1.45  -5.412
    Z

Read as geometry rather than as commands, it is **four arcs of radius 6.082,
sweeping 131.8° each, joined by four short chords**, closing on itself. Every arc
endpoint sits on radius 4.533 or radius 10.136 from the hub, and the four points
at each radius are 90° apart — so the blade is the annulus between those two
radii, cut by four chords at the same four angles.

That annulus *is* a rotor: Lucide strokes it at 2pt with round joins, so its ink
runs 5.53 … 11.14 — a 1:2 hub-to-rim disc, which is what the app's hand-fit
`RotorBlade` was reaching for and never quite hit.

An animated rotor needs this in **unit** space, so it can be scaled to any
diameter and spun by any angle: the hub lands on radius 0.5 and the rim on 1.0.
One *lobe* is emitted — the arc from an inner point out to the next outer one,
then the chord that walks back in — because a rotor draws three copies of one
lobe and must not close the path while doing it.

Run this once and commit the result; it is not part of the build.
"""
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'Sources/ClaudeBar/Views/Shared/LucideHardwareGeometry.swift'
OUT = ROOT / 'Sources/ClaudeBar/Resources/fan-blade.tsv'

HUB = (12.0, 12.0)
HUB_RADIUS = 0.5                 # the hub, as a fraction of the blade's rim
STROKE = 1.0                     # half of Lucide's 2pt stroke
INNER, OUTER = 4.5334, 10.1363   # where Lucide's arc endpoints sit


def distance(point, about=HUB):
    return math.hypot(point[0] - about[0], point[1] - about[1])


# --- 1. Read the generated geometry back -------------------------------------
body = SRC.read_text().split('        case .fan:', 1)[1].split('        ///', 1)[0]
ops: list[tuple[str, list[tuple[float, float]]]] = []
for line in body.strip().splitlines():
    points = [tuple(map(float, p))
              for p in re.findall(r'CGPoint\(x: (-?[\d.]+), y: (-?[\d.]+)\)', line)]
    if 'move(' in line:
        ops.append(('move', points))
    elif 'addLine' in line:
        ops.append(('chord', points))
    elif 'addCurve' in line:
        # Generated as (to:control1:control2:); store (c1, c2, endpoint).
        ops.append(('arc', [points[1], points[2], points[0]]))
    elif 'closeSubpath' in line:
        ops.append(('close', []))

close_index = next(i for i, (kind, _) in enumerate(ops) if kind == 'close')
blade_ops = ops[:close_index]
# Four lobes of (a 180° arc split into two cubics, then a chord).
assert [kind for kind, _ in blade_ops] == ['move'] + ['arc', 'arc', 'chord'] * 4, \
    f'unexpected fan structure: {[kind for kind, _ in blade_ops]}'
assert [kind for kind, _ in ops[close_index:]] == ['close', 'move', 'chord'], \
    f'the hub dot must follow the blade: {[kind for kind, _ in ops[close_index:]]}'

# --- 2. Prove the structure before trusting it -------------------------------
# A 180° arc's endpoints are antipodal on its own circle, so its declared radius
# is half their distance. That is what makes the blade a clean annulus, and it is
# exactly the property a redesigned blade would break. (The arc is centred on the
# hub *flower*, not on the hub, so the chord's midpoint is not a centre.)
lobes: list[dict] = []
for index in range(4):
    arc = [blade_ops[1 + index * 3][1], blade_ops[2 + index * 3][1]]
    move_or_previous = blade_ops[0][1][0] if index == 0 else lobes[-1]['chord']
    chord = blade_ops[3 + index * 3][1][0]
    end = arc[1][2]
    start = move_or_previous
    assert abs(distance(start) - INNER) < 0.01, \
        f'arc {index} does not start on the inner radius: {distance(start):.4f}'
    assert abs(distance(end) - OUTER) < 0.01, \
        f'arc {index} does not end on the outer radius: {distance(end):.4f}'
    # Lucide declares `a 6.082 6.082`: a 131.8-degree sweep, which makes the
    # chord 11.104 long rather than the 12.164 a half circle would give. Assert
    # the declared sweep, since that is the number the icon was drawn to.
    sweep = math.degrees(2 * math.asin(math.dist(start, end) / (2 * 6.082)))
    assert abs(sweep - 131.806) < 0.02, \
        f'arc {index} is not Lucide\'s 131.8-degree sweep: {sweep:.3f}'
    assert abs(distance(chord) - INNER) < 0.01, \
        f'chord {index} does not land on the inner radius: {distance(chord):.4f}'
    lobes.append({'start': start, 'end': end,
                  'points': [arc[0][0], arc[0][1], arc[0][2],
                             arc[1][0], arc[1][1], arc[1][2]],
                  'chord': chord})

assert math.dist(lobes[-1]['chord'], blade_ops[0][1][0]) < 0.01, \
    'the last chord must close the blade onto its move'
# The four inner points must be 90 degrees apart, or the blade is not symmetric.
angles = sorted(math.degrees(math.atan2(lobe['chord'][1] - HUB[1],
                                        lobe['chord'][0] - HUB[0])) for lobe in lobes)
steps = [round((angles[(i + 1) % 4] - angles[i]) % 360, 3) for i in range(4)]
assert all(abs(step - 90) < 0.02 for step in steps), \
    f'the blade chords must be 90 degrees apart, got {steps}'

# --- 3. Emit it in unit space, as one lobe ------------------------------------
rim = OUTER + STROKE
assert abs(rim - 11.1363) < 0.01, f'the blade rim drifted from 11.136: {rim}'
scale = 1.0 / rim


def unit(point):
    return ((point[0] - HUB[0]) * scale, (point[1] - HUB[1]) * scale)


lobe = lobes[0]
lines = [
    '# Lucide `fan`, one blade in unit space — the rotor the app spins.',
    '# Generated by `Tools/gen-fan-blade.py` from the `.fan` case of',
    '# LucideHardwareGeometry.swift. Do not hand-edit.',
    '#',
    '# Columns: kind<TAB>x<TAB>y   — kind is move, arc or chord.',
    '# An `arc` row is a cubic control point: control1, control2, then the',
    '# endpoint, and a lobe is one move, six arc rows and one chord.',
    '# Three of this lobe, each rotated 120 degrees, is Lucide\'s blade.',
    f'# hub_radius {HUB_RADIUS:.6f}',
    f'# rim {rim:.6f}   (Lucide units the unit box corresponds to)',
    '# sourced_from "Lucide fan, four 6.082-radius arcs of 131.8 degrees (ISC)"',
]
lines.append('move\t%.6f\t%.6f' % unit(lobe['start']))
for point in lobe['points']:
    lines.append('arc\t%.6f\t%.6f' % unit(point))
lines.append('chord\t%.6f\t%.6f' % unit(lobe['chord']))

OUT.write_text('\n'.join(lines) + '\n')
print(f'wrote {OUT.relative_to(ROOT)}: one lobe of {len(lobe["points"])} arc points, '
      f'rim {rim:.3f}, hub {INNER / rim:.3f} of rim')
