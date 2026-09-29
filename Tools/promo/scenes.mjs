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
 * The status sheet, composited from the **real** renders.
 *
 * `Tools/render-greeting-preview.py` draws the production sheet out of the
 * production Swift — the Metal sky, the six-day strip, the instrument column,
 * the sill — so these stills are the app's own drawing, not a redrawing of it.
 * The film supplies the camera and the day: it crossfades the app's own sun,
 * cloud, rain and night stills, so even the walk through the day is made of
 * skies the app really rendered.
 *
 * `GREETING_BOX` is the card's own rectangle inside the 2296x1044 preview
 * plate, measured off the render (a 24pt margin on a `#EEF3F8` canvas). The
 * plate is captured at 2x, so 1100x474 is the app's own point size — the film
 * draws the card 1:1 with the app, the same way it draws the island and the
 * popup.
 */
const GREETING_BOX = { x: 48, y: 48, w: 2200, h: 948 };
const GREETING_POINTS = { w: 1100, h: 474 };   // GREETING_BOX / 2

function greetingImage(film, theme, sky) {
  const img = film.assets[`greeting-${theme}-${sky}`];
  if (!img) {
    throw new Error(`missing greeting render: ${theme}-${sky} — `
      + 'run Tools/render-greeting-preview.py');
  }
  return img;
}

/**
 * The card's own shadow and rim, from the app: a keyed lift under the plate and
 * a hairline that is darker inside the card and lighter outside it.
 */
function drawGreetingFrame(g, x, y, w, h, ink) {
  g.save();
  g.shadowColor = ink.shadow; g.shadowBlur = 54; g.shadowOffsetY = 20;
  fillRR(g, x, y, w, h, 26, '#FFFFFF');
  g.restore();
  g.save();
  strokeRR(g, x + 0.5, y + 0.5, w - 1, h - 1, 26, ink.hairline, 1);
  g.restore();
}

/** One real still, drawn at its own aspect, at the film's scale. */
function drawGreetingSky(g, { film, theme, sky, x, y, w, h, alpha = 1, tint = null }) {
  const img = greetingImage(film, theme, sky);
  g.save();
  g.globalAlpha = alpha;
  g.beginPath(); rr(g, x, y, w, h, 26); g.clip();
  const s = (w * 2) / GREETING_BOX.w;
  g.drawImage(img,
    x - GREETING_BOX.x * s, y - GREETING_BOX.y * s,
    img.width * s, img.height * s);
  if (tint) { g.fillStyle = tint; g.fillRect(x, y, w, h); }
  g.restore();
}

/**
 * One instant of the sheet: a real still, with the film's own "the page is
 * still arriving" wash over it. `wash` is the only thing the film adds — the
 * card, the sky and every reading in it are the app's drawing.
 */
export function drawGreetingCard(g, {
  film, x, y, w = GREETING_POINTS.w, h = GREETING_POINTS.h,
  theme = 'light', sky = 'sun', ink, alpha = 1, wash = 0, layer = 1,
}) {
  g.save();
  g.globalAlpha = alpha;
  if (layer >= 2) drawGreetingFrame(g, x, y, w, h, ink);
  drawGreetingSky(g, { film, theme, sky, x, y, w, h });
  if (wash > 0) {
    g.save();
    g.beginPath(); rr(g, x, y, w, h, 26); g.clip();
    g.fillStyle = ink.canvas;
    g.globalAlpha = alpha * wash;
    g.fillRect(x, y, w, h);
    g.restore();
  }
  g.restore();
}

// ==================================================== 3 · the greeting card
/**
 * One card, one day. The camera never cuts: it pushes until the greeting runs
 * past the right edge, and under it the sheet crossfades between the four skies
 * the app itself rendered. Nothing here is redrawn — the card, its type, its
 * six-day strip and its sill are `light-1100-*.png`.
 */
export function scene3(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  const arrive = ramp(t, 0, 1.4, 'enter');
  const push = ramp(t, 3.6, 9.6, 'slow');

  // The day, walked: clear → cloud → night. Each hand-off is a long crossfade,
  // so the camera move and the sky move together and neither of them cuts.
  // The walk only ever moves forward — a day does not run backwards, and a sky
  // that reappears after it has left reads as a loop rather than as a day.
  const keys = ['sun', 'cloud', 'night'];
  const walk = ramp(t, 1.6, 12.6, 'slow');
  const idx = Math.min(keys.length - 1, Math.floor(walk * keys.length));
  const sky = keys[idx];
  const next = keys[Math.min(keys.length - 1, idx + 1)];
  const mix = clamp(walk * (keys.length - 1) - idx);

  // The push has to earn the frame: the sheet is 3.2:1, so a shot that only
  // *contains* it is all letterbox. Past 1.25 the card's own corner leaves the
  // edge and the typing band fills the width, which is the shot's subject.
  const scale = lerp(0.88, 1.0, arrive) * lerp(1.0, 1.32, push);
  const cx = W / 2 + (1 - arrive) * -360;
  const cy = H / 2 + 130 - arrive * 130 - push * 118;

  const cw = GREETING_POINTS.w, ch = GREETING_POINTS.h;
  const x = cx - cw / 2, y = cy - ch / 2;

  withCamera(g, { scale, x: cx, y: cy, dy: -push * 4 }, (c) => {
    c.globalAlpha = arrive;
    if (mix > 0.001 && next !== sky) {
      // Two real stills, one on top of the other: the transition is a dissolve
      // between skies the app drew, not a redraw of either.
      drawGreetingCard(c, { film: env, x, y, sky, ink, layer: 2 });
      drawGreetingCard(c, { film: env, x, y, sky: next, ink,
                            alpha: mix, layer: 0 });
    } else {
      drawGreetingCard(c, { film: env, x, y, sky, ink, layer: 2 });
    }
    c.globalAlpha = 1;
  });

  const copyIn = ramp(t, 10.2, 11.2, 'enter');
  const copyOut = ramp(t, 14.8, 15.8, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '问候是一扇窗。',
                body: '天空由太阳高度角决定，不是钟点。这一整天，都是应用自己渲染的。',
                x: 120, y: H / 2 - 130, width: 520, ink });
  g.globalAlpha = 1;
}

