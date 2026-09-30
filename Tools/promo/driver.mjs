// ClaudeBar promo film — driver.
//
// Owns the timeline (which scene, at what local time), loads the assets the
// scenes draw with, walks t at 1/30 s, captures each frame through Chrome, and
// then hands the PNG sequence to ffmpeg.
//
//   node driver.mjs --frames            render the PNG sequence
//   node driver.mjs --encode            encode mp4 + gif from the sequence
//   node driver.mjs                     both
//   node driver.mjs --only 2 --preview  a contact sheet of one scene, for checking

import { createRequire } from 'node:module';
const require = createRequire(new URL('../../.build/promo/package.json', import.meta.url));
const { chromium } = require('playwright-core');
import { readFileSync, mkdirSync, existsSync, readdirSync, unlinkSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { W, H, FPS } from './film.mjs';
import { pageSource as page_source } from './page.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');
const BUILD = join(ROOT, '.build/promo');
const FRAMES = join(BUILD, 'frames');

// ---------------------------------------------------------------- timeline
// prompt.md §4, in order. `dur` is scene-local; the driver adds the head start.
export const TIMELINE = [
  { n: 1, id: 'weather', dur: 10, title: '天气，是工作台的第一眼。', subtitle: '天空、问候、天气与今日读数，同在一张卡片。' },
  { n: 2, id: 'popup', dur: 12, title: '展开，\n就是全局。', subtitle: '从一眼概览，到每条会话。' },
  { n: 3, id: 'island', dur: 11, title: '把进度，留在余光里。', subtitle: '灵动岛：常驻状态 → 完成提醒 → 展开详情。' },
  { n: 4, id: 'desktop', dur: 13, title: '从顶栏，走进你的桌面。', subtitle: '原生主窗口：天气、系统负载、能源流向与会话。' },
  { n: 5, id: 'workspace', dur: 12, title: '每一层设计，都装着真实的工作。', subtitle: '会话、用量、流量，各自展开。' },
  { n: 6, id: 'closing', dur: 8, title: '一套工作台，三种打开方式。', subtitle: '天气卡片 · 菜单栏 popup · 灵动岛 · 桌面主窗口' },
];
// Scenes use seconds directly; no hidden second time base or overlapping cuts.
export const TOTAL_SECONDS = TIMELINE.reduce((sum, s) => sum + s.dur, 0);
export const TOTAL_FRAMES = Math.round(TOTAL_SECONDS * FPS);
export function at(t) {
  let start = 0;
  for (let i = 0; i < TIMELINE.length; i++) {
    const scene = TIMELINE[i];
    if (t < start + scene.dur || i === TIMELINE.length - 1)
      return { scene, local: Math.max(0, t - start), index: i };
    start += scene.dur;
  }
}

// ---------------------------------------------------------------- assets
const ASSET_FILES = {
  icon: ['Sources/AppIcon-1024.png', 'image/png'],
};

/**
 * The surfaces the film composites are the **real renders** — the app's own
 * drawing, produced by the preview tools out of the production Swift:
 *
 *   .build/island-preview/     Tools/render-island-preview.py
 *   .build/popup-preview/      Tools/render-popup-preview.py
 *   .build/mainwindow-preview/ Tools/render-mainwindow-preview.py
 *   .build/greeting-preview/   Tools/render-greeting-preview.py
 *
 * Missing ones are a hard failure rather than a silent fallback: a film that
 * quietly substitutes a placeholder is exactly the failure this pipeline exists
 * to prevent (prompt.md §5).
 */
const SURFACE_FILES = [
  ...['collapsed', 'alert', 'expanded'].map(state => [
    `island-${state}-light`, `.build/promo/assets/island-${state}-light.png`,
  ]),
  ['popup-light', '.build/popup-preview/popup-light.png'],
  ...['overview', 'sessions', 'usage'].map(page => [
    `window-${page}-light`, `.build/mainwindow-preview/${page}-light.png`,
  ]),
  ['window-traffic-dark', '.build/mainwindow-preview/traffic-dark.png'],
  ...['sun', 'cloud', 'rain', 'night'].map(sky => [
    `greeting-light-${sky}`, `.build/greeting-preview/light-1100-${sky}.png`,
  ]),
];

