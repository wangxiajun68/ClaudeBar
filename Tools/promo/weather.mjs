// The greeting card's sky, drawn to the same contract as the app's atmosphere
// (docs/design/greeting-atmosphere.md §5–§6): a vertical gradient whose three
// stops come from solar altitude and weather, a horizon glow, volume-ish cloud
// layers, the sun/moon on its real arc, and — in the rain scene — the card's own
// glass droplets, which is the one interaction the film leans on hardest.
//
// This is the film's stand-in for the Metal shader. It is not the shader: the
// film cannot run MTKView off-screen per frame. The palette constants below are
// read from the design doc so the film and the card agree on colour even though
// they disagree on implementation.

import { clamp, lerp, S, fbm, hash, rr } from './film.mjs';

// greeting-atmosphere.md §6.1 — clear-sky stops by solar band.
export const CLEAR = [
  // name, zenith, mid, horizon
  ['night',   '#050A1C', '#0B1634', '#17264C'],
  ['dawn',    '#0E1C4A', '#34427F', '#8A77A8'],
  ['sunrise', '#27427F', '#9A86B4', '#FFB48A'],
  ['morning', '#2A6FD1', '#63A5EA', '#C4E3FA'],
  ['noon',    '#1D62D8', '#4E9CF2', '#AAD8FF'],
  ['afternoon','#2C66C2', '#72A8DE', '#EFDFC4'],
  ['sunset',  '#2B3A7A', '#C4668A', '#FF9656'],
  ['dusk',    '#141A46', '#3E3070', '#A6566E'],
];
// §6.1 — overcast veils the clear stops toward these tints.
export const OVERCAST = [
  ['night',   '#0A1021', '#101A34', '#182547'],
  ['dawn',    '#17244B', '#344172', '#796C96'],
  ['sunrise', '#354C7F', '#8B80A6', '#E0A687'],
  ['morning', '#457DCC', '#73A7DE', '#BBD7ED'],
  ['noon',    '#4E86D6', '#7FB0E6', '#C7DFF2'],
  ['afternoon','#4E7FC8', '#8AAEDF', '#E4E4DE'],
  ['sunset',  '#3B4577', '#9C7F9F', '#E0A183'],
  ['dusk',    '#1B2246', '#4A3F73', '#8E6274'],
];

export const hex2rgb = (h) => {
  if (typeof h !== 'string') throw new TypeError(`not a hex colour: ${h}`);
  const s = h.replace('#', '');
  const n = s.length === 3 ? s.split('').map((c) => c + c).join('') : s;
  return [0, 2, 4].map((i) => parseInt(n.slice(i, i + 2), 16));
};
export const rgb2css = (c) => `rgb(${c.map((v) => Math.round(clamp(v, 0, 255))).join(',')})`;
export const rgbaCss = (c, a) =>
  `rgba(${c.map((v) => Math.round(clamp(v, 0, 255))).join(',')},${clamp(a)})`;
/** Mix two hex colours; `t` is how far toward `b`. Accepts and returns hex. */
export function mixHexRaw(a, b, t) {
  const A = hex2rgb(a), B = hex2rgb(b);
  return '#' + A.map((v, i) => Math.round(lerp(v, B[i], t)).toString(16).padStart(2, '0')).join('');
}
export const mixHex = (a, b, t) => rgb2css(hex2rgb(mixHexRaw(a, b, t)));

/** Band index + within-band fraction from solar altitude (degrees). */
export function bandFor(alt) {
  if (alt < -18) return [0, clamp((alt + 30) / 12)];
  if (alt < -4) return [1, clamp((alt + 18) / 14)];
  if (alt < 8) return [2, clamp((alt + 4) / 12)];
  if (alt < 35) return [3, clamp((alt - 8) / 27)];
  if (alt > 35) return [4, 0];
  return [3, 1];
}

/**
 * The three sky stops (zenith / mid / horizon) as **hex**, so the result can be
 * fed back into `mixHexRaw` — the glow overlay and the cloud tints both do. A
 * function that returns css strings from hex inputs looks harmless and then
 * breaks the moment its own output is used as an input.
 */
export function skyStops(alt, overcast = 0) {
  const [lo, f] = bandFor(alt);
  const hi = Math.min(lo + 1, CLEAR.length - 1);
  const pick = (table, i) => table[i].slice(1);
  const blend = (a, b) => a.map((c, i) => mixHexRaw(c, b[i], f * 0.9));
  const clear = blend(pick(CLEAR, lo), pick(CLEAR, hi));
  const over = blend(pick(OVERCAST, lo), pick(OVERCAST, hi));
  return clear.map((c, i) => (overcast > 0.01 ? mixHexRaw(over[i], c, 1 - overcast) : c));
}

