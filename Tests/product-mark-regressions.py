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
   Cursor is the same lesson a second time: it spent months as an **SF Symbol**
   (`cursorarrow.motionlines` — a pointer with speed lines), which is not Cursor's
   logo, and no tint or size makes a symbol into one. All three families are
   rendered below, so a family that regresses to a glyph has nowhere to hide.
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
import re
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
# `claudebar` has no LobeHub source: it is derived from the app icon by its own
# script, which the generator then normalises like the other three. Run the
# derivation first, and pin the *chain* — a generator that normalised a missing
# or stale source would otherwise pass while drawing the fallback glyph.
deriver = root / 'Tools/make-claudebar-mark.py'
assert deriver.is_file(), (
    'Tools/make-claudebar-mark.py is missing — the ClaudeBar mark for the 第三方 '
    'tally is derived from the app icon, and nothing else can regenerate it')
result = subprocess.run([sys.executable, str(deriver), '--check'],
                        cwd=root, capture_output=True, text=True)
assert result.returncode == 0, (
    'the ClaudeBar mark no longer matches the app icon:\n'
    + result.stdout + result.stderr)
result = subprocess.run([sys.executable, str(generator), '--check'],
                        cwd=root, capture_output=True, text=True)
assert result.returncode == 0, (
    'the committed tile glyphs do not match their sources:\n'
    + result.stdout + result.stderr)

# --- 2. The ink direction, measured on the files themselves -----------------
#
# This is the assertion that would have caught the two rounds of "the island's
# icons are black". The mapping in `ProductBrandMark.dark` picks a *file* by the
# page the mark stands on, and the two files are one ink each; the names are
# about the backdrop, not the glyph, which is the opposite of the intuition and
# was inverted in shipped code twice. So the ink is read off the committed PNGs
# and the *direction* is pinned: `-dark` must be the light ink (it is named for
# the dark page it is drawn on), `-light` the dark ink.
from PIL import Image
import numpy as np

BUNDLE = root / 'Sources/BrandAssets'
for brand in ('anthropic', 'openai', 'cursor', 'claudebar'):
    inks = {}
    for variant in ('dark', 'light'):
        image = Image.open(BUNDLE / f'{brand}-{variant}.png').convert('RGBA')
        alpha = np.array(image)[:, :, 3]
        opaque = alpha > 200
        assert opaque.sum() > 1000, f'{brand}-{variant} has no opaque ink to measure'
        inks[variant] = float(np.array(image)[:, :, :3][opaque].mean())
    assert inks['dark'] > 200, (
        f'{brand}-dark measures a mean ink of {inks["dark"]:.0f}/255 — it must be the '
        'LIGHT ink, because it is the file drawn on a dark page. If this asset was '
        'replaced with dark artwork, invert `ProductBrandMark.dark` and the widget '
        'together, and update the 眼见 note there; do not "fix" it per call site.')
    assert inks['light'] < 55, (
        f'{brand}-light measures a mean ink of {inks["light"]:.0f}/255 — it must be the '
        'DARK ink, because it is the file drawn on a light page.')
    assert inks['dark'] - inks['light'] > 180, (
        f'{brand}: the two variants must be opposite inks, measured '
        f'{inks["dark"]:.0f} vs {inks["light"]:.0f}')

# The call sites must agree with that direction: a surface that is black in both
# themes passes `page: true` (the `-dark`, light-ink file), and a light one
# passes `page: false`. The island is the case that regressed, so it is pinned
# by name rather than left to the render sweep.
island = (root / 'Sources/ClaudeBar/Views/Island/IslandComponents.swift').read_text()
# The doc comment above the type also spells `page: true`, so count the *calls*.
island_calls = [line for line in island.splitlines() if 'ProductBrandMark(' in line]
assert len(island_calls) == 3, f'expected three island mark calls, found {len(island_calls)}'
for line in island_calls:
    assert 'page: true' in line, (
        'each of the island badge\'s three families must pass `page: true` — the island '
        'is black in both themes, so it needs the light (`-dark`) ink file: ' + line.strip())
assert 'page: !' not in island, \
    'the island must not invert a ground flag; state the ground directly'

