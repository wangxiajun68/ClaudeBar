# ClaudeBar visual language

CatStatus-class **status sheet**: ice canvas in light, graphite in dark. White
(or raised dark) cards, SF Rounded metrics. Color lives in charts and status.

Scope: this document describes the **app target** (`Sources/ClaudeBar`). The
WidgetKit extension (`Sources/Widget`) is compiled separately from only three
files and cannot reach `Theme` or any shared primitive, so it keeps its own
drawing; it is not a consumer of this language and is not covered by it.

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

There is no rate-driven ornament on a machine mark, and the two that existed are
gone. `LoadRing` was a lit arc circling the tile's *small* glyph, turning at a
rate proportional to the tile's own percentage; `InstrumentRing` was the same
idea redrawn as a conic ring around it. Both were removed, views and decoration
kind together. A ~96° arc — and a ring, whichever way its ink is laid out — at
20–28pt reads as a **spinner**, which says "waiting", never what a working
machine is doing, and both repeated a figure already printed three lines below at
a smaller size and a lower contrast.

That rule is about *small* glyphs. It is not a rule against motion, and it is not
a rule about **rings as such**: an arc that encodes one reading is the honest
shape for that reading, and the machine marks below use them. What it rules out is
a rotating or ringed ornament standing where a caption belongs.

The live reading belongs to the mark on the right: Lucide's icon for the part,
with its own lane of bars beneath.

## Controls

The surface language above says what a card *is*; this says what a control does
when touched. Both live in `Views/Shared/` and both answer the same two rules —
motion is a one-shot state change or a gated Core Animation layer, and every
ornament is one shape rather than a stack of views.

