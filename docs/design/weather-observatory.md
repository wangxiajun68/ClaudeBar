# Weather observatory

> **Superseded.** This is the record of the Canvas-era greeting band and its
> popover-era inline forecast. The card has since been rebuilt around a Metal
> atmosphere; the current specification is
> [Greeting atmosphere](greeting-atmosphere.md). `SkyVeil` / `SkyGrain` and the
> popover-era `WeatherExplorer` / `SolarHorizon` / `ForecastStrip` views are
> deleted; the trend strip became `ForecastRibbon` in `GreetingInstruments.swift`.
> `WeatherBackdrop.swift` survives as the Canvas sky `FallbackSky` mounts while
> the Metal pipeline is unready or unavailable; it holds `WeatherBackdrop`, its
> `SkyPalette` and a private cloud texture. The Metal palette is not this one —
> it lives in `SkyScene`. What still matches the code — the provider chain and
> `SkyAstronomy`'s contract — also appears in the
> [file index](../technical/09-file-index.md),
> [weather and atmosphere](../technical/18-weather-and-atmosphere.md) and the
> [FAQ](../FAQ.md); the Canvas frame intervals are restated in the
> [rendering review](../reviews/rendering-audit.md), and the `WeatherStore`
> cadence is stated here (the technical documents only say it reuses the
> existing refresh cycle). Later Metal-era measurements are in
> [weather-card measurements](../reviews/weather-card-measurements-2026-09-30.md).
> The layout, forecast and motion paragraphs below describe the earlier band,
> not the current card.

Scope: the Canvas-era SwiftUI greeting band and its inline forecast zone in
`Sources/ClaudeBar`. It introduced no web view, JavaScript runtime or custom
font dependency.

## Layout and interaction

`GreetingCard` presents the greeting and clock, current weather, model readings
and today's usage on one continuous surface. Hairlines divide the rows. A 36pt
continuous corner encloses the whole band; internal readings have no separate
card backgrounds. The dock holds two zones side by side — model / quota
readings and today's usage — and `ViewThatFits` keeps them in a row while its
640pt minimum fits, stacking them below that.

The forecast is **inline in the weather HUD**, not in the dock: `ForecastStrip`
draws the available dates from a six-date request (today and day +1 through day
+5) as slim columns — weekday, glyph, low/high — under the current temperature.
It replaced the dock's full-width rail and the 620pt `WeatherDetails` popover it
opened; the reading (a six-day trend) is unchanged, but it no longer needs a
third of the card to say it. Each glyph ran a repeating `symbolEffect`
(`.variableColor.iterative.reversing`) gated on visibility and Reduce Motion —
there was no timer and no `TimelineView` in the strip. A day with no forecast
drew no strip at all; the HUD's own "no weather" line already said why.

## Architecture and data

| Source | Responsibility |
| --- | --- |
| `Views/Shared/GreetingCard.swift` | Store bindings, responsive band, dock zones and visible-time updates |
| `Views/Shared/WeatherReadingSky.swift` (was `WeatherExplorer.swift`) | `WeatherReading.Sky` glyph/caption mapping. The HUD-era `WeatherExplorer` / `SolarHorizon` / `ForecastStrip` views this file also carried lost their call site with the popover and have since been deleted; only the extension above survives |
| `Views/Shared/WeatherBackdrop.swift` | `SkyPalette`, atmospheric Canvas and celestial projection |
| `Utils/SkyAstronomy.swift` | Sun, moon, phase and bright-star horizon coordinates |
| `Utils/WeatherForecastFetcher.swift` | Open-Meteo geocoding, current/daily request and parsing (overseas + fallback) |
| `Utils/WeatherAmapFetcher.swift` | AMap geocode/regeo + current/daily request — the proxy-free primary source |
| `Utils/WeatherCNFetcher.swift` | 中国天气网 keyless fallback: offline cityid table + `weather_index` JS payload |
| `Utils/WeatherFetcher.swift` | `WeatherReading`, the provider chain (`高德 → 中国天气网 → Open-Meteo → wttr.in`), domestic parsers and shared `WeatherStore` |

The provider chain is `高德 → 中国天气网 → Open-Meteo → wttr.in`. The two
domestic sources answer over Chinese IPs, which the VPN's `GEOIP,CN → Direct`
rule sends direct — so the card keeps working with no proxy at all, which is the
reason they lead. AMap (when a key is configured, blank by default) supplies
current conditions and a 4-day forecast from geocoded adcodes; 中国天气网, which
needs no key, supplies both from its `weather_index` JS payload. Neither speaks
WMO codes, so a reading carries a `skyHint` and the code tables live apart from
`sky(for:)`; neither publishes a rain probability, sunrise/sunset or day/night,
which are estimated or left blank.

Open-Meteo supplies current conditions and daily forecasts in one payload, and
remains the source for overseas cities (the domestic pair covers mainland China
only) and the last fallback. Named cities use its geocoding API; valid
latitude/longitude pairs bypass that lookup. The request uses `forecast_days=6`,
`timezone=auto` and Unix timestamps. Dates and sunrise/sunset labels are
interpreted in the returned location's timezone. (The detail footer that linked
to the active provider belonged to the popover and is gone with it.)

