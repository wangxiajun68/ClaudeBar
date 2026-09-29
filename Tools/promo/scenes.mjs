// The film. One exported function per scene; each paints the 1920x1080 canvas
// for a given local time and returns nothing. scenes.mjs owns *what is on
// screen*; film.mjs owns how it is drawn and driver.mjs owns when.
//
// Every number that matters (scale, colour, duration) traces back to
// docs/promo/prompt.md §4. If a scene drifts from that document, the document
// is right and this file is wrong.

import * as F from './film.mjs';
// The scenes are written against the film core's names directly. When the page
// flattens the three modules into one script, `stripModules` removes this whole
// statement; the names it would have bound are already in scope because
// film.mjs is inlined above. Nothing else here depends on `F`.
const NS = (name) => ((__wx && __wx[name]) || undefined);
const { S, lerp, clamp, ramp, gate, pulse, hash, fbm,
        rr, fillRR, strokeRR, text, measure, fmtTokens, INK,
        drawScreenEdge, drawStatusItem, drawPointer, drawCopy, wrap } = F;
import * as Wx from './weather.mjs';
// These alias the weather module's functions under plain names. In module form
// they come from the namespace; the flattened page rebinds them the same way, so
// a call site reads identically either way.
const WX_drawSky = Wx.drawSky, WX_drawRain = Wx.drawRain, WX_drawSnow = Wx.drawSnow;
const WX_drawDroplets = Wx.drawDroplets, WX_sunTint = Wx.sunTint, WX_mixHex = Wx.mixHex;
const WX_WEATHER = Wx.WEATHER, WX_skyStops = Wx.skyStops, WX_bandFor = Wx.bandFor;

// ---------------------------------------------------------------- camera
/**
 * The film's only three moves (prompt.md §2): push in, pull out, hold. The
 * background always travels at 0.35x the foreground, which is what makes a
 * scale change read as "moving closer" rather than "zooming a picture".
 */
function withCamera(g, cam, drawFn) {
  const s = cam.scale ?? 1;
  const fx = cam.x ?? W / 2, fy = cam.y ?? H / 2;
  g.save();
  g.translate(fx, fy);
  g.scale(s, s);
  g.translate(-fx - (cam.bgDx ?? 0) * 0.35, -fy - (cam.bgDy ?? 0) * 0.35);
  g.translate(cam.dx ?? 0, cam.dy ?? 0);
  drawFn(g);
  g.restore();
}

// ---------------------------------------------------------------- chrome
function titleCard(g, t, { mark, alt = null, name = 'ClaudeBar',
                           sub = '菜单栏里的 AI 工作台', meta = 'macOS 15 · Apple Silicon · MIT',
                           markSize = 188, nameSize = 84, ink, glow = 0 }) {
  const cx = W / 2;
  const y0 = H / 2;
  const inA = ramp(t, 0.15, 1.05, 'enter');
  const inB = ramp(t, 0.35, 1.25, 'enter');
  const inC = ramp(t, 0.55, 1.45, 'enter');

  if (glow > 0) {
    const rg = g.createRadialGradient(cx, y0 - 40, 0, cx, y0 - 40, 900);
    rg.addColorStop(0, `rgba(150,170,255,${0.16 * glow})`);
    rg.addColorStop(1, 'rgba(150,170,255,0)');
    g.fillStyle = rg;
    g.fillRect(0, 0, W, H);
  }

  const my = y0 - 90 + (1 - inA) * 18;
  g.save();
  g.globalAlpha = inA;
  if (mark) {
    g.save();
    g.shadowColor = ink.shadow; g.shadowBlur = 70; g.shadowOffsetY = 28;
    rr(g, cx - markSize / 2, my - markSize / 2, markSize, markSize, markSize * 0.22);
    g.fillStyle = '#FFFFFF'; g.fill();
    g.restore();
    g.save();
    rr(g, cx - markSize / 2, my - markSize / 2, markSize, markSize, markSize * 0.22); g.clip();
    g.drawImage(mark, cx - markSize / 2, my - markSize / 2, markSize, markSize);
    g.restore();
  } else if (alt) {
    alt(g, cx, my, markSize);
  }
  g.restore();

  text(g, name, cx, my + markSize / 2 + 32 + nameSize * 0.82,
       { size: nameSize, weight: 600, color: ink.title, align: 'center',
         tracking: -0.045 * nameSize, opacity: inB });
  text(g, sub, cx, my + markSize / 2 + 32 + nameSize * 1.02 + 26,
       { size: 28, weight: 400, color: ink.faint, align: 'center', opacity: inB * 0.95 });
  if (meta) {
    text(g, meta, cx, my + markSize / 2 + 32 + nameSize * 1.02 + 76,
         { size: 17, weight: 400, color: ink.faint, align: 'center',
           tracking: 0.04 * 17, opacity: inC * 0.85 });
  }
}

// ================================================================= 1 · title
export function scene1(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);
  const out = ramp(t, 4.6, 5.4, 'slow');
  g.globalAlpha = 1 - out;
  withCamera(g, { scale: lerp(1.0, 1.02, ramp(t, 0, 6.6, 'slow')) }, (c) => {
    titleCard(c, t, { mark: env.assets.icon, ink });
  });
  g.globalAlpha = 1;
}

// ========================================================= 2 · the four icons
const TOOLS = [
  { gly: 'shield', label: 'VPN' },
  { gly: 'arrow-left-right', label: '代理' },
  { gly: 'shuffle', label: '切换器' },
  { gly: 'list', label: '会话' },
];

function toolGlyph(g, kind, x, y, s, color) {
  g.save();
  g.strokeStyle = color; g.lineWidth = 1.8 * s; g.lineCap = 'round'; g.lineJoin = 'round';
  g.translate(x, y); g.scale(s, s);
  const p = (fn) => { g.beginPath(); fn(); g.stroke(); };
  if (kind === 'shield') {
    p(() => { g.moveTo(0, -11); g.lineTo(9, -7); g.lineTo(9, 3); g.quadraticCurveTo(9, 10, 0, 13);
              g.quadraticCurveTo(-9, 10, -9, 3); g.lineTo(-9, -7); g.closePath(); });
  } else if (kind === 'arrow-left-right') {
    p(() => { g.moveTo(-9, -6); g.lineTo(10, -6); g.moveTo(6, -10); g.lineTo(10, -6); g.lineTo(6, -2); });
    p(() => { g.moveTo(10, 6); g.lineTo(-9, 6); g.moveTo(-6, 2); g.lineTo(-10, 6); g.lineTo(-6, 10); });
  } else if (kind === 'shuffle') {
    p(() => { g.moveTo(-10, -7); g.lineTo(-3, -7); g.lineTo(4, 7); g.lineTo(10, 7); });
    p(() => { g.moveTo(6, 3); g.lineTo(10, 7); g.lineTo(6, 11); });
    p(() => { g.moveTo(-10, 7); g.lineTo(-4, 7); g.lineTo(0, 1); });
  } else {
    p(() => { g.moveTo(-9, -7); g.lineTo(9, -7); g.moveTo(-9, 0); g.lineTo(9, 0); g.moveTo(-9, 7); g.lineTo(4, 7); });
  }
  g.restore();
}

export function scene2(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  const drift = ramp(t, 8.9, 8.9) * 0; // scene-local; the driver owns the cut
  const appear = ramp(t, 0.1, 1.4, 'enter');
  const crowd = ramp(t, 5.0, 6.6, 'slow');      // 11.2 s into the film
  const leave = ramp(t, 7.4, 8.9, 'slow');

  const n = TOOLS.length;
  const tile = 120, step0 = tile - 18, step1 = tile - 62;
  const step = lerp(step0, step1, crowd);
  const totalW = tile + step * (n - 1);
  const startX = W / 2 - totalW / 2 - 240 + drift;

  withCamera(g, { dx: -leave * 520, bgDx: -leave * 520 }, (c) => {
    TOOLS.forEach((tool, i) => {
      const bx = startX + i * step + (1 - appear) * 40;
      const by = H / 2 - 40 + Math.sin(i * 1.7) * 6;
      const sc = lerp(1, 0.92, crowd);
      c.save();
      c.globalAlpha = appear * (1 - leave * 0.4);
      c.translate(bx + tile / 2, by + tile / 2);
      c.scale(sc, sc);
      c.translate(-(bx + tile / 2), -(by + tile / 2));
      c.save();
      c.shadowColor = ink.shadow; c.shadowBlur = 26; c.shadowOffsetY = 10;
      fillRR(c, bx, by, tile, tile, 26, 'rgba(255,255,255,0.92)');
      c.restore();
      strokeRR(c, bx, by, tile, tile, 26, ink.hair, 1);
      // One muted colour for every glyph: this scene is about clutter, not identity.
      toolGlyph(c, tool.gly, bx + tile / 2, by + tile / 2, 1.0, '#6E6E73');
      c.globalAlpha *= 0.75;
      text(c, tool.label, bx + tile / 2, by + tile + 26, { size: 15, weight: 500,
           color: ink.faint, align: 'center' });
      c.restore();
    });
  });

  // The caption sits left of the cluster and fades as the tiles crowd.
  const copyIn = ramp(t, 1.6, 2.6, 'enter');
  g.globalAlpha = copyIn * (1 - ramp(t, 6.6, 7.6, 'slow'));
  drawCopy(g, { eyebrow: '以前', title: '四个图标。',
                body: '每切一次模型，就要离开终端一次。VPN、代理、切换器、会话列表，各自占一个托盘图标。',
                x: 150, y: H / 2 - 210, width: 560, ink });
  g.globalAlpha = 1;
}

// ================================================ the greeting status sheet
/**
 * The card, composed to the real spec (docs/design/greeting-atmosphere.md §2):
 * sky to the sill, the greeting on the 0.62 anchor, the instruments around it,
 * and a 56pt sill carrying the same readings the app shows. The sky itself is
 * drawn by weather.mjs; the type is the card's own hierarchy, not the film's.
 */
export function drawGreetingCard(g, {
  x, y, w, h, t, far, alt, azimuth, weather, greeting, sign, place, temp, condition,
  feels, humidity, wind, rain, sunset, tokens, ccModel, codexModel, cursor, codex, time,
  glyphsDone = 1, sill = 56, scale = 1,
}) {
  const sillH = sill;
  const skyH = h - sillH;

  g.save();
  g.translate(x, y);
  g.scale(scale, scale);

  // Shell: the sky is the fill; the card adds only a hairline and a shadow.
  g.save();
  g.shadowColor = 'rgba(20,24,32,0.18)'; g.shadowBlur = 48; g.shadowOffsetY = 20;
  rr(g, 0, 0, w, h, 32); g.fillStyle = '#0A1230'; g.fill();
  g.restore();

  WX_drawSky(g, { x: 0, y: 0, w, h: skyH, alt, azimuth, weather, time });
  if (rain > 0) WX_drawRain(g, { x: 0, y: 0, w, h: skyH, time, density: rain, wind: 8, near: 30, far: 220 });
  if (rain === -1) WX_drawSnow(g, { x: 0, y: 0, w, h: skyH, time, density: 1 });

  const inkOnSky = alt > -8 ? '#FFFFFF' : '#EEF2FF';
  const M = 32;

  // Clock + date, top left — the mirror of the weather inscription on the right.
  text(g, '16:15', M, skyH * 0.10 + 20, { size: 22, weight: 300, color: inkOnSky, opacity: 0.9 });
  text(g, '9月28日 周一', M + 76, skyH * 0.10 + 20, { size: 11, weight: 500,
       color: inkOnSky, opacity: 0.6, tracking: 0.4 });

  // City and the current reading, right-aligned on the same baseline.
  const rx = w - M;
  text(g, `${place}`, rx - 46, skyH * 0.10 + 20, { size: 11, weight: 500, color: inkOnSky,
       opacity: 0.7, align: 'right' });
  text(g, `${temp}°`, rx, skyH * 0.10 + 26, { size: 22, weight: 300, color: inkOnSky,
       opacity: 0.92, align: 'right' });
  text(g, condition, rx - 62, skyH * 0.10 + 24, { size: 13, weight: 500, color: inkOnSky,
       opacity: 0.78, align: 'right' });
  text(g, `体感 ${feels}° · 湿 ${humidity}% · 东南 3级`, rx, skyH * 0.10 + 48,
       { size: 11, weight: 400, color: inkOnSky, opacity: 0.58, align: 'right' });
  text(g, `↑${temp + 3}° ↓${temp - 4}°`, rx, skyH * 0.10 + 4, { size: 10, weight: 400,
       color: inkOnSky, opacity: 0.6, align: 'right' });

  // The greeting: the only element allowed to cross 60% of the width.
  const gsize = 123;
  const gy = skyH * 0.62 + gsize * 0.34;
  drawScript(g, greeting, M - gsize * 0.04, gy, { size: gsize, color: inkOnSky,
              alt, glyphsDone, time, glow: alt > -6 ? (alt > 5 ? 0.2 : 0.34) : 0.22 });

  // The signature is the greeting's second voice: same optical band (the design
  // puts it below the baseline, right-aligned to column 9), and never in the
  // six-day strip's band — a name read through a forecast column is noise.
  // Right-aligned to the card's own margin, at the greeting's optical block. The
  // six-day strip lives below it (skyH * 0.80), so the two never share a row —
  // measured, because the tracking makes the name wider than it looks.
  text(g, sign, w - M, gy + gsize * 0.30, { size: 22, weight: 600,
       color: inkOnSky, opacity: 0.88, tracking: 0.16 * 20, family: 'rounded',
       align: 'right' });
  // NOTE: `gy` is the greeting's baseline. `skyH * 0.62` is the card's own
  // anchor for it, so the signature lands around 0.72 and the six-day strip is
  // pushed to the sill's shoulder at 0.84 — one clear band each.

  // Sunset line and the one interaction hint.
  text(g, `日落 ${sunset} · 拖动天空，漫游一天`, M, skyH * 0.92 + 14,
       { size: 10, weight: 500, color: inkOnSky, opacity: 0.45 });

  // Sun path: a real arc from today's sunrise to sunset with the body on it.
  const pathY = skyH * 0.92 - 26, pathX = M, pathW = 150;
  g.save();
  g.globalAlpha = 0.45;
  g.strokeStyle = inkOnSky; g.lineWidth = 1; g.setLineDash([3, 3]);
  g.beginPath(); g.moveTo(pathX, pathY);
  g.quadraticCurveTo(pathX + pathW / 2, pathY - 34, pathX + pathW, pathY); g.stroke();
  g.setLineDash([]);
  const ap = clamp((alt + 6) / 100);
  g.fillStyle = WX_sunTint(alt);
  g.beginPath(); g.arc(pathX + pathW * ap, pathY - Math.sin(ap * Math.PI) * 32, 4, 0, Math.PI * 2); g.fill();
  g.restore();

  // Six-day strip, bottom right, on the card's own baseline.
  drawForecast(g, { x: w - M - 340, y: skyH * 0.84, w: 340, h: 68, ink: inkOnSky, time });

  // ---------------------------------------------------------------- sill
  // One glass shelf, no second card inside it (design §7: the card allows
  // exactly one layer of glass).
  g.save();
  rr(g, 0, skyH, w, sillH, 32); g.clip();
  g.fillStyle = 'rgba(10,20,38,0.42)';
  g.fillRect(0, skyH, w, sillH);
  g.fillStyle = 'rgba(255,255,255,0.10)';
  g.fillRect(0, skyH, w, 0.5);
  g.restore();

  const sy = skyH + sillH / 2;
  let sx = 22;
  sx = sillPill(g, sx, sy, ccModel, { mark: env0('anthropic'), sub: null });
  sx = sillPill(g, sx, sy, codexModel, { mark: env0('openai'), sub: null });
  sx = sillPill(g, sx, sy, null, { cursor, codex });
  const tk = fmtTokens(tokens);
  const uw = measure(g, tk.u, { size: 11, weight: 500 });
  const vw2 = measure(g, tk.v, { size: 17, weight: 600, family: 'rounded' });
  text(g, tk.v, w - 22 - uw - 3, sy + 3, { size: 17, weight: 600, family: 'rounded',
       color: '#F2F5FA', align: 'right' });
  text(g, tk.u, w - 22, sy + 4, { size: 11, weight: 500, color: 'rgba(242,245,250,0.75)',
       align: 'right' });
  text(g, '↑33%', w - 22 - uw - 3 - vw2 - 8, sy + 3, { size: 10, weight: 500,
       color: 'rgba(94,234,212,0.9)', align: 'right' });

  g.restore();
}

