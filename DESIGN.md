# ClaudeBar visual language

CatStatus-class **status sheet**: ice canvas in light, graphite in dark. White
(or raised dark) cards, SF Rounded metrics. Color lives in charts and status.

## Canvas

- Light: ice `#EEF3F8`, white cards. Dark: `#16181C` canvas, `#252A31` cards.
- Switch in Settings or the popup moon/sun control. Not system-follow — two
  authored palettes.
- Popup and main window take `NSAppearance.aqua` / `.darkAqua` with an opaque
  fill — no dark vibrancy.

## Type

- Device / page titles: SF Rounded semibold 16–22.
- Hero metrics: SF Rounded 24–28, monospaced digits.
- Captions and pills: 11pt medium rounded.

## Color

| Role | Use |
| --- | --- |
| Chart green `#34C759` | CPU die, remaining quota |
| Chart blue `#5B9CFF` | GPU bars |
| Chart amber `#FF9F0A` | Memory line |
| Chart purple `#BF5AF2` | Usage heatmap / share bars |
| Ink / snow | Primary text in light / dark |

Claude / Cursor / Codex hues remain for identity chips only.

Every signal hue has two variants and they are not interchangeable: `Theme.Ink.*`
is the **text** version (mixed until it clears 4.5:1 on the ice canvas) and the
raw `chart*` / `status*` hue is the **shape** version. A glyph, a bar, a dot, a
ring and a card wash take the raw hue; a label, a pill, a count and a percentage
take the ink. A provider card's state therefore has both — `ProviderCardState.color`
for its badge and `.faceColor` for its wash and rings. Using one value for both
is how a state ends up readable in exactly one theme.

## Surfaces

One surface language, four parts (`Views/Shared/UiverseSurfaces.swift`), so a
card in one grid is the same object as a card in another:

1. **Base + accent wash** — `cardSurface`, then the card's own hue at 5–17 %.
   The wash is what makes a page of tiles scannable by row; it never moves under
   the pointer except by deepening.
2. **Inner frame ring** — a 1pt ring inset 3pt inside the card's own edge
   (`InnerFrameRing`, and `Theme.innerFrame` / `innerFrameMuted`). White on a
   tinted tile, an engraved hairline on a plain one.
3. **Depth lens** — up to three rings receding off one corner (`DepthLens`).
   They are **not concentric**: each shrinks *and* drifts toward the corner, and
   that drift is what reads as depth. One `Canvas` per card; they carry no
   glyph, because a card's mark belongs in its header where it stays legible and
   keeps its own accessible name.