/** The sun's apparent tint by altitude (§5.5). */
export function sunTint(alt) {
  if (alt >= 40) return '#FFF6E0';
  if (alt >= 15) return mixHexRaw('#FFE3A8', '#FFF6E0', (alt - 15) / 25);
  if (alt >= 5) return mixHexRaw('#FFB86B', '#FFE3A8', (alt - 5) / 10);
  if (alt >= 0) return mixHexRaw('#FF8A4C', '#FFB86B', alt / 5);
  return '#F37A5C';
}

/** Cloud coverage per weather (§5.3: clear .78 → thunder .04 are *clearance*). */
export const WEATHER = {
  clear:  { clearance: 0.78, label: '晴', glyph: 'sun', rain: 0 },
  partly: { clearance: 0.52, label: '多云', glyph: 'cloud-sun', rain: 0 },
  overcast:{ clearance: 0.18, label: '阴', glyph: 'cloud', rain: 0 },
  rain:   { clearance: 0.10, label: '阵雨', glyph: 'cloud-rain', rain: 1 },
  heavy:  { clearance: 0.06, label: '大雨', glyph: 'cloud-rain', rain: 1.6 },
  snow:   { clearance: 0.12, label: '有雪', glyph: 'cloud-snow', rain: -1 },
};

/**
 * Paint the sky. `scene` carries the solar state, the weather, the drift the
 * clouds have accumulated, and how much rain is in the air.
 */
export function drawSky(g, {
  x, y, w, h, alt, azimuth = 0.5, weather = WEATHER.clear, time = 0,
  sunX = null, sunY = null, veil = 0,
}) {
  const overcast = 1 - weather.clearance;
  const stops = skyStops(alt, overcast);

  g.save();
  rr(g, x, y, w, h, 32);
  g.clip();

  const grd = g.createLinearGradient(0, y, 0, y + h);
  grd.addColorStop(0, rgbaCss(hex2rgb(stops[0]), 1));
  grd.addColorStop(0.55, rgbaCss(hex2rgb(stops[1]), 1));
  grd.addColorStop(1, rgbaCss(hex2rgb(stops[2]), 1));
  g.fillStyle = grd;
  g.fillRect(x, y, w, h);

  // Horizon glow centred on the body's azimuth (§6.1 overlay).
  const gx = sunX == null ? x + w * azimuth : sunX;
  const gy = sunY == null ? y + h * 0.92 : sunY;
  const glowA = alt > 20 ? 0.35 : alt > 5 ? 0.3 : alt > -4 ? 0.42 : 0.16;
  const rg = g.createRadialGradient(gx, gy, 0, gx, gy, w * 0.9);
  rg.addColorStop(0, rgbaCss(hex2rgb(mixHexRaw(stops[2], '#FFFFFF', 0.12)), glowA));
  rg.addColorStop(0.55, rgbaCss(hex2rgb(mixHexRaw(stops[1], stops[2], 0.5)), glowA * 0.35));
  rg.addColorStop(1, 'rgba(0,0,0,0)');
  g.fillStyle = rg;
  g.fillRect(x, y, w, h);

  // Night: stars fade in between -6° and -18° (§5.5), and only 12% twinkle.
  if (alt < -6) {
    const vis = clamp((-6 - alt) / 12);
    for (let i = 0; i < 260; i++) {
      const sx = x + hash(i * 3.1) * w;
      const sy = y + hash(i * 7.7) * h * 0.86;
      const tw = hash(i * 11.3) < 0.12 ? 0.75 + 0.25 * Math.sin(time * (0.6 + hash(i) * 1.8) + i) : 1;
      const mag = 0.6 + hash(i * 5.5) * 1.6;
      g.globalAlpha = vis * tw * (0.35 + hash(i * 2.2) * 0.55);
      g.fillStyle = '#FFFFFF';
      g.beginPath(); g.arc(sx, sy, mag, 0, Math.PI * 2); g.fill();
    }
    g.globalAlpha = 1;
  }

  // Body: disc + halo, sized up near the horizon (the horizon illusion, §5.5).
  const horizonBoost = 1 + 0.35 * (1 - S(alt, 0, 15));
  if (alt > -1) {
    const r = 22 * horizonBoost;
    const tint = sunTint(alt);
    const halo = g.createRadialGradient(gx, gy, 0, gx, gy, r * 7);
    halo.addColorStop(0, hexA(tint, 0.55));
    halo.addColorStop(0.25, hexA(tint, 0.22));
    halo.addColorStop(1, 'rgba(0,0,0,0)');
    g.fillStyle = halo;
    g.beginPath(); g.arc(gx, gy, r * 7, 0, Math.PI * 2); g.fill();
    g.fillStyle = tint;
    g.beginPath(); g.arc(gx, gy, r, 0, Math.PI * 2); g.fill();
  } else {
    // Moon: a disc with a terminator ellipse and a 6% earthshine floor.
    const r = 16 * horizonBoost;
    const halo = g.createRadialGradient(gx, gy, 0, gx, gy, r * 8);
    halo.addColorStop(0, 'rgba(244,247,255,0.30)');
    halo.addColorStop(1, 'rgba(0,0,0,0)');
    g.fillStyle = halo;
    g.beginPath(); g.arc(gx, gy, r * 8, 0, Math.PI * 2); g.fill();
    g.fillStyle = '#F4F7FF';
    g.beginPath(); g.arc(gx, gy, r, 0, Math.PI * 2); g.fill();
    g.fillStyle = 'rgba(12,16,34,0.88)';
    g.save();
    g.beginPath(); g.arc(gx, gy, r, 0, Math.PI * 2); g.clip();
    g.beginPath(); g.ellipse(gx - r * 0.55, gy, r * 0.95, r, 0, 0, Math.PI * 2); g.fill();
    g.restore();
  }

  // Cloud layers: two fBm sheets drifting at different speeds (§5.4). The
  // clearance value is the threshold, so "clear" leaves only wispy edges.
  const cov = 1 - weather.clearance;
  if (cov > 0.05) {
    drawCloudSheet(g, { x, y, w, h, seed: 11, scale: 0.0016, speed: 4, thresh: 0.86 - cov * 0.5,
                        alpha: 0.5 * cov + 0.16, tint: lighter(stops[1]), time, blur: 26 });
    drawCloudSheet(g, { x, y, w, h, seed: 41, scale: 0.0031, speed: 9, thresh: 0.80 - cov * 0.42,
                        alpha: 0.42 * cov + 0.12, tint: lighter(stops[2]), time, blur: 12 });
  } else {
    drawCloudSheet(g, { x, y, w, h, seed: 7, scale: 0.0012, speed: 2.4, thresh: 0.93,
                        alpha: 0.22, tint: lighter(stops[2]), time, blur: 30 });
  }

  if (veil) { g.fillStyle = `rgba(8,18,38,${veil})`; g.fillRect(x, y, w, h); }
  g.restore();
}

