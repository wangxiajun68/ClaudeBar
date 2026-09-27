#!/usr/bin/env python3
"""The CC / Codex tiles: real brand ink, normalised, legible on their well.

Three things are one edit away from silently regressing, and none of them can be
seen by reading the Swift:

1. **The artwork is the brand, not a redraw.** `ProductBrandMark` must decode a
   bundled PNG. This file replaced a hand-drawn `Canvas` pair (a twelve-ray
   sunburst for CC, a scalloped blob with a terminal chevron for Codex) whose
   own doc comment recorded that they were "recognisable-*ish* and neither was
   the brand mark". A future edit that goes back to drawing paths by eye fails
   the first assertion below rather than shipping a plausible-looking blob.
2. **The mark fills its tile.** Raw LobeHub PNGs carry their own margin to the
   edge of a square canvas — measured on the bundled files that is 33.5pt of a
   13pt header tile for Anthropic and 32.5pt for OpenAI, so both marks were
   drawn at ~65% of an already-small tile and read as a smudge. This measures the
   committed assets and the *rendered* tile, because a tile that renders 65% ink
   passes every structural check while looking wrong to a user.
3. **The two families stand the same size.** Anthropic's mark is nearly twice as
   wide as it is tall; OpenAI's is square. Fitting each to its own box would put
   a visibly smaller knot beside the "A\\", which is what a CC chip and a Codex
   chip in one row would show.

Renders through the real `ProductBrandMark` with `ImageRenderer`, then measures
the PNG — the path a screenshot takes, and the only one that sees what the user
sees.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
shared = root / 'Sources/ClaudeBar/Views/Shared'
mark = (shared / 'ProductBrandMark.swift').read_text()

# --- 1. The mark is bundled brand artwork -----------------------------------
assert 'Image(nsImage: image)' in mark, \
    'ProductBrandMark must draw the bundled brand PNG'
assert 'Canvas' not in mark, \
    'ProductBrandMark must not go back to hand-drawn geometry'
for needle in ('"openai"', '"anthropic"'):
    assert needle in mark, f'ProductBrandMark must name the {needle} asset'
assert 'Bundle.main.resourceURL' in mark, \
    'the assets must load from the app bundle'

# --- The generator owns the normalisation, and it is re-runnable ------------
generator = root / 'Tools/gen-brand-marks.py'
assert generator.is_file(), 'Tools/gen-brand-marks.py is missing'
result = subprocess.run([sys.executable, str(generator), '--check'],
                        cwd=root, capture_output=True, text=True)
assert result.returncode == 0, (
    'the committed CC / Codex tile glyphs do not match their LobeHub sources:\n'
    + result.stdout + result.stderr)

# --- The build ships them ----------------------------------------------------
build = (root / 'Sources/build.sh').read_text()
assert 'BrandAssets' in build, 'Sources/build.sh must copy Sources/BrandAssets into the bundle'
assert 'ProductBrandMark.swift' in build or 'require_file' in build

# --- 2/3. Render every size the app draws, in both themes -------------------
probe = r'''
import SwiftUI
import AppKit

struct Theme {
    static let isDark = false
    static let bgSecondary = Color(hex: 0xF7FAFC)
    /// Mirrors the app's `Theme.Ink`, whose two members are the only thing the
    /// mark's missing-asset fallback reads. A nested type (not a static `let`)
    /// so `Theme.Ink.codex` parses the way it does in the app.
    enum Ink {
        static let claude = Color(hex: 0x1D4FB8)
        static let codex = Color(hex: 0x5F6368)
    }
}
extension Color {
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
struct InstrumentBadge: View {
    enum Kind { case config, sessions }
    let kind: Kind
    var size: CGFloat
    var tint: Color
    var body: some View { EmptyView() }
}
<<<MARK>>>

@main struct Probe {
    @MainActor static func main() {
        _ = NSApplication.shared
        ProductBrandMark.resourceRoot = URL(fileURLWithPath: CommandLine.arguments[1])
        let out = URL(fileURLWithPath: CommandLine.arguments[2])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (index, codex) in [false, true].enumerated() {
            for (si, side) in [13.0, 15.0, 22.0, 26.0, 38.0].enumerated() {
                let renderer = ImageRenderer(content: ZStack {
                    Color.white
                    ProductBrandMark(codex: codex).frame(width: side, height: side)
                }.frame(width: 64, height: 64))
                renderer.scale = 8
                guard let cg = renderer.cgImage else { fatalError("no image") }
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])!
                    .write(to: out.appendingPathComponent("\(index)-\(si).png"))
            }
        }
        print("rendered")
    }
}
'''.replace('<<<MARK>>>', mark)

with tempfile.TemporaryDirectory(prefix='claudebar-product-mark-') as folder:
    folder = Path(folder)
    source = folder / 'Probe.swift'
    source.write_text(probe)
    binary = folder / 'probe'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)],
                   check=True, capture_output=True, text=True)
    shots = folder / 'shots'
    subprocess.run([str(binary), str(root / 'Sources/BrandAssets'), str(shots)],
                   check=True, capture_output=True, text=True)

    from PIL import Image
    import numpy as np

    SCALE = 8.0
    WELL = np.array([0xF7, 0xFA, 0xFC])

    def measure(path):
        """(well span, ink width, ink height) in points.

        The well is `Theme.bgSecondary` on a white page, so its own edge is the
        boundary: an exact colour match ignores the antialiased rim, and a
        *tight* tolerance is what keeps the page (white) out of the box.
        """
        a = np.array(Image.open(path).convert('RGB')).astype(int)
        is_well = np.abs(a - WELL).sum(axis=2) < 8
        ys, xs = np.where(is_well)
        assert xs.size, 'the mark must draw its well'
        x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
        box = a[y0:y1 + 1, x0:x1 + 1]
        # Ink is dark and opaque: the black SVG on the light well.
        ink = box.sum(axis=2) < 320
        iy, ix = np.where(ink)
        assert ix.size, 'the well must carry the mark'
        ink_w = (ix.max() - ix.min() + 1) / SCALE
        ink_h = (iy.max() - iy.min() + 1) / SCALE
        return (x1 - x0 + 1) / SCALE, ink_w, ink_h

    widths, heights, shares = {}, {}, []
    for ci, codex in enumerate([False, True]):
        for si, side in enumerate([13.0, 15.0, 22.0, 26.0, 38.0]):
            tile, ink_w, ink_h = measure(shots / f'{ci}-{si}.png')
            assert abs(tile - side) < 0.3, \
                f'a {side}pt mark must draw a {side}pt well, measured {tile:.1f}pt'
            share = ink_w / side
            assert 0.55 <= share <= 0.68, (
                f'{side}pt {"Codex" if codex else "CC"}: the mark spans {share:.0%} of its '
                f'tile; it must sit between 55% and 68% (measured {ink_w:.2f}pt of {tile:.1f}pt). '
                'Under 55% is the smudge the raw LobeHub margin produced (65% of the '
                'already-inset artwork box); over 68% the mark starts to crowd the '
                "well's own corner radius.")
            widths.setdefault(side, {})[codex] = ink_w
            heights.setdefault(side, {})[codex] = ink_h
            shares.append(share)

    # The knot is square and the "A\" is wide-and-short, so a shared width is the
    # invariant that keeps a CC chip and a Codex chip in one row the same size.
    for side, pair in widths.items():
        cc, codex = pair[False], pair[True]
        assert abs(cc - codex) <= max(0.6, side * 0.04), (
            f'at {side}pt the CC mark stands {cc:.2f}pt wide and Codex {codex:.2f}pt — '
            'the two families must read the same size in one row')

    # Ink must scale with the tile, not be a fixed pt inset.
    small = widths[13.0][False] / 13.0
    large = widths[38.0][False] / 38.0
    assert abs(small - large) < 0.03, \
        f'the mark must scale with its tile ({small:.0%} at 13pt vs {large:.0%} at 38pt)'

    print('PASS: ProductBrandMark draws the bundled Anthropic / OpenAI marks in a well at '
          f'{len(shares)} sizes; ink spans {min(shares):.0%}–{max(shares):.0%} of its tile; '
          'CC and Codex stand the same width; the generator reproduces the committed assets')