4. **Edge + lift** — a hairline that lights up to the accent on hover, and a 2pt
   lift. Both are hover *state*, never a loop. A corner already occupied by
   content (a session tile's agent cluster) takes the hue and skips the lens.

`.tile()` is the grid-cell form and `.panelCard()` the page-level one; both
draw the same four parts. `.hoverTile()` is `.tile()` for a call site that has
no other use for the hover flag — never two `.onHover` regions for one target.

`SegmentedCapsule` is the one filter / chip control: a capsule well with one
sliding selection pill (`matchedGeometryEffect`), replacing the earlier "capsule
of loose capsules" where a four-item filter drew four cards inside an outer one.
It backs the connector type and platform filters, the provider client switcher
and category filter, the usage period tabs and the VPN group tabs.

`OrbitGauge` is a trim-based arc with a body riding it (the quota gauges);
`ConveyorBelt` is the travelling-tick strip used where a surface is *doing*
something continuous, so liveness is drawn rather than pulsed.

There is no rate-driven ornament on a machine mark, and the one that existed is
gone. `LoadRing` was a lit arc circling the tile's *small* glyph, turning at a
rate proportional to the tile's own percentage; it was removed, view and
decoration kind together. A ~96° arc at 22–28pt reads as a **spinner** — which
says "waiting", never what a working machine is doing — and it repeated a figure
already printed three lines below it, at a smaller size and a lower contrast.
The live reading belongs to the big mark on the right, drawn in the shape of the
hardware it describes.

## Machine marks

The 本机负载 strip (dashboard `ResourceStrip`, popup `MachineKpiStrip`) splits
the reading in two, and the split is the whole design:

- **The small icon in the tile header names the tile.** Nothing more. It used to
  carry a `LoadRing` — a ~96° arc orbiting the glyph at a rate proportional to
  the tile's own percentage — and that was two mistakes at once: a ~96° arc at
  22–28pt reads as a **spinner**, which means "waiting", and it repeated a figure
  printed three lines below it at a smaller size and a lower contrast. It is
  gone from the four machine tiles and from every cell of the popup's KPI strip,
  including the earbud cell it used to circle.
- **The big mark on the right is the reading**, drawn in the shape of the
  hardware it describes rather than around it.

| Tile | What the big mark is wired to |
| --- | --- |
| CPU | one cell per **logical core** (`HostStats.coreLoad`), each lit by that core's own busy fraction |
| GPU | one column per **graphics sub-unit** (`HostStats.gpuRenderers`), each filled to its own 0…100 reading |
| Memory | one well per **page category** (`memoryActive` / `memoryWired` / `memoryCompressed`), each normalised by physical memory |
| Disk | two wells, **used / free**, against capacity |
| Fan | the rotors, which say the same thing more literally |

The rule that keeps this a *reading* rather than a decoration:

1. **A cell is a measurement or it is not drawn.** Twelve cores draw twelve
   cells; a driver that publishes no sub-units draws one plate at the aggregate
   instead of inventing three. The sampler's first tick has no per-core baseline
   yet, so the die falls back to a single lit plate until the second one lands.
2. **Below 4 % a core is dark, and it stays drawn.** An idle machine must not
   glow — the same threshold discipline `SoftRotor` follows (`rpm >= 80`) — but
   the cell keeps a pale *socket*, so twelve cores stay countable at rest rather
   than the die emptying out. The two fills are opaque and far apart (≈120/255
   busy, ≈225/255 idle at tile size). An earlier version stacked two translucent
   tints over the die's gradient plate and the readings came out 6/255 apart:
   a mark that measured nothing while looking like a mark.
3. **The mark never contradicts the number above it.** The cells are the
   allocations the aggregate is already computed from, so the mean of the cells
   *is* the printed percentage (modulo per-sample rounding).
4. **Colour carries state, the mark carries load.** `StatusPill`, temperature
   and pressure still own the state readouts; nothing lights up because it is
   busy.

## Mark

Dock: three thick jade rings on a white ice card (blue / violet / green) over
a slim live bar. Menu-bar status item is a template **ring + bar**.

## Anatomy

1. **Switcher HUD** — session/proxy facts, then CC / Codex / VPN.
2. **Machine KPIs** — one connected strip in the popup. Dashboard is a 2×3
   resource grid (CPU / GPU / memory, disk / links / dual fans). Each fan
   rotor toggles max vs auto and spins at its own RPM; every other meter carries
   its reading in the *shape* of the hardware — a per-core die, per-sub-unit GPU
   columns, capacity wells. See **Machine marks** above.
3. **Sessions** — popup is one full-width column. Empty tool families omit.
4. **Usage** — model tokens only (heatmap, source triad, token mix, daily
   spark, model bars). VPN quota stays on the VPN page.
5. **VPN CTA** — dark sparkle pill. Live outbound path is a `›` breadcrumb,
   not a decorative metro line.
6. **Settings** — one control per grid tile, including theme.
7. **Connectors** — a header card (title, live counts, refresh, project picker)
   over a `SegmentedCapsule` type filter (插件 / Skills / MCP / 本机 CLI, each
   with its count), a second `SegmentedCapsule` for the platform (全部 / Claude
   Code / Codex / Cursor), and the search box. Tiles are fixed-height and
   adaptive; each names its type and keeps the state action visible. A sheet
   renders Skill Markdown, MCP tool metadata, or plugin contents; scrolling
   never expands or relays out a tile.
8. **Main navigation** — a centered white capsule floats over the continuous
   ice canvas; brand and live status stay outside it. At narrow widths tabs
   lose glyphs before labels, preserving the full destination list.

## Motion / performance

- Popup sections lift in once on open — never stagger inner cells. (The
  staggered `appearLift` pass is currently removed; the rule stands for
  whatever re-introduces a section entrance.)
- Traffic rates live on `VpnLiveRates` (4 Hz). Mosaic does not observe them.
- YAML sanitize + `networksetup` run off the main actor.
- Fan rotors are a Core Animation layer with one endless rotation retimed in
  place as RPM changes (`RotorLayerView.setSpeed`), so the blades never snap
  back to rest and the app does no per-frame work. Do not drive blades with
  `rotationEffect` on a SwiftUI view.
- Connector controls animate only on press, selection, focus, or an explicit
  state change. Inventory tiles stay lazy and fixed-height. They carry a hover
  shadow and a 1pt lift (`.tile()`), which is a hover *state* change, not a
  loop; reduce-motion removes both, and no tile animates while the grid scrolls
  under a stationary pointer.
- The depth lens and the inner frame ring are geometry, not animation: one
  `Canvas` and one stroked `RoundedRectangle` per card, drawn once. Rings on an
  unscrolled card cost nothing per frame.
- Two one-shot motions exist and both are gated on `surfaceIsVisible` **and**
  reduce-motion: the status-button shine (`ShineSweep`, a single 0.55 s sweep
  when hover begins) and the conveyor belt (`DecorativeMotion.kind == .conveyor`,
  a Core Animation layer). Neither repeats a SwiftUI animation.
- The machine marks are static `Canvas` geometry, redrawn only when the
  sampler publishes a new reading (every 2 s, 1 s while a window is frontmost,
  and the marks are inside the strip's own `.transaction { animation = nil }`
  so a tick repaints once rather than interpolating). Nothing about them runs
  per frame. The rate-driven `LoadRing` that used to sit behind each meter is
  gone: its five Core Animation layers were the strip's only per-frame cost, and
  what they bought — a spinner reading as "waiting" — was the wrong idea.
- The 3D card's tilt is a **hero** treatment, not part of `.tile()`: only
  `ConnectorCard` opts in via `.depthTilt()`, and only while that one card is
  hovered, so at most one subtree is ever rasterised in 3D. It stays off
  scrolling grids of 200 cards.
- The main navigation uses one static elevated surface; only tab hover and
  selection animate. No full-width material blur or scrolling tab strip.
