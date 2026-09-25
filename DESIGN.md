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

## Mark

Dock: three thick jade rings on a white ice card (blue / violet / green) over
a slim live bar. Menu-bar status item is a template **ring + bar**.

## Anatomy

1. **Switcher HUD** — session/proxy facts, then CC / Codex / VPN.
2. **Machine KPIs** — one connected strip in the popup. Dashboard is a 2×3
   resource grid (CPU / GPU / memory, disk / links / dual fans). Each fan
   rotor toggles max vs auto; blades keep spinning via accumulated phase.
3. **Sessions** — popup is one full-width column. Empty tool families omit.
4. **Usage** — model tokens only (heatmap, source triad, token mix, daily
   spark, model bars). VPN quota stays on the VPN page.
5. **VPN CTA** — dark sparkle pill. Live outbound path is a `›` breadcrumb,
   not a decorative metro line.
6. **Settings** — one control per grid tile, including theme.
7. **Connectors** — a compact client rail with a separate shared Agent CLI
   destination for each CLI and its declared Skills/MCP, a segmented type
   filter, and equal-height adaptive grid tiles. Each tile names its type and
   keeps the state action visible. A sheet renders Skill Markdown, MCP tool
   metadata, or plugin contents; scrolling never expands or relays out a tile.
8. **Main navigation** — a centered white capsule floats over the continuous
   ice canvas; brand and live status stay outside it. At narrow widths tabs
   lose glyphs before labels, preserving the full destination list.

## Motion / performance

- Popup sections lift in once on open. Do not stagger inner cells.
- Traffic rates live on `VpnLiveRates` (4 Hz). Mosaic does not observe them.
- YAML sanitize + `networksetup` run off the main actor.
- Fan rotors tick on a periodic TimelineView and accumulate angle; do not
  drive blades with `rotationEffect` (parent refresh snaps them back).
- Connector controls animate only on press, selection, focus, or an explicit
  state change. Inventory tiles remain lazy, fixed-height and shadow-free;
  reduce-motion removes nonessential movement.
- The main navigation uses one static elevated surface; only tab hover and
  selection animate. No full-width material blur or scrolling tab strip.
