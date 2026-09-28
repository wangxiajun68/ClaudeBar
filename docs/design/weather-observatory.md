# Weather observatory

Scope: the native SwiftUI greeting band and its inline forecast zone in
`Sources/ClaudeBar`. This extends the existing visual language locally. It
introduces no web view, JavaScript runtime or custom font dependency.

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
third of the card to say it. Each glyph runs a one-shot `symbolEffect`
(`.variableColor`) gated on visibility and Reduce Motion — there is no timer and
no `TimelineView` here, so an idle card animates nothing. A day with no forecast
draws no strip at all; the HUD's own "no weather" line already says why.

## Architecture and data

| Source | Responsibility |
| --- | --- |
| `Views/Shared/GreetingCard.swift` | Store bindings, responsive band, dock zones and visible-time updates |
| `Views/Shared/WeatherExplorer.swift` | `WeatherReading.Sky` glyph/caption mapping, the HUD's inline `ForecastStrip`, and `SolarHorizon`. `WeatherExplorer` / `SolarHorizon` no longer have a call site — the popover they were built for is gone |
| `Views/Shared/WeatherBackdrop.swift` | `SkyPalette`, atmospheric Canvas and celestial projection |
| `Utils/SkyAstronomy.swift` | Sun, moon, phase and bright-star horizon coordinates |
| `Utils/WeatherForecastFetcher.swift` | Open-Meteo geocoding, current/daily request and parsing |
| `Utils/WeatherFetcher.swift` | `WeatherReading`, fallback fetch and shared `WeatherStore` |

Open-Meteo supplies current conditions and daily forecasts in one payload.
Named cities use its geocoding API; valid latitude/longitude pairs bypass that
lookup. The request uses `forecast_days=6`, `timezone=auto` and Unix timestamps.
Dates and sunrise/sunset labels are interpreted in the returned location's
timezone. The detail footer links to the active provider.

If Open-Meteo fails, the existing wttr.in fetch supplies current conditions
and a forecast-unavailable note. Incomplete daily arrays retain valid dates
and report partial availability; missing optional forecast metrics show a dash.
The UI does not fabricate five extra days. `WeatherStore` shares one reading,
uses a 15-minute freshness interval and a single in-flight request, and retains
the last good reading after a failed refresh. Location use follows the existing
permission gate; a configured city remains the fallback.

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

The weather `TimelineView` requests minimum intervals of 1/12 second for clear
skies, 1/16 for cloud/fog and 1/30 for precipitation. It pauses when
`surfaceIsVisible` is false or Reduce Motion is enabled. Reduce Motion draws a
fixed atmospheric phase and suppresses pointer scaling and arrival movement.
The minute astronomy task exits when the surface becomes hidden. These are
implementation limits, not measured CPU/GPU or frame-rate guarantees.

Background drawing is hidden from accessibility and ignores hit testing.
Native date buttons retain text labels, tooltips and selected-state traits;
metrics carry their units in text. Decorative graphs do not replace values.

## Verification

From the repository root on macOS:

```sh
python3 Tests/weather-astronomy-regressions.py
python3 Tests/greeting-data-regressions.py
python3 Tests/inflight-animation-regressions.py
python3 Tools/render-greeting-preview.py
bash Sources/build.sh
```

The astronomy regression compiles production parsing/calculation code and uses
synthetic fixtures for equinox, east/west placement, polar day/night, moon
phase, sidereal stars, day +5, timezone handling and partial/null data. The
preview renderer uses production view code with synthetic readings; it also
regenerates `Tools/greeting-preview-support.swift`. It does not establish live
service availability or replace pointer, keyboard and visibility checks in
the running app.

Visual fixtures in `.build/greeting-preview/`:

- `light-1100-cloud.png`: wide band with compact rail.
- `dark-620-rain.png`: narrow stacked band.
- `detail-light-current.png` / `detail-dark-day5.png`: the inline forecast zone
  captured on its own, in light and night palettes.

## Design references

- [Componentry Magnetic Dock](https://componentry.dev/docs/components/magnetic-dock):
  reference for pointer-revealed controls and active indicators, translated into
  native SwiftUI readings and buttons.
- [Componentry Scroll Choreography](https://componentry.dev/docs/components/scroll-choreography):
  reference for coordinated motion. The implemented band uses brief grouped
  arrivals; it does not implement the reference's scroll-driven image stack.
- [Uiverse](https://uiverse.io): reference collection for tactile hover and
  press treatments, consistent with the app's existing control language.

These are interaction references. Runtime behavior and exact values are owned
by the Swift source above.