# --- the island does not caption its split bar -------------------------------
#
# The 本月 line carried a four-entry legend (three client marks plus the app's
# own) in front of the split bar. It was removed on 2026-09-27 because it did not
# fit — measured on the shipped build it pushed the pace label to `上月同期…` with
# its figure sliced off — and because the bar beside it, which is already
# `UsageSource.allCases` in each source's colour with a `.help` tooltip naming
# every source and figure, already said the same thing.
#
# Pinned so the legend cannot come back without the line being re-measured: the
# fix was to delete it, not to shrink it, and a future edit that re-adds four
# captions here would truncate the pace again. See `IslandUsageCard.monthLine`.
assert 'UsageSourceMark' not in island, (
    'the island must not caption its usage line — the legend was removed because '
    'it truncated the pace reading, and the split bar already names its sources '
    'on hover')
assert 'IslandSourceSplit(values: usage.monthBySource)' in island, (
    'the split bar is what answers "which client made this month"; it must stay')
assert 'fixedSize()' in island.split('private var monthLine')[1][:2600], (
    'the pace is the widest text on the month line and must be `.fixedSize()`, so '
    'it is never the part that yields to the layout')

# --- UsageSourceMark still names a mark for every source ---------------------
#
# Not the island's legend any more, but the mapping is still what makes the
# Traffic page's source chips total — and it is where 第三方 got artwork. A
# regression to the old `Bool?` would drop the third family again.
uiverse = (shared / 'UiverseKit.swift').read_text()
for needle in ('ProductBrandMark.Brand {', 'case .thirdParty: return .claudebar'):
    assert needle in uiverse, (
        'UsageSourceMark.brand(of:) must be total and name a mark for every '
        f'source, including 第三方: missing {needle!r}')
assert 'ProductBrandMark(brand: Self.brand(of: source)' in uiverse, (
    'UsageSourceMark must pass the returned Brand through — the old spelling took '
    'a `Bool?` and dropped the third family')

# --- no themed call site forgets the tile it stands on -----------------------
#
# The second reported bug (twice): a mark drawn on the island's black card while
# still painting its own `Theme.bgSecondary` tile — a near-white square. Every
# call that states a ground for the *ink* has to state one for the *tile* too,
# because the two questions have the same answer. A `page:` without a `well:`
# on the same call is that bug's shape.
offenders = []
for path in sorted(root.glob('Sources/**/*.swift')):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if 'ProductBrandMark(' not in line:
            continue
        # The call can wrap; take the line and the next two as one statement.
        window = ' '.join([line] + path.read_text().splitlines()[number:number + 2])
        if 'page:' in window and 'well:' not in window:
            offenders.append(f'{path.relative_to(root)}:{number}: {line.strip()}')
assert not offenders, (
    'a call that passes `page:` states the ground for the ink and must state it '
    'for the tile as well (`well:`) — otherwise the mark paints a `bgSecondary` '
    'square on a ground that is not one:\n  ' + '\n  '.join(offenders))

# --- a light page must never take the white-ink file on its own tile ---------
#
# The bug this pins, reported from the shipped build as "这颜色还是看不清啊":
# the greeting card passed `well: palette.isLightGround` (true on the ice
# canvas) together with `page: palette.isLightGround` (true), which selected the
# WHITE `-dark` ink to draw on the WHITE `bgSecondary` tile the same call had
# just asked for. Measured off the user's own screenshot, the glyph sat at
# **1.13:1** against the tile it stood on and the tile at 1.24:1 against the
# card: three near-white values stacked, and the mark read as a blank chip.
#
# `page: true` means "white ink"; it is only ever correct when the thing behind
# the artwork is dark. Two shapes are therefore wrong by construction, and both
# are checked here across every call site rather than at the one that regressed:
#
#   - `page: true` together with `well: true`  -> white ink on the light tile
#   - `page:`/`well:` fed the SAME expression   -> the two questions have
#                                                 opposite answers on a light
#                                                 ground, so one must be wrong
#
BAD_PAIRS = ('page: true, well: true', 'well: true, page: true')
mispaired = []
for path in sorted(root.glob('Sources/**/*.swift')):
    text = path.read_text()
    for number, line in enumerate(text.splitlines(), 1):
        if 'ProductBrandMark(' not in line:
            continue
        window = ' '.join([line] + text.splitlines()[number:number + 3])
        flat = ' '.join(window.split())
        for pair in BAD_PAIRS:
            if pair in flat:
                mispaired.append(
                    f'{path.relative_to(root)}:{number}: `{pair}` — the tile the '
                    'mark paints is `bgSecondary`, which is LIGHT in light mode, '
                    'so white ink disappears into it')
        # Same expression for both parameters: `well: X, page: X`.
        for well_arg, page_arg in re.findall(r'well:\s*([^,)]+?)\s*,\s*page:\s*([^,)]+)',
                                             flat):
            if well_arg.strip() == page_arg.strip():
                mispaired.append(
                    f'{path.relative_to(root)}:{number}: `well:` and `page:` are '
                    f'both `{well_arg.strip()}` — they answer different questions '
                    '(may the mark paint its own light tile / what ink can the '
                    'ground carry) and on a light ground their answers are '
                    'opposite, so passing one expression to both is wrong')

