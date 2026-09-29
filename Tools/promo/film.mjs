// ClaudeBar promo film — renderer core.
//
// The whole film is a pure function of t: draw(t) paints one frame onto a
// 1920x1080 canvas, the driver walks t in 1/30 s steps and Chrome captures each
// one. Nothing here reads the clock, the network or a file at draw time — that
// is what makes a frame reproducible and a re-render honest.
//
// Geometry, colour and timing are taken from docs/promo/prompt.md, which is the
// film's single specification. Where a number appears here it exists there too.

import { readFileSync, existsSync } from 'node:fs';

export const W = 1920;
export const H = 1080;
export const FPS = 30;

// ---------------------------------------------------------------- palette
// prompt.md §3: ice canvas in light, graphite in dark. Colour lives in the
// data, the island and the brand mark — never in the film's own background.
export const INK = {
  light: { canvas: '#EEF3F8', title: '#1D1D1F', body: '#6E6E73', faint: '#86868B',
           card: '#FFFFFF', hair: 'rgba(0,0,0,0.08)', shadow: 'rgba(20,24,32,0.14)' },
  dark:  { canvas: '#16181C', title: '#F5F5F7', body: '#A1A1A6', faint: '#A1A1A6',
           card: '#252A31', hair: 'rgba(255,255,255,0.10)', shadow: 'rgba(0,0,0,0.45)' },
};

// prompt.md §1: the film's own easing names. One vocabulary, no ad-hoc curves.
export const EASE = {
  slow:  [0.4, 0, 0.2, 1],
  enter: [0.16, 1, 0.3, 1],
  snap:  [0.34, 1.56, 0.64, 1],
  wipe:  [0.65, 0, 0.35, 1],
};

// ---------------------------------------------------------------- easing
export const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
export const lerp = (a, b, t) => a + (b - a) * t;
export const inv = (a, b, v) => (b === a ? 0 : (v - a) / (b - a));

/** cubic-bezier(p1x,p1y,p2x,p2y) — the same solve the browser uses. */
export function cubicBezier(p1x, p1y, p2x, p2y) {
  const A = (a, b) => 1 - 3 * b + 3 * a;
  const B = (a, b) => 3 * b - 6 * a;
  const C = (a) => 3 * a;
  const calc = (t, a, b) => ((A(a, b) * t + B(a, b)) * t + C(a)) * t;
  const slope = (t, a, b) => 3 * A(a, b) * t * t + 2 * B(a, b) * t + C(a);
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const s = slope(t, p1x, p2x);
      if (Math.abs(s) < 1e-6) break;
      t -= (calc(t, p1x, p2x) - x) / s;
    }
    return calc(t, p1y, p2y);
  };
}

export const CURVE = Object.fromEntries(
  Object.entries(EASE).map(([k, c]) => [k, cubicBezier(...c)]));

/** Eased 0→1 over [t0,t1] on curve `name`. */
export function ramp(t, t0, t1, name = 'slow') {
  return CURVE[name](clamp(inv(t0, t1, t)));
}

/** 0→1→0 with an attack and a release, both eased. */
export function gate(t, inA, inB, outA, outB, name = 'slow') {
  return ramp(t, inA, inB, name) * (1 - ramp(t, outA, outB, name));
}

/** A one-shot pulse: rises over `attack`, decays over `decay`, both from `t0`. */
export function pulse(t, t0, attack, decay, name = 'slow') {
  return ramp(t, t0, t0 + attack, name) * (1 - ramp(t, t0 + attack, t0 + attack + decay, name));
}

export const S = (t, a, b) => {
  const x = clamp((t - a) / (b - a));
  return x * x * (3 - 2 * x);
};