// ================================================ 4 · the card's glass rain
/**
 * Held close on the upper-left of the **real** rain plate. The drops this shot
 * is about are still the film's — a still cannot carry the life cycle of a drop
 * — but they fall on the app's own sky, over the app's own type, at the app's
 * own scale. The gesture: a drop lands, a drop slides, a pointer sweeps the
 * sheet, a click merges them.
 */
export function scene4(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  // The push: from the whole sheet to the greeting's optical band. It has to
  // land hard enough that the shot is a close-up on the type the drops fall
  // across, and not a picture of a card.
  //
  // The one thing it must *not* do is wait. Adjacent scenes cross-dissolve, so
  // the first half second of this scene is still carrying scene 3's night sky;
  // a push that only starts at 0.6 s lets that night sit in an otherwise wet
  // shot and reads as a dropped frame. Rain is on screen from t = 0.
  const push = ramp(t, 0, 7.2, 'slow');
  const scale = lerp(1.06, 1.72, push);
  const cw = GREETING_POINTS.w, ch = GREETING_POINTS.h;
  // Aims at the greeting's block, a little left of centre, and stays there. The
  // card is 3.2:1, so the shot is always wider than the frame — the corner is
  // allowed to leave, the descender is not.
  const cx = W / 2 - lerp(60, 150, push);
  const cy = H / 2 + lerp(40, 120, push);
  const x = cx - cw / 2, y = cy - ch / 2;

  const drops = [];
  const landT = 3.4;
  drops.push({ x: cx - 240, y: cy - 150, r: 9,
               grow: ramp(t, landT, landT + 0.12, 'snap'),
               ripple: t < landT ? -1 : ramp(t, landT, landT + 0.26, 'slow'),
               trail: 0, life: t > landT ? 1 : 0 });
  const slideT = 5.4;
  const slideP = ramp(t, slideT, 9.4, 'slow');
  if (t > slideT) {
    const d = drops[0];
    d.x += Math.sin(slideP * 6) * 12 + slideP * 40;
    d.y += slideP * 116;
    d.trail = clamp(slideP * 1.4) * 88;
    d.r = 9 + slideP * 1.6;
  }
  for (let i = 0; i < 26; i++) {
    const seed = hash(i * 13.7);
    const life = gate(t, 0.9 + seed * 2.6, 1.5 + seed * 2.6, 12.4, 13.2);
    drops.push({ x: cx + (seed - 0.5) * 1100, y: cy - 380 + hash(i * 4.4) * 760,
                 r: 3 + hash(i * 8.8) * 5, grow: 1, ripple: -1, trail: 0, life });
  }

  const pointerT = 7.8, clickT = 9.8;
  const sweep = ramp(t, pointerT, pointerT + 2.0, 'slow');
  const pointerX = cx + lerp(-820, 820, sweep);
  const pointerY = cy - 80 + Math.sin(sweep * 4) * 26;
  const press = pulse(t, clickT, 0.12, 0.3, 'snap');

  withCamera(g, { scale, x: cx, y: cy }, (c) => {
    drawGreetingCard(c, { film: env, x, y, sky: 'rain', ink, layer: 2 });
    // The drops are in front of the type — that is the whole point (§5.2, L5).
    WX_drawDroplets(c, { x, y, w: cw, h: ch, drops });
  });

  if (t > pointerT && t < clickT + 0.8) drawPointer(g, pointerX, pointerY, { press, r: 7 });

  const copyIn = ramp(t, 10.4, 11.2, 'enter');
  g.globalAlpha = copyIn;
  drawCopy(g, { title: '雨在字前面。',
                body: '字是场景的一部分：雨滴从字面划过，倒映着同一片天空。',
                x: 120, y: H - 250, width: 560, ink });
  g.globalAlpha = 1;
}

// ============================================================ the island
/**
 * The island, composited from the **real** renders.
 *
 * `Tools/render-island-preview.py` draws `NotchIslandView` out of the production
 * Swift — the agent marks, the session rows, the 30-day histogram, the allowance
 * arcs — so these images are the app's own drawing, not a redrawing of it. The
 * film supplies the camera, the transitions, and the notch band they hang from.
 *
 * The previews are black-on-white plates; `Tools/promo/key-island.py` keys them
 * to transparent silhouettes first, which is what lets the island sit on the
 * film's canvas and melt into a notch drawn at the film's own scale.
 */
