# ClaudeBar visual language

CatStatus-class **status sheet**: ice canvas in light, graphite in dark. White
(or raised dark) cards, SF Rounded metrics. Color lives in charts and status.

Scope: this document describes the **app target** (`Sources/ClaudeBar`). The
WidgetKit extension (`Sources/Widget`) is compiled separately from its own four
sources plus `Sources/Shared/BuildChannel.swift`, and cannot reach `Theme`, so
it keeps its own drawing; it is not a consumer of this language and is not
covered by it.

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
| Chart purple `#BF5AF2` | General usage accents; analytical figures use the palette below |
| Ink / snow | Primary text in light / dark (`Theme.textPrimary`) |

Claude / Cursor / Codex hues remain for identity chips only.

Usage analysis keeps a categorical plot palette for its five metrics and the
Token-composition bar — `UsagePlotPalette` for the metrics, `UsageReportPalette`
for the bar's four parts (`Views/Shared/UsageAnalytics.swift`) — and the heatmap
ramp is a single hue's opacity ladder (`Theme.chartPurple`, keyed by opacity
samples 0.16 / 0.4 / 0.7 / 1.0), not a multi-stop scale: the page uses fixed
categorical colors, not a sequential ramp. Zero-record days use the neutral well.
See [the usage brief](docs/design/surfaces/usage.md) for normalization and data
scope.

Every signal hue has two variants and they are not interchangeable: `Theme.Ink.*`
is the **text** version (mixed until it clears 4.5:1 on the ice canvas) and the
raw `chart*` / `status*` hue is the **shape** version. A glyph, a bar, a dot, a
ring and a card wash take the raw hue; a label, a pill, a count and a percentage
take the ink. A provider card's state therefore has both — `ProviderCardState.color`
for its badge and `.faceColor` for its wash and rings. Using one value for both
is how a state ends up readable in exactly one theme.

## Surfaces

One surface language, four parts (`TileSurface.body` in
`Views/Shared/Tile.swift`; the ring and lens views in
`Views/Shared/UiverseSurfaces.swift`), so a card in one grid is the same object
as a card in another:

1. **Base + accent wash** — `cardSurface`, then the card's own hue at 5.5 %
   (light) / 11 % (dark), deepened ×1.7 under the pointer; a page band carries
   a heavier 9 / 15 % so its inner frame ring reads at full width. The wash is
   what makes a page of tiles scannable by row; it never moves under the
   pointer except by deepening.
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
and category filter, and the usage period tabs.

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
| `InstrumentToggleStyle` | `metanef` switch | the **one** switch: an engraved inset track with a lit bottom edge, and a plated handle that travels on the state change. Backs the settings rows and every provider-editor toggle (`.instrument` / `SettingsToggleRow`); native `.switch` remains only on the VPN overview controls, the fan detail sheet and the session-migration dialog, and `.checkbox` on the domain-log failure filter. The handle **does not stretch** toward its destination on hover — that is geometry moving because the pointer arrived, and the control already states its state; the hover is a lit rim instead. |
| `ActionButton` | reference CSS pill + `ultimate-3d-btn` | **the one push button**, named by *intent* rather than appearance: `tone:` (`.neutral` is the default; `.accent` / `.destructive` / `.sparkle` are opted into), `emphasis:` (`.primary` fills solid — one per page at most), `metrics:` (`.regular` / `.large`). Every solid push button is this plate; inline text-only affordances (`Button` + `.buttonStyle(.plain)` / `.link`, e.g. the provider sheet's 关闭 or the proxy picker's 添加供应商) stay text and are not action plates. `.neutral` (the default) draws the quiet machined plate — a light fill with a hairline — for a button that must not punch a dark hole in a card. `.sparkle` is the **dark plate** (`SparklePlate`): a near-black pill whose identity *is* its own surface, so it does not tint from the caller's hue — it was ported from a reference CSS button (`#1C1A1C`, hover gradient `#A47CF3 → #683FEA`, glow `#9917FF`, 450 ms ease-in-out, hence `Theme.Animation.sparkle`). |
| `ProviderActionStyle` | `ultimate-3d-btn` | a **historical spelling** of the same button, kept because those call sites pass it positionally. It forwards to `ActionPlateButtonStyle`, so a connector button, a provider card's button and a native `ActionButton` are the same plate and cannot drift. `adaptiveGlassButton()` and `InstrumentButtonStyle` are gone — see the note below the table. |
| `ChipButton` | `mymiamo` glass menu | a compact *selectable* chip — a state you flip, not an action you fire. Radius 8 rather than a capsule, so a filter row does not read as a row of buttons. |
| `SegmentedCapsule` | `mymiamo` glass menu | the one filter / segmented control, with one sliding pill. Backs the connector type / platform / 连接器-飞书文档 filters, the provider client switcher and category filter, the usage period tabs, the traffic filters, the domain-log view picker and the three settings pickers. |
| `headerControl()` | `metanef` switch track | **the page band's own control** — now literally `ActionPlateButtonStyle` at the band's proportions, in the quiet tone. Shared by 连接器 and 模型 so two bands read as the same object. |
| `InstrumentMenuLabel` | `mymiamo` glass menu | the same well for a `Menu`'s own label (the settings compact category picker, 继续会话终端, 问候语, 问候语言 and 问候字体). It is a *label*: the native menu inside a machined tile is Aqua chrome, so this draws the well, the hover rim and the chevron and leaves the press state to the `Menu` that owns the button. |
| `PerimeterSweep` | `ultimate-3d-btn::before` | a lit arc travelling a control's **own** perimeter, once, on hover only. Never a loop: a permanent rotating border is per-frame chrome and stops meaning anything. |
| `GroundShadow` | `stat-widget` `.ground-shadow` | the soft ellipse that appears under a control with its hover lift, so the pair says "picked up". |
| `TokenMixStrip` | `NK2552003` stat card | the usage page's stacked input / hit / write / output track (`Views/Shared/UsageViz.swift`), also used inside every model card. |
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