// The film drawing has no bundle to read marks from, so the driver decodes them
// and hands them in as ready-to-draw images (an <img> that has not loaded draws
// as nothing at all, which is how a missing mark would ship unnoticed).
let __env2 = null;
export function bindEnv(env) { __env2 = env; }
const env0 = (name) => (__env2 && __env2.assets && __env2.assets[name]) || null;

function sillPill(g, x, y, title, { mark, sub, cursor, codex }) {
  const h = 30, pad = 10;
  let contentW = 0;
  if (title) contentW = 18 + 6 + measure(g, title, { size: 11, weight: 600 }) + pad * 2;
  if (cursor) contentW = 22 + 6 + 74 + pad * 2;
  if (codex) contentW = 22 + 6 + 74 + pad * 2;
  fillRR(g, x, y - h / 2, contentW, h, 15, 'rgba(255,255,255,0.08)');
  let cx = x + pad;
  if (mark) { g.drawImage(mark, cx, y - 9, 18, 18); cx += 24; }
  if (title) {
    text(g, title, cx, y + 4, { size: 11, weight: 600, color: 'rgba(242,245,250,0.92)' });
    cx += measure(g, title, { size: 11, weight: 600 });
  }
  if (cursor) {
    cx += 4;
    text(g, 'Cursor', cx, y - 1, { size: 9, weight: 500, color: 'rgba(242,245,250,0.6)' });
    cx += 42;
    ring(g, cx, y, 9, cursor, '#5EEAD4');
    cx += 26;
    text(g, 'Other', cx, y - 1, { size: 9, weight: 500, color: 'rgba(242,245,250,0.6)' });
    cx += 38;
    ring(g, cx, y, 9, codex == null ? 0.6 : 0.6, '#5EEAD4');
  }
  if (codex) {
    // two windows: 5 小时 / 7 天
    const wins = [['5 小时', codex[0]], ['7 天', codex[1]]];
    for (const [label, v] of wins) {
      text(g, label, cx, y - 1, { size: 9, weight: 500, color: 'rgba(242,245,250,0.6)' });
      cx += measure(g, label, { size: 9, weight: 500 }) + 4;
      ring(g, cx, y, 9, v, v <= 0.25 ? '#FFC53D' : '#5EEAD4');
      cx += 24;
    }
  }
  return x + contentW + 8;
}

/** The remaining-allowance arc: it grows with what is left, not what is used. */
function ring(g, cx, cy, r, remaining, color) {
  g.save();
  g.lineWidth = 2;
  g.strokeStyle = 'rgba(255,255,255,0.18)';
  g.beginPath(); g.arc(cx, cy, r, 0, Math.PI * 2); g.stroke();
  g.strokeStyle = color;
  g.lineCap = 'round';
  g.beginPath();
  g.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * clamp(remaining));
  g.stroke();
  g.restore();
  text(g, `${Math.round(remaining * 100)}%`, cx, cy + 0.5, { size: 8, weight: 700,
       color: '#F2F5FA', align: 'center', baseline: 'middle' });
}

/**
 * The greeting's script face. SwiftUI draws a glass glyph by refracting the sky
 * behind it; here the glass is built the other way round — the fill is a light
 * gradient, a directional rim follows the sun's azimuth, and the shadow keeps it
 * legible over a bright noon. The write-on entrance (prompt.md §4 scene 3) is a
 * horizontal reveal over the same glyphs, so the letterforms never change.
 */
function drawScript(g, str, x, y, { size, color, alt, glyphsDone, time, glow }) {
  const font = `400 ${size}px "Snell Roundhand", "Borel", cursive`;
  const total = (() => { g.save(); g.font = font; const w = g.measureText(str).width; g.restore(); return w; })();
  const revealed = total * clamp(glyphsDone);

  g.save();
  g.font = font;
  g.textBaseline = 'alphabetic';

  // Paint the glass word into an offscreen canvas, then composite it through a
  // soft horizontal ramp. A rect clip would leave a hard edge across the
  // letterforms — the nib has to fade in behind where it has already written,
  // not slice the glyph it is inside.
  const pad = Math.ceil(size * 0.9);
  const off = document.createElement('canvas');
  off.width = Math.ceil(total + pad * 2);
  off.height = Math.ceil(size * 2.4);
  const o = off.getContext('2d');
  const ox = pad, oy = off.height * 0.72;

  o.font = font;
  o.textBaseline = 'alphabetic';

  // 1. halo, 2. drop shadow for legibility over a bright noon, 3. the glass fill.
  o.save();
  o.shadowColor = `rgba(255,213,138,${glow})`;
  o.shadowBlur = size * 0.18;
  const grd = o.createLinearGradient(0, oy - size * 0.7, 0, oy + size * 0.12);
  grd.addColorStop(0, color);
  grd.addColorStop(1, alt > 0 ? WX_mixHex('#FFFFFF', '#FFD58A', 0.28) : '#BFCBFF');
  o.fillStyle = grd;
  o.fillText(str, ox, oy);
  o.restore();

  o.save();
  o.shadowColor = 'rgba(0,0,0,0.22)'; o.shadowBlur = 24; o.shadowOffsetY = 10;
  o.globalAlpha = 0.45;
  o.fillText(str, ox, oy);
  o.restore();

  // Rim light on the sun's side only (dot(glyphNormal, lightDir), truncated).
  o.globalCompositeOperation = 'source-atop';
  const rg = o.createLinearGradient(ox + total * 0.30, oy - size * 0.6, ox + total * 0.95, oy + size * 0.1);
  rg.addColorStop(0, 'rgba(255,255,255,0)');
  rg.addColorStop(1, 'rgba(255,236,200,0.5)');
  o.fillStyle = rg;
  o.fillRect(0, 0, off.width, off.height);
  o.globalCompositeOperation = 'source-over';

  // The reveal: an alpha ramp whose soft edge is ~2% of the line width, as in
  // the app's shader ("the ink behind the nib is not dry").
  const feather = Math.max(2, total * 0.02);
  const ramp = o.createLinearGradient(revealed - feather * 3, 0, revealed + feather, 0);
  ramp.addColorStop(0, 'rgba(0,0,0,1)');
  ramp.addColorStop(0.62, 'rgba(0,0,0,1)');
  ramp.addColorStop(1, 'rgba(0,0,0,0)');
  o.globalCompositeOperation = 'destination-in';
  o.fillStyle = ramp;
  o.fillRect(0, 0, off.width, off.height);
  o.globalCompositeOperation = 'source-over';

  // The wet highlight just behind the nib.
  if (glyphsDone < 0.999) {
    o.globalCompositeOperation = 'destination-over';
    o.fillStyle = 'rgba(255,255,255,0.28)';
    o.fillRect(revealed - feather, oy - size * 0.62, feather * 1.6, size * 0.9);
    o.globalCompositeOperation = 'source-over';
  }

  g.drawImage(off, x - pad, y - oy);
  g.restore();
  return total;
}

/** Six slim forecast columns: weekday, glyph, low/high (design §2). */
function drawForecast(g, { x, y, w, h, ink, time }) {
  const days = [['今天', 0, 32, 25], ['周二', 1, 31, 24], ['周三', 2, 30, 23],
                ['周四', 3, 29, 22], ['周五', 4, 28, 21], ['周六', 5, 27, 20]];
  const cw = w / days.length;
  g.save();
  g.globalAlpha = 0.9;
  days.forEach(([label, i, hi, lo], k) => {
    const cx = x + cw * k + cw / 2;
    text(g, label, cx, y + 12, { size: 11, weight: 500, color: ink, opacity: k === 0 ? 0.95 : 0.72,
         align: 'center' });
    weatherGlyph(g, cx, y + 30, 9, i === 2 ? 'rain' : i === 3 ? 'cloud' : i === 5 ? 'cloud-sun' : 'sun',
                 ink, time + k);
    text(g, `${hi}°`, cx - 2, y + 56, { size: 13, weight: 600, color: ink, align: 'right', opacity: 0.9 });
    text(g, `${lo}°`, cx + 3, y + 56, { size: 13, weight: 400, color: ink, align: 'left', opacity: 0.62 });
  });
  // The trend line across the highs, with a focus dot on the middle day.
  const path = [32, 31, 30, 29, 28, 27];
  g.strokeStyle = 'rgba(255,255,255,0.5)'; g.lineWidth = 1.4;
  g.beginPath();
  path.forEach((v, k) => {
    const px = x + cw * k + cw / 2, py = y + 46 - (v - 27) * 1.6;
    k === 0 ? g.moveTo(px, py) : g.lineTo(px, py);
  });
  g.stroke();
  g.restore();
}

function weatherGlyph(g, cx, cy, r, kind, color, seed = 0) {
  g.save();
  g.strokeStyle = color; g.fillStyle = color; g.lineWidth = 1.4; g.lineCap = 'round';
  if (kind === 'sun') {
    g.beginPath(); g.arc(cx, cy, r * 0.55, 0, Math.PI * 2); g.stroke();
    for (let i = 0; i < 8; i++) {
      const a = (i / 8) * Math.PI * 2;
      g.beginPath();
      g.moveTo(cx + Math.cos(a) * r * 0.8, cy + Math.sin(a) * r * 0.8);
      g.lineTo(cx + Math.cos(a) * r * 1.15, cy + Math.sin(a) * r * 1.15);
      g.stroke();
    }
  } else if (kind === 'cloud' || kind === 'cloud-sun' || kind === 'cloud-rain') {
    if (kind === 'cloud-sun') {
      g.beginPath(); g.arc(cx + r * 0.7, cy - r * 0.5, r * 0.34, 0, Math.PI * 2); g.stroke();
    }
    g.beginPath();
    g.arc(cx - r * 0.42, cy, r * 0.40, Math.PI * 0.5, Math.PI * 1.5);
    g.arc(cx, cy - r * 0.22, r * 0.46, Math.PI, Math.PI * 2);
    g.arc(cx + r * 0.52, cy, r * 0.34, Math.PI * 1.5, Math.PI * 0.5);
    g.closePath();
    g.fill();
    if (kind === 'cloud-rain') {
      for (const dx of [-r * 0.35, 0, r * 0.35]) {
        g.beginPath(); g.moveTo(cx + dx, cy + r * 0.5); g.lineTo(cx + dx - r * 0.18, cy + r * 1.1); g.stroke();
      }
    }
  }
  g.restore();
}

/** A point on the app's `SkyAstronomy` arc for the moment being shown. */
export function sunArc(progress) {
  // Azimuth mapped across ±110° around south; altitude on a smooth day arc.
  const az = 0.5 + (progress - 0.5) * 0.86;
  const alt = Math.sin(progress * Math.PI) * 62 - 4;
  return { az, alt };
}

// ==================================================== 3 · the greeting card
export function scene3(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  // 0:15.0 the card arrives low and small, then the camera pushes in until the
  // greeting crosses 62% of the frame (prompt.md §4 scene 3).
  const arrive = ramp(t, 0, 1.4, 'enter');
  const push = ramp(t, 4.4, 9.2, 'slow');

  // One day, walked: dawn → noon → sunset → night, keyed to solar altitude.
  const alt = lerp(14, 62, S(t, 4.4, 8.6)) - lerp(0, 66, S(t, 8.6, 12.4))
              - lerp(0, 22, S(t, 12.4, 16.2));
  const progress = clamp((alt + 6) / 74);

  const weather = t < 8.0 ? WX_WEATHER.clear
                : t < 12.2 ? WX_WEATHER.partly
                : WX_WEATHER.clear;
  const greeting = alt > 4 ? 'good morning,' : alt > -14 ? 'good evening,' : 'good evening,'; 

  const cardW = 1100, cardH = 430;
  const scale = lerp(0.86, 1.0, arrive) * lerp(1.0, 1.10, push);
  const px = W / 2 + (1 - arrive) * -300;
  const py = H / 2 + 60 - arrive * 60 - push * 40;

  withCamera(g, { scale, x: px, y: py - 40, dy: -push * 6 }, (c) => {
    c.globalAlpha = arrive;
    drawGreetingCard(c, {
      x: px - cardW / 2, y: py - cardH / 2, w: cardW, h: cardH, t, far: push,
      alt, azimuth: 0.5 + (progress - 0.5) * 0.5, weather,
      greeting, sign: 'XIAJUN WANG', place: '广州 · 天河区', temp: 29, condition: weather.label,
      feels: 32, humidity: 68, wind: 8, rain: 0, sunset: '18:22',
      tokens: 128_400_000, ccModel: 'deepseek-v4.1-flash', codexModel: 'gpt-6-astra',
      cursor: 0.46, codex: [0.18, 0.50], time: t * 1.0,
      glyphsDone: ramp(t, 0.0, 3.2, 'snap'),
    });
    c.globalAlpha = 1;
  });

  // The caption is part of the shot, not a lower third: it sits where the card
  // is not, and it leaves before the sky does.
  const copyIn = ramp(t, 9.6, 10.6, 'enter');
  const copyOut = ramp(t, 14.6, 15.6, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '问候是一扇窗。',
                body: '天空由太阳高度角决定，不是钟点。云影从字面掠过，雨丝从字前划过。',
                x: 120, y: H / 2 - 120, width: 520, ink });
  g.globalAlpha = 1;
}