/**
 * The island's own size in **film points**, measured off the keyed renders
 * (`Tools/promo/key-island.py` prints them). The previews are captured at 2x, and
 * the notch is 186pt wide, so the collapsed island's 626px box is 313pt of
 * island: 186 of notch plus a 52pt wing each side, plus the 6pt flares. These
 * numbers are what let the film draw the island 1:1 with the app's geometry.
 */
const ISLAND_POINTS = {
  collapsed: { w: 313, h: 46 },
  alert: { w: 409, h: 100 },
  expanded: { w: 529, h: 338 },
};

function islandImage(film, mode, theme) {
  const img = film.assets[`island-${mode}-${theme}`];
  if (!img) {
    throw new Error(`missing island render: island-${mode}-${theme} — `
      + 'run Tools/render-island-preview.py then Tools/promo/key-island.py');
  }
  return img;
}

/**
 * The screen's top edge with the island on it. `notch` is the hardware cut-out
 * in film points; the island's own image already carries its notch-shaped top
 * edge and its rim, so this only draws the bezel band behind it.
 */
export function drawIsland(g, {
  mode, t, film, theme = 'light', x = W / 2, notch = { w: 186, h: 46 },
  scale = 1, sweep = -1, dim = 1,
}) {
  g.save();
  g.globalAlpha = dim;

  // The hardware cut-out behind the island: exactly the notch, exactly its
  // height. The island's own image carries the shape's flares and bottom
  // corners, so this must not be wider or taller than the cut-out — a full-width
  // band turns the shot's top edge into a black slab and reads as a bogus bezel.
  const bandH = notch.h * scale;
  g.fillStyle = '#000000';
  g.fillRect(x - (notch.w / 2) * scale, 0, notch.w * scale, bandH);

  const img = islandImage(film, mode, theme);
  const size = ISLAND_POINTS[mode];
  const w = size.w * scale, h = size.h * scale;
  const py = notch.h * scale;
  const px = x - w / 2;

  g.drawImage(img, px, py, w, h);

  // The alert's one-shot identity-colour glint along the island's lower edge
  // (design §2: one pass, then never again).
  if (sweep >= 0 && sweep <= 1) {
    const sw = 300 * scale;
    const sx = px + w * sweep - sw / 2;
    const sy = py + h - 3 * scale;
    const gr = g.createLinearGradient(sx, 0, sx + sw, 0);
    gr.addColorStop(0, 'rgba(232,132,94,0)');
    gr.addColorStop(0.5, 'rgba(232,132,94,0.6)');
    gr.addColorStop(1, 'rgba(232,132,94,0)');
    g.fillStyle = gr;
    g.fillRect(sx, sy, sw, 3 * scale);
  }
  g.restore();
  return { w, h };
}

// -------------------------------------------------------------- 5 · collapsed
export function scene5(g, t, env) {
  const ink = INK.light;

  // A pull-out from the card: the card leaves the frame and the camera leans in
  // on the top edge (prompt.md §4 scene 5). The island is the real render, so
  // the zoom is what makes a 46pt strip read at 1080.
  const push = ramp(t, 0.6, 3.0, 'slow');
  const cardGone = ramp(t, 0.0, 1.0, 'slow');

  const bg = g.createLinearGradient(0, 0, 0, H);
  bg.addColorStop(0, ink.canvas);
  bg.addColorStop(1, '#E3EAF2');
  g.fillStyle = bg; g.fillRect(0, 0, W, H);

  if (cardGone < 0.999) {
    g.save();
    g.globalAlpha = 1 - cardGone;
    g.translate(0, cardGone * 560);
    drawGreetingCard(g, { film: env, x: W / 2 - GREETING_POINTS.w / 2, y: H * 0.30 - 40,
                          sky: 'cloud', ink });
    g.restore();
  }

  // Scale enough to read the count and the day's total, and no further: the
  // island is a 46pt strip, and past ~1.8x it stops reading as a menu bar and
  // starts reading as a wall. The frame keeps the strip plus the screen under it.
  const zoom = lerp(1.0, 1.8, push);
  withCamera(g, { scale: zoom, x: W / 2, y: 0, dy: 120 }, (c) => {
    drawIsland(c, { mode: 'collapsed', t, film: env, theme: 'light',
                    scale: zoom, sweep: ramp(t, 3.4, 4.3, 'slow') });
    drawStatusItem(c, W - 44 - 155, 23, {
      icon: env.assets.statusIcon, down: '1.7K', up: '0.6K', tunneled: false, level: 82,
    });
  });

  const copyIn = ramp(t, 4.8, 5.6, 'enter');
  const copyOut = ramp(t, 7.8, 8.6, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '余光里就够了。',
                body: '左翼是谁在跑，右翼是今天烧了多少。够用，不必盯。',
                x: 150, y: H * 0.58, width: 560, ink });
  g.globalAlpha = 1;
}