/** Hex + alpha as a css colour. Every gradient stop goes through this or
 *  `rgbaCss`, because a hand-rolled string concat is how a stop ends up as
 *  `rgb(NaN,NaN,7)` and the whole frame throws at addColorStop. */
function hexA(hex, a) { return rgbaCss(hex2rgb(hex), a); }
function lighter(hex, amt = 0.3) { return mixHexRaw(hex, '#FFFFFF', amt); }

function drawCloudSheet(g, { x, y, w, h, seed, scale, speed, thresh, alpha, tint, time, blur }) {
  g.save();
  rr(g, x, y, w, h, 32); g.clip();
  g.filter = `blur(${blur}px)`;
  const step = 14;
  for (let py = -step; py < h + step; py += step) {
    for (let px = -step; px < w + step; px += step) {
      const wx = px + time * speed;
      const n = fbm((wx * scale) + seed + (py * scale) * 0.7, 4);
      const v = n - thresh;
      if (v <= 0) continue;
      g.globalAlpha = clamp(v * 3.2) * alpha;
      g.fillStyle = tint;
      g.beginPath();
      g.ellipse(x + px, y + py + v * 80, step * 1.5, step * 0.92, 0, 0, Math.PI * 2);
      g.fill();
    }
  }
  g.restore();
}

/** Rain: the far sheet of stretched threads, then the near, defocused drops. */
export function drawRain(g, { x, y, w, h, time, density = 1, wind = 0, near = 30, far = 220 }) {
  g.save();
  rr(g, x, y, w, h, 32); g.clip();
  const tilt = Math.min(18, wind * 0.6) * Math.PI / 180;

  g.strokeStyle = 'rgba(255,255,255,0.22)';
  g.lineWidth = 0.6;
  for (let i = 0; i < far * density; i++) {
    const seed = hash(i * 1.7);
    const sp = 620;
    const yy = ((seed * h + time * sp) % (h + 60)) - 30;
    const xx = (hash(i * 3.3) * w + yy * Math.tan(tilt) + time * 30) % w;
    g.beginPath();
    g.moveTo(x + xx, y + yy);
    g.lineTo(x + xx - 14 * Math.sin(tilt), y + yy + 14);
    g.stroke();
  }

  g.strokeStyle = 'rgba(255,255,255,0.30)';
  g.lineWidth = 1.4;
  g.filter = 'blur(4px)';
  for (let i = 0; i < near * density; i++) {
    const seed = hash(i * 9.1 + 3);
    const yy = ((seed * h + time * 700) % (h + 120)) - 60;
    const xx = (hash(i * 4.7) * w + yy * Math.tan(tilt)) % w;
    g.beginPath();
    g.moveTo(x + xx, y + yy);
    g.lineTo(x + xx - 38 * Math.sin(tilt), y + yy + 38);
    g.stroke();
  }
  g.restore();
}