| Control | Reference | What it is |
| --- | --- | --- |
| `InstrumentField` / `InstrumentWell` / `InstrumentFieldStyle` | `metanef` switch track | the **one** field surface: a recessed well (`Theme.fieldWell`), a lit accent rim on focus, and the same inner frame ring the tiles wear. Search boxes, ports, rates, filters and every provider input are this box. `InstrumentWell` is its surface alone, for a control *drawn* as a field but not typed into (an API key's read state, the model selector); `InstrumentField` is one line delegating to it. The providers directory's second search field is a thin alias. |
| `InstrumentToggleStyle` | `metanef` switch | the **one** switch: an engraved inset track with a lit bottom edge, and a plated handle that widens toward the side it would travel to on hover. Backs all 16 toggles in the app. |
| `SegmentedCapsule` | `mymiamo` glass menu | the one filter / segmented control, with one sliding pill. Backs the connector type and platform filters, the provider client switcher and category filter, the usage period tabs, the VPN group tabs, and the three settings pickers. |
| `PerimeterSweep` | `ultimate-3d-btn::before` | a lit arc travelling a control's **own** perimeter, once, on hover only. Never a loop: a permanent rotating border is per-frame chrome and stops meaning anything. |
| `GroundShadow` | `stat-widget` `.ground-shadow` | the soft ellipse that appears under a control with its hover lift, so the pair says "picked up". |
| `SourceTriad` / `UsageDaySpark` / `TokenMixStrip` | `NK2552003` stat card | the **one** bar-chart card: vertical bars keeping the reference's own two-stop gradient, its top cap dot and its average guide line. `UsageDaySpark` is the seven-bucket period chart; `SourceTriad` is the three-meter share card; `TokenMixStrip` is the stacked token-mix track. One bar shape across all three, so the usage page reads as one card family rather than three charts that happen to be adjacent. |
| `StandbyEmptyState` | — | the one empty state: an inline row, or a centred block with a caption and an action. Replaced five different empty states. |

Two reference elements are deliberately **not** translated, and the reason is
scale rather than taste:

- The 3D button's glitch text and click shockwave. A glitch on a native macOS
  control reads as a rendering fault, not as intent, and the ripple is a touch
  metaphor with no pointer analogue. The perimeter sweep already carries the
  part worth keeping — "this control is live, and the pointer arrived".
- The deep machine-faceplate toggle. A 2.5D plated switch with glow trails is a
  *hero* control; every switch in this app is one row of a settings tile, and
  the `metanef` track is the honest translation at that size.

`HairlineDivider` is the only rule; a native `Divider()` is a different grey in
light and dark and belongs to no family. `SectionHeader` is the only section
heading and `StatusPill` the only capsule readout.

## Machine marks

The 本机负载 strip (dashboard `ResourceStrip`, popup `MachineKpiStrip`) draws each
meter as **two stacked lanes**, and the split is the design:

- **The icon says which part it is.** These are **Lucide's own icons** —
  `cpu`, `gpu`, `memory-stick`, `hard-drive` — converted from Lucide's upstream
  SVGs into `Views/Shared/LucideHardwareGeometry.swift` by
  `Tools/gen-lucide-hardware.py`. Lucide is already vendored for the GPU and VPN
  marks (`Sources/Licenses/Lucide.txt`); using its real geometry is what makes
  these read as designed. Four silhouettes hand-authored on a Canvas — the
  previous attempt — were recognisable-ish and plainly amateur, because inventing
  curve geometry by eye does not produce designed curves.
- **The lane beneath says how busy it is**, in one bar per unit: per logical core
  (CPU), per graphics sub-unit (GPU), per area (内存 / 硬盘). A bar's *height* is
  its own reading, so the shape of the row is the shape of the load.

The two are separate lanes on purpose. The first attempt squeezed the reading
*inside* the artwork and the two fought: bars crossed the GPU's port circles and
the DIMM's chip windows. Giving the reading its own lane keeps the icon legible
as an icon and the reading legible as a reading.

| Tile | Bars |
| --- | --- |
| CPU | one per **logical core** (`HostStats.coreLoad`) — 12 cores is 12 countable bars |
| GPU | one per **graphics sub-unit** (`HostStats.gpuRenderers`), each at its own 0…100 |
| 内存 | one per **page category** (`memoryActive` / `memoryWired` / `memoryCompressed`) |
| 硬盘 | used / free |
| 风扇 | the rotors, which say the same thing more literally |

The rules that keep this a *reading* rather than a decoration:

1. **The lane moves, and only when there is something to say.** A light sweep
   crosses each bar at a rate proportional to the tile's own figure — 2.9 s per
   sweep at idle-ish, 0.6 s at full — so the strip is visibly working. **Below
   4 % it stops** (the `LucideRotor` discipline, `rpm >= 80`), and Reduce Motion
   or an off-screen surface stops it too. The sweep is derived from absolute time,
   so a load change speeds it up rather than restarting it, and it is driven by
   `TimelineView` inside the mark rather than by a second timer.
2. **A bar is a measurement or it is not drawn.** Twelve cores draw twelve bars;
   a driver that publishes no sub-units draws one bar at the aggregate instead of
   inventing three. The sampler's first tick has no per-core baseline, so the lane
   shows the aggregate until the second one lands.
3. **Two opaque, far-apart fills.** A busy unit is ink; an idle unit is a pale
   stub that still keeps its slot, so twelve cores stay countable at rest. An
   earlier version stacked two translucent tints over a gradient plate and the
   reads came out 6/255 apart — a mark that measured nothing while looking like
   one.
4. **Colour carries state, the mark carries load.** `StatusPill`, temperature and
   pressure own the state readouts; nothing lights up because it is busy.

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

## Numbers

Every figure that can change — a count, a percentage, a token total, a rate, a
delay, a selection tally — rolls per digit with the island's own effect:
`monospacedDigit()` + `.contentTransition(.numericText())`, and **no** implicit
`.animation(_:value:)`.

- One definition, two spellings, in `Views/Shared/Interaction.swift`:
  `View.rollingNumber()` (the common method) and `RollingNumberText(_:)` (the
  same transition, so a call site reads as a *figure*). Both route through the
  one modifier; there is no second implementation.
- Apply it to the **leaf** that renders the digits — a bare `Text`, or a
  `Label` whose title is a number — never to a container, and never to a whole
  island/panel. A figure inside a sentence takes it too: `.numericText` rolls
  only the digit glyphs, so the surrounding copy stays put.
- Do not reach for a raw `.contentTransition(.numericText())` at a call site:
  that is the duplicate this replaces.
- Do not add `.animation(_:value:)` beside it. The value changes every poll, so
  an implicit animation leaves a transaction permanently in flight and every
  display cycle re-lays out the whole hosting view. `.numericText` *is* the
  animation. (`Tests/inflight-animation-regressions.py`.)
- Static copy — paths, version strings, model names, a count computed once for
  a confirmation sentence — stays plain: there is nothing to roll.

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
- The machine marks are `Canvas` geometry, redrawn only when the sampler
  publishes a new reading (every 2 s, 1 s while a window is frontmost) — but the
  sweep across their reading lanes is driven by a `TimelineView` at 30 Hz, paused
  by the same three-way gate as every other ornament: the reading (below 4 % the
  mark is still), `surfaceIsVisible`, and reduce-motion. So an idle machine
  animates nothing, and a visible one pays for one canvas redraw per 33 ms, not
  for a view graph. The rate-driven `LoadRing` that used to sit behind each meter
  is gone: its five Core Animation layers were the strip's only per-frame cost,
  and what they bought — a spinner reading as "waiting" — was the wrong idea.
- Overview fan instruments use native SF Symbols within a quiet
  neutral ring. Core Animation retimes rotation in place as RPM changes;
  below 80 RPM, off-screen, and Reduce Motion all stop the rotation.
  The fan buttons directly toggle max / auto; the rest of the tile opens details.
  Detail-panel turbines use circular crops from the internal illustration.
  Internals use a bundled detailed vector-style PNG illustration. It is a
  conceptual overview, not an exact host-specific board map or a true SVG.
  Both illustrated fans animate independently using the shared turbine crops.
- The 3D card's tilt is a **hero** treatment, not part of `.tile()`: only
  `ConnectorCard` opts in via `.depthTilt()`, and only while that one card is
  hovered, so at most one subtree is ever rasterised in 3D. It stays off
  scrolling grids of 200 cards.
- The main navigation uses one static elevated surface; only tab hover and
  selection animate. No full-width material blur or scrolling tab strip.
