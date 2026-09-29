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
   lift. Both are hover *state*, never a loop. The lift moves the card's own
   frame, so the hit shape is pinned to the **unlifted** geometry (`.contentShape`
   before the `.offset`) — otherwise a pointer parked on the card's bottom edge
   is carried out of the card by the rise and back, once per frame. A full-width
   **page band** opts out of the lift entirely (`PageHeaderCard` → `lift: false`):
   its controls sit in the lower half and there is one band per page, so the rise
   buys nothing and only widens the strip that can oscillate. The same band also
   skips the lens: a ring stack cropped into a one-control-tall strip reads as a
   broken circle and runs through the buttons. A corner already occupied by
   content (a session tile's agent cluster, a provider directory card) takes the
   hue and skips the lens.

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
| `InstrumentToggleStyle` | `metanef` switch | the **one** switch: an engraved inset track with a lit bottom edge, and a plated handle that travels on the state change. Backs all 16 toggles in the app. The handle **does not stretch** toward its destination on hover — that is geometry moving because the pointer arrived, and the control already states its state; the hover is a lit rim instead. |
| `ActionButton` | reference CSS pill + `ultimate-3d-btn` | **the one push button**, named by *intent* rather than appearance: `tone:` (`.sparkle` the default, `.neutral` / `.accent` / `.destructive`), `emphasis:` (`.primary` fills solid — one per page at most), `metrics:` (`.regular` / `.large`). Every labelled action in the app is this. `.sparkle` is the **dark plate** (`SparklePlate`): a near-black pill whose identity *is* its own surface, so it does not tint from the caller's hue — it was ported from a reference CSS button (`#1C1A1C`, hover gradient `#A47CF3 → #683FEA`, glow `#9917FF`, 450 ms ease-in-out, hence `Theme.Animation.sparkle`). `.neutral` draws the quiet machined plate instead, for a button that must not punch a dark hole in a card. |
| `InstrumentButtonStyle` / `ProviderActionStyle` | `ultimate-3d-btn` | the two **historical spellings** of the same button, kept because those call sites pass them positionally. Each forwards to `ActionPlateButtonStyle`, so a connector button, a provider card's button and a native `ActionButton` are the same plate and cannot drift. `adaptiveGlassButton()` is gone — see the note below the table. |
| `ChipButton` | `mymiamo` glass menu | a compact *selectable* chip — a state you flip, not an action you fire. Radius 8 rather than a capsule, so a filter row does not read as a row of buttons. |
| `SegmentedCapsule` | `mymiamo` glass menu | the one filter / segmented control, with one sliding pill. Backs the connector type and platform filters, the provider client switcher and category filter, the usage period tabs, the VPN group tabs, and the three settings pickers. |
| `headerControl()` | `metanef` switch track | **the page band's own control** — now literally `ActionPlateButtonStyle` at the band's proportions, in the quiet tone. Shared by 连接器 and 模型 so two bands read as the same object. |
| `InstrumentMenuLabel` | `mymiamo` glass menu | the same well for a `Menu`'s own label (settings 打开方式, proxy upstream). It is a *label*: the native menu inside a machined tile is Aqua chrome, so this draws the well, the hover rim and the chevron and leaves the press state to the `Menu` that owns the button. |
| `PerimeterSweep` | `ultimate-3d-btn::before` | a lit arc travelling a control's **own** perimeter, once, on hover only. Never a loop: a permanent rotating border is per-frame chrome and stops meaning anything. |
| `GroundShadow` | `stat-widget` `.ground-shadow` | the soft ellipse that appears under a control with its hover lift, so the pair says "picked up". |
| `SourceTriad` / `UsageDaySpark` / `TokenMixStrip` | `NK2552003` stat card | the usage page's three cards, one shape family. `UsageDaySpark` is the **rhythm** chart: one column per bucket at the grain of the selected range (日 → that week by day, 月 → each calendar day, 年 → twelve months, 全部 → months, or years past a two-year span), keeping the reference's two-stop gradient, its top cap dot on the peak and its dashed average guide. `SourceTriad` is the **share** track — one full-width segmented bar where a segment's width *is* its share of the period, with the absolute count on a row beneath (free-floating meters let a 99/1 split and a 50/50 split draw the same picture). `TokenMixStrip` is the stacked input/hit/write/output track. All three spring once when the range changes and stay put when a total ticks inside it. |
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

**`adaptiveGlassButton()` is gone**, and so is the habit behind it. It was the
name of the one push button for two generations of this design — Liquid Glass,
then a bordered system button, then a machined pill — and every one of those was
a *description of an appearance* rather than an intent, which is why the same
page could end up with two button languages: the alias had no opinion about what
a given button was **for**, so callers supplied one through
`prominent:` / `filled:` / `ink:` and a tint that happened to equal
`Theme.statusError`. `ActionButton` asks the question the page actually has
(`tone:` = what is this, `emphasis:` = is it the default), so "which button
style" is decided once, next to the plate. The ~40 migrated call sites read
`ActionButton("刷新")`, `ActionButton("清空", tone: .destructive)`,
`ActionButton("导入选中 (N)", tone: .accent, emphasis: .primary)`.

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
   so a load change speeds it up rather than restarting it, and it is a
   `CAGradientLayer` per busy bar (`ReadingSweep`) rather than a second timer or
   a `TimelineView` — see Motion / performance.
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
  publishes a new reading (every 2 s, 1 s while a window is frontmost). The
  sweep across their reading lanes is **not** a schedule: each busy bar carries
  one `ReadingSweep` `CAGradientLayer`, translated by the render server at a
  rate proportional to that bar's own figure, so the app runs no per-frame
  layout. It is gated the same three ways as every other ornament — the reading
  (below 4 % the mark is still), `surfaceIsVisible`, and reduce-motion — and a
  new reading keeps the phase instead of restarting it. An idle machine animates
  nothing, and a visible one pays for a canvas redraw per sampler tick, not for
  a view graph. **Do not put this back on a `TimelineView`**: §11 of the UI
  audit measured that the cost of an `.animation`-scheduled timeline is the
  *schedule*, not the pixels — it lays the whole hosting view out on every
  display cycle, and lowering the frame rate does not help. The rate-driven
  `LoadRing` that used to sit behind each meter is gone too: its five Core
  Animation layers were the strip's only per-frame cost, and what they bought —
  a spinner reading as "waiting" — was the wrong idea.
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

## Greeting sky window

This component-level extension belongs to `GreetingCard` and its Metal
atmosphere (`Views/Shared/Atmosphere/`). The app's ice / graphite visual
language remains the global system. This surface frames a handwritten greeting
in an atmospheric sky, with corner instruments and one glass dock along the
bottom.

- **Typography:** the greeting is drawn from CoreText glyph outlines by
  `GreetingScript`, in one of **24 selectable script faces** (设置 → 通用 →
  天气与问候 → 问候字体). Twenty are bundled in `Resources/Fonts` (SIL OFL 1.1 /
  Apache 2.0, each licence beside its file — see `ASSET-LICENSES.md`); four
  are the Mac's own (SignPainter, Snell Roundhand, Savoye LET, Zapfino) and
  are looked up by PostScript name, greyed out when absent. The default,
  **Borel**, is the only monoline, round-capped face among them, which is what
  a handwritten greeting is supposed to read as. Monoline faces get an even
  round-joined stroke outside the fill — a uniform weight increase that does
  not close the counters of a / e / o; high-contrast faces are not stroked,
  since a hairline plus a stroke is a smudge. Falls back to
  `SnellRoundhand-Bold` if the resources are missing. The name beside it is
  rounded system bold, already Latinised pinyin by `MachineIdentity`
  (`Xiajun Wang`). The clock, weather, models and usage keep system type and
  monospaced figures.
- **Composition:** a 272 / 300pt sky band leaves room around the greeting. The
  clock sits at the upper left with the auto / manual sky toggle under it; the
  weather HUD sits at the upper right. The sun path or, in manual mode, the sky
  console sits at the lower left. The outer window has continuous 36pt corners
  and the sky is its own `MTKView`, full-bleed inside them. The single
  24pt-corner dock contains two zones — model / quota readings and today's
  usage — and `ViewThatFits` keeps them in a row when its 640pt minimum fits.
  Thin rules separate zones inside the shared surface.
- **Color and material:** `SkyScene` derives the palette and shader parameters
  from **solar altitude (not clock time) × weather**, so the same eight periods
  hold at any latitude and season, and `SkyScene.mix` cross-fades the
  continuous quantities (palette, cloud cover, precipitation, fog, starlight)
  over 1.2 s when the weather changes. Ink over the sky does not follow the app
  theme: legibility comes from the shader's own masks and the glyph's drop
  shadow. `DaybreakGlass` uses native tinted glass on macOS 26 and an
  `ultraThinMaterial` layer, tint and hairline on macOS 15. Reduce Transparency
  replaces both dock and weather HUD material with an opaque light or dark
  fill.
- **Readings and actions:** model rows open model management. The dock's Cursor
  and Codex chips and the popup's switcher chips read an allowance the **same
  way** — `SillGauge`, **remaining** per cent, the arc growing with what is
  left, amber at ≤ 25 % and red at ≤ 10 % — because two readings of one
  allowance are read as two different numbers. Cursor's are Cursor's **own two
  pool names** — Cursor Models (`autoPercentUsed`) and Other Models
  (`apiPercentUsed`) — which share the month's single money limit, so the money
  rides underneath as one shared figure rather than once per pool; the popover
  behind the chip names both in full and adds the Grok Bot weekly window, which
  is an independent allowance with its own reset. Codex's split into **5 小时 /
  7 天** with each reset on the hover line, and a narrow card keeps only the
  window that runs out first. The account balance chip is **gone**: an official
  account almost always reads `0 Credits`, which is not a reading anyone acts
  on. Today's usage opens usage details and compares actual today / yesterday
  token totals with two proportional bars; no hourly shape is inferred from
  daily totals. Cost is labelled as an **estimate** in help and accessibility
  text — except on the usage page's model tiles, where Cursor's **actual charge**
  is a second, separately-labelled figure (`Cursor 实扣`) that is never added to
  the estimate. Loading, unavailable quota and stale weather remain explicit
  states.
- **Sky interaction:** horizontal dragging previews up to 12 hours before or
  after now. Left / right arrows move one hour, and Escape returns to now;
  matching accessibility actions are available. Drag release eases back over
  0.75 seconds, driven by a `CADisplayLink` (`FrameTicker`) rather than a
  sleeping task, which would beat against the refresh rate. The preview uses
  the reading's coordinates and local astronomy and does not change the current
  weather measurement in the HUD. The **auto / manual** toggle under the clock
  switches to a fixed sky: the sun path's corner becomes a console — eight
  weathers, eight periods derived from the day's real sunrise and sunset, and a
  24-hour timeline whose track is painted with that weather's hourly colors —
  and the chosen weather and hour persist in defaults, so a chosen sky survives
  a relaunch.
- **Rendering and motion:** one runtime-compiled Metal fragment shader
  (`AtmosphereShader`) composites the layers far to near: sky gradient and
  horizon scattering → stars / moon / sun → cirrus → a volumetric cloud deck
  (fBm density, five light-march steps toward the sun, Beer-Lambert
  transmission with a powder term, silver lining when the disc is behind
  cover) → fog → far precipitation → rainbow / meteor / lightning → **the
  greeting** → near precipitation → refraction through drops on the card's own
  glass. The greeting sits *between* the cloud deck and the near precipitation
  on purpose: cloud shadow crosses the lettering, near streaks pass in front of
  it, and the lit rim turns with the sun. The shader is compiled at runtime
  because the build uses bare `swiftc`, which has no offline Metal compiler,
  while the runtime compiler ships with the OS. The `MTKView` keeps its own
  pointer tracking area, so parallax and wiping drops never invalidate the
  SwiftUI graph. Frame rate follows what is on screen (display rate while
  writing, fading or dragging; 60 for rain and snow; 30 for drifting cloud; 15
  under Low Power Mode or thermal pressure) and the view draws nothing when
  hidden, occluded or under Reduce Motion.

The implementation reuses Open-Meteo weather and its wttr.in fallback, plus
local low-precision astronomy for sun, moon and bright-star placement. Weather
motion is illustrative. The earlier Canvas implementation and its verification
background remain in [Weather observatory](docs/design/weather-observatory.md);
the current specification, including the manual-sky console and the performance
budget, is [Greeting atmosphere](docs/design/greeting-atmosphere.md).

## Client marks

The app watches **three client families** — Claude Code, Codex and Cursor — and
names them in a dozen places: the popup's source tallies, the island's agent
badges, the dashboard tiles' pills, the session section headers, the settings
connectivity row, the connector platform filter, and the widget's header. Each
of those used to answer "which client?" with whatever was nearest: an SF Symbol
(`command`, `terminal`, `cursorarrow.rays`), a two-letter string, or the real
artwork — so one product had three faces and `cursorarrow.rays` said "a pointer",
which is not Cursor's mark (its mark is a cube).

All of it is now `ProductBrandMark`, from **LobeHub
`@lobehub/icons-static-png@1.97.1`** — nothing in this repo redraws a brand by
eye, and `Sources/ProviderIcons/README.md` pins every asset to its URL. Three
things are worth stating because each was a bug:

1. **The mark sits on a tile, and the tile is why it is readable.** A pure-black
   mark on a dark card, or a pure-white one on a light card, is *invisible*;
   `ProductBrandMark` puts the artwork on `Theme.bgSecondary` in a rounded
   square. `well: false` is for a caller that already has its own well.
2. **The page decides the ink, not the theme.** `page: nil` = a themed surface,
   `true` = a **black** one, `false` = a **light** one. It is deliberately not
   `Theme.isDark`: the island is black in both themes, so answering the theme
   question drew black-on-transparent artwork on the app's blackest surface.
3. **The artwork is normalised, not used raw.** LobeHub's PNGs each carry their
   own margin to a square canvas; at a 13pt header tile that left Anthropic at
   65% and read as a smudge. `Tools/gen-brand-marks.py` trims each mark to its
   own ink and writes it back at 90% of the canvas, **sized on the width** so a
   wide mark and a square one stand the same width in one row — which is what
   lets a CC chip and a Codex chip sit side by side. The build copies
   `Sources/BrandAssets/` into the appex too: an extension has its own
   `Bundle.main`, so without that the widget silently drew the fallback glyph.

**第三方 has a mark as well.** It is not a client, which is why it drew bare text
beside three marks — and a legend whose fourth entry has no glyph reads as a row
that failed to finish. ClaudeBar has a mark of its own (derived from
`Sources/AppIcon-1024.png` by `Tools/make-claudebar-mark.py`), so every entry in
those legends now carries one.

`PillMark` (`Theme`) is the pill's own three-case enum rather than a reuse of
`ProductBrandMark.Brand`, because a pill is also used for subjects that are not
clients; the conversion lives in one place so the two cannot drift.

## Greeting

The greeting is a **sentence**, and two of its words are decided rather than
printed.

**The salutation is chosen, not stamped.** `GreetingPhrase` picks from a festival
table, then one of six parts of a day (late / dawn / morning / noon / afternoon /
evening / night, with the 22:00 line between 晚 and 深夜 the one that had to
move — 23:28 is not an evening). It is **not randomised**: a greeting that
changes on every re-render is a slot machine, and the card re-renders on every
pointer move. A stable phrase per (time, date) is what lets the entrance
animation be *the* event.

The name is the **person**, taken from the machine's name and then written the
way the rest of the card is written. `MachineIdentity` reads
`SCDynamicStoreCopyComputerName` — the `ComputerName` the user typed in
系统设置 → 共享, the same string `scutil --get ComputerName` prints — and two
rules run over it. `person(in:)` strips the possessive and the model:
`王夏军的MacBook Pro` → `王夏军` (CJK 的, Latin `'s` / `’s`, then the host-name
joiners `de` / `s`). `displayName(for:)` then transliterates a Han name to
pinyin, **given name first**: `王夏军` → `Xiajun Wang`, because every other word
on this surface is English (`Good afternoon`). Delivery order is given-then-
family, so it is `Xiajun Wang` and not `Wang Xiajun`; a name already in Latin
script is returned untouched (`Sam` stays `Sam`). The surname is the first
character rather than a table lookup, which reads a compound surname
(`欧阳修`) as `Yangxiu Ou` — the one shape this cannot spell. A table of the
~80 two-character surnames is a larger wrong surface than the single name it
would fix, so the simple rule stands and is documented rather than half-built.
Two things this replaced, both of which shipped:

- Reading `kern.hostname`, which **the LAN can rewrite** — a router that leases
  by address hands the card `192.168.10.102`, and it greeted the user with their
  own IP. The system name is not reachable through that string.
- Greeting `王夏军的MacBook Pro` in full, i.e. saying hello to a laptop. A person
  does not call themselves "王大锤的MacBook Pro".

A prefix shorter than two characters is a stray marker, not a name, so the whole
string is kept; and the fallback is `Mac` rather than the host name, because a
generic greeting is a smaller wrong than a numeric one.
`Tests/greeting-name-regressions.py` drives both rules over a table of machine
names, and asserts the drawn name carries no surviving ideograph.


## Settings

Settings is an Operate surface with a quieter, native control language. Its
four categories (通用 / 灵动岛 / 权限与隐私 / 本地代理) stay above a scrolling
800pt-wide column. `SettingsGroup` owns the single neutral surface;
`SettingsRow` aligns explanatory text left and native controls right. No
per-option cards, colored glyph wells, depth lenses or hover lifts. Switches,
segmented pickers and menus use macOS controls; secondary actions use the
neutral button tone. This surface deliberately opts out of the dashboard's
tile grammar. See [the settings brief](docs/design/surfaces/settings.md) for
the retained preferences, removed clutter and build-dependent verification.