// ---------------------------------------------------------------- rng
/** Deterministic 1-D value noise. Same t, same picture. */
export function hash(n) {
  const s = Math.sin(n * 127.1 + 311.7) * 43758.5453123;
  return s - Math.floor(s);
}
export function noise1(x) {
  const i = Math.floor(x), f = x - i;
  const u = f * f * (3 - 2 * f);
  return lerp(hash(i), hash(i + 1), u);
}
export function fbm(x, oct = 4) {
  let v = 0, a = 0.5, f = 1;
  for (let i = 0; i < oct; i++) { v += a * noise1(x * f); f *= 2.03; a *= 0.5; }
  return v;
}

// ---------------------------------------------------------------- draw helpers
export function rr(g, x, y, w, h, r) {
  const k = Math.min(r, w / 2, h / 2);
  g.beginPath();
  g.moveTo(x + k, y);
  g.arcTo(x + w, y, x + w, y + h, k);
  g.arcTo(x + w, y + h, x, y + h, k);
  g.arcTo(x, y + h, x, y, k);
  g.arcTo(x, y, x + w, y, k);
  g.closePath();
  return g;
}

export function fillRR(g, x, y, w, h, r, style) {
  g.fillStyle = style;
  rr(g, x, y, w, h, r);
  g.fill();
}

export function strokeRR(g, x, y, w, h, r, style, lw = 1) {
  g.strokeStyle = style;
  g.lineWidth = lw;
  rr(g, x, y, w, h, r);
  g.stroke();
}

/** The card shadow the app uses (`Theme.PanelCardModifier` / prompt.md §3). */
export function cardShadow(ctx, drawFn, { blur = 40, dy = 18, color = 'rgba(20,24,32,0.14)' } = {}) {
  ctx.save();
  ctx.shadowColor = color;
  ctx.shadowBlur = blur;
  ctx.shadowOffsetY = dy;
  drawFn();
  ctx.restore();
}

export function text(g, str, x, y, {
  size = 24, weight = 400, family = 'display', color = '#1D1D1F',
  align = 'left', baseline = 'alphabetic', tracking = 0, opacity = 1, mono = false,
} = {}) {
  const fam = mono ? 'ui-monospace, SFMono-Regular, Menlo, monospace'
    : family === 'rounded' ? 'ui-rounded, "SF Pro Rounded", -apple-system, sans-serif'
    : family === 'script' ? '"Snell Roundhand", "Borel", cursive'
    : '"SF Pro Display", "SF Pro Text", -apple-system, BlinkMacSystemFont, sans-serif';
  g.save();
  g.globalAlpha *= opacity;
  g.font = `${weight} ${size}px ${fam}`;
  g.textAlign = align;
  g.textBaseline = baseline;
  g.fillStyle = color;
  if (tracking) {
    // Letter-spacing is not a canvas primitive; draw per glyph.
    const chars = [...str];
    const widths = chars.map((c) => g.measureText(c).width + tracking);
    const total = widths.reduce((a, b) => a + b, 0) - tracking;
    let cx = align === 'center' ? x - total / 2 : align === 'right' ? x - total : x;
    const prev = g.textAlign; g.textAlign = 'left';
    chars.forEach((c, i) => { g.fillText(c, cx, y); cx += widths[i]; });
    g.textAlign = prev;
  } else {
    g.fillText(str, x, y);
  }
  g.restore();
}

export function measure(g, str, { size = 24, weight = 400, family = 'display', mono = false, tracking = 0 } = {}) {
  const fam = mono ? 'ui-monospace, SFMono-Regular, Menlo, monospace'
    : family === 'rounded' ? 'ui-rounded, "SF Pro Rounded", -apple-system, sans-serif'
    : family === 'script' ? '"Snell Roundhand", "Borel", cursive'
    : '"SF Pro Display", "SF Pro Text", -apple-system, sans-serif';
  g.save();
  g.font = `${weight} ${size}px ${fam}`;
  const w = g.measureText(str).width + tracking * Math.max(0, [...str].length - 1);
  g.restore();
  return w;
}