function loadAssets() {
  const out = {};
  for (const [key, [rel, mime]] of Object.entries(ASSET_FILES)) {
    const p = join(ROOT, rel);
    if (!existsSync(p)) { console.error(`  ! missing asset ${rel}`); continue; }
    out[key] = `data:${mime};base64,${readFileSync(p).toString('base64')}`;
  }
  const missing = [];
  for (const [key, rel] of SURFACE_FILES) {
    const p = join(ROOT, rel);
    if (!existsSync(p)) { missing.push(rel); continue; }
    out[key] = `data:image/png;base64,${readFileSync(p).toString('base64')}`;
  }
  if (missing.length) {
    console.error('\n  missing surface renders — the film composites the real ones:\n'
      + missing.map((m) => `    ${m}`).join('\n')
      + '\n  run: python3 Tools/render-island-preview.py && python3 Tools/render-popup-preview.py'
      + '\n       python3 Tools/render-mainwindow-preview.py && python3 Tools/render-greeting-preview.py'
      + '\n       python3 Tools/promo/key-island.py\n');
    process.exit(1);
  }
  return out;
}

// ---------------------------------------------------------------- page
/**
 * The page contains the CSS 3D scene and its assets. draw(t) determines the
 * layout and transforms directly from time, allowing deterministic seeking.
 */
// The page source lives in page.mjs so it can be syntax-checked and its
// top-level collisions reported without launching a browser.
const pageSource = () => page_source({
  here: HERE, width: W, height: H, timeline: TIMELINE,
});