// ================================================ 4 · the card's glass rain
export function scene4(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  // A held close-up on the upper-left two thirds, where the drops are.
  const cardW = 1100, cardH = 430, scale = 1.22;
  const px = W * 0.30, py = H * 0.46;

  // Three gestures, each given room to be read: a drop lands, a drop slides, a
  // pointer sweeps the drops aside, then a click merges them.
  const drops = [];
  const landT = 3.0;
  drops.push({ x: px + 40, y: py - 150, r: 5.5,
               grow: ramp(t, landT, landT + 0.12, 'snap'),
               ripple: t < landT ? -1 : ramp(t, landT, landT + 0.26, 'slow'),
               trail: 0, life: t > landT ? 1 : 0 });
  const slideT = 5.2;
  const slideP = ramp(t, slideT, 9.6, 'slow');
  if (t > slideT) {
    const d = drops[0];
    d.x += Math.sin(slideP * 6) * 14 + slideP * 46;
    d.y += slideP * 120;
    d.trail = clamp(slideP * 1.4) * 90;
    d.r = 5.5 + slideP * 1.2;
  }
  for (let i = 0; i < 14; i++) {
    const seed = hash(i * 13.7);
    const life = gate(t, 1.2 + seed * 3, 1.8 + seed * 3, 12.6, 13.4);
    drops.push({ x: px + (seed - 0.5) * 900, y: py - 260 + hash(i * 4.4) * 520,
                 r: 2 + hash(i * 8.8) * 3.4, grow: 1, ripple: -1, trail: 0, life });
  }

  // The pointer's path: sweep across, then press at the merge point.
  const pointerT = 7.6, clickT = 9.6;
  const px1 = -900, px2 = 900;
  const sweep = ramp(t, pointerT, pointerT + 2.0, 'slow');
  const pointerX = px + lerp(px1, px2, sweep);
  const pointerY = py - 60 + Math.sin(sweep * 4) * 30;
  const press = pulse(t, clickT, 0.12, 0.3, 'snap');

  withCamera(g, { scale, x: px, y: py }, (c) => {
    drawGreetingCard(c, {
      x: px - cardW / 2, y: py - cardH / 2, w: cardW, h: cardH, t, far: 1,
      alt: 6, azimuth: 0.5, weather: WX_WEATHER.rain,
      greeting: 'good morning,', sign: 'XIAJUN WANG', place: '广州 · 天河区', temp: 29,
      condition: '阵雨', feels: 32, humidity: 68, wind: 8, rain: 1, sunset: '18:22',
      tokens: 128_400_000, ccModel: 'deepseek-v4.1-flash', codexModel: 'gpt-6-astra',
      cursor: 0.46, codex: [0.18, 0.50], time: t,
    });
    // Drops are drawn after the greeting: they are in front of the type, which
    // is the whole point of the scene (§5.2, L5 greeting between L4 and L6).
    WX_drawDroplets(c, { x: px - cardW / 2, y: py - cardH / 2, w: cardW, h: cardH - 56, drops });
  });

  if (t > pointerT && t < clickT + 0.8) drawPointer(g, pointerX, pointerY, { press, r: 7 });

  const copyIn = ramp(t, 10.6, 11.4, 'enter');
  g.globalAlpha = copyIn;
  drawCopy(g, { title: '雨在字前面。',
                body: '文字本身是场景的一部分：透过雨滴看到的是倒过来的天空。',
                x: 120, y: H - 250, width: 560, ink });
  g.globalAlpha = 1;
}

// ============================================================ the island
/**
 * The island, in its three real sizes (docs/design/10-notch-island.md §2 and
 * §4.3). It is black on hardware black: no border and no shadow while
 * collapsed, a 1px rim only once it has grown out of the notch.
 */
export function drawIsland(g, {
  mode, t, notch = { w: 200, h: 46 }, wings = true, wingCount = 2, todayTokens = 312_000_000,
  alert = null, sessions = [], usage = null, route = 'DeepSeek · v4', vpn = true,
  rim = 1, expand = 1, alertT = 0, scroll = 0, scrub = -1, scrubSettle = 0, sweep = -1,
}) {
  const cx = W / 2, top = 0;
  const flare = 6;

  // Geometry straight out of IslandStyle / NotchIslandState.
  const collapsed = { w: notch.w + 2 * flare + (wings ? 2 * 52 : 0), h: notch.h };
  const alertSize = { w: Math.max(380, notch.w + 2 * flare + 200), h: notch.h + 54 };
  let size = mode === 'collapsed' ? collapsed : mode === 'alert' ? alertSize
    : { w: Math.max(520, notch.w + 2 * flare + 320), h: notch.h + 6 + 110 + 8 + 156 + 12 };
  if (mode === 'alert') size = { w: lerp(collapsed.w, size.w, expand), h: lerp(collapsed.h, size.h, expand) };
  const bottomR = mode === 'collapsed' ? 9 : mode === 'alert' ? 22 : 26;

  const x = cx - size.w / 2;
  g.save();

  // Silhouette: top edge open (the notch's own flare), bottom corners rounded.
  g.beginPath();
  g.moveTo(x - flare, top);
  g.quadraticCurveTo(x, top, x + bottomR * 0.5, top + bottomR * 0.5);
  g.lineTo(x + size.w - bottomR * 0.5, top + bottomR * 0.5);
  g.quadraticCurveTo(x + size.w, top, x + size.w + flare, top);
  g.lineTo(x + size.w + flare, top + size.h - bottomR);
  g.quadraticCurveTo(x + size.w + flare, top + size.h, x + size.w + flare - bottomR, top + size.h);
  g.lineTo(x - flare + bottomR, top + size.h);
  g.quadraticCurveTo(x - flare, top + size.h, x - flare, top + size.h - bottomR);
  g.closePath();
  g.fillStyle = '#000';
  g.fill();
  if (rim > 0 && mode !== 'collapsed') {
    g.save();
    g.strokeStyle = 'rgba(255,255,255,0.09)'; g.lineWidth = 1; g.stroke();
    g.restore();
  }

  g.save();
  g.beginPath();
  g.moveTo(x - flare, top);
  g.lineTo(x + size.w + flare, top);
  g.lineTo(x + size.w + flare, top + size.h - bottomR);
  g.quadraticCurveTo(x + size.w + flare, top + size.h, x + size.w + flare - bottomR, top + size.h);
  g.lineTo(x - flare + bottomR, top + size.h);
  g.quadraticCurveTo(x - flare, top + size.h, x - flare, top + size.h - bottomR);
  g.closePath();
  g.clip();

  const inner = size.w - 2 * flare;
  if (mode === 'collapsed' && wings) {
    drawIslandWings(g, { x, y: top, notch, wingCount, todayTokens, sweep });
  } else if (mode === 'alert' && alert) {
    drawIslandAlert(g, { x, y: top, w: size.w, h: size.h, notch, alert, t: alertT, sweep });
  } else if (mode === 'expanded') {
    drawIslandExpanded(g, { x, y: top, w: size.w, h: size.h, notch, route, vpn,
                            sessions, usage, scroll, scrub, scrubSettle, sweep, t });
  }

  // The alert's one-shot rim glint (design §2: a single identity-colour pass).
  if (sweep >= 0 && sweep <= 1) {
    const sx = x + size.w * sweep;
    const gr = g.createLinearGradient(sx - 120, 0, sx + 120, 0);
    gr.addColorStop(0, 'rgba(232,132,94,0)');
    gr.addColorStop(0.5, 'rgba(232,132,94,0.5)');
    gr.addColorStop(1, 'rgba(232,132,94,0)');
    g.fillStyle = gr;
    g.fillRect(sx - 120, top + size.h - 3, 240, 3);
  }
  g.restore();
  g.restore();
  return size;
}

function drawIslandWings(g, { x, y, notch, wingCount, todayTokens, sweep }) {
  const flare = 6, wing = 52;
  const leftX = x + flare, rightX = x + flare + wing + notch.w;
  // Left: the lead agent's mark on its orbit, with a count when more than one
  // session runs. Idle it becomes today's pace ring — the collapsed island has
  // nothing else to say.
  const markY = y + notch.h / 2;
  const ax = leftX + 12;
  g.save();
  g.translate(ax, markY);
  g.rotate(sweep >= 0 ? sweep * Math.PI * 2 : (Date.now(), 0));
  g.strokeStyle = 'rgba(232,132,94,0.55)';
  g.lineWidth = 1.4;
  g.beginPath(); g.arc(0, 0, 11, 0.4, 0.4 + Math.PI * 1.35); g.stroke();
  g.restore();
  agentMark(g, ax, markY, 18, 'claude', true);
  if (wingCount > 1) {
    text(g, String(wingCount), leftX + 30, markY + 4, { size: 11, weight: 700, family: 'rounded',
         color: '#E8845E' });
  }

  const tk = fmtTokens(todayTokens);
  const rw = measure(g, tk.v, { size: 11.5, weight: 600, family: 'rounded' });
  text(g, tk.v + tk.u, rightX + wing - 14, markY + 4, { size: 11.5, weight: 600,
       family: 'rounded', color: 'rgba(255,255,255,0.92)', align: 'right' });
}

/** The agent marks the island draws: Claude's star, Codex's shell, Cursor's cube. */
export function agentMark(g, cx, cy, size, agent, busy = false) {
  const color = agent === 'claude' ? '#E8845E' : agent === 'codex' ? '#7C9CFF' : '#B79CFF';
  const r = size / 2;
  g.save();
  g.translate(cx, cy);
  if (agent === 'claude') {
    // Anthropic's asterisk: radial spokes, uneven lengths, round caps.
    g.strokeStyle = color; g.lineWidth = size * 0.14; g.lineCap = 'round';
    const spokes = [[0, 1.0], [60, 0.86], [120, 1.0], [180, 0.86], [240, 1.0], [300, 0.86]];
    spokes.forEach(([deg, k]) => {
      const a = (deg * Math.PI) / 180;
      g.beginPath();
      g.moveTo(Math.cos(a) * r * 0.18, Math.sin(a) * r * 0.18);
      g.lineTo(Math.cos(a) * r * k, Math.sin(a) * r * k);
      g.stroke();
    });
  } else if (agent === 'codex') {
    g.strokeStyle = color; g.lineWidth = size * 0.11;
    for (let i = 0; i < 6; i++) {
      const a = (i / 6) * Math.PI * 2 - Math.PI / 2;
      g.beginPath();
      g.moveTo(Math.cos(a) * r * 0.34, Math.sin(a) * r * 0.34);
      g.lineTo(Math.cos(a) * r * 0.62, Math.sin(a) * r * 0.62);
      g.lineTo(Math.cos(a + 1.05) * r * 0.95, Math.sin(a + 1.05) * r * 0.95);
      g.stroke();
    }
    g.beginPath(); g.arc(0, 0, r * 0.30, 0, Math.PI * 2); g.stroke();
  } else {
    g.strokeStyle = color; g.lineWidth = size * 0.11; g.lineJoin = 'round';
    const s = r * 0.78;
    g.beginPath();
    g.moveTo(0, -s); g.lineTo(s, -s * 0.45); g.lineTo(s, s * 0.45);
    g.lineTo(0, s); g.lineTo(-s, s * 0.45); g.lineTo(-s, -s * 0.45);
    g.closePath(); g.stroke();
    g.beginPath(); g.moveTo(0, -s); g.lineTo(0, 0); g.lineTo(s, s * 0.45); g.stroke();
  }
  g.restore();
}

function drawIslandAlert(g, { x, y, w, h, notch, alert, t, sweep }) {
  const flare = 6;
  const side = Math.max(0, (w - 2 * flare - notch.w) / 2 - 14);
  const left = x + flare + 14;
  const bodyY = y + notch.h;

  // Left wing: the agent's mark with its verdict badge.
  agentMark(g, left + 10, bodyY + 20, 20, alert.agent);
  g.save();
  g.translate(left + 22, bodyY + 30);
  g.fillStyle = '#000';
  g.beginPath(); g.arc(0, 0, 6, 0, Math.PI * 2); g.fill();
  g.strokeStyle = alert.kind === 'quota' ? '#FFC53D' : '#5EEAD4';
  g.lineWidth = 1.6; g.lineCap = 'round';
  g.beginPath();
  if (alert.kind === 'quota') { g.arc(0, 0, 3.4, 0.6, Math.PI * 1.7); }
  else { g.moveTo(-3, 0); g.lineTo(-0.6, 2.6); g.lineTo(3.4, -2.4); }
  g.stroke();
  g.restore();

  text(g, alert.verdict, left + 44, bodyY + 22, { size: 12.5, weight: 600, family: 'rounded',
       color: 'rgba(255,255,255,0.92)' });
  text(g, alert.detail, left + 44, bodyY + 40, { size: 10.5, weight: 500, family: 'rounded',
       color: 'rgba(255,255,255,0.40)' });
  if (alert.windows) {
    let wx2 = left + 44 + measure(g, alert.verdict, { size: 12.5, weight: 600 }) + 8;
    alert.windows.forEach((lbl) => {
      const lw = measure(g, lbl, { size: 9, weight: 600 }) + 14;
      fillRR(g, wx2, bodyY + 11, lw, 16, 8, 'rgba(255,197,61,0.16)');
      text(g, lbl, wx2 + lw / 2, bodyY + 22, { size: 9, weight: 600, color: '#FFC53D', align: 'center' });
      wx2 += lw + 6;
    });
  }

  // Right wing: the action that follows from the alert.
  const right = x + w - flare - 14;
  const bw = 74, bh = 26;
  fillRR(g, right - bw, bodyY + 14, bw, bh, 13, 'rgba(255,255,255,0.07)');
  text(g, alert.action, right - bw / 2, bodyY + 31, { size: 11.5, weight: 600, family: 'rounded',
       color: '#5EEAD4', align: 'center' });

  // The 6 s countdown, drawn inside the lower edge as a draining rule.
  if (t > 0) {
    const remain = clamp(1 - t / 6);
    g.fillStyle = 'rgba(94,234,212,0.75)';
    g.fillRect(x, y + h - 1.5, w * remain, 1.5);
  }
}

function drawIslandExpanded(g, { x, y, w, h, notch, route, vpn, sessions, usage, scroll, scrub, scrubSettle, sweep, t = 0 }) {
  const flare = 6, sidePad = 12;
  const headerH = notch.h;
  const left = x + flare + sidePad;
  const right = x + w - flare - sidePad;

  // Header: the route being looked at on the left, VPN + main window on the right.
  agentMark(g, left + 8, headerH / 2, 16, route.startsWith('gpt') ? 'codex' : 'claude');
  text(g, route, left + 22, headerH / 2 + 4, { size: 11, weight: 500, family: 'rounded',
       color: 'rgba(255,255,255,0.62)' });
  if (vpn) {
    const pw = 62;
    fillRR(g, right - pw - 26, headerH / 2 - 9, pw, 18, 9, 'rgba(255,255,255,0.08)');
    g.fillStyle = '#34C759';
    g.beginPath(); g.arc(right - pw - 26 + 10, headerH / 2, 3, 0, Math.PI * 2); g.fill();
    text(g, '代理', right - pw - 26 + 18, headerH / 2 + 3.5, { size: 9.5, weight: 600,
         color: 'rgba(255,255,255,0.62)' });
  }
  strokeRR(g, right - 22, headerH / 2 - 9, 22, 18, 6, 'rgba(255,255,255,0.20)', 1);
  text(g, '⧉', right - 11, headerH / 2 + 4, { size: 11, weight: 500,
       color: 'rgba(255,255,255,0.55)', align: 'center' });

  // Sessions: a 2x2 native grid, 44pt rows, 4pt gaps — no cards, just rows.
  const laneY = headerH + 6 + 12 + 8;
  const laneH = 110, rowH = 44, gap = 4;
  const colW = (w - 2 * flare - 2 * sidePad - 8) / 2;
  g.save();
  g.beginPath(); g.rect(left - 2, laneY - 4, w - 2 * (flare + sidePad) + 4, laneH); g.clip();
  sessions.forEach((s, i) => {
    const col = i % 2, row = Math.floor(i / 2);
    const rx = left + col * (colW + 8);
    const ry = laneY + row * (rowH + gap) - scroll;
    if (ry + rowH < laneY - 8 || ry > laneY + laneH) return;
    drawSessionRow(g, { x: rx, y: ry, w: colW, h: rowH, s });
  });
  g.restore();

  text(g, `${sessions.length} 个会话`, left, laneY + laneH + 12, { size: 9.5, weight: 500,
       family: 'rounded', color: 'rgba(255,255,255,0.40)' });
  text(g, '上下滑动查看更多', right, laneY + laneH + 12, { size: 9.5, weight: 500,
       family: 'rounded', color: 'rgba(255,255,255,0.40)', align: 'right' });

  // The usage card: today, today's spend, the 30-day histogram, the month's pace
  // and the source split (design §2, §3.2).
  const cardY = laneY + laneH + 20, cardH = 156;
  fillRR(g, left, cardY, w - 2 * (flare + sidePad), cardH, 14, 'rgba(255,255,255,0.055)');
  drawUsageCard(g, { x: left + 14, y: cardY + 12, w: w - 2 * (flare + sidePad) - 28, h: cardH - 24,
                     usage, scrub, scrubSettle, t });
}