/** Tokens, the app's way: 亿 in Chinese units, M otherwise. */
export function fmtTokens(n, style = 'chinese') {
  if (style === 'chinese') {
    if (n >= 1e8) return { v: (n / 1e8).toFixed(2).replace(/\.?0+$/, ''), u: '亿' };
    if (n >= 1e4) return { v: (n / 1e4).toFixed(1).replace(/\.0$/, ''), u: '万' };
    return { v: String(Math.round(n)), u: '' };
  }
  if (n >= 1e6) return { v: (n / 1e6).toFixed(2).replace(/\.?0+$/, ''), u: 'M' };
  if (n >= 1e3) return { v: (n / 1e3).toFixed(1).replace(/\.0$/, ''), u: 'K' };
  return { v: String(Math.round(n)), u: '' };
}

// ---------------------------------------------------------------- assets
const ASSET_CACHE = new Map();
export function loadAsset(env, rel) {
  const key = rel;
  if (ASSET_CACHE.has(key)) return ASSET_CACHE.get(key);
  const meta = env && env.assets ? env.assets[rel] : null;
  if (!meta) { ASSET_CACHE.set(key, null); return null; }
  const img = new Image();
  img.src = meta;
  ASSET_CACHE.set(key, img);
  return img;
}

// ---------------------------------------------------------------- chrome
/**
 * The screen's top edge with a hardware notch, drawn behind the island. This is
 * the Mac's own object, not the app's — the island melts into it (prompt.md §4
 * scene 5: the collapsed island is edge-less and casts nothing).
 */
export function drawScreenEdge(g, { notch = { w: 200, h: 46 }, height = 46, dim = 1 } = {}) {
  const cx = W / 2;
  g.save();
  g.globalAlpha = dim;
  // The bezel band across the full width.
  g.fillStyle = '#050607';
  g.fillRect(0, 0, W, height);
  // The notch itself: top corners flare into the band, bottom corners rounded.
  const x = cx - notch.w / 2, y = 0, w = notch.w, h = notch.h;
  const r = 11, flare = 6;
  g.beginPath();
  g.moveTo(x - flare, y);
  g.quadraticCurveTo(x, y, x + r, y + r);
  g.lineTo(x + w - r, y + r);
  g.quadraticCurveTo(x + w, y, x + w + flare, y);
  g.lineTo(x + w + flare, y + h - r);
  g.quadraticCurveTo(x + w + flare, y + h, x + w + flare - r, y + h);
  g.lineTo(x - flare + r, y + h);
  g.quadraticCurveTo(x - flare, y + h, x - flare, y + h - r);
  g.closePath();
  g.fillStyle = '#000';
  g.fill();
  g.restore();
}

/** The menu-bar status item: mark, two rate rows, battery — and nothing else. */
export function drawStatusItem(g, x, y, {
  icon, down = '1.7K', up = '0.6K', tunneled = false, level = 82, charging = false,
  ink = INK.light, scale = 1, opacity = 1,
} = {}) {
  g.save();
  g.globalAlpha *= opacity;
  g.translate(x, y);
  g.scale(scale, scale);

  const green = '#31D159';
  const rate = tunneled ? green : (ink === INK.dark ? '#FFFFFF' : '#1D1D1F');

  if (icon) g.drawImage(icon, 0, 0, 22, 22);

  let cx = 28;
  // Two rate rows: ↓ above ↑, each unit-tinted; the arrow is the same colour as
  // its number so the pair reads as one reading (MenuBarController.rateColor).
  g.font = '600 10px ui-rounded, "SF Pro Rounded", -apple-system, sans-serif';
  g.textAlign = 'left'; g.textBaseline = 'middle';
  g.fillStyle = rate;
  g.fillText('↓', cx, -5);
  g.fillText('↑', cx, 7);
  const aw = g.measureText('↑').width + 2;
  g.fillText(down, cx + aw, -5);
  g.fillText(up, cx + aw, 7);
  cx += aw + Math.max(g.measureText(down).width, g.measureText(up).width) + 12;

  // Battery: shell, level, and the terminal nub.
  const bw = 30, bh = 13;
  g.strokeStyle = ink === INK.dark ? 'rgba(255,255,255,0.55)' : 'rgba(0,0,0,0.42)';
  g.lineWidth = 1.4;
  rr(g, cx, -bh / 2, bw, bh, 3.5); g.stroke();
  g.fillStyle = g.strokeStyle;
  rr(g, cx + bw + 1.5, -3, 2, 6, 1); g.fill();
  const lvl = clamp(level / 100);
  g.fillStyle = charging ? green : lvl <= 0.1 ? '#FF3B30' : lvl <= 0.2 ? '#FF9F0A' : '#FFFFFF';
  rr(g, cx + 2.5, -bh / 2 + 2.5, (bw - 5) * lvl, bh - 5, 2); g.fill();
  cx += bw + 8;
  g.fillStyle = ink === INK.dark ? 'rgba(255,255,255,0.85)' : 'rgba(0,0,0,0.75)';
  g.font = '600 10px ui-rounded, "SF Pro Rounded", -apple-system, sans-serif';
  g.fillText(`${level}%`, cx, 0);
  g.restore();
  return cx + 30;
}