// ------------------------------------------------------------------ 6 · alert
export function scene6(g, t, env) {
  const ink = INK.light;
  const bg = g.createLinearGradient(0, 0, 0, H);
  bg.addColorStop(0, ink.canvas); bg.addColorStop(1, '#E3EAF2');
  g.fillStyle = bg; g.fillRect(0, 0, W, H);

  // The alert grows out of the notch on the alert spring, which is deliberately
  // bouncier than the expand spring (design §1). On screen that is a vertical
  // reveal about the top edge plus one small whole-frame overshoot.
  const grow = ramp(t, 0.8, 2.0, 'snap');
  const collapse = ramp(t, 9.6, 10.4, 'slow');
  const alive = grow * (1 - collapse);
  const nudge = 1 + pulse(t, 0.8, 0.1, 0.35, 'snap') * 0.02;
  const zoom = 1.65 * nudge;

  withCamera(g, { scale: zoom, x: W / 2, y: 0, dy: 110 }, (c) => {
    c.save();
    c.beginPath();
    c.rect(0, 0, W, (46 + 100 * alive) * zoom);
    c.clip();
    drawIsland(c, { mode: 'alert', t, film: env, theme: 'light', scale: zoom,
                    sweep: t < 0.8 ? -1 : ramp(t, 1.0, 1.6, 'slow') });
    c.restore();
    drawStatusItem(c, W - 44 - 155, 23, {
      icon: env.assets.statusIcon, down: '1.7K', up: '0.6K', level: 82,
    });
  });

  const copyIn = ramp(t, 6.0, 7.0, 'enter');
  const copyOut = ramp(t, 9.4, 10.4, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '它跑完了，会自己说。',
                body: '交付了答案才提醒，不是「忙转闲」。点一下回到那个终端。',
                x: 150, y: H * 0.58, width: 620, ink });
  g.globalAlpha = 1;
}

// --------------------------------------------------------------- 7 · expanded
export function scene7(g, t, env) {
  const ink = INK.light;
  const bg = g.createLinearGradient(0, 0, 0, H);
  bg.addColorStop(0, ink.canvas); bg.addColorStop(1, '#E3EAF2');
  g.fillStyle = bg; g.fillRect(0, 0, W, H);

  // The expanded island is 394pt — the tallest surface in the film — so the push
  // stops where the whole silhouette fits with air below it (prompt.md §4 s7).
  const expand = ramp(t, 0.6, 2.0, 'snap');
  const zoom = 1 + 0.30 * expand;
  const islandH = ISLAND_POINTS.expanded.h;

  withCamera(g, {
    scale: zoom, x: W / 2, y: 0,
    dy: (H * 0.46) - (islandH * zoom * 0.5),
  }, (c) => {
    drawIsland(c, { mode: 'expanded', t, film: env, theme: 'light', scale: zoom });
  });

  const bandW = (W - Math.min(W - 80, ISLAND_POINTS.expanded.w * zoom)) / 2;
  const copyIn = ramp(t, 9.4, 10.4, 'enter');
  const copyOut = ramp(t, 11.6, 12.4, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '碰一下刘海。',
                body: '会话格、上下文油量、30 天直方图。滑一下就是任何一天。',
                x: Math.max(56, bandW - 500), y: H / 2 - 110,
                width: Math.max(300, bandW - 70), ink, titleSize: 54, bodySize: 19 });
  g.globalAlpha = 1;
}

// ================================================= 8/9 · the popup's scenes
/**
 * The popup, composited from the **real** render.
 *
 * `Tools/render-popup-preview.py` draws the production `PanelHeader`, session
 * cards and `UsagePanel` — 460pt wide at 2x — so this is the app's own popup,
 * not a redrawing of it. The film supplies the camera, the switcher popover and
 * the panel that opens from the VPN pill; those are interactions a still cannot
 * contain, so they are drawn over the real plate at its own scale.
 */
const POPUP_POINTS = { w: 460, h: 856 };

function popupImage(film, theme) {
  const img = film.assets[`popup-${theme}`];
  if (!img) {
    throw new Error('missing popup render — run Tools/render-popup-preview.py');
  }
  return img;
}