function drawSessionRow(g, { x, y, w, h, s }) {
  fillRR(g, x, y, w, h - 2, 10, s.busy ? 'rgba(124,156,255,0.10)' : 'rgba(255,255,255,0.045)');
  if (s.busy) { g.fillStyle = '#7C9CFF'; rr(g, x, y + 6, 2, h - 14, 1); g.fill(); }
  agentMark(g, x + 16, y + h / 2 - 1, 14, s.agent, s.busy);
  text(g, s.project, x + 30, y + 17, { size: 11, weight: 600, family: 'rounded',
       color: 'rgba(255,255,255,0.92)' });
  text(g, s.activity || '等待你的下一步', x + 30, y + 31, { size: 9, weight: 400,
       family: 'rounded', color: 'rgba(255,255,255,0.40)' });
  // Context "fuel": a thin bar that turns amber at 60% and coral at 85%.
  const bw = 74, bx = x + w - bw - 12, by = y + 14;
  g.fillStyle = 'rgba(255,255,255,0.14)';
  rr(g, bx, by, bw, 3, 1.5); g.fill();
  g.fillStyle = s.ratio >= 0.85 ? '#FF6B61' : s.ratio >= 0.6 ? '#FFC53D' : '#7C9CFF';
  rr(g, bx, by, bw * clamp(s.ratio), 3, 1.5); g.fill();
  text(g, s.cost, x + w - 12, y + 34, { size: 9, weight: 500, family: 'rounded',
       color: 'rgba(255,255,255,0.40)', align: 'right' });
  if (s.hover) {
    fillRR(g, x + w - 70, y + h - 20, 58, 16, 8, 'rgba(255,255,255,0.10)');
    text(g, '继续 ↗', x + w - 41, y + h - 9, { size: 9, weight: 600, family: 'rounded',
         color: '#5EEAD4', align: 'center' });
  }
}

function drawUsageCard(g, { x, y, w, h, usage, scrub, scrubSettle, t = 0 }) {
  const tk = fmtTokens(usage.today);
  text(g, '今日', x, y + 12, { size: 10, weight: 600, family: 'rounded',
       color: 'rgba(255,255,255,0.40)' });
  text(g, tk.v, x, y + 42, { size: 26, weight: 600, family: 'rounded', color: '#FFFFFF' });
  const vw = measure(g, tk.v, { size: 26, weight: 600, family: 'rounded' });
  text(g, tk.u, x + vw + 4, y + 36, { size: 12, weight: 500, family: 'rounded',
       color: 'rgba(255,255,255,0.55)' });

  text(g, '今日花费', x + w * 0.52, y + 12, { size: 10, weight: 600, family: 'rounded',
       color: 'rgba(255,255,255,0.40)' });
  text(g, '¥128.40', x + w * 0.52, y + 42, { size: 26, weight: 600, family: 'rounded',
       color: '#FFFFFF' });
  text(g, '另有 $43.20', x + w * 0.52, y + 58, { size: 9.5, weight: 400, family: 'rounded',
       color: 'rgba(255,255,255,0.42)' });

  // 30 bars, drawn once, scrubbing sideways under the pointer.
  const bars = usage.days, n = bars.length;
  const hx = x, hy = y + 72, hw = w, hh = 42;
  const bw = 6, step = (hw - bw) / (n - 1);
  bars.forEach((v, i) => {
    const max = Math.max(...bars);
    const bh = Math.max(2, (v / max) * hh);
    const focus = scrub === i;
    g.fillStyle = focus ? '#5EEAD4' : `rgba(124,156,255,${0.34 + (v / max) * 0.5})`;
    rr(g, hx + i * step - (scrub >= 0 ? scrubSettle * step * 0.0 : 0), hy + hh - bh, bw, bh, 1.5);
    g.fill();
  });
  if (scrub >= 0) {
    const bx = hx + scrub * step + bw / 2;
    g.strokeStyle = 'rgba(94,234,212,0.5)'; g.lineWidth = 1; g.setLineDash([2, 2]);
    g.beginPath(); g.moveTo(bx, hy - 2); g.lineTo(bx, hy + hh + 2); g.stroke();
    g.setLineDash([]);
    const tip = `${bars[scrub] >= 1e8 ? '9月12日' : ''}`;
    const label = `9月12日 · 1.42亿 · ¥57.60`;
    const lw = measure(g, label, { size: 10, weight: 600, family: 'rounded' }) + 18;
    const lx = clamp(bx - lw / 2, hx, hx + hw - lw);
    fillRR(g, lx, hy - 30, lw, 20, 10, 'rgba(10,14,24,0.92)');
    strokeRR(g, lx, hy - 30, lw, 20, 10, 'rgba(94,234,212,0.35)', 1);
    text(g, label, lx + lw / 2, hy - 16.5, { size: 10, weight: 600, family: 'rounded',
         color: '#5EEAD4', align: 'center' });
  }

  text(g, `昨日的 112% · 1,204 次`, x, hy + hh + 16, { size: 10, weight: 500, family: 'rounded',
       color: '#FFC53D' });
  text(g, `本月 33.9亿  上月同期 99%`, x, hy + hh + 30, { size: 10, weight: 500, family: 'rounded',
       color: 'rgba(255,255,255,0.55)' });

  // Source split: CC clay / Codex cobalt / third-party magenta, in that order.
  const sw = w * 0.34, sx = x + w - sw, sy = hy + hh + 24;
  fillRR(g, sx, sy - 6, sw, 6, 3, 'rgba(255,255,255,0.10)');
  const segs = [[0.434, '#E8845E'], [0.512, '#7C9CFF'], [0.054, '#F472B6']];
  let acc = 0;
  segs.forEach(([v, c], i) => {
    // Each segment grows in on its own 120 ms beat, left to right.
    const on = ramp(t, i * 0.12, i * 0.12 + 0.4, 'slow');
    g.fillStyle = c;
    rr(g, sx + sw * acc, sy - 6, sw * v * on, 6, 3); g.fill();
    acc += v;
  });
  text(g, 'CC', sx, sy + 12, { size: 9, weight: 600, family: 'rounded', color: '#E8845E' });
  text(g, 'Codex', sx + 26, sy + 12, { size: 9, weight: 600, family: 'rounded', color: '#7C9CFF' });
  text(g, '第三方', sx + 74, sy + 12, { size: 9, weight: 600, family: 'rounded', color: '#F472B6' });
}

// ================================================== 5 · island, collapsed
export function scene5(g, t, env) {
  const ink = INK.light;

  // A pull-out from the card: the screen's top edge becomes the composition's
  // upper third and the card leaves the frame (prompt.md §4 scene 5). The island
  // is the subject, so the camera keeps it large — the collapsed island is only
  // 46pt tall on a 1080 canvas, and at 1:1 it is a hairline nobody can read.
  const pull = ramp(t, 0, 1.2, 'slow');
  const push = ramp(t, 1.6, 3.6, 'slow');
  const cardGone = ramp(t, 0.2, 1.1, 'slow');

  const bg = g.createLinearGradient(0, 0, 0, H);
  bg.addColorStop(0, ink.canvas);
  bg.addColorStop(1, '#E3EAF2');
  g.fillStyle = bg; g.fillRect(0, 0, W, H);

  // The card, leaving below the frame. Drawn first so nothing overlaps its exit.
  if (cardGone < 0.999) {
    g.save();
    g.globalAlpha = 1 - cardGone;
    g.translate(0, cardGone * 520);
    drawGreetingCard(g, {
      x: W / 2 - 550, y: H * 0.34, w: 1100, h: 430, t, far: 1, alt: 24, azimuth: 0.5,
      weather: WX_WEATHER.partly, greeting: 'good morning,', sign: 'XIAJUN WANG',
      place: '广州 · 天河区', temp: 29, condition: '多云', feels: 32, humidity: 68, wind: 8,
      rain: 0, sunset: '18:22', tokens: 128_400_000, ccModel: 'deepseek-v4.1-flash',
      codexModel: 'gpt-6-astra', cursor: 0.46, codex: [0.18, 0.50], time: t,
    });
    g.restore();
  }

  // A 2.4x push onto the top edge. The camera scales about (W/2, 0) — the top
  // edge itself — so the strip stays pinned to the frame's top and grows down
  // into the shot, which is what "leaning in to look at the notch" means. Any
  // other origin sends the edge this scene is about off screen.
  const zoom = lerp(1.0, 2.4, push);
  withCamera(g, { scale: zoom, x: W / 2, y: 0, dy: 40 * zoom }, (c) => {
    drawScreenEdge(c, { notch: { w: 200, h: 46 }, height: 46 });
    // One full orbit of the busy mark over 0.9s, then it settles.
    drawIsland(c, {
      mode: 'collapsed', t, wingCount: 2,
      todayTokens: lerp(309_000_000, 312_000_000, S(t, 3.4, 5.2)),
      sweep: ramp(t, 4.0, 4.9, 'slow'),
    });
    drawStatusItem(c, W - 40 - 155, 23, {
      icon: env.assets.statusIcon, down: '1.7K', up: '0.6K', tunneled: false, level: 82,
    });
  });

  // The caption sits under the zoomed strip, in the frame's lower half.
  const copyIn = ramp(t, 5.0, 5.8, 'enter');
  const copyOut = ramp(t, 7.8, 8.6, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '余光里就够了。',
                body: '左翼是谁在跑，右翼是今天烧了多少。够用，不必盯。',
                x: 150, y: H * 0.62, width: 520, ink });
  g.globalAlpha = 1;
}

// ====================================================== 6 · island, alert
export function scene6(g, t, env) {
  const ink = INK.light;
  const bg = g.createLinearGradient(0, 0, 0, H);
  bg.addColorStop(0, ink.canvas); bg.addColorStop(1, '#E3EAF2');
  g.fillStyle = bg; g.fillRect(0, 0, W, H);

  drawScreenEdge(g, { notch: { w: 200, h: 46 }, height: 46 });
  const ic = env.assets.statusIcon;
  drawStatusItem(g, W - 40 - 155, 23, { icon: ic, down: '1.7K', up: '0.6K', level: 82 });

  // The island grows out of the notch on the alert spring, which is slightly
  // bouncier than the expand spring by design (design §1).
  const grow = ramp(t, 2.4, 3.6, 'snap');
  const sweep = t < 2.4 ? -1 : ramp(t, 2.6, 3.2, 'slow');
  const collapse = ramp(t, 9.6, 10.4, 'slow');
  const alive = grow * (1 - collapse);

  // The whole shot gets one 1.03 nudge on the frame the alert appears.
  const nudge = 1 + pulse(t, 2.4, 0.1, 0.35, 'snap') * 0.03;

  // Hover highlight on 继续 at 3.9 s and again at 5.9 s.
  const hov = pulse(t, 3.9, 0.2, 1.0, 'slow') > 0.5 || pulse(t, 5.9, 0.2, 0.6, 'slow') > 0.5;

  g.save();
  g.translate(W / 2, 0);
  g.scale(nudge, nudge);
  g.translate(-W / 2, 0);
  drawIsland(g, {
    mode: 'alert', t, expand: alive, alertT: t - 2.4, sweep,
    alert: alive > 0.02 ? {
      agent: 'claude', kind: 'done',
      verdict: 'ClaudeBar', detail: 'Claude Code · opus · 等待你的下一步',
      action: '继续 ↗', hover: hov,
    } : null,
  });
  g.restore();

  const copyIn = ramp(t, 6.6, 7.6, 'enter');
  const copyOut = ramp(t, 9.4, 10.4, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '它跑完了，会自己说。',
                body: '交付了答案才提醒，不是「忙转闲」。点一下回到那个终端。',
                x: 150, y: H * 0.60, width: 620, ink });
  g.globalAlpha = 1;
}