/** Snow: three depth layers with a Brownian drift (§5.4). */
export function drawSnow(g, { x, y, w, h, time, density = 1 }) {
  const layers = [
    { n: 180, r: 1.2, sp: 18, blur: 1, a: 0.5 },
    { n: 90, r: 2.5, sp: 32, blur: 0, a: 0.7 },
    { n: 16, r: 6.5, sp: 54, blur: 5, a: 0.85 },
  ];
  g.save();
  rr(g, x, y, w, h, 32); g.clip();
  for (const L of layers) {
    g.filter = L.blur ? `blur(${L.blur}px)` : 'none';
    g.fillStyle = `rgba(255,255,255,${L.a})`;
    for (let i = 0; i < L.n * density; i++) {
      const seed = hash(i * 2.9 + L.n);
      const yy = ((seed * h + time * L.sp) % (h + 40)) - 20;
      const drift = Math.sin(time * 0.7 + seed * 9) * 12;
      const xx = (hash(i * 6.1) * w + drift) % w;
      g.beginPath(); g.arc(x + xx, y + yy, L.r, 0, Math.PI * 2); g.fill();
    }
  }
  g.restore();
}

/**
 * The card's own glass droplets (§8.5) — the film's one "there is a hand here"
 * moment. Each drop is a lens: it samples the sky upside down, grows on
 * landing, then slides with a wet trail behind it.
 */
export function drawDroplets(g, { x, y, w, h, drops }) {
  g.save();
  rr(g, x, y, w, h, 32); g.clip();
  for (const d of drops) {
    if (d.life <= 0) continue;
    const r = d.r * d.grow;
    // Wet trail behind a sliding drop: a tapering smear, not a second drop.
    if (d.trail > 0) {
      const tg = g.createLinearGradient(d.x, d.y - d.trail, d.x, d.y);
      tg.addColorStop(0, 'rgba(255,255,255,0)');
      tg.addColorStop(1, `rgba(255,255,255,${0.16 * d.life})`);
      g.fillStyle = tg;
      g.fillRect(d.x - r * 0.55, d.y - d.trail, r * 1.1, d.trail);
    }
    g.save();
    g.globalAlpha = d.life;
    // The lens: dark rim, bright top-left highlight, and an inverted sky sample.
    const lens = g.createRadialGradient(d.x - r * 0.3, d.y - r * 0.35, r * 0.1, d.x, d.y, r);
    lens.addColorStop(0, 'rgba(255,255,255,0.85)');
    lens.addColorStop(0.45, 'rgba(255,255,255,0.18)');
    lens.addColorStop(1, 'rgba(0,0,0,0.30)');
    g.fillStyle = lens;
    g.beginPath(); g.ellipse(d.x, d.y, r * 0.92, r, 0, 0, Math.PI * 2); g.fill();
    g.strokeStyle = 'rgba(255,255,255,0.55)';
    g.lineWidth = 0.8;
    g.beginPath(); g.ellipse(d.x, d.y, r * 0.92, r, 0, 0, Math.PI * 2); g.stroke();
    // Contact shadow — the drop sits on glass, not in it.
    g.strokeStyle = 'rgba(0,0,0,0.18)';
    g.beginPath(); g.ellipse(d.x, d.y + r * 0.9, r * 0.7, r * 0.16, 0, 0, Math.PI * 2); g.stroke();
    // Ripple on landing.
    if (d.ripple > 0 && d.ripple < 1) {
      g.globalAlpha = d.life * (1 - d.ripple);
      g.strokeStyle = 'rgba(255,255,255,0.6)';
      g.lineWidth = 0.8;
      g.beginPath(); g.ellipse(d.x, d.y, r * (1 + d.ripple * 2), r * (1 + d.ripple * 2), 0, 0, Math.PI * 2); g.stroke();
    }
    g.restore();
  }
  g.restore();
}