export function scene8(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  const islandOut = ramp(t, 0, 0.5, 'slow');
  if (islandOut < 1) {
    drawIsland(g, { mode: 'collapsed', t, film: env, theme: 'light', dim: 1 - islandOut });
  }

  const inA = ramp(t, 0.4, 1.6, 'enter');
  const push = ramp(t, 2.6, 4.4, 'slow');
  const scale = lerp(0.9, 1.0, inA) * lerp(1.0, 1.30, push);

  const px = W * 0.55, py = H / 2 + 20;
  const w = POPUP_POINTS.w * scale, h = POPUP_POINTS.h * scale;

  // Hover the CC chip, then open its switcher; the popover is 240pt of the real
  // `ModelSwitchList`, which a still cannot show.
  // Scene 8 is 7.4 s in the cut, so the whole beat sheet has to fit in it: the
  // popover opens, is read, the pick lands, the toast confirms. The list holds
  // from ~2.2 s to ~5.4 s — long enough to read six rows — and the pick happens
  // at 5.4 so the toast has the rest of the shot to itself.
  const open = ramp(t, 1.9, 2.2, 'snap');
  const pickT = 5.4;
  const picked = t > pickT;

  g.save();
  g.globalAlpha = inA;
  g.save();
  g.shadowColor = ink.shadow; g.shadowBlur = 48 * scale; g.shadowOffsetY = 18;
  fillRR(g, px - w / 2, py - h / 2, w, h, 22 * scale, ink.card);
  g.restore();
  g.drawImage(popupImage(env, 'light'), px - w / 2, py - h / 2, w, h);
  g.restore();

  // The switcher popover, under the first 143pt column.
  const popT = open * (1 - ramp(t, pickT, pickT + 0.3, 'slow'));
  if (popT > 0.01) {
    // The chip opens its list *below* itself (`arrowEdge: .bottom` in
    // `HeaderSwitchChip`), so the list hangs under the switcher row rather than
    // over the session tiles. Anchored to the CC chip's own box, with the
    // popover's little arrow pointing back up at it.
    const cw = (POPUP_POINTS.w - 2 * 12 - 2) / 3;
    const chipX = px - w / 2 + 12 * scale;
    const chipW = cw * scale;
    const ow = 232 * scale;
    const ox = chipX + 14 * scale;
    const oy = py - h / 2 + (12 + 86 + 8) * scale;
    const rows = [
      { header: 'Aibox' },
      { title: 'deepseek-v4-flash', active: !picked },
      { title: 'deepseek-v4-pro', active: picked },
      { title: 'glm-5.3-flash' },
      { header: 'Anthropic' },
      { title: 'claude-opus-4-6' },
    ];
    const oh = (18 + rows.reduce((a, r) => a + (r.header ? 22 : 24), 0) + 10) * scale;
    g.save();
    g.globalAlpha = popT;
    g.translate(0, (1 - popT) * -6);
    g.save();
    g.shadowColor = 'rgba(20,24,32,0.18)'; g.shadowBlur = 24; g.shadowOffsetY = 10;
    fillRR(g, ox, oy, ow, oh, 12 * scale, '#FFFFFF');
    g.restore();
    strokeRR(g, ox, oy, ow, oh, 12 * scale, ink.hair, 1);
    // The popover's anchor arrow, pointing up at the chip it came from.
    const ax = chipX + chipW / 2;
    g.save();
    g.fillStyle = '#FFFFFF';
    g.beginPath();
    g.moveTo(ax - 7 * scale, oy + 1);
    g.lineTo(ax + 7 * scale, oy + 1);
    g.lineTo(ax, oy - 8 * scale);
    g.closePath();
    g.fill();
    g.strokeStyle = ink.hair; g.lineWidth = 1;
    g.beginPath();
    g.moveTo(ax - 7 * scale, oy + 1);
    g.lineTo(ax, oy - 8 * scale);
    g.lineTo(ax + 7 * scale, oy + 1);
    g.stroke();
    g.restore();
    text(g, '切换 Claude Code', ox + 12 * scale, oy + 16 * scale,
         { size: 10 * scale, weight: 500, color: ink.faint });
    let ry = oy + 26 * scale;
    rows.forEach((r) => {
      if (r.header) {
        text(g, r.header, ox + 12 * scale, ry + 10 * scale,
             { size: 10 * scale, weight: 500, color: ink.faint });
        ry += 22 * scale;
      } else {
        const hot = r.active && picked;
        if (hot) fillRR(g, ox + 6 * scale, ry - 2 * scale, ow - 12 * scale, 20 * scale, 6 * scale,
                        'rgba(61,125,255,0.10)');
        text(g, hot ? '✓' : '', ox + 12 * scale, ry + 11 * scale,
             { size: 9 * scale, weight: 600, color: '#1D4FB8' });
        text(g, r.title, ox + 26 * scale, ry + 11 * scale,
             { size: 12 * scale, weight: hot ? 600 : 400, color: hot ? '#3D7DFF' : ink.body });
        ry += 24 * scale;
      }
    });
    g.restore();
  }

  // The feedback toast, which is what switching a model leaves behind.
  const toast = gate(t, pickT + 0.2, pickT + 0.5, pickT + 1.8, pickT + 2.2);
  if (toast > 0.01) {
    g.globalAlpha = toast;
    const msg = picked ? 'CC · Aibox / deepseek-v4-pro' : 'CC · Aibox / deepseek-v4-flash';
    const fw = measure(g, msg, { size: 11, weight: 600 }) + 26;
    fillRR(g, px - fw / 2, py + h / 2 - 34, fw, 22, 11, 'rgba(10,14,24,0.86)');
    text(g, msg, px, py + h / 2 - 20, { size: 11, weight: 600, color: '#FFFFFF', align: 'center' });
    g.globalAlpha = 1;
  }

  // The VPN node panel, opened on the status row's pill after the switcher closes.
  if (t > 8.6) {
    const a = ramp(t, 8.6, 8.9, 'snap');
    const lit = clamp((t - 9.0) / 1.0);
    g.globalAlpha = a;
    drawNodePanel(g, {
      x: px + w / 2 - 12 * scale - 240 * scale, y: py - h / 2 + 66 * scale,
      w: 240 * scale, ink, lit,
      nodes: [['日本 A01 · 带宽优化', 42, true], ['日本 A02 · 低倍率', 58, false],
              ['香港 B01 · 容灾', 76, false], ['新加坡 C01', 96, false]],
    });
    g.globalAlpha = 1;
  }

  const copyIn = ramp(t, 10.2, 11.0, 'enter');
  const copyOut = ramp(t, 12.6, 13.4, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '点一下，换了。',
                body: '三格是 CC / Codex / Cursor。激活写回各自的配置文件，互不覆盖。',
                x: 60, y: 150, width: Math.max(280, px - w / 2 - 110),
                ink, titleSize: 58, bodySize: 19 });
  g.globalAlpha = 1;
}