// =================================================== 7 · island, expanded
export function scene7(g, t, env) {
  const ink = INK.light;
  const bg = g.createLinearGradient(0, 0, 0, H);
  bg.addColorStop(0, ink.canvas); bg.addColorStop(1, '#E3EAF2');
  g.fillStyle = bg; g.fillRect(0, 0, W, H);

  const expand = ramp(t, 0.8, 2.2, 'snap');
  const scroll = ramp(t, 4.4, 5.4, 'slow') * 52;
  const scrubOn = t > 7.0;
  const scrubIdx = scrubOn ? Math.round(lerp(29, 14, S(t, 7.0, 8.2))) : -1;

  const sessions = [
    { project: 'ClaudeBar', activity: 'Bash · build.sh', agent: 'claude', ratio: 0.62, cost: '¥12.40', busy: false },
    { project: 'api', activity: 'Read · handler.go', agent: 'codex', ratio: 0.12, cost: '¥1.20', busy: true },
    { project: 'api-server', activity: '等待你的下一步', agent: 'claude', ratio: 0.08, cost: '¥0.40', busy: false },
    { project: 'cursor', activity: 'Edited app.py', agent: 'cursor', ratio: 0.40, cost: '¥3.80', busy: false },
  ];
  const days = Array.from({ length: 30 }, (_, i) =>
    0.24 + 0.62 * fbm(i * 0.42 + 3.1, 3) + (i % 7 === 5 ? 0.22 : 0));

  // The island is 338pt tall. A push that scales about the frame centre sends its
  // top edge off screen, so the camera pins the island's own top-left instead:
  // the silhouette stays fully visible with air below it (prompt.md §4 scene 7).
  const islandH = 46 + 6 + 110 + 8 + 156 + 12;
  const zoom = 1 + 0.25 * expand;
  withCamera(g, {
    scale: zoom,
    x: W / 2,
    y: 0,
    dy: (H * 0.5) - (islandH * zoom * 0.5) - 40,
  }, (c) => {
    drawScreenEdge(c, { notch: { w: 200, h: 46 }, height: 46 });
    const h = drawIsland(c, {
      mode: 'expanded', t, expand, scroll, scrub: scrubIdx,
      route: 'DeepSeek · v4', vpn: true, sessions,
      usage: { today: 312_400_000, days },
    });
    return h;
  }, 0);

  // A pointer, so the scrub has a cause.
  const pointerIn = ramp(t, 6.6, 7.0, 'enter');
  g.globalAlpha = pointerIn * (1 - ramp(t, 10.6, 11.4, 'slow'));
  const px = W / 2 + lerp(-120, 60, S(t, 7.0, 8.2));
  drawPointer(g, px, 46 + 6 + 110 + 20 + 72 + 20, { r: 7 });
  g.globalAlpha = 1;

  // The caption goes in the band beside the island, which is the only part of the
  // frame the island does not occupy at this zoom.
  const copyIn = ramp(t, 9.6, 10.6, 'enter');
  const copyOut = ramp(t, 11.6, 12.4, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  const bandW = (W - Math.min(W - 80, 620 * zoom)) / 2;
  drawCopy(g, { title: '碰一下刘海。',
                body: '会话格、上下文油量、30 天直方图。滑一下就是任何一天。',
                x: Math.max(60, bandW - 520), y: H / 2 - 120,
                width: Math.min(460, bandW - 80), ink, titleSize: 56, bodySize: 20 });
  g.globalAlpha = 1;
}

// ============================================================== 8 · popup
const POPUP_W = 460;

/** The three switcher chips: one 143pt column each, four fixed zones so the
 *  row never staircases (docs/design/04-popup-layout.md, PanelHeader). */
function drawSwitchChips(g, { x, y, w, chips, ink, hoverIdx = -1, popover = null, popT = 0, rollout = 1 }) {
  const gap = 1, cw = (w - gap * 2) / 3, ch = 96;
  chips.forEach((c, i) => {
    const cx = x + i * (cw + gap);
    g.fillStyle = i === hoverIdx ? 'rgba(0,0,0,0.035)' : 'rgba(0,0,0,0.015)';
    g.fillRect(cx, y, cw, ch);
    if (i > 0) { g.fillStyle = ink.hair; g.fillRect(cx - gap, y, gap, ch); }

    const px2 = cx + 12, py = y + 12;
    if (c.mark) g.drawImage(c.mark, px2, py, 15, 15);
    text(g, c.family, px2 + 19, py + 12, { size: 11, weight: 500, color: ink.body });

    // The model name rolls digits/letters into place when it changes.
    const label = c.title;
    const roll = i === rollout ? 1 : 0;
    text(g, label, px2, y + 40, { size: 16, weight: 600, family: 'rounded', color: ink.title });

    if (c.gauges) {
      let gx = px2;
      c.gauges.forEach(([name, v]) => {
        if (name) text(g, name, gx, y + 62, { size: 9, weight: 500, color: ink.faint });
        gx += name ? Math.max(30, measure(g, name, { size: 9, weight: 500 })) + 4 : 0;
        miniRing(g, gx + 7, y + 66, 7, v, v <= 0.25 ? '#FF9F0A' : '#34C759', ink);
        gx += 22;
      });
    }
    if (c.footer) text(g, c.footer, px2, y + ch - 10, { size: 10, weight: 400, color: ink.faint });
    if (c.spend) {
      text(g, c.spend, cx + cw - 12, y + ch - 10, { size: 10, weight: 500,
           color: ink.body, align: 'right' });
    }
  });

  // The switcher popover, when one is open.
  if (popover && popT > 0) {
    const i = popover.chip;
    const ox = x + i * (cw + gap), ow = 240;
    const rows = popover.rows;
    const oh = 18 + rows.reduce((a, r) => a + (r.header ? 22 : 24), 0) + 10;
    const oy = y + ch + 6;
    g.save();
    g.globalAlpha = popT;
    g.translate(0, (1 - popT) * -6);
    g.save();
    g.shadowColor = 'rgba(20,24,32,0.18)'; g.shadowBlur = 24; g.shadowOffsetY = 10;
    fillRR(g, ox, oy, ow, oh, 12, '#FFFFFF');
    g.restore();
    strokeRR(g, ox, oy, ow, oh, 12, ink.hair, 1);
    text(g, popover.title, ox + 12, oy + 16, { size: 10, weight: 500, color: ink.faint });
    let ry = oy + 26;
    rows.forEach((r) => {
      if (r.header) {
        text(g, r.header, ox + 12, ry + 10, { size: 10, weight: 500, color: ink.faint });
        ry += 22;
      } else {
        if (r.active) fillRR(g, ox + 6, ry - 2, ow - 12, 20, 6, 'rgba(61,125,255,0.10)');
        text(g, r.active ? '✓' : '', ox + 12, ry + 11, { size: 9, weight: 600, color: '#1D4FB8' });
        text(g, r.title, ox + 26, ry + 11, { size: 12, weight: r.active ? 600 : 400,
             color: r.active ? '#3D7DFF' : ink.body });
        if (r.pick) {
          g.fillStyle = 'rgba(0,0,0,0.06)';
          rr(g, ox + 6, ry - 2, ow - 12, 20, 6); g.fill();
          fillRR(g, ox + 8, ry, 2, 16, 1, '#3D7DFF');
        }
        ry += 24;
      }
    });
    g.restore();
  }
}

function miniRing(g, cx, cy, r, v, color, ink) {
  g.save();
  g.lineWidth = 2;
  g.strokeStyle = 'rgba(0,0,0,0.10)';
  g.beginPath(); g.arc(cx, cy, r, 0, Math.PI * 2); g.stroke();
  g.strokeStyle = color; g.lineCap = 'round';
  g.beginPath(); g.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * clamp(v)); g.stroke();
  g.restore();
  text(g, `${Math.round(v * 100)}%`, cx, cy + 0.5, { size: 6.5, weight: 700, color: ink.title,
       align: 'center', baseline: 'middle' });
}

export function drawPopup(g, { x, y, w, t, ink, sections = {}, hover = -1, popover = null,
                               popT = 0, feedback = null, vpnPanel = null, scroll = 0 }) {
  const h = sections.height ?? 640;
  g.save();
  g.translate(x, y);
  g.save();
  g.shadowColor = ink.shadow; g.shadowBlur = 48; g.shadowOffsetY = 18;
  fillRR(g, 0, 0, w, h, 22, ink.card);
  g.restore();
  strokeRR(g, 0, 0, w, h, 22, ink.hair, 1);

  g.save();
  rr(g, 0, 0, w, h, 22); g.clip();
  g.translate(0, -scroll);

  const M = 12;
  let cy = 10;

  // Row 1 — live facts: sessions, the local proxy, the VPN pill, refresh.
  text(g, '●', M, cy + 14, { size: 10, color: '#34C759' });
  text(g, '1 会话', M + 12, cy + 14, { size: 12, weight: 500, color: ink.title });
  text(g, '本地 15721', M + 62, cy + 14, { size: 12, weight: 400, color: ink.body });
  text(g, '↓', M + 128, cy + 14, { size: 11, weight: 600, color: ink.title });
  text(g, '1.7K', M + 140, cy + 14, { size: 11, weight: 600, color: ink.title });
  text(g, '↑', M + 172, cy + 14, { size: 11, weight: 600, color: ink.title });
  text(g, '0.6K', M + 184, cy + 14, { size: 11, weight: 600, color: ink.title });

  // The VPN pill: node name then latency, both measured, so the two never print
  // on top of each other in a row that is only 138pt wide.
  const pillNode = '日本 A01';
  const pillMs = '42ms';
  const pillW = 20 + measure(g, pillNode, { size: 10.5, weight: 500 }) + 6
              + measure(g, pillMs, { size: 10, weight: 600 }) + 12;
  const pillX = w - M - pillW;
  fillRR(g, pillX, cy + 3, pillW, 22, 11, 'rgba(0,0,0,0.04)');
  g.fillStyle = '#34C759';
  g.beginPath(); g.arc(pillX + 11, cy + 14, 3, 0, Math.PI * 2); g.fill();
  text(g, pillNode, pillX + 19, cy + 18, { size: 10.5, weight: 500, color: ink.title });
  text(g, pillMs, pillX + pillW - 9, cy + 18, { size: 10, weight: 600,
       color: '#34C759', align: 'right' });
  iconButton(g, w - M - 12, cy + 4, 20, 'refresh', ink);
  cy += 30;

  drawSwitchChips(g, { x: M, y: cy, w: w - 2 * M, chips: sections.chips, ink,
                       hoverIdx: hover, popover, popT, rollout: sections.rollout ?? -1 });
  cy += 96 + 6;

  if (vpnPanel) {
    const ph = 168, px2 = M + 200;
    fillRR(g, px2, cy, 240, ph, 12, '#FFFFFF');
    strokeRR(g, px2, cy, 240, ph, 12, ink.hair, 1);
    text(g, '节点', px2 + 12, cy + 18, { size: 10, weight: 500, color: ink.faint });
    const nodes = [['日本 A01 · 带宽优化', 42, true], ['日本 A02 · 低倍率', 58, false],
                   ['香港 B01 · 容灾', 76, false], ['新加坡 C01', 96, false]];
    let ny = cy + 30;
    nodes.forEach(([name, ms, on], i) => {
      const lit = vpnPanel.pick >= 0 && i <= vpnPanel.pick;
      if (on) fillRR(g, px2 + 6, ny - 2, 228, 26, 8, 'rgba(52,199,89,0.10)');
      g.globalAlpha = lit ? 1 : 0.25;
      text(g, name, px2 + 14, ny + 15, { size: 11.5, weight: on ? 600 : 400,
           color: on ? ink.title : ink.body });
      text(g, `${ms}ms`, px2 + 228, ny + 15, { size: 10.5, weight: 600,
           color: ms < 60 ? '#34C759' : '#8E8E93', align: 'right' });
      g.globalAlpha = 1;
      ny += 30;
    });
  } else if (sections.rows) {
    // The session cards and the usage panel, as the popup really stacks them.
    let ry = cy;
    sections.rows.forEach((sec) => {
      const sh = sec.height;
      fillRR(g, M, ry + scroll * 0, w - 2 * M, sh, 14, ink.card);
      strokeRR(g, M, ry, w - 2 * M, sh, 14, ink.hair, 1);
      sec.draw(g, { x: M, y: ry, w: w - 2 * M, h: sh, ink });
      ry += sh + 6;
    });
  }

  // The toast rides at the bottom of the shell and fades on its own.
  if (feedback && feedback.a > 0) {
    g.globalAlpha = feedback.a;
    const fw = measure(g, feedback.text, { size: 11, weight: 600 }) + 26;
    fillRR(g, w / 2 - fw / 2, h - 34, fw, 22, 11, 'rgba(10,14,24,0.86)');
    text(g, feedback.text, w / 2, h - 20, { size: 11, weight: 600, color: '#FFFFFF', align: 'center' });
    g.globalAlpha = 1;
  }
  g.restore();
  g.restore();
}

function iconButton(g, x, y, s, kind, ink) {
  fillRR(g, x, y, s, s, 6, 'rgba(0,0,0,0.04)');
  g.save();
  g.strokeStyle = ink.body; g.lineWidth = 1.4; g.lineCap = 'round';
  g.translate(x + s / 2, y + s / 2); g.scale(0.7, 0.7);
  g.beginPath();
  g.arc(0, 0, 6, 0.6, 0.6 + Math.PI * 1.6); g.stroke();
  g.beginPath(); g.moveTo(6.4, -6); g.lineTo(6.4, -1.6); g.lineTo(2, -1.6); g.stroke();
  g.restore();
}

/** A popup session card: status dot, two-part title, context, tool, heartbeat. */
export function drawPopupSessionCard(g, { x, y, w, h, s, ink, tool, context, memory, ago, heartbeat }) {
  text(g, s.project, x + 22, y + 22, { size: 13, weight: 600, family: 'rounded', color: ink.title });
  text(g, '|', x + 22 + measure(g, s.project, { size: 13, weight: 600, family: 'rounded' }) + 5,
       y + 22, { size: 13, weight: 400, color: '#C7C7CC' });
  text(g, s.title, x + 22 + measure(g, s.project, { size: 13, weight: 600, family: 'rounded' }) + 14,
       y + 22, { size: 13, weight: 400, color: ink.body });

  if (s.busy) {
    fillRR(g, x + w - 60, y + 10, 46, 18, 9, 'rgba(61,125,255,0.12)');
    text(g, '运行中', x + w - 37, y + 23, { size: 10, weight: 600, color: '#1D4FB8', align: 'center' });
  } else {
    fillRR(g, x + w - 52, y + 10, 38, 18, 9, 'rgba(0,0,0,0.04)');
    text(g, '空闲', x + w - 33, y + 23, { size: 10, weight: 600, color: ink.faint, align: 'center' });
  }

  text(g, context, x + 22, y + 48, { size: 12, weight: 600, family: 'rounded', color: ink.title });
  const cw = measure(g, context, { size: 12, weight: 600, family: 'rounded' });
  fillRR(g, x + 30 + cw, y + 42, 150, 4, 2, 'rgba(0,0,0,0.08)');
  fillRR(g, x + 30 + cw, y + 42, 150 * s.ratio, 4, 2, '#3D7DFF');
  text(g, `${Math.round(s.ratio * 100)}% · ${memory} ${ago}`, x + w - 22, y + 48,
       { size: 11, weight: 400, color: ink.body, align: 'right' });

  text(g, tool, x + 22, y + 70, { size: 11, weight: 400, color: ink.body });
  // The heartbeat: recent busy/idle samples, one bar each.
  let hx = x + w - 22 - heartbeat.length * 4;
  const hy = y + 60;
  heartbeat.forEach((v) => {
    g.fillStyle = v ? 'rgba(61,125,255,0.85)' : 'rgba(0,0,0,0.10)';
    g.fillRect(hx, hy, 3, 14 * (v ? 1 : 0.35) + 2);
    hx += 4;
  });
}

/** The popup's usage panel: period chips, heatmap, two totals, three model rows. */
export function drawPopupUsage(g, { x, y, w, h, ink, period = 1, heatT = 1 }) {
  text(g, '用量', x + 18, y + 26, { size: 15, weight: 600, family: 'rounded', color: ink.title });
  text(g, '2026年9月 · 141.9亿', x + 52, y + 26, { size: 11, weight: 400, color: ink.body });

  // The one segmented control in the app (SegmentedCapsule).
  const segs = ['日', '月', '年', '自定'];
  const sw = 25, sh = 22, sx = x + w - 18 - (sw + 4) * segs.length - 4;
  fillRR(g, sx - 3, y + 10, (sw + 4) * segs.length + 6, sh + 2, 12, 'rgba(0,0,0,0.05)');
  segs.forEach((s, i) => {
    if (i === period) fillRR(g, sx + i * (sw + 4), y + 11, sw + 1, sh, 11, '#FFFFFF');
    text(g, s, sx + i * (sw + 4) + sw / 2, y + 25, { size: 10.5, weight: 500,
         color: i === period ? ink.title : ink.body, align: 'center' });
  });

  // The heatmap: 5 rows x 26 columns, lit in order from the top left.
  const hx = x + 18, hy = y + 44, cw = (w - 36) / 26, chh = 13;
  let k = 0;
  for (let r = 0; r < 5; r++) {
    for (let c = 0; c < 26; c++, k++) {
      const v = fbm(c * 0.6 + r * 2.1, 2);
      const lit = clamp(heatT * 130 - k) > 0;
      g.fillStyle = lit ? `rgba(191,90,242,${0.25 + v * 0.6})` : 'rgba(0,0,0,0.045)';
      rr(g, hx + c * cw, hy + r * chh, cw - 2, chh - 3, 2); g.fill();
    }
  }

  const ty = hy + 5 * chh + 14;
  text(g, 'Token 用量', x + 18, ty, { size: 10, weight: 500, color: ink.faint });
  text(g, '141.9亿', x + 18, ty + 20, { size: 17, weight: 600, family: 'rounded', color: ink.title });
  text(g, '所选时段累计', x + 18, ty + 34, { size: 9.5, weight: 400, color: ink.faint });
  text(g, '花费', x + w / 2 + 6, ty, { size: 10, weight: 500, color: ink.faint });
  text(g, '¥404.70', x + w / 2 + 6, ty + 20, { size: 17, weight: 600, family: 'rounded', color: ink.title });
  text(g, '另有 $43.20', x + w / 2 + 6, ty + 34, { size: 9.5, weight: 400, color: ink.faint });

  const my = ty + 52;
  [['deepseek-v4.1-flash', '105.9亿'], ['claude-opus-4-6', '24.1亿'], ['gpt-6-astra', '11.9亿']]
    .forEach(([name, v], i) => {
      text(g, name, x + 18, my + i * 18, { size: 11, weight: i === 0 ? 600 : 400, color: ink.title });
      text(g, v, x + w - 18, my + i * 18, { size: 11, weight: i === 0 ? 600 : 400,
           color: ink.body, align: 'right' });
    });
}