// ---------------------------------------------------------------- capture
async function capture(argv) {
  const only = argv.includes('--only') ? Number(argv[argv.indexOf('--only') + 1]) : null;
  const preview = argv.includes('--preview');
  const storyboard = argv.includes('--storyboard');
  const rangeArg = argv.includes('--range') ? argv[argv.indexOf('--range') + 1] : null;
  const ranges = rangeArg?.split(',').map(value => value.split(':').map(Number));
  if (ranges?.some(([a, b]) => !Number.isFinite(a) || !Number.isFinite(b) || a < 0 || b <= a || b > TOTAL_SECONDS))
    throw new Error('Use --range start:end[,start:end], within the film duration');
  mkdirSync(FRAMES, { recursive: true });

  const browser = await chromium.launch({
    channel: 'chrome', headless: true,
    args: ['--hide-scrollbars', '--disable-lcd-text', '--force-color-profile=srgb'],
  });
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  await page.setContent(pageSource());
  // Decode every asset before the first draw: drawImage throws on an <img> that
  // has not finished loading, and a half-loaded mark is exactly the kind of
  // failure that would only show up on a slow machine.
  await page.evaluate(async (a) => {
    const decoded = {};
    await Promise.all(Object.entries(a).map(([key, src]) => new Promise((res, reject) => {
      const img = new Image();
      img.onload = () => { decoded[key] = img; res(); };
      img.onerror = () => reject(new Error('asset failed to decode: ' + key));
      img.src = src;
    })));
    await window.setEnv(decoded);
  }, loadAssets());

  if (argv.includes('--motion-check')) {
    for (const time of [5, 16, 29, 39, 52, 64]) {
      await page.evaluate(t => window.draw(t), time);
      const first = await page.screenshot();
      const originalStyles = await page.locator('#film-stage').evaluate(el => el.innerHTML);
      const planes = await page.locator('#space .plane').evaluateAll(elements => elements
        .filter(el => getComputedStyle(el).display !== 'none' && Number(getComputedStyle(el).opacity) > .15)
        .map(el => ({ matrix: getComputedStyle(el).transform, bounds: el.getBoundingClientRect().toJSON() })));
      if (!planes.length || !planes.some(p => p.matrix.startsWith('matrix3d(')))
        throw new Error(`No actual perspective plane at ${time}`);
      await page.evaluate(t => window.draw(t), time + .35);
      const next = await page.screenshot();
      if (time < 63 && first.equals(next)) throw new Error(`Static motion sample at ${time}`);
      await page.evaluate(t => window.draw(t), time);
      const repeatStyles = await page.locator('#film-stage').evaluate(el => el.innerHTML);
      if (originalStyles !== repeatStyles) throw new Error(`History-dependent frame at ${time}`);
      console.log(`motion ${time}s: 3D matrix, frame displacement and deterministic rewind OK`);
    }
    await browser.close(); return [];
  }
  const shots = [];
  if (storyboard) {
    const dir = join(BUILD, 'storyboard'); mkdirSync(dir, { recursive: true });
    let start = 0;
    for (const scene of TIMELINE) {
      for (const [name, local] of [['enter', 0], ['early', scene.dur * .22], ['hold', scene.dur * .5], ['late', scene.dur * .78], ['end', scene.dur - 1 / FPS]]) {
        await page.evaluate(t => window.draw(t), start + local);
        await page.screenshot({ path: join(dir, `${scene.id}-${name}.png`) });
      }
      start += scene.dur;
    }
    for (const [name, time] of [['poster', 5], ['overview', 37], ['sessions', 48], ['usage', 52]]) {
      await page.evaluate(t => window.draw(t), time);
      await page.screenshot({ path: join(ROOT, `docs/promo/${name}.png`) });
    }
    await browser.close(); console.log(`Storyboard: ${dir}`); return [];
  }
  if (only) {
    const s = TIMELINE.find((x) => x.n === only);
    // The scene's own head start. `draw()` takes film time, so a preview that
    // passed scene-local time would silently render the *previous* scene.
    const offset = TIMELINE.slice(0, TIMELINE.indexOf(s))
      .reduce((a, x) => a + x.dur, 0);
    const n = preview ? 12 : Math.round(s.dur * FPS);
    for (let i = 0; i < n; i++) {
      const local = preview ? (i / (n - 1)) * (s.dur - 1 / FPS) : i / FPS;
      await page.evaluate((t) => window.draw(t), offset + local);
      const dir = preview ? join(BUILD, 'preview') : FRAMES;
      mkdirSync(dir, { recursive: true });
      const file = join(dir, `s${String(s.n).padStart(2, '0')}_${String(i).padStart(4, '0')}.png`);
      await page.screenshot({ path: file, clip: { x: 0, y: 0, width: W, height: H } });
      shots.push(file);
    }
    await browser.close();
    console.log(`${preview ? 'preview' : 'scene'} ${only}: ${shots.length} frames -> ${shots[0]}`);
    return shots;
  }

  // Clear the sequence first. ffmpeg globs `f%05d.png`, so a shorter cut left in
  // the same directory re-encodes the *old* longer film — the frames past the
  // new total are still on disk and still match the pattern. Clearing is what
  // makes a re-time actually land.
  for (const f of readdirSync(FRAMES)) {
    if (!ranges && /^f\d{5}\.png$/.test(f)) unlinkSync(join(FRAMES, f));
  }

  const total = TOTAL_FRAMES;
  const t0 = Date.now();
  for (let i = 0; i < total; i++) {
    const t = i / FPS;
    if (ranges && !ranges.some(([a, b]) => t >= a && t < b)) continue;
    await page.evaluate((tt) => window.draw(tt), t);
    const file = join(FRAMES, `f${String(i).padStart(5, '0')}.png`);
    await page.screenshot({ path: file });
    if (i % 90 === 0) {
      const rate = (Date.now() - t0) / Math.max(1, i + 1);
      process.stdout.write(`\r  frame ${i}/${total}  ${(rate).toFixed(0)} ms/frame  ` +
        `eta ${(((total - i) * rate) / 1000 / 60).toFixed(1)} min   `);
    }
  }
  await browser.close();
  console.log(`\n  ${total} frames -> ${FRAMES}`);
  return [];
}