The provider card's capture control is a 30pt `ActionIcon`: its own
`capture.requests` mark combines capture corners with bidirectional data flow.
A solid green dot means enabled; a hollow grey dot means disabled. Help and
the accessibility value retain the meaning, and state comes from the saved
provider's `captureEnabled`. See [the providers brief](docs/design/surfaces/providers.md).
The traffic page's 300pt list toolbar uses a 30pt trash `ActionIcon` in
`Theme.Ink.error` for clearing all captures. Help and the accessibility label
state that scope; the action opens the existing confirmation before deleting
all records and request / response bodies.

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

The two are separate lanes on purpose. A bar's unit is:
`ProcessSampler.cells.cores` for the CPU bars, `ProcessSampler.cells.gpuRenderers`
for the GPU bars, `memoryActive` / `memoryWired` / `memoryCompressed` for the
memory wells and the disk's used / free for the drive bay. The first attempt
squeezed the reading *inside* the artwork and the two fought: bars crossed the
GPU's port circles and the DIMM's chip windows. Giving the reading its own lane
keeps the icon legible as an icon and the reading legible as a reading.

| Tile | Bars |
| --- | --- |
| CPU | one per **logical core** (`ProcessSampler.cells.cores`) — 12 cores is 12 countable bars |
| GPU | one per **graphics sub-unit** (`ProcessSampler.cells.gpuRenderers`), each at its own 0…100 |
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
   stub that still keeps its slot, so twelve cores stay countable at rest.
   Translucent tints over a gradient plate are not acceptable: two such fills
   are one reading, not two.
4. **Colour carries state, the mark carries load.** `StatusPill`, temperature and
   pressure own the state readouts; nothing lights up because it is busy.

## Mark