// ================================================= 8/9 · the popup's scenes
const CHIPS = {
  get(ink, env) {
    return [
      { family: 'CC', title: 'deepseek-v4.1-flash', mark: env.assets.anthropic, footer: 'Aibox' },
      { family: 'Codex', title: '未配置', mark: env.assets.openai, footer: 'Codex 额度查询失败' },
      { family: 'Cursor', title: '月度套餐', mark: env.assets.cursor,
        gauges: [['Cursor', 0.48], ['Other', 0.60]], spend: '$9.20 / $20', footer: '' },
    ];
  },
};

export function scene8(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  // The island folds back and the popup rises from the lower left, then the
  // camera pushes in until the switcher row is the subject (prompt.md §4 §8).
  const islandOut = ramp(t, 0, 0.5, 'slow');
  g.globalAlpha = 1 - islandOut;
  if (islandOut < 1) drawIsland(g, { mode: 'collapsed', t, wingCount: 2, todayTokens: 312_400_000 });
  g.globalAlpha = 1;

  const inA = ramp(t, 0.4, 1.6, 'enter');
  const push = ramp(t, 2.6, 4.4, 'slow');
  const scale = lerp(0.9, 1.0, inA) * lerp(1.0, 1.24, push);

  const chips = CHIPS.get(ink, env);
  // The switcher opens at 2.8 s, is picked at 6.6 s, and the toast rides 2 s.
  const open = ramp(t, 2.8, 3.1, 'snap');
  const pickT = 6.6;
  const picked = t > pickT;
  if (picked) chips[0].title = 'deepseek-v4-pro';
  const rollIdx = picked ? 0 : -1;

  const popW = 660, popH = 760;
  const px = W / 2 - 90, py = H / 2 - 10;

  withCamera(g, { scale, x: px, y: py }, (c) => {
    drawPopup(c, {
      x: px - popW / 2, y: py - popH / 2, w: popW, t, ink,
      hover: t > 1.6 && t < pickT ? 0 : -1,
      sections: {
        height: popH, chips, rollout: rollIdx,
        // The shell is not a header floating over white: the popup stacks its
        // session cards and then the usage panel, and both are what make the
        // window read as the app rather than as three chips.
        rows: [
          { height: 300, draw: (c, r) => {
              c.save();
              text(c, 'Claude Code', r.x + 18, r.y + 26,
                   { size: 13, weight: 600, family: 'rounded', color: ink.title });
              drawPopupSessionCard(c, {
                x: r.x, y: r.y + 36, w: r.w, h: 84, ink,
                s: { project: 'ClaudeBar', title: '修 CI 红', busy: true, ratio: 0.27 },
                context: '135k / 500k', tool: 'Bash · killall · deepseek-v4.1-flash',
                memory: '343 MB', ago: '56s', heartbeat: hb(t, 24, 0.7),
              });
              text(c, 'Cursor', r.x + 18, r.y + 152,
                   { size: 13, weight: 600, family: 'rounded', color: ink.title });
              text(c, '5 · 0A', r.x + r.w - 18, r.y + 152,
                   { size: 11, weight: 400, color: ink.body, align: 'right' });
              drawPopupSessionCard(c, {
                x: r.x, y: r.y + 162, w: r.w, h: 84, ink,
                s: { project: 'Neo', title: 'AgentLoop 追踪', busy: true, ratio: 0.37 },
                context: '183k / 500k', tool: 'Edited routes.ts',
                memory: '396 MB', ago: '8s', heartbeat: hb(t, 24, 0.95),
              });
              c.restore();
            } },
          { height: 348, draw: (c, r) => {
              drawPopupUsage(c, { x: r.x, y: r.y + 6, w: r.w, h: r.h, ink,
                                  period: 1, heatT: 1 });
            } },
        ],
      },
      popover: t > 2.8 && t < pickT + 0.1 ? {
        chip: 0, title: '切换 Claude Code',
        rows: [
          { header: 'Aibox' },
          { title: 'deepseek-v4-flash', active: !picked },
          { title: 'deepseek-v4-pro', active: picked, pick: picked },
          { title: 'glm-5.3-flash' },
          { header: 'Anthropic' },
          { title: 'claude-opus-4-6' },
        ],
      } : null,
      popT: open * (1 - ramp(t, pickT, pickT + 0.3, 'slow')),
      feedback: t > pickT + 0.2 ? { text: 'CC · Aibox / deepseek-v4-pro',
                                   a: gate(t, pickT + 0.2, pickT + 0.5, pickT + 1.8, pickT + 2.2) } : null,
    });
  });

  // VPN node panel, opened on the pill at 8.2 s.
  if (t > 8.6) {
    const a = ramp(t, 8.6, 8.9, 'snap');
    g.globalAlpha = a;
    const ph = 168, hx = px + popW / 2 - 12 - 240, hy = py - popH / 2 + 150;
    const lit = Math.floor(clamp((t - 9.0) / 1.0) * 4);
    fillPopover(g, hx, hy, 240, ph, '节点', [['日本 A01 · 带宽优化', 42, true],
      ['日本 A02 · 低倍率', 58, false], ['香港 B01 · 容灾', 76, false], ['新加坡 C01', 96, false]],
      lit, ink);
    g.globalAlpha = 1;
  }

  // The popup owns the centre, so the caption lives in the left band — clear of
  // the panel at every point of the push.
  const copyIn = ramp(t, 10.2, 11.0, 'enter');
  const copyOut = ramp(t, 12.6, 13.4, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '点一下，换了。',
                body: '三格是 CC / Codex / Cursor。激活写回各自的配置文件，互不覆盖。',
                x: 70, y: 150, width: Math.max(300, px - popW * scale / 2 - 110),
                ink, titleSize: 62, bodySize: 20 });
  g.globalAlpha = 1;
}

function fillPopover(g, x, y, w, h, title, rows, lit, ink) {
  g.save();
  g.shadowColor = 'rgba(20,24,32,0.18)'; g.shadowBlur = 24; g.shadowOffsetY = 10;
  fillRR(g, x, y, w, h, 12, '#FFFFFF');
  g.restore();
  strokeRR(g, x, y, w, h, 12, ink.hair, 1);
  text(g, title, x + 12, y + 18, { size: 10, weight: 500, color: ink.faint });
  rows.forEach(([name, ms, on], i) => {
    const ry = y + 30 + i * 30;
    if (on) fillRR(g, x + 6, ry - 2, w - 12, 26, 8, 'rgba(52,199,89,0.10)');
    g.globalAlpha *= (i < lit || on) ? 1 : 0.25;
    text(g, name, x + 14, ry + 15, { size: 11.5, weight: on ? 600 : 400, color: on ? ink.title : ink.body });
    text(g, `${ms}ms`, x + w - 12, ry + 15, { size: 10.5, weight: 600,
         color: ms < 60 ? '#34C759' : '#8E8E93', align: 'right' });
    g.globalAlpha = 1;
  });
}

export function scene9(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  // The popup is drawn whole and taller than the frame, and the camera pans down
  // it. The pan distance is the panel's height minus what the frame can hold at
  // this zoom — a fixed 900pt overshoots into the empty tail below the usage
  // panel and the shot ends on nothing.
  const popW = 660;
  const secH = 240, usageH = 348, headH = 300;
  const popH = headH + secH + usageH + 24;
  const px = W * 0.62, py = 300;
  const scale = 1.12;
  const maxPan = Math.max(0, popH - H / scale);
  const pan = ramp(t, 2.4, 4.0, 'slow') * maxPan;

  withCamera(g, { scale, x: px, y: py, dy: -pan * 0.35 }, (c) => {
    c.save();
    c.translate(0, -pan * 0.0);
    // Only the lower half of the popup is painted: sessions, then usage.
    c.save();
    c.translate(px - popW / 2 + pan * 0.0, py - popH / 2);
    c.save();
    c.shadowColor = ink.shadow; c.shadowBlur = 48; c.shadowOffsetY = 18;
    fillRR(c, 0, 0, popW, popH, 22, ink.card);
    c.restore();
    strokeRR(c, 0, 0, popW, popH, 22, ink.hair, 1);
    c.save();
    rr(c, 0, 0, popW, popH, 22); c.clip();
    const M = 12;
    // Claude Code section header.
    text(c, 'Claude Code', M + 18, 34, { size: 13, weight: 600, family: 'rounded', color: ink.title });
    drawPopupSessionCard(c, {
      x: M, y: 46, w: popW - 2 * M, h: 84, ink,
      s: { project: 'ClaudeBar', title: '修 CI 红', busy: false, ratio: 0.27 },
      context: '135k / 500k', tool: 'Bash · killall · deepseek-v4.1-flash',
      memory: '343 MB', ago: '56s', heartbeat: hb(t, 24, 0.25),
    });
    drawPopupSessionCard(c, {
      x: M, y: 136, w: popW - 2 * M, h: 84, ink,
      s: { project: 'Neo', title: 'AgentLoop 追踪', busy: true, ratio: 0.37 },
      context: '183k / 500k', tool: 'Bash · sleep · deepseek-v4.1-flash',
      memory: '396 MB', ago: '5m', heartbeat: hb(t, 24, 0.85),
    });
    const secH = 84, secY = 240;
    fillRR(c, M, secY, popW - 2 * M, secH, 14, ink.card);
    strokeRR(c, M, secY, popW - 2 * M, secH, 14, ink.hair, 1);
    text(c, 'Cursor', M + 18, secY + 26, { size: 13, weight: 600, family: 'rounded', color: ink.title });
    text(c, '5 · 0A', popW - M - 18, secY + 26, { size: 11, weight: 400,
         color: ink.body, align: 'right' });
    drawPopupUsage(c, { x: M, y: secY + secH + 8, w: popW - 2 * M, h: 340, ink,
                        period: 1, heatT: ramp(t, 1.0, 2.2, 'slow') });
    c.restore();
    c.restore();
    c.restore();
  });

  // Double-click a session card: the terminal grows out of it, then folds back.
  const termA = gate(t, 5.4, 5.9, 7.8, 8.4);
  if (termA > 0.01) {
    const tw = 760, th = 300;
    const tx = W * 0.30, ty = py + 120;
    const sc = lerp(0.86, 1, ramp(t, 5.4, 5.9, 'enter'));
    g.save();
    g.globalAlpha = termA;
    g.translate(tx, ty); g.scale(sc, sc); g.translate(-tx, -ty);
    g.save();
    g.shadowColor = 'rgba(0,0,0,0.30)'; g.shadowBlur = 60; g.shadowOffsetY = 24;
    fillRR(g, tx - tw / 2, ty - th / 2, tw, th, 12, '#1A1C20');
    g.restore();
    strokeRR(g, tx - tw / 2, ty - th / 2, tw, th, 12, 'rgba(255,255,255,0.10)', 1);
    [['#FF5F57', 0], ['#FEBC2E', 1], ['#28C840', 2]].forEach(([c, i]) => {
      g.fillStyle = c;
      g.beginPath(); g.arc(tx - tw / 2 + 18 + i * 18, ty - th / 2 + 18, 5.5, 0, Math.PI * 2); g.fill();
    });
    text(g, 'claudebar — claude — 120×32', tx, ty - th / 2 + 22, { size: 11, weight: 500,
         color: 'rgba(255,255,255,0.45)', align: 'center' });
    text(g, '$ claude --resume 4f3a…', tx - tw / 2 + 22, ty - th / 2 + 64, { size: 13, weight: 400,
         color: '#E8E8EA', mono: true });
    const typed = ramp(t, 5.7, 6.5, 'slow');
    text(g, 'resumed in ~/Project/ClaudeBar', tx - tw / 2 + 22, ty - th / 2 + 96,
         { size: 13, weight: 400, color: '#5EEAD4', mono: true, opacity: typed });
    text(g, '● 3 个工具在跑 · 上下文 135k / 500k', tx - tw / 2 + 22, ty - th / 2 + 132,
         { size: 11, weight: 400, color: 'rgba(255,255,255,0.45)', mono: true });
    g.restore();
  }

  const copyIn = ramp(t, 0.4, 1.4, 'enter');
  const copyOut = ramp(t, 8.6, 9.6, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '接着刚才那次会话。',
                body: '目录 | 标题、上下文、当前工具、心跳、内存。双击就在终端里接上。',
                x: 130, y: 700, width: 620, ink });
  g.globalAlpha = 1;
}

function hb(t, n, busy) {
  return Array.from({ length: n }, (_, i) => {
    const advance = clamp((t - 1.4) / 0.12);
    if (i > advance) return false;
    return hash(i * 3.7) < busy;
  });
}

// ========================================================== 10 · main window
/** A dashboard tile: label, big reading, detail, and its own instrument lane. */
function dashboardTile(g, { x, y, w, h, label, value, detail, badge, ink, bars, tint }) {
  g.save();
  g.shadowColor = 'rgba(20,24,32,0.06)'; g.shadowBlur = 12; g.shadowOffsetY = 4;
  fillRR(g, x, y, w, h, 18, ink.card);
  g.restore();
  strokeRR(g, x, y, w, h, 18, ink.hair, 1);
  text(g, label, x + 22, y + 30, { size: 14, weight: 500, color: ink.body });
  if (badge) {
    fillRR(g, x + w - 22 - measure(g, badge, { size: 10, weight: 600 }) - 16, y + 18,
           measure(g, badge, { size: 10, weight: 600 }) + 16, 20, 10, 'rgba(0,0,0,0.045)');
    text(g, badge, x + w - 30, y + 32, { size: 10, weight: 600, color: ink.body, align: 'right' });
  }
  text(g, value, x + 22, y + h - 46, { size: 46, weight: 600, family: 'rounded', color: tint || ink.title });
  text(g, detail, x + 22, y + h - 22, { size: 11, weight: 400, color: ink.faint });
  if (bars) {
    // The instrument lane: one bar per unit, height = its own reading.
    const bw = 7, n = bars.length, total = n * bw + (n - 1) * 3;
    bars.forEach((v, i) => {
      g.fillStyle = i < Math.round(n * (bars.filter(Boolean).length / n))
        ? tint || ink.title : 'rgba(0,0,0,0.10)';
      rr(g, x + w - 24 - total + i * (bw + 3), y + h - 56, bw, 40, 3);
      g.fill();
    });
  }
}