// ---------------------------------------------------------------- encode
function ffmpeg(args) {
  return execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args],
                      { stdio: ['ignore', 'inherit', 'inherit'] });
}

function encode() {
  const out = join(ROOT, 'docs/promo');
  mkdirSync(out, { recursive: true });
  const mp4 = join(out, 'claudebar.mp4');
  const gif = join(out, 'claudebar.gif');
  const frameNames = readdirSync(FRAMES).filter(f => /^f\d{5}\.png$/.test(f)).sort();
  if (frameNames.length !== TOTAL_FRAMES || frameNames.some((name, i) => name !== `f${String(i).padStart(5, '0')}.png`))
    throw new Error(`Incomplete frame sequence: expected ${TOTAL_FRAMES}, got ${frameNames.length}. Render --frames first.`);

  console.log('  encoding mp4…');
  ffmpeg(['-framerate', String(FPS), '-i', join(FRAMES, 'f%05d.png'),
          '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-pix_fmt', 'yuv420p',
          '-movflags', '+faststart', '-r', String(FPS), mp4]);

  // The GIF is the README's autoplay, so it is the file every clone pays for.
  // Two passes so the flat card greys do not band, and a hard budget: 800 wide,
  // 6 fps, 128 colours. A GIF is not the film — it is the poster that proves the
  // film exists, and it links to the MP4 for anyone who wants the real thing.
  // Anything much past ~8 MB is a README nobody finishes loading.
  console.log('  encoding gif…');
  const teaser = join(BUILD, 'teaser.mp4');
  const clips = [[2, 6], [14, 18], [26, 30], [36, 40], [59, 63]];
  const segments = clips.map(([a, b], i) => `[0:v]trim=start=${a}:end=${b},setpts=PTS-STARTPTS[v${i}]`).join(';');
  ffmpeg(['-i', mp4, '-filter_complex', segments + ';' + clips.map((_, i) => `[v${i}]`).join('') + `concat=n=${clips.length}:v=1:a=0[teaser]`,
    '-map', '[teaser]', '-c:v', 'libx264', '-preset', 'fast', '-crf', '20', teaser]);
  const pal = join(BUILD, 'palette.png');
  const gifFilter = 'fps=6,scale=800:-1:flags=lanczos';
  ffmpeg(['-i', teaser, '-vf', `${gifFilter},palettegen=max_colors=128:stats_mode=diff`, pal]);
  ffmpeg(['-i', teaser, '-i', pal, '-lavfi',
          `${gifFilter}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle`,
          '-loop', '0', gif]);

  for (const p of [mp4, gif]) {
    const kb = (readFileSync(p).length / 1024).toFixed(0);
    console.log(`  ${p.replace(ROOT + '/', '')}  ${kb} KB`);
  }
}

// ---------------------------------------------------------------- main
const argv = process.argv.slice(2);
const onlyFrames = argv.includes('--frames');
const onlyEncode = argv.includes('--encode');
const main = async () => {
  if (argv.includes('--motion-check') || argv.includes('--storyboard') || argv.includes('--only') || !onlyEncode) await capture(argv);
  if (!onlyFrames && !argv.includes('--only') && !argv.includes('--storyboard') && !argv.includes('--motion-check')) encode();
  if (!onlyEncode && !argv.includes('--only') && !argv.includes('--storyboard') && !argv.includes('--motion-check')) {
    console.log(`\n  ${TOTAL_SECONDS.toFixed(1)} s · ${TOTAL_FRAMES} frames · ${W}x${H} @ ${FPS}fps`);
  }
};
main().catch((err) => { console.error(err); process.exit(1); });