assert not mispaired, (
    'a mark is drawn in an ink that cannot be read on the tile it paints:\n  '
    + '\n  '.join(mispaired))

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
    /// Mirrors the app's `Theme.Ink`. Its members are the only thing the mark's
    /// missing-asset fallback reads, so this stub must grow whenever that
    /// fallback learns a family — `cursor` was added with the third mark, and a
    /// stub that lags it fails to compile rather than testing nothing. A nested
    /// type (not a static `let`) so `Theme.Ink.codex` parses the way it does in
    /// the app.
    enum Ink {
        static let claude = Color(hex: 0x1D4FB8)
        static let codex = Color(hex: 0x5F6368)
        static let cursor = Color(hex: 0x7A34B8)
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
        // All three families, not just the two the mark started with: Cursor
        // joined the mark on 2026-09-27 (it had been an SF Symbol, which is the
        // wrong shape for a logo), and its artwork is the one whose ink/margin
        // nobody had measured before.
        for (index, brand) in [ProductBrandMark.Brand.claude, .codex, .cursor, .claudebar].enumerated() {
            for (si, side) in [13.0, 15.0, 22.0, 26.0, 38.0].enumerated() {
                let renderer = ImageRenderer(content: ZStack {
                    Color.white
                    ProductBrandMark(brand: brand).frame(width: side, height: side)
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
    for ci, codex in enumerate([False, True, None, 'claudebar']):
        for si, side in enumerate([13.0, 15.0, 22.0, 26.0, 38.0]):
            tile, ink_w, ink_h = measure(shots / f'{ci}-{si}.png')
            assert abs(tile - side) < 0.3, \
                f'a {side}pt mark must draw a {side}pt well, measured {tile:.1f}pt'
            share = ink_w / side
            family = {False: "CC", True: "Codex", None: "Cursor",
                      'claudebar': "ClaudeBar"}[codex]
            assert 0.55 <= share <= 0.68, (
                f'{side}pt {family}: the mark spans {share:.0%} of its '
                f'tile; it must sit between 55% and 68% (measured {ink_w:.2f}pt of {tile:.1f}pt). '
                'Under 55% is the smudge the raw LobeHub margin produced (65% of the '
                'already-inset artwork box); over 68% the mark starts to crowd the '
                "well's own corner radius.")
            widths.setdefault(side, {})[codex] = ink_w
            heights.setdefault(side, {})[codex] = ink_h
            shares.append(share)

    # The knot is square, the "A\" is wide-and-short and Cursor's cube is taller
    # than it is wide, so a shared *width* is the invariant that keeps a chip of
    # any family the same size as its neighbours in one row.
    for side, family in widths.items():
        cc = family[False]
        for name, other in (("Codex", family[True]), ("Cursor", family[None]),
                            ("ClaudeBar", family['claudebar'])):
            assert abs(cc - other) <= max(0.6, side * 0.04), (
                f'at {side}pt the CC mark stands {cc:.2f}pt wide and {name} {other:.2f}pt — '
                'the families must read the same size in one row')

    # Ink must scale with the tile, not be a fixed pt inset.
    small = widths[13.0][False] / 13.0
    large = widths[38.0][False] / 38.0
    assert abs(small - large) < 0.03, \
        f'the mark must scale with its tile ({small:.0%} at 13pt vs {large:.0%} at 38pt)'

    print('PASS: ProductBrandMark draws the bundled Anthropic / OpenAI / Cursor marks — '
          'and the app\'s own rings for 第三方 — in a well at '
          f'{len(shares)} sizes; ink spans {min(shares):.0%}–{max(shares):.0%} of its tile; '
          'all four families stand the same width; both generators reproduce the '
          'committed assets')