/** A node list with latencies: the panel the VPN pill opens. */
function drawNodePanel(g, { x, y, w, ink, nodes, lit }) {
  const s = w / 240;
  const h = 168 * s;
  g.save();
  g.shadowColor = 'rgba(20,24,32,0.18)'; g.shadowBlur = 24; g.shadowOffsetY = 10;
  fillRR(g, x, y, w, h, 12 * s, '#FFFFFF');
  g.restore();
  strokeRR(g, x, y, w, h, 12 * s, ink.hair, 1);
  text(g, '节点', x + 12 * s, y + 18 * s, { size: 10 * s, weight: 500, color: ink.faint });
  nodes.forEach(([name, ms, on], i) => {
    const ry = y + (30 + i * 30) * s;
    if (on) fillRR(g, x + 6 * s, ry - 2 * s, w - 12 * s, 26 * s, 8 * s, 'rgba(52,199,89,0.10)');
    g.globalAlpha *= (on || i <= lit * (nodes.length - 1)) ? 1 : 0.25;
    text(g, name, x + 14 * s, ry + 15 * s,
         { size: 11.5 * s, weight: on ? 600 : 400, color: on ? ink.title : ink.body });
    text(g, `${ms}ms`, x + w - 12 * s, ry + 15 * s,
         { size: 10.5 * s, weight: 600, color: ms < 60 ? '#34C759' : '#8E8E93', align: 'right' });
    g.globalAlpha = 1;
  });
}

