#!/usr/bin/env python3
"""Generate `Sources/ClaudeBar/Views/Shared/LucideHardwareGeometry.swift`.

The machine marks (CPU / GPU / 内存 / 硬盘) are **Lucide's own icon geometry**,
converted to SwiftUI `Path` code, not shapes hand-authored in this repo.

Why generated rather than hand-drawn: hand-drawing four hardware silhouettes on a
Canvas produced marks that were recognisable-ish and plainly amateur — the
curves were approximations, the proportions were invented, and every fix moved
the problem somewhere else. Lucide is a real icon system with a drawn spec
(24pt grid, 2pt stroke, round caps and joins), it is already vendored in this
repo for the GPU and VPN marks, and its `cpu` / `gpu` / `memory-stick` /
`hard-drive` icons are exactly the four hardware parts these tiles need. Using
the real geometry means the mark is *correct* rather than *nearly* correct.

Licence: Lucide is ISC; see `Sources/Licenses/Lucide.txt`, which is copied into
the app bundle by `Sources/build.sh`. Regenerate with:

    python3 Tools/gen-lucide-hardware.py

The converter understands the subset of SVG that Lucide icons use: `path` with
absolute M/L/H/V/C/S/Q/T/A/Z commands, plus `circle` and `rect`. Anything it
cannot represent is a hard error — a silently dropped element would ship a mark
with a piece missing.
"""
from __future__ import annotations
import re
import sys
import urllib.request
from pathlib import Path

# Lucide ships these four; the names are Lucide's own file names.
ICONS = {
    "cpu": "cpu",
    "gpu": "gpu",
    "memory": "memory-stick",
    "disk": "hard-drive",
    # The fan card's popover draws a laptop with the fans inside it; the chassis
    # outline is Lucide's `laptop-minimal` for the same reason the four marks are
    # Lucide's: invented geometry does not look designed.
    "laptop": "laptop-minimal",
    # The blade silhouette inside each of the popover's two fan bays. A rotor
    # blade is the one shape this repo must not invent: the tile's `RotorBlade`
    # was already a hand-fit Bézier, and a second hand-fit blade in the popover
    # would be a second guess at the same curve — so both now come from Lucide's
    # `fan`, which is four 6.08-radius arcs and so is exactly a rotor seen face
    # on. `Resources/fan-blade.tsv` carries it in SwiftUI's unit space.
    "fan": "fan",
}
RAW = "https://raw.githubusercontent.com/lucide-icons/lucide/main/icons/{}.svg"
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Sources/ClaudeBar/Views/Shared/LucideHardwareGeometry.swift"

NUM = r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"


def fmt(value: float) -> str:
    """Trim float noise so the generated file reads like hand-written code."""
    if abs(value - round(value)) < 1e-9:
        return str(int(round(value)))
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return text