export function drawMainWindow(g, { x, y, w, h, t, ink, page, heatT = 1, cmdK = 0, tabT = 1 }) {
  g.save();
  g.translate(x, y);
  g.save();
  g.shadowColor = ink.shadow; g.shadowBlur = 60; g.shadowOffsetY = 24;
  fillRR(g, 0, 0, w, h, 14, ink.canvas);
  g.restore();
  strokeRR(g, 0, 0, w, h, 14, ink.hair, 1);

  g.save();
  rr(g, 0, 0, w, h, 14); g.clip();
  // Title bar: traffic lights, the product, the seven pages, ⌘K.
  [[0, '#FF5F57'], [1, '#FEBC2E'], [2, '#28C840']].forEach(([i, c]) => {
    g.fillStyle = c;
    g.beginPath(); g.arc(26 + i * 20, 28, 6.5, 0, Math.PI * 2); g.fill();
  });
  const mark = __env2 && __env2.assets.icon;
  if (mark) g.drawImage(mark, 118, 18, 22, 22);
  text(g, 'ClaudeBar', 148, 34, { size: 16, weight: 600, family: 'rounded', color: ink.title });
  const tabs = ['概览', '会话', '模型', '用量', '流量', 'VPN', '设置'];
  let tx = 400;
  tabs.forEach((tb, i) => {
    const active = i === page;
    const tw = measure(g, tb, { size: 13, weight: 500, family: 'rounded' }) + 34;
    if (active) fillRR(g, tx, 16, tw, 26, 13, 'rgba(61,125,255,0.10)');
    text(g, tb, tx + tw / 2, 33, { size: 13, weight: 500, family: 'rounded',
         color: active ? '#1D4FB8' : ink.body, align: 'center' });
    tx += tw + 6;
  });
  fillRR(g, w - 150, 16, 74, 26, 13, 'rgba(0,0,0,0.04)');
  text(g, '1 运行中', w - 113, 33, { size: 11, weight: 500, color: ink.body, align: 'center' });
  text(g, '⌘K', w - 46, 33, { size: 11, weight: 500, color: ink.faint, align: 'center' });

  g.fillStyle = ink.hair;
  g.fillRect(0, 54, w, 1);

  // Pages slide horizontally by 220 ms; this is that push, caught mid-flight.
  const slide = (1 - tabT) * 26;
  g.save();
  g.translate(-slide, 0);

  const M = 30, top = 78;
  if (page === 0) {
    text(g, '概览', M + 26, top + 26, { size: 22, weight: 600, family: 'rounded', color: ink.title });
    fillRR(g, w - M - 96, top + 6, 96, 28, 14, 'rgba(61,125,255,0.10)');
    text(g, '⟳ 刷新', w - M - 48, top + 25, { size: 12, weight: 600, color: '#1D4FB8', align: 'center' });

    const gy = top + 48, tw = (w - 2 * M - 2 * 16) / 3, th = 210;
    const specs = [
      ['CPU', '47%', '— · 74°C', '12 核', '#34C759', Array.from({ length: 12 }, (_, i) => i < 6)],
      ['GPU', '35%', '本机 35% · 82°C', '本机', '#FF9F0A', Array.from({ length: 10 }, (_, i) => i < 4)],
      ['内存', '84%', '已使用 15.1 GB / 18.0 GB', '偏高', '#FF9F0A', Array.from({ length: 16 }, (_, i) => i < 13)],
      ['硬盘', '82%', '已使用 375.4 GB / 460.4 GB', '偏高', '#BF5AF2', Array.from({ length: 16 }, (_, i) => i < 13)],
      ['连接', 'cxwifi222', '-40 dBm · 已接通', '已连接', '#34C759', null],
      ['风扇', '1463 · 1580', '自动', '自动', ink.title, null],
    ];
    specs.forEach(([label, value, detail, badge, tint, bars], i) => {
      const cx = M + (i % 3) * (tw + 16), cy = gy + Math.floor(i / 3) * (th + 16);
      dashboardTile(g, { x: cx, y: cy, w: tw, h: th, label, value, detail, badge, ink, bars, tint });
    });

    // Energy flow: the one wide card, with power moving left to right.
    const ey = gy + 2 * (th + 16), eh = 150;
    g.save();
    g.shadowColor = 'rgba(20,24,32,0.06)'; g.shadowBlur = 12; g.shadowOffsetY = 4;
    fillRR(g, M, ey, w - 2 * M, eh, 18, ink.card);
    g.restore();
    strokeRR(g, M, ey, w - 2 * M, eh, 18, ink.hair, 1);
    text(g, '⚡ 能源流向', M + 22, ey + 28, { size: 14, weight: 600, color: ink.title });
    text(g, '实时功率', w - M - 22, ey + 28, { size: 11, weight: 400, color: ink.faint, align: 'right' });
    const bx = M + 130, bw2 = w - 2 * M - 240;
    const bg2 = g.createLinearGradient(bx, 0, bx + bw2, 0);
    bg2.addColorStop(0, 'rgba(122,168,232,0.32)');
    bg2.addColorStop(1, 'rgba(122,168,232,0.06)');
    fillRR(g, bx, ey + 50, bw2, eh - 66, 12, bg2);
    for (let i = 0; i < 26; i++) {
      g.strokeStyle = 'rgba(255,255,255,0.35)'; g.lineWidth = 1;
      const yy = ey + 50 + (i / 26) * (eh - 66);
      g.beginPath(); g.moveTo(bx, yy);
      g.quadraticCurveTo(bx + bw2 / 2, yy + Math.sin(i + t * 1.4) * 6, bx + bw2, yy); g.stroke();
    }
    text(g, '50.28 W', bx + bw2 / 2, ey + 92, { size: 30, weight: 600, family: 'rounded',
         color: ink.title, align: 'center' });
    text(g, '电源', M + 66, ey + eh / 2 + 6, { size: 12, weight: 500, color: ink.body, align: 'center' });
    text(g, '50 W', w - M - 66, ey + eh / 2 + 6, { size: 12, weight: 500, color: ink.body, align: 'center' });
    text(g, '电源输入 → 整机消耗 / 电池充电 · 微小功率以细线表示。', M + 22, ey + eh + 20,
         { size: 10.5, weight: 400, color: ink.faint });
  } else if (page === 1) {
    text(g, '会话', M + 26, top + 26, { size: 22, weight: 600, family: 'rounded', color: ink.title });
    const secs = [
      ['CLAUDE CODE', [['ClaudeBar | 修 CI 红', '135k / 500k', 0.27, 'Bash · build.sh', 0],
                       ['Neo | AgentLoop 追踪', '183k / 500k', 0.37, 'Bash · sleep', 1]]],
      ['CURSOR', [['ClaudeBar', '4m', 0.2, 'Shell · cd', 0], ['lingxi-agent', '2h', 0.4, 'Read · AgentLoopTracer.java', 0]]],
      ['CODEX', [['api-server', '8m', 0.08, 'exec_command', 1]]],
    ];
    let sy = top + 50;
    secs.forEach(([name, items], si) => {
      const appear = clamp(tabT * 3 - si * 0.5);
      g.globalAlpha = appear;
      text(g, name, M + 26, sy + 14, { size: 11, weight: 600, color: ink.faint, tracking: 0.06 * 11 });
      sy += 28;
      const cw = (w - 2 * M - 16) / 2;
      items.forEach(([title, ctx, ratio, tool, busy], i) => {
        const cx = M + (i % 2) * (cw + 16), cy = sy + Math.floor(i / 2) * 104;
        fillRR(g, cx, cy, cw, 92, 16, ink.card);
        strokeRR(g, cx, cy, cw, 92, 16, ink.hair, 1);
        g.fillStyle = busy ? '#3D7DFF' : '#C7C7CC';
        g.beginPath(); g.arc(cx + 20, cy + 24, 4, 0, Math.PI * 2); g.fill();
        text(g, title, cx + 34, cy + 28, { size: 13, weight: 600, family: 'rounded', color: ink.title });
        text(g, ctx, cx + 20, cy + 54, { size: 13, weight: 600, family: 'rounded', color: '#3D7DFF' });
        fillRR(g, cx + 96, cy + 46, 150, 4, 2, 'rgba(0,0,0,0.08)');
        fillRR(g, cx + 96, cy + 46, 150 * ratio, 4, 2, '#3D7DFF');
        text(g, tool, cx + 20, cy + 76, { size: 11, weight: 400, color: ink.body });
        // A heartbeat at the card's right edge — idle bars are short.
        let hx = cx + cw - 20 - 22 * 4;
        Array.from({ length: 22 }, (_, k) => k < 14).forEach((on, k) => {
          g.fillStyle = on ? (busy ? 'rgba(61,125,255,0.85)' : 'rgba(0,0,0,0.14)') : 'rgba(0,0,0,0.06)';
          g.fillRect(hx + k * 4, cy + 62, 3, on ? 14 : 4);
        });
      });
      sy += items.length > 2 ? 104 * Math.ceil(items.length / 2) : 104;
      g.globalAlpha = 1;
    });
  } else if (page === 3) {
    text(g, '用量', M + 26, top + 26, { size: 22, weight: 600, family: 'rounded', color: ink.title });
    const segs = ['日', '月', '年', '全部', '自定'];
    let sx = M + 26;
    segs.forEach((s, i) => {
      const sw = 44;
      if (i === 1) fillRR(g, sx - 2, top + 8, sw, 26, 13, '#FFFFFF');
      text(g, s, sx + sw / 2 - 2, top + 26, { size: 11, weight: 500, family: 'rounded',
           color: i === 1 ? ink.title : ink.body, align: 'center' });
      sx += sw;
    });
    // Heatmap: 7 x 26, revealed from the top left (0.7 s for the whole grid).
    const hx = M + 26, hy = top + 52, cw = (w - 2 * M - 52) / 26, chh = 24;
    let k = 0;
    for (let r = 0; r < 7; r++) for (let c = 0; c < 26; c++, k++) {
      const v = fbm(c * 0.53 + r * 1.7, 2);
      const lit = clamp(heatT * 182 - k) > 0;
      g.fillStyle = lit ? `rgba(191,90,242,${0.22 + v * 0.66})` : 'rgba(0,0,0,0.05)';
      rr(g, hx + c * cw, hy + r * chh, cw - 3, chh - 3, 3); g.fill();
    }
    // Three charts: source split, pace, cache anatomy — each trims open.
    const cy2 = hy + 7 * chh + 22, cw3 = (w - 2 * M - 32) / 3, ch3 = 140;
    const grow = ramp(t, 1.0, 1.6, 'slow');
    [0, 1, 2].forEach((i) => {
      const cx = M + i * (cw3 + 16);
      fillRR(g, cx, cy2, cw3, ch3, 16, ink.card);
      strokeRR(g, cx, cy2, cw3, ch3, 16, ink.hair, 1);
      const titles = ['来源', '节奏', '构成'];
      text(g, titles[i], cx + 18, cy2 + 26, { size: 13, weight: 600, family: 'rounded', color: ink.title });
      if (i === 0) {
        const segs2 = [[0.434, '#E8845E'], [0.512, '#7C9CFF'], [0.054, '#F472B6']];
        let acc = 0;
        segs2.forEach(([v, c]) => {
          g.fillStyle = c;
          rr(g, cx + 18 + (cw3 - 36) * acc, cy2 + 48, (cw3 - 36) * v * grow, 14, 4); g.fill();
          acc += v;
        });
        const labels = ['CC 43.4%', 'Codex 51.2%', '第三方 5.4%'];
        labels.forEach((l, kk) => text(g, l, cx + 18 + kk * 84, cy2 + 84, { size: 10, weight: 500,
             color: ink.body }));
      } else if (i === 1) {
        const pts = Array.from({ length: 22 }, (_, kk) => fbm(kk * 0.44 + 5, 3));
        const max = Math.max(...pts);
        g.strokeStyle = '#BF5AF2'; g.lineWidth = 1.6; g.lineJoin = 'round';
        g.beginPath();
        const shown = Math.floor(grow * pts.length);
        pts.slice(0, shown).forEach((v, kk) => {
          const px2 = cx + 18 + (kk / (pts.length - 1)) * (cw3 - 36);
          const py2 = cy2 + ch3 - 30 - (v / max) * 60;
          kk === 0 ? g.moveTo(px2, py2) : g.lineTo(px2, py2);
        });
        g.stroke();
      } else {
        const parts = [['输入', 0.42, '#5B9CFF'], ['命中', 0.38, '#34C759'],
                       ['写入', 0.08, '#FF9F0A'], ['输出', 0.12, '#BF5AF2']];
        let acc = 0;
        parts.forEach(([nm, v, c]) => {
          g.fillStyle = c;
          rr(g, cx + 18 + (cw3 - 36) * acc, cy2 + 48, (cw3 - 36) * v * grow, 14, 4); g.fill();
          acc += v;
        });
        parts.forEach(([nm, v, c], kk) => {
          const lx = cx + 18 + kk * 52;
          g.fillStyle = c; g.beginPath(); g.arc(lx + 4, cy2 + 80, 3.5, 0, Math.PI * 2); g.fill();
          text(g, nm, lx + 11, cy2 + 84, { size: 9.5, weight: 500, color: ink.body });
        });
      }
    });
  } else if (page === 5) {
    text(g, 'VPN', M + 26, top + 26, { size: 22, weight: 600, family: 'rounded', color: ink.title });
    fillRR(g, M + 26, top + 46, 96, 28, 14, 'rgba(52,199,89,0.14)');
    text(g, '已启用', M + 74, top + 65, { size: 12, weight: 600, color: '#1B7F3A', align: 'center' });

    const ly = top + 92, lw = (w - 2 * M - 52) / 2;
    const nodes = [['日本 A01 · 带宽优化', 42, true], ['日本 A02 · 低倍率', 58, false],
                   ['香港 B01 · 容灾', 76, false], ['新加坡 C01 · 家用', 96, false],
                   ['美国 D02 · 流媒体', 168, false]];
    const appear = ramp(t, 0.6, 1.8, 'slow');
    nodes.forEach(([name, ms, on], i) => {
      const cx = M + 26 + (i % 2) * (lw + 16), cy = ly + Math.floor(i / 2) * 52;
      g.globalAlpha = clamp(appear * 5 - i * 0.7);
      fillRR(g, cx, cy, lw, 44, 12, ink.card);
      strokeRR(g, cx, cy, lw, 44, 12, on ? 'rgba(52,199,89,0.5)' : ink.hair, on ? 1.5 : 1);
      text(g, name, cx + 16, cy + 27, { size: 12.5, weight: on ? 600 : 400, color: ink.title });
      text(g, `${ms}ms`, cx + lw - 16, cy + 27, { size: 12, weight: 600,
           color: ms < 60 ? '#34C759' : ink.body, align: 'right' });
      g.globalAlpha = 1;
    });
    // The live rate reads along the bottom, moving as it does in the strip.
    const ry = ly + Math.ceil(nodes.length / 2) * 52 + 20;
    text(g, '实时速率', M + 26, ry, { size: 11, weight: 500, color: ink.faint });
    text(g, `↓ ${(2.1 + Math.sin(t * 2) * 0.3).toFixed(1)}M  ↑ ${(0.31 + Math.cos(t * 1.7) * 0.04).toFixed(2)}M`,
         M + 100, ry, { size: 13, weight: 600, family: 'rounded', color: '#31D159' });
  }

  // ⌘K, the command palette, rising from the bottom edge.
  if (cmdK > 0) {
    const pw = 620, ph = 320;
    const py2 = h - 120 - ph * cmdK;
    g.globalAlpha = cmdK;
    g.save();
    g.shadowColor = 'rgba(20,24,32,0.22)'; g.shadowBlur = 40; g.shadowOffsetY = 16;
    fillRR(g, (w - pw) / 2, py2, pw, ph, 16, '#FFFFFF');
    g.restore();
    strokeRR(g, (w - pw) / 2, py2, pw, ph, 16, ink.hair, 1);
    text(g, '⌘K', (w - pw) / 2 + 22, py2 + 34, { size: 12, weight: 600, color: ink.faint });
    text(g, '跳页面、会话或模型', (w - pw) / 2 + 56, py2 + 34, { size: 13, weight: 400, color: ink.body });
    g.fillStyle = ink.hair; g.fillRect((w - pw) / 2, py2 + 52, pw, 1);
    const items = [['概览', '页面'], ['修 CI 红', '会话'], ['deepseek-v4-pro', '模型'],
                   ['VPN · 日本 A01', '节点']];
    items.forEach(([nm, kind], i) => {
      const iy = py2 + 62 + i * 40;
      if (i === 2) fillRR(g, (w - pw) / 2 + 8, iy, pw - 16, 34, 10, 'rgba(61,125,255,0.10)');
      text(g, nm, (w - pw) / 2 + 26, iy + 23, { size: 13, weight: i === 2 ? 600 : 400, color: ink.title });
      text(g, kind, (w - pw) / 2 + pw - 26, iy + 23, { size: 11, weight: 400,
           color: ink.faint, align: 'right' });
    });
    g.globalAlpha = 1;
  }

  g.restore();
  g.restore();
  g.restore();
}