export function scene9(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  // The popup is 856pt tall; the camera pans down it. The pan distance is what
  // the frame cannot hold at this zoom, so the shot ends on the usage panel and
  // never on the empty tail below it.
  // The popup is 460x856pt; at 1.15 that is 529x984, which the 1080 frame holds
  // whole. It sits left of centre so the terminal has somewhere to land, and it
  // is never allowed to hang off the edge — a panel sliding out of frame reads
  // as a mistake, not as a camera move.
  const scale = 1.15;
  const w = POPUP_POINTS.w * scale, h = POPUP_POINTS.h * scale;
  const px = W * 0.36;
  // Start at the panel's top, travel down by exactly what the frame cannot hold.
  const maxPan = Math.max(0, h - H + 48);
  const pan = ramp(t, 2.4, 4.2, 'slow') * maxPan;
  const top = -24 - pan;

  g.save();
  g.globalAlpha = ramp(t, 0.2, 1.0, 'enter');
  g.save();
  g.shadowColor = ink.shadow; g.shadowBlur = 48; g.shadowOffsetY = 18;
  fillRR(g, px - w / 2, top, w, h, 22 * scale, ink.card);
  g.restore();
  g.save();
  g.beginPath();
  rr(g, px - w / 2, top, w, h, 22 * scale);
  g.clip();
  g.drawImage(popupImage(env, 'light'), px - w / 2, top, w, h);
  g.restore();
  g.restore();

  // The terminal that a double-click on a session card opens, then folds back.
  const termA = gate(t, 5.4, 5.9, 7.8, 8.4);
  if (termA > 0.01) {
    const tw = 700, th = 280;
    const tx = W * 0.72, ty = H * 0.62;
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
    text(g, 'claudebar — claude — 120×32', tx, ty - th / 2 + 22,
         { size: 11, weight: 500, color: 'rgba(255,255,255,0.45)', align: 'center' });
    text(g, '$ claude --resume 4f3a…', tx - tw / 2 + 22, ty - th / 2 + 64,
         { size: 13, weight: 400, color: '#E8E8EA', mono: true });
    text(g, 'resumed in ~/Project/ClaudeBar', tx - tw / 2 + 22, ty - th / 2 + 96,
         { size: 13, weight: 400, color: '#5EEAD4', mono: true,
           opacity: ramp(t, 5.7, 6.5, 'slow') });
    text(g, '● 3 个工具在跑 · 上下文 135k / 500k', tx - tw / 2 + 22, ty - th / 2 + 132,
         { size: 11, weight: 400, color: 'rgba(255,255,255,0.45)', mono: true });
    g.restore();
  }

  const copyIn = ramp(t, 0.4, 1.4, 'enter');
  const copyOut = ramp(t, 8.6, 9.6, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  // The caption sits in the right-hand column the popup has vacated, on the
  // popup's own centre line — not floating at some unrelated y.
  drawCopy(g, { title: '接着刚才那次会话。',
                body: '目录 | 标题、上下文、当前工具、心跳、内存。双击就在终端里接上。',
                x: W * 0.68, y: (H - 44 - 92) / 2, width: 430, ink,
                titleSize: 50, bodySize: 18 });
  g.globalAlpha = 1;
}

// ========================================================== 10 · main window
/**
 * The main window, composited from the **real** renders.
 *
 * `Tools/render-mainwindow-preview.py` draws the production pages — the greeting
 * sheet with its Metal sky, the resource strip, the session tiles, the heatmap
 * and the three charts, the VPN node list, the traffic inspector — out of the
 * production Swift. The film supplies the camera and the page changes; the pages
 * themselves are the app's own drawing.
 */
const WINDOW_POINTS = {
  // Preview pixels / 2, so these are the app's own point sizes.
  overview: { w: 1120, h: 1697 },
  sessions: { w: 1120, h: 762 },
  usage: { w: 1120, h: 1553 },
  vpn: { w: 1120, h: 1180 },
  traffic: { w: 1120, h: 720 },
};

function windowImage(film, page, theme) {
  const img = film.assets[`window-${page}-${theme}`];
  if (!img) {
    throw new Error(`missing main-window render: ${page}-${theme} — `
      + 'run Tools/render-mainwindow-preview.py');
  }
  return img;
}

/**
 * Draw one window page inside a window frame the film draws itself.
 *
 * The page renders are page-only (the preview tool captures a page, not a
 * window), so the chrome — traffic lights, the product, the seven tabs, the
 * running count, ⌘K — is drawn here to the app's own bar: 54pt tall, tabs at
 * 13pt rounded, the active one on a 10% accent wash. The page body then scrolls
 * under it, which is what a window with a tall page actually does.
 */
export function drawMainWindow(g, {
  x, y, w, h, film, page, theme = 'light', ink, scroll = 0, cmdK = 0,
  reveal = 1, tab = null,
}) {
  const img = windowImage(film, page, theme);
  const size = WINDOW_POINTS[page];
  const s = w / size.w;
  const bodyH = h - 54 * s;

  // Window plate.
  g.save();
  g.shadowColor = ink.shadow; g.shadowBlur = 60; g.shadowOffsetY = 24;
  fillRR(g, x, y, w, h, 14, ink.canvas);
  g.restore();

  // Page body, scrolled, clipped to everything below the bar.
  g.save();
  g.beginPath();
  rr(g, x, y, w, h, 14);
  g.clip();
  g.drawImage(img, x, y + 54 * s - scroll * s, w, size.h * s);
  g.restore();

  // The bar, over the body's top edge.
  g.save();
  g.beginPath();
  rr(g, x, y, w, h, 14); g.clip();
  g.fillStyle = ink.canvas;
  g.fillRect(x, y, w, 54 * s);
  g.fillStyle = ink.hair;
  g.fillRect(x, y + 54 * s, w, 1);

  [[0, '#FF5F57'], [1, '#FEBC2E'], [2, '#28C840']].forEach(([i, c]) => {
    g.fillStyle = c;
    g.beginPath();
    g.arc(x + 26 * s + i * 20 * s, y + 28 * s, 6.5 * s, 0, Math.PI * 2);
    g.fill();
  });
  // The product mark, out of the same asset table the rest of the film uses.
  const mark = film && film.assets ? film.assets.icon : null;
  if (mark) g.drawImage(mark, x + 108 * s, y + 17 * s, 22 * s, 22 * s);
  text(g, 'ClaudeBar', x + 138 * s, y + 34 * s,
       { size: 16 * s, weight: 600, family: 'rounded', color: ink.title });

  const tabs = ['概览', '会话', '模型', '用量', '流量', 'VPN', '设置'];
  const activeName = tab ?? { overview: '概览', sessions: '会话', usage: '用量',
                              vpn: 'VPN', traffic: '流量' }[page];
  let tx = x + 400 * s;
  tabs.forEach((tb) => {
    const active = tb === activeName;
    const tw = measure(g, tb, { size: 13 * s, weight: 500, family: 'rounded' }) + 34 * s;
    if (active) fillRR(g, tx, y + 16 * s, tw, 26 * s, 13 * s, 'rgba(61,125,255,0.10)');
    text(g, tb, tx + tw / 2, y + 33 * s,
         { size: 13 * s, weight: 500, family: 'rounded',
           color: active ? '#1D4FB8' : ink.body, align: 'center' });
    tx += tw + 6 * s;
  });
  fillRR(g, x + w - 150 * s, y + 16 * s, 74 * s, 26 * s, 13 * s, 'rgba(0,0,0,0.04)');
  text(g, '1 运行中', x + w - 113 * s, y + 33 * s,
       { size: 11 * s, weight: 500, color: ink.body, align: 'center' });
  text(g, '⌘K', x + w - 46 * s, y + 33 * s,
       { size: 11 * s, weight: 500, color: ink.faint, align: 'center' });
  g.restore();

  strokeRR(g, x, y, w, h, 14, ink.hair, 1);
}

export function scene10(g, t, env) {
  const ink = INK.light;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  // Captions live in their own band, never on top of a surface. The window is
  // the subject of every shot in this scene; a caption laid over it is just the
  // film covering the thing it is trying to show.
  const BAND = 168;

  const pull = ramp(t, 0, 1.2, 'slow');
  const sc = lerp(1.06, 0.90, pull);

  const cuts = [[0.0, 'overview'], [3.2, 'sessions'], [6.4, 'usage'], [9.6, 'vpn']];
  let page = 'overview', local = t;
  for (const [at, pg] of cuts) if (t >= at) { page = pg; local = t - at; }
  const enter = ramp(local, 0, 0.45, 'enter');

  // The window is sized from the page it is showing, so nothing is ever cut
  // mid-card. A page shorter than the box just leaves the box shorter — the
  // window is a window, not a crop.
  const w = 1180;
  const natural = WINDOW_POINTS[page].h * (w / WINDOW_POINTS[page].w);
  const h = Math.min(natural, H - BAND - 96);

  withCamera(g, { scale: sc, x: W / 2, y: (H - BAND) / 2 }, (c) => {
    c.save();
    c.globalAlpha = enter;
    drawMainWindow(c, {
      x: W / 2 - w / 2, y: (H - BAND) / 2 - h / 2, w, h, film: env, page, theme: 'light', ink,
      scroll: 0,
    });
    c.restore();
  });

  const names = {
    overview: ['一块冰面。', '从 CPU 到能源流向。颜色只出现在图表里。'],
    sessions: ['三条产品线，一页。', 'Claude Code、Cursor、Codex 各自成频道，含子 Agent。'],
    usage: ['只统计模型 Token。', '日 / 月 / 年 / 全部，热力与构成，花费按刊例价估算。'],
    vpn: ['隧道也是这里管的。', '订阅、节点、测延迟、系统代理或 TUN。'],
  }[page];
  const copyIn = ramp(local, 0.15, 0.75, 'enter');
  g.globalAlpha = copyIn * 0.98;
  drawCopy(g, { title: names[0], body: names[1],
                x: 96, y: H - BAND + 34, width: 760, ink, titleSize: 46, bodySize: 17 });
  g.globalAlpha = 1;

  // ⌘K rises on the last beat, in the band, next to the caption.
  const cmdK = page === 'vpn' ? ramp(local, 1.6, 1.9, 'snap') : 0;
  if (cmdK > 0) {
    const pw = 560, ph = 268;
    const px = W - 96 - pw, py = H - BAND + 24 + (1 - cmdK) * 26;
    g.save();
    g.globalAlpha = cmdK;
    g.save();
    g.shadowColor = 'rgba(20,24,32,0.22)'; g.shadowBlur = 40; g.shadowOffsetY = 16;
    fillRR(g, px, py, pw, ph, 16, '#FFFFFF');
    g.restore();
    strokeRR(g, px, py, pw, ph, 16, ink.hair, 1);
    text(g, '⌘K', px + 22, py + 32, { size: 12, weight: 600, color: ink.faint });
    text(g, '跳页面、会话或模型', px + 56, py + 32, { size: 13, weight: 400, color: ink.body });
    g.fillStyle = ink.hair; g.fillRect(px, py + 48, pw, 1);
    [['概览', '页面'], ['修 CI 红', '会话'], ['deepseek-v4-pro', '模型'],
     ['VPN · 日本 A01', '节点']].forEach(([nm, kind], i) => {
      const iy = py + 56 + i * 36;
      if (i === 2) fillRR(g, px + 8, iy, pw - 16, 30, 10, 'rgba(61,125,255,0.10)');
      text(g, nm, px + 26, iy + 21, { size: 13, weight: i === 2 ? 600 : 400, color: ink.title });
      text(g, kind, px + pw - 26, iy + 21,
           { size: 11, weight: 400, color: ink.faint, align: 'right' });
    });
    g.restore();
  }
}

// ============================================================= 11 · traffic
export function scene11(g, t, env) {
  const ink = INK.dark;
  g.fillStyle = ink.canvas; g.fillRect(0, 0, W, H);

  const wipe = t < 0.5 ? 1 - ramp(t, 0, 0.5, 'wipe') : 0;
  if (wipe > 0) { g.fillStyle = '#070709'; g.fillRect(0, 0, W, H); }

  const inA = ramp(t, 0.3, 1.2, 'enter');
  const sc = lerp(0.94, 1.0, inA);

  // The traffic page is the one surface that is its own window in the app (it is
  // a dark inspector), so the film shows it at its own proportions. The caption
  // gets the band above it — the inspector runs nearly the full height, so a
  // caption at the bottom would be sitting on the log it is describing.
  const BAND = 150;
  const w = 1240, h = 676;
  const cy = BAND + (H - BAND) / 2;
  withCamera(g, { scale: sc, x: W / 2, y: cy }, (c) => {
    c.save();
    c.globalAlpha = inA;
    drawWindowPage(c, { x: W / 2 - w / 2, y: cy - h / 2, w, h, film: env, ink });
    c.restore();
  });

  const copyIn = ramp(t, 5.6, 6.4, 'enter');
  const copyOut = ramp(t, 7.2, 7.8, 'slow');
  g.globalAlpha = copyIn * (1 - copyOut);
  drawCopy(g, { title: '留在本机。', body: '对话、工具调用、图片和原始报文。代理只转发到你自己的上游。',
                x: 96, y: 44, width: 720, ink, titleSize: 44, bodySize: 17 });
  g.globalAlpha = 1;
}

/** The traffic inspector, drawn as its own dark window around the real render. */
function drawWindowPage(g, { x, y, w, h, film, ink }) {
  const img = windowImage(film, 'traffic', 'dark');
  const size = WINDOW_POINTS.traffic;
  const scale = w / size.w;
  g.save();
  g.shadowColor = 'rgba(0,0,0,0.5)'; g.shadowBlur = 60; g.shadowOffsetY = 24;
  fillRR(g, x, y, w, h, 14, '#0E1013');
  g.restore();
  strokeRR(g, x, y, w, h, 14, 'rgba(255,255,255,0.08)', 1);
  g.save();
  g.beginPath(); rr(g, x, y, w, h, 14); g.clip();
  g.drawImage(img, x, y, w, size.h * scale);
  g.restore();
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
