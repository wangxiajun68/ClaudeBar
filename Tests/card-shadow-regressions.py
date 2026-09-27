#!/usr/bin/env python3
"""The card surface's drop shadow must stay on Core Animation.

`.shadow(...)` and a `CALayer` with a `shadowPath` draw the same picture and
cost wildly different amounts. SwiftUI evaluates `.shadow` as a filter inside
the display-list pass: it re-runs for every display cycle the card's subtree is
visited, and it makes that subtree a compositing unit. A layer with an explicit
`shadowPath` is rasterised once by the render server and costs the view graph
nothing.

Measured on the idle dashboard, one app at a time, alternating arms (SCStream
paints per 6 s, n=6): `.shadow` **383** (371–388), layer **741** (727–752) —
disjoint ranges, 1.9x, p50 16.8 ms → 8.3 ms. Same direction on scroll
(517 → 949), page switching (1452 → 1863 frames, >20 ms 26 → 2), 模式 (462 →
693) and 连接器 (605 → 726).

The point of this file is that the regression is *invisible*: the two shadows
are pixel-identical, so nothing but a frame measurement can catch a revert, and
"this looks like the same thing, let me inline it" is exactly the edit that
brings it back.

The opposite mistake is asserted too, because it is the tempting generalisation:
the same swap on `PanelCardModifier` (384 → 386) and on the button chips
(738 → 736) buys **nothing** — the cost tracks the shadowed subtree, and those
subtrees are a couple of rounded rects. Converting them would put a layer per
panel on the render server for no return, so the panel surface is pinned to
*not* route through `LayerShadow`.

See docs/technical/08-performance.md §2026-09-26（续）.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []


def body_of(source: str, signature: str) -> str:
    """The braces-balanced body of `signature`, signature line included."""
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    index = brace + 1
    while depth:
        depth += (source[index] == '{') - (source[index] == '}')
        index += 1
    return source[start:index]


def without_comments(code: str) -> str:
    """Drop `//` and `/* … */` comments — the doc comments here quote the
    forbidden modifier on purpose, to tell the next reader why it is gone."""
    code = re.sub(r'/\*.*?\*/', '', code, flags=re.S)
    return re.sub(r'//[^\n]*', '', code)


tile = (root / 'Sources/ClaudeBar/Views/Shared/Tile.swift').read_text()
surface = without_comments(body_of(tile, 'struct TileSurface<Content: View>: View'))

if re.search(r'\.shadow\(', surface):
    failures.append(
        'Tile.swift: TileSurface carries a SwiftUI `.shadow(...)` again. It is a '
        'display-list filter — it re-runs every display cycle the card subtree is '
        'visited — and it is worth 358 frames per 6 s on the idle dashboard '
        '(383 vs 741 with the layer-backed shadow). Route it through `LayerShadow`.')

if 'LayerShadow(' not in surface:
    failures.append(
        'Tile.swift: TileSurface no longer applies `LayerShadow`. A card surface '
        'with no shadow at all is also a regression against the design (the '
        'shadow is 4 % black, radius 5, y 1 at rest / 7 %, 9, 4 hovered) — this '
        'assertion is here so "delete the expensive thing" is not the fix.')

# The layer shadow's own contract: it must be a rasterised rounded rect, and it
# must not become a hit target. `hitTest` returning nil is what keeps a
# decoration sitting behind the card from taking the card's clicks; without it
# the representable, which is laid over the card's background, would swallow
# every press on the tile.
host = without_comments(body_of(tile, 'final class ShadowHostView: NSView'))
if 'shadowPath' not in host:
    failures.append(
        'Tile.swift: ShadowHostView no longer sets an explicit `shadowPath`. '
        'That is the whole reason the layer is cheap — without it Core Animation '
        'derives the silhouette from the layer contents (an offscreen mask for an '
        'opaque fill with a corner radius) instead of rasterising the rounded '
        'rect directly.')
if not re.search(r'func hitTest\([^)]*\)\s*->\s*NSView\?\s*\{\s*nil\s*\}', host):
    failures.append(
        'Tile.swift: ShadowHostView.hitTest no longer returns nil. The shadow host '
        'is laid out behind the card as a `background`, so a hit-testable host '
        'swallows the tile\'s clicks.')
if 'isFlipped' not in host:
    failures.append(
        'Tile.swift: ShadowHostView is no longer flipped. Its comment documents '
        'that this is what makes the layer\'s `shadowOffset.height` mean what the '
        '`y:` argument meant in the modifier it replaces (positive = below the '
        'card); unflipped, the shadow jumps above it.')

# The counter-case, pinned so a later "let's do the panels too" pass is stopped
# by a test rather than by a frame measurement nobody runs.
theme = (root / 'Sources/ClaudeBar/Theme/Theme.swift').read_text()
panel = without_comments(body_of(theme, 'struct PanelCardModifier: ViewModifier'))
if 'LayerShadow(' in panel:
    failures.append(
        'Theme.swift: PanelCardModifier now routes its drop shadow through '
        'LayerShadow. Measured: 384 → 386 frames per 6 s, i.e. nothing — the '
        'cost tracks the shadowed subtree, and a panel\'s is two rounded rects, '
        'unlike a tile\'s (DepthLens rings + border + hover state). This adds a '
        'layer per panel to the render server for no return.')

# --- The most-repeated component must be layer-backed too ---------------------
#
# `InstrumentButton` is the app's most-repeated component: the provider
# directory alone carries 8 per card. Its plate shadow was a
# `.compositingGroup()` + two `.shadow(...)` pair, and it is worth more than the
# card shadow on a button-dense page — measured on the provider directory under
# a deep scroll, alternating arms: `.shadow` 1260 frames / 66.6 fps (p50
# 16.5 ms, >20 ms 73) vs layer 2019 / 108.6 fps (p50 8.4 ms, >20 ms 0).
#
# This is the *page-dependent* half of the rule above: the identical swap
# measured 738 → 736 on the idle dashboard, because the dashboard barely uses
# this button. An assertion here is what keeps "it didn't matter there" from
# being read as "it doesn't matter anywhere".
controls = (root / 'Sources/ClaudeBar/Views/Shared/InstrumentControls.swift').read_text()
button = without_comments(body_of(controls, 'private struct InstrumentButtonBody: View'))
# Scoped to the *plate* pair, not to every `.shadow` in the body: the label
# keeps a `radius: 0` 1pt drop, which is a text-edge trick rather than a blurred
# shadow and was present in both arms of the measurement. `.compositingGroup()`
# sitting under a `.shadow(...)` is the exact shape that was removed — the
# group made the whole button one compositing unit so the two shadows could
# stack without fringing the gloss.
if re.search(r'\.compositingGroup\(\)\s*\n\s*\.shadow\(', button):
    failures.append(
        'InstrumentControls.swift: InstrumentButtonBody is back to '
        '`.compositingGroup()` + `.shadow(...)` for its plate. On the provider '
        'directory (deep scroll, 19 s) that costs 759 frames — 66.6 fps vs '
        '108.6 fps — because the button is the most-repeated component in the '
        'app. Keep it on `LayerShadow`; the tinted second shadow goes in as '
        '`underColor`/`underOpacity`.')
if 'LayerShadow(' not in button:
    failures.append(
        'InstrumentControls.swift: InstrumentButtonBody no longer applies '
        '`LayerShadow`. The plate keeps its two shadows (black over the tinted '
        'one) — deleting them is not the fix.')
if 'underColor' not in button:
    failures.append(
        'InstrumentControls.swift: InstrumentButtonBody lost the tinted second '
        'shadow. `filled` buttons pair a black shadow with `tint.opacity(0.18)`; '
        'that pair is what reads as a plate lit from above.')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}', file=sys.stderr)
    sys.exit(1)

print('PASS: the tile surface\'s drop shadow is layer-backed (with a shadowPath, '
      'non-hit-testable, flipped), and the panel surface keeps its SwiftUI '
      'shadow — the swap is worth 1.9x on a card and nothing on a panel')