def arc_to_cubics(x1: float, y1: float, rx: float, ry: float, rot: float,
                  large: int, sweep: int, x2: float, y2: float) -> list[tuple[float, ...]]:
    """SVG elliptical arc -> list of (c1x, c1y, c2x, c2y, x, y) cubics.

    Standard endpoint -> centre parameterisation (SVG 1.1 F.6.5). Each arc is
    split so no segment exceeds 90°, which is where the cubic approximation
    stays visually exact.
    """
    import math
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [(x1, y1, x2, y2, x2, y2)]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(rot % 360)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)
    # Step 1: transform to the ellipse's own frame.
    dx2, dy2 = (x1 - x2) / 2, (y1 - y2) / 2
    x1p = cos_phi * dx2 + sin_phi * dy2
    y1p = -sin_phi * dx2 + cos_phi * dy2
    # Scale the radii up if they cannot span the chord.
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        scale = math.sqrt(lam)
        rx, ry = rx * scale, ry * scale
    # Step 2: centre.
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    factor = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large == sweep:
        factor = -factor
    cxp = factor * rx * y1p / ry
    cyp = -factor * ry * x1p / rx
    cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2
    cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2
    # Step 3: angles.
    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        norm = math.hypot(ux, uy) * math.hypot(vx, vy)
        if norm == 0:
            return 0.0
        value = max(-1.0, min(1.0, dot / norm))
        sign = -1.0 if (ux * vy - uy * vx) < 0 else 1.0
        return sign * math.acos(value)
    theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                  (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if sweep == 0 and delta > 0:
        delta -= 2 * math.pi
    elif sweep == 1 and delta < 0:
        delta += 2 * math.pi
    # Step 4: one cubic per <=90 degrees.
    segments = max(1, int(math.ceil(abs(delta) / (math.pi / 2))))
    step = delta / segments
    alpha = 4 / 3 * math.tan(step / 4)
    out: list[tuple[float, ...]] = []
    theta = theta1
    def point(t):
        return (cx + rx * math.cos(t) * cos_phi - ry * math.sin(t) * sin_phi,
                cy + rx * math.cos(t) * sin_phi + ry * math.sin(t) * cos_phi)
    def derivative(t):
        return (-rx * math.sin(t) * cos_phi - ry * math.cos(t) * sin_phi,
                -rx * math.sin(t) * sin_phi + ry * math.cos(t) * cos_phi)
    for _ in range(segments):
        theta_end = theta + step
        px, py = point(theta)
        qx, qy = point(theta_end)
        d1x, d1y = derivative(theta)
        d2x, d2y = derivative(theta_end)
        out.append((px + alpha * d1x, py + alpha * d1y,
                    qx - alpha * d2x, qy - alpha * d2y, qx, qy))
        theta = theta_end
    return out


def tokenize(d: str) -> list[str]:
    return re.findall(r"[MmLlHhVvCcSsQqTtAaZz]|" + NUM, d.replace(",", " "))


def to_calls(d: str) -> list[str]:
    """Absolute SVG path -> SwiftUI Path calls. Relative commands are made
    absolute here so the generated code has one convention."""
    tokens = tokenize(d)
    out: list[str] = []
    i = 0
    cx = cy = 0.0          # current point
    sx = sy = 0.0          # subpath start
    last_c: tuple[float, float] | None = None   # for S/T reflection

    def take(n: int) -> list[float]:
        nonlocal i
        vals = [float(tokens[i + k]) for k in range(n)]
        i += n
        return vals

    while i < len(tokens):
        cmd = tokens[i]
        if re.match(NUM, cmd):
            raise SystemExit(f"implicit command repetition is not supported: {d!r}")
        i += 1
        up = cmd.upper()
        rel = cmd.islower()
        if up == "M":
            x, y = take(2)
            if rel: x, y = cx + x, cy + y
            out.append(f"p.move(to: CGPoint(x: {fmt(x)}, y: {fmt(y)}))")
            cx, cy = x, y
            sx, sy = x, y
            last_c = None
        elif up == "L":
            x, y = take(2)
            if rel: x, y = cx + x, cy + y
            out.append(f"p.addLine(to: CGPoint(x: {fmt(x)}, y: {fmt(y)}))")
            cx, cy = x, y
            last_c = None
        elif up == "H":
            (x,) = take(1)
            if rel: x = cx + x
            out.append(f"p.addLine(to: CGPoint(x: {fmt(x)}, y: {fmt(cy)}))")
            cx = x
            last_c = None
        elif up == "V":
            (y,) = take(1)
            if rel: y = cy + y
            out.append(f"p.addLine(to: CGPoint(x: {fmt(cx)}, y: {fmt(y)}))")
            cy = y
            last_c = None
        elif up == "C":
            x1, y1, x2, y2, x, y = take(6)
            if rel: x1, y1, x2, y2, x, y = cx + x1, cy + y1, cx + x2, cy + y2, cx + x, cy + y
            out.append(f"p.addCurve(to: CGPoint(x: {fmt(x)}, y: {fmt(y)}), "
                       f"control1: CGPoint(x: {fmt(x1)}, y: {fmt(y1)}), "
                       f"control2: CGPoint(x: {fmt(x2)}, y: {fmt(y2)}))")
            last_c = (x2, y2)
            cx, cy = x, y
        elif up == "S":
            x2, y2, x, y = take(4)
            if rel: x2, y2, x, y = cx + x2, cy + y2, cx + x, cy + y
            x1, y1 = (2 * cx - last_c[0], 2 * cy - last_c[1]) if last_c else (cx, cy)
            out.append(f"p.addCurve(to: CGPoint(x: {fmt(x)}, y: {fmt(y)}), "
                       f"control1: CGPoint(x: {fmt(x1)}, y: {fmt(y1)}), "
                       f"control2: CGPoint(x: {fmt(x2)}, y: {fmt(y2)}))")
            last_c = (x2, y2)
            cx, cy = x, y
        elif up == "Q":
            x1, y1, x, y = take(4)
            if rel: x1, y1, x, y = cx + x1, cy + y1, cx + x, cy + y
            out.append(f"p.addQuadCurve(to: CGPoint(x: {fmt(x)}, y: {fmt(y)}), "
                       f"control: CGPoint(x: {fmt(x1)}, y: {fmt(y1)}))")
            last_c = (x1, y1)
            cx, cy = x, y
        elif up == "T":
            x, y = take(2)
            if rel: x, y = cx + x, cy + y
            x1, y1 = (2 * cx - last_c[0], 2 * cy - last_c[1]) if last_c else (cx, cy)
            out.append(f"p.addQuadCurve(to: CGPoint(x: {fmt(x)}, y: {fmt(y)}), "
                       f"control: CGPoint(x: {fmt(x1)}, y: {fmt(y1)}))")
            last_c = (x1, y1)
            cx, cy = x, y
        elif up == "A":
            rx, ry, rot, large, sweep, x, y = take(7)
            if rel: x, y = cx + x, cy + y
            # SVG arcs are emitted as cubic Béziers (spec F.6.5 endpoint ->
            # centre parameterisation, then one 90°-bounded curve per segment).
            # Dropping them would silently square off every rounded corner on the
            # card, which is the whole look of the GPU mark.
            for seg in arc_to_cubics(cx, cy, rx, ry, rot, int(large), int(sweep), x, y):
                (c1x, c1y, c2x, c2y, ex, ey) = seg
                out.append(f"p.addCurve(to: CGPoint(x: {fmt(ex)}, y: {fmt(ey)}), "
                           f"control1: CGPoint(x: {fmt(c1x)}, y: {fmt(c1y)}), "
                           f"control2: CGPoint(x: {fmt(c2x)}, y: {fmt(c2y)}))")
            last_c = None
            cx, cy = x, y
        elif up == "Z":
            out.append("p.closeSubpath()")
            cx, cy = sx, sy
            last_c = None
        else:
            raise SystemExit(f"unsupported command {cmd!r} in {d!r}")
    return out


def fetch(name: str) -> str:
    url = RAW.format(name)
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            return response.read().decode()
    except Exception as error:                        # noqa: BLE001
        raise SystemExit(f"cannot fetch {url}: {error}") from error


def convert(svg: str) -> list[str]:
    body = re.search(r"<svg\b.*?>(.*)</svg>", svg, re.S)
    if not body:
        raise SystemExit("no <svg> body")
    inner = body.group(1)
    calls: list[str] = []
    for tag in re.finditer(r"<(path|circle|rect|line|polyline|polygon)\b([^>]*)/?>", inner):
        kind, attrs = tag.group(1), tag.group(2)
        get = lambda key: (re.search(rf'{key}="([^"]*)"', attrs) or [None, None])[1]  # noqa: E731
        if kind == "path":
            d = get("d")
            if not d:
                raise SystemExit("path without d")
            calls.extend(to_calls(d))
        elif kind == "circle":
            cx, cy, r = float(get("cx") or 0), float(get("cy") or 0), float(get("r") or 0)
            calls.append(
                f"p.addEllipse(in: CGRect(x: {fmt(cx - r)}, y: {fmt(cy - r)}, "
                f"width: {fmt(2 * r)}, height: {fmt(2 * r)}))")
        elif kind == "rect":
            x, y = float(get("x") or 0), float(get("y") or 0)
            w, h = float(get("width") or 0), float(get("height") or 0)
            rx = float(get("rx") or 0)
            if rx:
                calls.append(
                    f"p.addRoundedRect(in: CGRect(x: {fmt(x)}, y: {fmt(y)}, "
                    f"width: {fmt(w)}, height: {fmt(h)}), cornerSize: CGSize(width: {fmt(rx)}, height: {fmt(rx)}))")
            else:
                calls.append(
                    f"p.addRect(CGRect(x: {fmt(x)}, y: {fmt(y)}, "
                    f"width: {fmt(w)}, height: {fmt(h)}))")
        elif kind == "line":
            x1, y1 = float(get("x1") or 0), float(get("y1") or 0)
            x2, y2 = float(get("x2") or 0), float(get("y2") or 0)
            calls.append(f"p.move(to: CGPoint(x: {fmt(x1)}, y: {fmt(y1)}))")
            calls.append(f"p.addLine(to: CGPoint(x: {fmt(x2)}, y: {fmt(y2)}))")
        else:
            raise SystemExit(f"unsupported element <{kind}> — extend the generator")
    if not calls:
        raise SystemExit("no drawable elements")
    return calls


def main() -> int:
    arg_paths = {k: Path(v) for k, v in
                 (a.split("=", 1) for a in sys.argv[1:] if "=" in a)}
    blocks: list[str] = []
    for swift_name, lucide_name in ICONS.items():
        local = arg_paths.get(swift_name)
        svg = local.read_text() if local else fetch(lucide_name)
        calls = convert(svg)
        body = "\n".join(f"            {c}" for c in calls)
        blocks.append(
            f"        /// Lucide `{lucide_name}`.\n"
            f"        case .{swift_name}:\n{body}")
    out = f'''import SwiftUI

/// **Generated file — do not hand-edit.**
///
/// Lucide's own geometry for the four machine marks, converted from the
/// upstream SVGs by `Tools/gen-lucide-hardware.py`; run that script to
/// regenerate.
///
/// These are real icon-system drawings (24pt grid, 2pt stroke, round caps and
/// joins) rather than shapes invented in this file. The previous version of
/// `HardwareIllustration` hand-authored its silhouettes on a Canvas and produced
/// marks that were recognisable-ish and plainly amateur; using the upstream
/// geometry is what makes them read as designed.
///
/// ISC licensed — Lucide Icons and Contributors. `Sources/Licenses/Lucide.txt`
/// is copied into the bundle by `Sources/build.sh`.
enum LucideHardwareGeometry {{
    /// Every mark is authored on Lucide's 24-point grid.
    static let grid: CGFloat = 24

    /// The outline of one hardware mark, in Lucide's coordinate space.
    static func path(for kind: Kind) -> Path {{
        var p = Path()
        switch kind {{
{chr(10).join(blocks)}
        }}
        return p
    }}

    enum Kind {{ case cpu, gpu, memory, disk, laptop, fan }}
}}
'''
    OUT.write_text(out)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(blocks)} marks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