Dock: an ice card with blue, violet and green rings and a slim live bar (see
the app icon artwork). Menu-bar status item is a template **ring + bar**
(`MenuBarMark`, drawn as `NSBezierPath` and marked `isTemplate` — it renders
black for the menu bar rather than carrying the icon's mint fill).

## Anatomy

1. **Switcher HUD** — row 1 is session / proxy / VPN facts; row 2 is the CC /
   Codex / Cursor switcher chips. VPN rides the fact strip as a pill, not the
   switcher row.
2. **Machine KPIs** — one connected strip in the popup. Dashboard is a 2×3
   resource grid (CPU / GPU / memory, disk / links / dual fans). Each fan
   rotor toggles max vs auto and spins at its own RPM; every other meter carries
   its reading in the *shape* of the hardware — a per-core die, per-sub-unit GPU
   columns, capacity wells. See **Machine marks** above.
3. **Sessions** — popup is one full-width column. Empty tool families omit.
4. **Usage** — local model tokens only (a period heatmap, five inline metrics,
   a token-composition card, then platform / provider / model breakdowns). VPN
   quota stays on the VPN page.
5. **VPN CTA** — dark sparkle pill. Live outbound path is a `›` breadcrumb,
   not a decorative metro line.
6. **Settings** — six purpose-based categories, sidebar navigation and grouped rows; explicit Save / Apply for credentials and ports.
7. **Connectors** — one 36pt toolbar contains the persistent 连接器 / 飞书文档
   switch, search and page actions. Each page reserves the same leading slot
   under the parent-owned switch, so navigation keeps its namespace and position.
   The connector list begins with fully expanded category and platform capsules
   on one row, including their counts; no title/statistics card or dropdown filter.
   Segment labels keep identical font metrics in both selection states, with
   smooth pill motion and no press scaling or spring overshoot.
   Tiles are fixed at 164pt with scope under the name, a two-line summary,
   platform chips and directly visible enable/disable, state and remove controls.
   Bulk shortcuts are also visible buttons. A sheet renders Skill Markdown,
   MCP tool metadata or plugin contents; no 3D tilt on this scrolling grid.
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

- The popup opens without a staggered section entrance today; the rule for
  whatever re-introduces one: a section entrance is one-shot per section, never
  staggered per inner cell.
- Traffic rates live on `VpnLiveRates` (4 Hz). Mosaic does not observe them.
- YAML sanitize + `networksetup` run off the main actor.
- Fan rotors are a Core Animation layer with one endless rotation retimed in
  place as RPM changes (`RotorLayerView.setSpeed`), so the blades never snap
  back to rest and the app does no per-frame work. Do not drive blades with
  `rotationEffect` on a SwiftUI view.
- Connector controls animate only on press, selection, focus, or an explicit
  state change. Inventory tiles stay lazy and fixed-height. They carry a hover
  shadow and a 2pt lift (`.tile()`), which is a hover *state* change, not a
  loop; reduce-motion removes both, and no tile animates while the grid scrolls
  under a stationary pointer.
- The depth lens and the inner frame ring are geometry, not animation: one
  `Canvas` and one stroked `RoundedRectangle` per card, drawn once. Rings on an
  unscrolled card cost nothing per frame.
- Two one-shot motions exist and both are gated on reduce-motion, and on
  `surfaceIsVisible` where the control can sit off-screen: the status-button
  shine (`ShineSweep`, a single 0.55 s sweep when hover begins) and the conveyor
  belt (`ConveyorBelt` → `DecorativeMotion.kind == .conveyor`, a Core Animation
  layer used by the connector scan strip). Neither repeats a SwiftUI animation.
- The machine marks are `Canvas` geometry, redrawn only when the sampler
  publishes a new reading (every 2 s with a resource UI open, 1 s while a
  session is live, 6 s in the background with attribution on, 12 s with no
  consumer at all — `ProcessSampler.applyPeriod`). The
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
- Local fan tiles draw the bundled rotor crops inside a neutral ring housing
  with a rim gauge (`LucideRotor` in `CompactFanPair`); the small badge and the
  popup KPI marks use the SF Symbol `fanblades.fill`. Core
  Animation retimes rotation in place as RPM changes; below 80 RPM, off-screen,
  and Reduce Motion all stop the rotation.
  The fan buttons directly toggle max / auto; the rest of the tile opens details.
  The internals detail panel overlays the same rotating turbine crops on the
  bundled illustration. That illustration is a conceptual overview in a
  simplified vector-like style, not an exact host-specific board map or a true
  SVG. Both illustrated fans animate independently using the shared turbine
  crops.
- The 3D card's tilt is a **hero** treatment, not part of `.tile()`.
  Connector inventory tiles use the ordinary surface and hover state; 3D tilt
  stays off scrolling grids of 200 cards.
- The main navigation uses one static elevated surface; only tab hover and
  selection animate. No full-width material blur or scrolling tab strip.

## Greeting sky window

This component-level extension belongs to `GreetingCard` and its Metal
atmosphere (`Views/Shared/Atmosphere/`). The app's ice / graphite visual
language remains the global system. This surface frames a handwritten greeting
in an atmospheric sky, with corner instruments and one glass dock along the
bottom.

- **Typography:** the greeting is drawn from CoreText glyph outlines by
  `GreetingScript`, in one of **53 selectable script faces** (`GreetingTypeface.allCases`;
  设置 → 外观与天气 → 天气与问候 → 问候字体). **49 are bundled** under the local
  face library (`FilePaths.greetingFontsDir`; SIL OFL 1.1 / Apache 2.0, each
  licence beside its file — see `ASSET-LICENSES.md`) and seeded into it by
  `AppPreferences.prepareGreetingFonts()`; **four are the Mac's own**
  (SignPainter, Snell Roundhand, Savoye LET, Zapfino) and are looked up by
  PostScript name, removed/restored only for the bundled ones. The Chinese /
  Latin split is `GreetingTypeface.chineseFaces` (14 Chinese faces + 39 Latin).
  The default is **寒蝉圆黑 · 粗体 (chillRoundBold)**, whose rounded, soft
  strokes sit right for a handwritten greeting. Monoline faces get an even
  round-joined stroke outside the fill — a uniform weight increase that does
  not close the counters of a / e / o; high-contrast faces are not stroked,
  since a hairline plus a stroke is a smudge. Falls back to
  `SnellRoundhand-Bold` if the resources are missing. The name beside it is
  rounded system medium at 18–28pt, with natural 0.015em tracking and the
  authored case preserved; already Latinised pinyin by `MachineIdentity`
  (`Xiajun Wang`). Long names may drop below the phrase; both clear the
  instruments. The clock, weather, models and usage keep system type and
  monospaced figures.
- **Composition:** a sky band of `min(430, max(380, width × 0.38))` over a 56pt
  sill. The clock sits at the upper left with the auto / manual sky toggle under
  it; the weather HUD sits at the upper right. The sun path or, in manual mode,
  the sky console sits at the lower left. The outer window has continuous 32pt
  corners and the sky is its own `MTKView`, full-bleed inside them. The card
  treats itself as narrow below 700pt: provider detail lines drop, the model
  chips truncate sooner and the manual console takes the forecast's place. The
  single full-width sill has no corner of its own; model / quota readings and
  today's usage share one surface, separated by a thin rule. Values here are the
  acceptance targets; the measured spec and its current build values are in
  [Greeting atmosphere](docs/design/greeting-atmosphere.md).
- **Color and material:** `SkyScene` derives the palette and shader parameters
  from **solar altitude (not clock time) × weather**, so the same eight periods
  hold at any latitude and season, and `SkyScene.mix` cross-fades the
  continuous quantities (palette, cloud cover, precipitation, fog, starlight)
  over `AtmosphereRenderer.weatherFade` = 1.2 s when the weather changes. Ink over the sky does not follow the app
  theme: legibility comes from the shader's own masks and the glyph's drop
  shadow. `SillGlass` uses native tinted glass on macOS 26 (`glassEffect`) and an
  `ultraThinMaterial` stack, tint and hairline on macOS 15; Reduce Transparency
  replaces the sill with an opaque dark fill.
- **Readings and actions:** model rows open model management. The sill's
  `SillGauge` and the popup's `QuotaSwayGauge` read an allowance the **same
  way** — **remaining** per cent, the arc growing with what is
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
  SwiftUI graph. The frame rate follows the hand, not the weather: the pen, a
  weather fade and a drag through the day run at the display's rate; parallax
  while the pointer is moving runs at up to 60 Hz; a card at rest presents at
  30 Hz (15 Hz when
  calm) because the cloud deck has its own slower clock and rain and snow are a
  baked plates. Rain uses tapered bright heads, rectangular atlas dimensions
  and independent lane velocities at three depths; thunder adds density, speed
  and a small gust. No per-drop CPU simulation or SwiftUI view is involved.
  Information uses opaque-enough white ink over fixed, feathered navy corners,
  composited after precipitation and lightning; the greeting chooses navy or
  light ink from the sky luminance at a 0.18 crossover. The native fallback
  follows the same information backing and type rules. Low Power
  Mode or thermal pressure is 30 Hz while the hand is down and 15 Hz otherwise.
  Turning weather rendering off draws no cloud, precipitation, fog or lightning
  at all, so the card has almost nothing to scroll. The view draws nothing when
  hidden, occluded or under Reduce Motion.

The implementation reuses Open-Meteo weather and its wttr.in fallback, plus
local low-precision astronomy for sun, moon and bright-star placement. Weather
motion is illustrative. The earlier Canvas implementation and its verification
background remain in [Weather observatory](docs/design/weather-observatory.md);
the current specification, including the manual-sky console and the frame-rate
policy, is [Greeting atmosphere](docs/design/greeting-atmosphere.md).

## Client marks

The app watches **three client families** — Claude Code, Codex and Cursor — and
names them in a dozen places: the popup's source tallies, the island's agent
badges, the dashboard tiles' pills, the session section headers, the session
migration dialog, the connector platform filter, and the widget's header. Each
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
table, then one of seven parts of a day (late / dawn / morning / noon / afternoon /
evening / night, with the 22:00 line between 晚 and 深夜 — 23:28 is not an
evening). It is **not randomised**: a phrase that changed on every re-render
would be a fresh draw each time the pointer moved, and the card re-renders on
every pointer move. A stable phrase per (time, date) is what lets the entrance
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


## Usage analysis

Usage is a compact Operate surface for exploring recorded token totals. A single
period toolbar leads into five inline metrics (`UsageAnalyticsSection.metrics`),
then two cards. Explanations move into native help rather than permanent metric
captions. Cards use 16pt padding and 12pt gaps within the existing neutral
surface language. Below them, 按平台 / 按供应商 / 按模型 lists the details;
there is no collapsing disclosure.

The activity card is the **period heatmap** (`UsageHeatmap`): a seven-cell week
strip for 日, a contribution grid for 月 / 年 / 全部, sized per grain (60 / 132 /
108pt at page width, 28 / 56 / 56pt compact) and colored as an opacity ladder of
one hue (`Theme.chartPurple`). Its caption carries the recorded-day count; hover
reads a day and a click drills down. A source row beneath the grid shows each
source's brand mark and its share.

The structure card is the **token composition**: a 12pt segmented bar over
input / cache read / cache write / output (`UsageCompositionBar` in
`Views/Shared/UsageAnalytics.swift`), with the cache-hit rate in its header and
a two-column grid of the four parts beneath, each with its token total and
share. Zero values keep their label and number on a neutral track.

Day, month and custom periods retain daily observations; year and all-history
periods aggregate monthly, with all-history switching to years beyond 730 elapsed
dates. Daily P50 / P95 include elapsed zero-record days and exclude future dates.
Cache reads divide by input + cache read + cache write; output is excluded.
Estimated costs and Cursor charges remain separately labelled in the model cards.
No hourly profile, billing history, forecast, savings, density estimate or
confidence band is inferred.

`UsageAnalysis` still computes the distribution, density, calendar, Lorenz and
effective-model-count series; the current two cards draw none of them, so they
are not described here. Ground truth and research sources live in
[the usage brief](docs/design/surfaces/usage.md).

## Settings

Settings is an Operate surface with six purpose-based categories: 通用、外观与天气、
灵动岛、用量与计费、权限与隐私、本地代理. A 200pt sidebar anchors containers at least
860pt wide; narrower containers use one category menu. The main window currently
has a 900pt minimum width, so the compact menu is below what the live window can
reach and is not currently covered by an automated preview.
A 32pt rounded category title and a single
line icon establish hierarchy above an independent, at-most-900pt scrolling column.
`SettingsGroup` integrates its icon/header into one neutral 18pt panel. Rows align
controls right and stack them below labels when necessary. No per-option cards,
hover lifts or perpetual decoration.

Settings now share `InstrumentToggleStyle`, `SegmentedCapsule`,
`InstrumentFieldStyle`, `InstrumentMenuLabel` and neutral `ActionButton` with the
rest of the app. Preference switches/selectors apply immediately; proxy ports
have explicit Apply; credentials have explicit Save. System authorization keeps
its own status and recovery link. See [the settings brief](docs/design/surfaces/settings.md).

`MainWindowView` owns `SettingsState` as a `@StateObject` above `.id(appearance)`
and passes it into Settings. Category, text drafts, port error and advanced-section
disclosure state survive page navigation and palette changes within that window's
lifetime. City text commits on submit, blur or leaving its category; credentials
and ports require Save / Apply or submit, so navigation preserves unsaved drafts.

Native previews (`Tools/render-mainwindow-preview.py`) render five pages from
the current production source — overview, 会话, 用量, VPN and 流量 — and do not
include the settings page. Settings verification therefore rests on the
registered regression suites (`make test`) and manual runs of the dev build;
installation, actual system authorization and proxy rebinding remain outside
those checks.

## Desktop wooden fish

The desktop wooden fish is a transparent native vector accessory: softly lit
amber wood, sparse curved grain, a thin stitched jade cushion and a highlighted
wooden mallet form the surface itself. Its standard instrument is 28% smaller
in linear size than the original; only artwork and feedback paths follow the
size setting. The 26pt hover tools, 11pt counts and 12pt Token label retain
native dimensions. Tools are separate circles on translucent black backgrounds;
the accessory has no generic card frame, inner rings or panel fill. Rest,
hover, automatic striking, shared shape capture and bounded
Reduce Motion behavior are specified in [the wooden fish brief](docs/design/surfaces/wooden-fish.md).