If every provider fails, the existing wttr.in fetch supplies current conditions
and a forecast-unavailable note. Incomplete daily arrays retain valid dates
and report partial availability; missing optional forecast metrics show a dash.
The UI does not fabricate five extra days — a shorter forecast just draws fewer
columns, and today's `ForecastRibbon` names "未来 N 天预报" with the count it
actually has. `WeatherStore` shares one reading, uses a 15-minute freshness
interval and a single in-flight request, and retains the last good reading after
a failed refresh. Location use follows the existing permission gate; a
configured city remains the fallback.

## Astronomy and atmosphere

`SkyAstronomy` converts low-precision geocentric solar/lunar coordinates to
altitude and azimuth using UTC time and the observer's coordinates. Bright
stars use a small fixed right-ascension/declination catalogue and sidereal
rotation. The view updates its actual-time snapshot every minute while visible;
changing the device timezone alone does not move the calculated sky.

The Canvas maps azimuth across its width and altitude vertically. Stars and
moon below the horizon are hidden; the sun has a small horizon allowance
(-1°). Twilight glow follows solar altitude, while condition-dependent opacity
reduces celestial visibility under clouds. The moon silhouette approximates
waxing/waning illumination. These calculations and the panoramic projection
support a weather illustration: no precision claim, refraction correction,
topocentric lunar parallax or navigation use is implied. Provider sunrise and
sunset times remain separate from the locally calculated solar curve.

The renderer distinguishes clear, partly cloudy, cloudy, fog, drizzle, rain,
sleet, snow, thunder and hail. Clouds drift; precipitation uses depth layers;
rain can produce splashes; wind streaks appear above 18 km/h. Rain density uses
the supplied precipitation-probability value as an illustration input, not a
measurement of rainfall rate. Atmospheric movement and star twinkle are
decorative; celestial placement comes from the astronomy snapshot.

## Motion, accessibility and visibility

The Canvas-era weather timeline requested minimum intervals of 1/12 second for
clear skies, 1/16 for cloud/fog and 1/30 for precipitation, and paused when
`surfaceIsVisible` was false or Reduce Motion was enabled. That schedule now
applies only to the Canvas fallback; the steady card is an `MTKView` with its
own frame-rate policy (see [Greeting atmosphere](greeting-atmosphere.md) §5.7).
The card chooses between the Metal surface and `FallbackSky` on
`AtmosphereGPU.shared != nil`, so the Canvas sky is what runs before the
pipeline finishes building on a background queue, and on a Mac where Metal is
unavailable. In that Canvas sky Reduce Motion draws a fixed atmospheric phase;
the Metal surface substitutes a cached still. The minute astronomy task exits
when the surface becomes hidden. These are implementation limits, not measured
CPU/GPU or frame-rate guarantees.

Background drawing is hidden from accessibility and ignores hit testing. The
Canvas-era date buttons retained text labels, tooltips and selected-state
traits; today's forecast lives in `ForecastRibbon`, which is one adjustable
accessibility element rather than a button per day. Metrics carry their units
in text. Decorative graphs do not replace values.

## Verification

These are the commands that existed when this record was written; they are not a
current gate. From the repository root on macOS:

```sh
python3 Tests/weather-astronomy-regressions.py
python3 Tests/inflight-animation-regressions.py
python3 Tools/render-greeting-preview.py
```

`Tests/weather-astronomy-regressions.py` is registered as `make test
TEST=weather-astronomy`; `Tests/greeting-data-regressions.py`, also listed here
originally, now covers Codex credit parsing and is no longer a weather check.
(`bash Sources/build.sh` builds the dev app and does not install it by default;
`make build` wraps that.) The astronomy regression compiles production
parsing/calculation code and uses synthetic fixtures for equinox, east/west
placement, polar day/night, moon phase, sidereal stars, day +5, timezone
handling and partial/null data. The preview renderer uses production view code
with synthetic readings; it also regenerates `Tools/greeting-preview-support.swift`.
It does not establish live service availability or replace pointer, keyboard and
visibility checks in the running app.

Visual fixtures in `.build/greeting-preview/`. Names carry the render mode — and,
apart from the `face-*` and `ribbon-*` passes, a scene suffix; the scene list is
`sun`, `rain`, `heavy`, `thunder`, `night`, `cloud`, `snow`, `fog`, `empty`, and
the modes are `auto` / `manual` / `bare`. The Canvas-era captures were renamed
away by that scheme; the three files below are what the current renderer
produces:

- `auto-light-1100-cloud.png`: wide band with compact rail.
- `auto-dark-620-rain.png`: narrow stacked band.
- `auto-light-1100-sun.png` / `auto-dark-1100-sun.png`: the day sky in both themes.

## Design references

- [Componentry Magnetic Dock](https://componentry.dev/docs/components/magnetic-dock):
  reference for pointer-revealed controls and active indicators, translated into
  native SwiftUI readings and buttons. The current card does not use it either.
- [Componentry Scroll Choreography](https://componentry.dev/docs/components/scroll-choreography):
  reference for coordinated motion. The implemented band uses brief grouped
  arrivals; it does not implement the reference's scroll-driven image stack.
- [Uiverse](https://uiverse.io): reference collection for tactile hover and
  press treatments, consistent with the app's existing control language.

These are interaction references from the popover era; the current control
language lives in [DESIGN.md](../../DESIGN.md). Runtime behavior and exact
values are owned by the Swift source.