// ========================================== 10 (continued) · window on stage
export function scene10(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  // The one pull-out in the film: from the terminal's neighbourhood out to the
  // whole window (prompt.md §2). The window does not move when the page
  // changes — only its content does.
  const pull = ramp(t, 0, 1.2, 'slow');
  const sc = lerp(1.06, 0.86, pull);
  const wW = 1400, wH = 860;

  // One window, four pages. `local` is time since the page it is showing was
  // entered, which is what the per-page reveals are driven by.
  const cuts = [[0.0, 0], [3.2, 1], [6.4, 3], [9.6, 5]];
  let page = 0, local = t;
  for (const [at, pg] of cuts) if (t >= at) { page = pg; local = t - at; }
  const tabT = ramp(local, 0, 0.22, 'slow')
    * (page === 0 ? 1 : 1);

  const heatT = page === 3 ? ramp(local, 0.4, 1.1, 'slow') : 0;
  const cmdK = page === 5 ? ramp(local, 1.6, 1.9, 'snap') : 0;

  withCamera(g, { scale: sc, x: W / 2, y: H / 2 }, (c) => {
    drawMainWindow(c, { x: W / 2 - wW / 2, y: H / 2 - wH / 2, w: wW, h: wH,
                        t: t, ink, page, heatT, cmdK, tabT });
  });
}

// ============================================================= 11 · traffic
export function scene11(g, t, env) {
  const ink = INK.dark;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  const wipe = t < 0.5 ? 1 - ramp(t, 0, 0.5, 'wipe') : 0;
  if (wipe > 0) { g.fillStyle = '#070709'; g.fillRect(0, 0, W, H); }

  const inA = ramp(t, 0.3, 1.2, 'enter');
  const sc = lerp(0.94, 1.0, inA);
  const wW = 1500, wH = 900;
  const pick = t > 3.4 ? 1 : 0;
  const raw = t > 5.6;

  withCamera(g, { scale: sc, x: W / 2, y: H / 2 }, (c) => {
    const x = W / 2 - wW / 2, y = H / 2 - wH / 2;
    c.save();
    c.translate(x, y);
    c.save();
    c.shadowColor = 'rgba(0,0,0,0.5)'; c.shadowBlur = 60; c.shadowOffsetY = 24;
    fillRR(c, 0, 0, wW, wH, 14, '#0E1013');
    c.restore();
    strokeRR(c, 0, 0, wW, wH, 14, 'rgba(255,255,255,0.08)', 1);
    c.save();
    rr(c, 0, 0, wW, wH, 14); c.clip();

    [[0, '#FF5F57'], [1, '#FEBC2E'], [2, '#28C840']].forEach(([i, col]) => {
      c.fillStyle = col;
      c.beginPath(); c.arc(26 + i * 20, 28, 6.5, 0, Math.PI * 2); c.fill();
    });
    text(c, '流量', 118, 34, { size: 16, weight: 600, family: 'rounded', color: '#F5F5F7' });
    fillRR(c, 180, 18, 62, 26, 13, 'rgba(255,255,255,0.12)');
    text(c, '检查器', 211, 35, { size: 12, weight: 600, color: '#FFFFFF', align: 'center' });
    text(c, '日志', 258, 35, { size: 12, weight: 400, color: 'rgba(255,255,255,0.5)' });
    text(c, '● 代理已启用', wW - 30, 35, { size: 12, weight: 500, color: '#31D159', align: 'right' });
    c.fillStyle = 'rgba(255,255,255,0.08)'; c.fillRect(0, 56, wW, 1);

    // Left: the request table. Each row is a request, not a session.
    const lw = 320;
    fillRR(c, 16, 72, 76, 24, 12, 'rgba(255,255,255,0.14)');
    text(c, '全部', 54, 88, { size: 11.5, weight: 600, color: '#FFFFFF', align: 'center' });
    text(c, 'Anthropic', 112, 88, { size: 11.5, weight: 400, color: 'rgba(255,255,255,0.55)' });
    text(c, 'OpenAI', 190, 88, { size: 11.5, weight: 400, color: 'rgba(255,255,255,0.55)' });
    const rows = [['glm-5.3-flash', 'Chat', '18:23', 'Anthropic · json · 202,374/433'],
                  ['glm-5.3-flash', 'Chat', '18:23', '[Request interrupted by user for tool use]'],
                  ['glm-5.3-flash', 'Chat', '18:21', 'Anthropic · stream'],
                  ['hello', 'Codex', '18:04', 'Chat · stream · 179,320/41']];
    rows.forEach(([model, kind, time, sub], i) => {
      const ry = 112 + i * 78;
      if (i === pick) {
        fillRR(c, 16, ry - 4, lw - 32, 72, 10, 'rgba(255,255,255,0.06)');
        c.fillStyle = '#3D7DFF'; rr(c, 16, ry - 4, 2, 72, 1); c.fill();
      }
      const tag = kind === 'Codex' ? '#31D159' : '#5B9CFF';
      fillRR(c, 30, ry + 4, 26, 16, 5, 'rgba(91,156,255,0.20)');
      text(c, kind === 'Codex' ? 'Cx' : 'CC', 43, ry + 16, { size: 9, weight: 700,
           color: tag, align: 'center' });
      text(c, model, 64, ry + 17, { size: 13, weight: 600, family: 'rounded',
           color: i === pick ? '#FFFFFF' : '#E8E8EA' });
      text(c, time, lw - 30, ry + 17, { size: 11, weight: 400,
           color: 'rgba(255,255,255,0.45)', align: 'right' });
      text(c, sub, 30, ry + 40, { size: 11, weight: 400, color: 'rgba(255,255,255,0.55)' });
      text(c, sub === '' ? '' : '', 30, ry + 58, { size: 10, weight: 400, color: 'rgba(255,255,255,0.35)' });
    });
    c.fillStyle = 'rgba(255,255,255,0.08)'; c.fillRect(lw, 56, 1, wH - 56);

    // Right: the three tabs and the reading strip above them.
    const rx = lw + 24;
    text(c, 'glm-5.3-flash', rx, 92, { size: 17, weight: 600, family: 'rounded', color: '#FFFFFF' });
    const nameW = measure(c, 'glm-5.3-flash', { size: 17, weight: 600, family: 'rounded' });
    fillRR(c, rx + nameW + 10, 76, 34, 18, 6, 'rgba(255,255,255,0.10)');
    text(c, 'Chat', rx + nameW + 27, 89, { size: 9.5, weight: 600,
         color: 'rgba(255,255,255,0.7)', align: 'center' });
    text(c, 'DONE', wW - 30, 92, { size: 12, weight: 600, color: '#31D159', align: 'right' });

    const stats = [['耗时', '6.0 s'], ['首字', '6.0 s'], ['HTTP', '200'],
                   ['输入', '17.9万'], ['输出', '41'], ['缓存', '17.9万']];
    stats.forEach(([k, v], i) => {
      const sx = rx + i * 118;
      text(c, k, sx, 118, { size: 10, weight: 400, color: 'rgba(255,255,255,0.45)' });
      text(c, v, sx, 138, { size: 13, weight: 600, family: 'rounded', color: '#FFFFFF' });
    });
    c.fillStyle = 'rgba(255,255,255,0.08)'; c.fillRect(lw, 158, wW - lw, 1);

    // Tabs: 对话 / 工具 / 原始 — a hairline underline, not a pill row.
    const tabs = ['对话', '工具', '原始'];
    let tx = rx;
    const active = raw ? 2 : 0;
    tabs.forEach((tb, i) => {
      const tw = measure(c, tb, { size: 12.5, weight: 500 }) + 26;
      text(c, tb, tx + tw / 2, 186, { size: 12.5, weight: i === active ? 600 : 400,
           color: i === active ? '#FFFFFF' : 'rgba(255,255,255,0.5)', align: 'center' });
      if (i === active) { c.fillStyle = '#FFFFFF'; c.fillRect(tx, 197, tw, 1.5); }
      tx += tw;
    });

    const bodyY = 216;
    if (!raw) {
      // One user message, with the image the app captured inline.
      fillRR(c, rx, bodyY, wW - rx - 30, 76, 10, 'rgba(255,255,255,0.05)');
      text(c, '用户', rx + 14, bodyY + 22, { size: 10.5, weight: 600, color: '#5B9CFF' });
      text(c, '<image name=[Image #1] path="/var/folders/lj/c89d7x7s0rn6_0gz9xrbvd040000gn/T/codex-clipboard-23ca93ef-4388-4640-ae63-745f7fc22ffc.png">',
           rx + 14, bodyY + 44, { size: 11, weight: 400, color: 'rgba(255,255,255,0.7)', mono: true });
      // A collapsed tool call: the row the app folds by default.
      fillRR(c, rx, bodyY + 88, wW - rx - 30, 40, 10, 'rgba(255,255,255,0.045)');
      text(c, '工具调用 1016 · exec_command · call_07136ca331554649b08bf49e · read_mcp_resource',
           rx + 14, bodyY + 113, { size: 11.5, weight: 400, color: 'rgba(255,255,255,0.62)', mono: true });
      text(c, '展开', wW - 44, bodyY + 113, { size: 11, weight: 500,
           color: 'rgba(255,255,255,0.5)', align: 'right' });
      // The assistant's answer.
      fillRR(c, rx, bodyY + 140, wW - rx - 30, 300, 10, 'rgba(94,234,212,0.05)');
      text(c, '助手', rx + 14, bodyY + 164, { size: 10.5, weight: 600, color: '#5EEAD4' });
      const paras = [
        '刚把截图做了像素级分离分析，先说两个结论：',
        '1. **斜着的「2026-09-02 18:37 1598…」数字水印不是网页面的** —— 我把 `admin/gateway` 的 SSR HTML、',
        '    全部 CSS/JS chunk、数据库都扫过，没有任何这类内容；它只存在于截图像素里。',
        '2. **模块本身确实还有几处突兀**，按 design.md（暖纸工作台、hover 只 tint）来收：',
        '    - 卡片 hover 时那条 2px 满宽橙红渐变顶线（`.bento-card::before`）在浅色下非常吵——在这张卡上禁掉；',
        '    - 远端行的 iOS 开关是默认 51×31 再 scale，横向挤进 2.5rem 的尾列。',
      ];
      paras.forEach((p, i) => text(c, p, rx + 14, bodyY + 192 + i * 22, { size: 11.5, weight: 400,
           color: 'rgba(255,255,255,0.72)' }));
      text(c, '现在动手改：', rx + 14, bodyY + 192 + paras.length * 22 + 6,
           { size: 11.5, weight: 400, color: 'rgba(255,255,255,0.72)' });
    } else {
      // Raw: the same request as JSON, in mono, with the stream flag highlighted.
      const rawLine = t - 5.6;
      const json = ['{', '  "model": "glm-5.3-flash",', '  "stream": true,',
                    '  "messages": [', '    { "role": "user", "content": […] }', '  ],',
                    '  "tools": [ … 12 ]', '}'];
      json.forEach((ln, i) => {
        const alpha = clamp((rawLine - i * 0.05) * 6);
        const hot = ln.includes('"stream"');
        if (hot && alpha > 0.5) {
          const lw2 = measure(c, ln, { size: 12.5, mono: true }) + 16;
          fillRR(c, rx + 6, bodyY + 22 + i * 26 - 14, lw2, 20, 5, 'rgba(94,234,212,0.12)');
        }
        text(c, ln, rx + 14, bodyY + 22 + i * 26, { size: 12.5, weight: 400, mono: true,
             color: hot ? '#5EEAD4' : 'rgba(255,255,255,0.72)', opacity: alpha });
      });
    }

    c.restore();
    c.restore();
  });

  const copyIn = ramp(t, 6.2, 7.0, 'enter');
  const copyOut = ramp(t, 7.2, 7.8, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '留在本机。', body: '对话、工具调用、图片和原始报文。代理只转发到你自己的上游。',
                x: 130, y: H - 210, width: 560, ink });
  g.globalAlpha = 1;
}

// ==================================================== 12 · the tunnel pill
export function scene12(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);
  drawScreenEdge(g, { notch: { w: 200, h: 46 }, height: 46 });

  // The status item: the two rate rows turn tunnel-green together (0.4 s), which
  // is the whole claim — these bytes are going through the proxy.
  const tunneled = t > 1.0;
  const gr = tunneled ? ramp(t, 1.0, 1.4, 'slow') : 0;
  drawStatusItem(g, W - 40 - 160, 23, {
    icon: env.assets.statusIcon,
    down: `${(1.7 + Math.sin(t * 2.4) * 0.2).toFixed(1)}K`,
    up: `${(0.6 + Math.cos(t * 1.9) * 0.08).toFixed(2)}K`,
    tunneled: gr > 0.5, level: 82,
  });

  // The VPN pill in the popup, lit at the same moment.
  const pw = 190, px = W / 2 - pw / 2, py = 200;
  fillRR(g, px, py, pw, 38, 19, '#FFFFFF');
  strokeRR(g, px, py, pw, 38, 19, ink.hair, 1);
  g.fillStyle = gr > 0.5 ? '#34C759' : '#8E8E93';
  g.beginPath(); g.arc(px + 22, py + 19, 4, 0, Math.PI * 2); g.fill();
  text(g, '日本 A01 · 带宽优化', px + 36, py + 24, { size: 13, weight: 500, color: ink.title });
  text(g, '42ms', px + pw - 16, py + 24, { size: 12, weight: 600, color: '#34C759', align: 'right' });

  // The moment is a claim about colour, so the shot ends on a crop of the two
  // readings and nothing else (prompt.md §4 scene 12).
  const zoom = ramp(t, 1.6, 2.4, 'slow');
  g.globalAlpha = 1;
  text(g, '隧道开着时，那两行速率是绿的。', W / 2, H - 150, { size: 30, weight: 600,
       family: 'rounded', color: ink.title, align: 'center' });
  text(g, '它说的是这些字节在走代理，不是机器有多忙。', W / 2, H - 110,
       { size: 18, weight: 400, color: ink.body, align: 'center' });
}

// =============================================================== 13 · close
export function scene13(g, t, env) {
  const ink = INK.dark;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);
  const inA = ramp(t, 0, 0.9, 'enter');
  g.globalAlpha = inA;
  titleCard(g, t, { mark: env.assets.icon, ink, markSize: 112, nameSize: 64,
                    sub: '开源。住在 macOS 顶栏。', meta: 'macOS 15 · Apple Silicon · MIT',
                    glow: 1 });
  g.globalAlpha = 1;
}