/** A soft round pointer, so a hover or click has a visible cause. */
export function drawPointer(g, x, y, { r = 7, press = 0, opacity = 1 } = {}) {
  g.save();
  g.globalAlpha *= opacity;
  const rr2 = r * (1 - press * 0.28);
  const grd = g.createRadialGradient(x, y, 0, x, y, rr2 * 3.2);
  grd.addColorStop(0, 'rgba(255,255,255,0.95)');
  grd.addColorStop(0.35, 'rgba(255,255,255,0.55)');
  grd.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = grd;
  g.beginPath(); g.arc(x, y, rr2 * 3.2, 0, Math.PI * 2); g.fill();
  g.fillStyle = 'rgba(255,255,255,0.92)';
  g.beginPath(); g.arc(x, y, rr2, 0, Math.PI * 2); g.fill();
  g.strokeStyle = 'rgba(0,0,0,0.28)';
  g.lineWidth = 1;
  g.beginPath(); g.arc(x, y, rr2, 0, Math.PI * 2); g.stroke();
  g.restore();
}

// ---------------------------------------------------------------- text blocks
/** A headline + body pair, the film's only on-screen prose (prompt.md §3). */
export function drawCopy(g, { eyebrow, title, body, x, y, width = 620, ink = INK.light,
                              titleSize = 84, bodySize = 24, opacity = 1, dy = 0 }) {
  g.save();
  g.globalAlpha *= opacity;
  let cy = y + dy;
  if (eyebrow) {
    text(g, eyebrow, x, cy, { size: 15, weight: 590, color: ink.faint, tracking: 0.08 * 15 });
    cy += 34;
  }
  const lines = wrap(g, title, width, { size: titleSize, weight: 600, tracking: -0.045 * titleSize });
  lines.forEach((ln) => {
    text(g, ln, x, cy + titleSize * 0.86, { size: titleSize, weight: 600, color: ink.title,
                                             tracking: -0.045 * titleSize });
    cy += titleSize * 1.02;
  });
  if (body) {
    cy += 22;
    const bl = wrap(g, body, Math.min(width, 480), { size: bodySize, weight: 400 });
    bl.forEach((ln) => {
      text(g, ln, x, cy + bodySize * 0.9, { size: bodySize, weight: 400, color: ink.body });
      cy += bodySize * 1.45;
    });
  }
  g.restore();
}

export function wrap(g, str, width, opts) {
  const words = str.split(/(?<=[\u4e00-\u9fff、。，：；）])| /).filter(Boolean);
  const out = [];
  let line = '';
  for (const w of words) {
    const cand = line + (line && /[A-Za-z0-9]$/.test(line) && /^[A-Za-z0-9]/.test(w) ? ' ' : '') + w;
    if (measure(g, cand, opts) > width && line) { out.push(line); line = w; }
    else line = cand;
  }
  if (line) out.push(line);
  return out;
}
