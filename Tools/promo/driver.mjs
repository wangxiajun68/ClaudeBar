// ClaudeBar promo film — driver.
//
// Owns the timeline (which scene, at what local time), loads the assets the
// scenes draw with, walks t at 1/30 s, captures each frame through Chrome, and
// then hands the PNG sequence to ffmpeg.
//
//   node driver.mjs --frames            render the PNG sequence
//   node driver.mjs --encode            encode mp4 + gif from the sequence
//   node driver.mjs                     both
//   node driver.mjs --only 7 --preview  a contact sheet of one scene, for checking

import { chromium } from 'playwright-core';
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { W, H, FPS } from './film.mjs';
import { pageSource as page_source } from './page.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');
const FRAMES = join(HERE, 'frames');

// ---------------------------------------------------------------- timeline
// prompt.md §4, in order. `dur` is scene-local; the driver adds the head start.
export const TIMELINE = [
  { n: 1,  id: 'opening',        dur: 6.6,  fn: 'scene1',  bg: 'light' },
  { n: 2,  id: 'four-icons',     dur: 8.9,  fn: 'scene2',  bg: 'light' },
  { n: 3,  id: 'greeting-sky',   dur: 16.2, fn: 'scene3',  bg: 'light' },
  { n: 4,  id: 'glass-rain',     dur: 11.2, fn: 'scene4',  bg: 'light' },
  { n: 5,  id: 'island-rest',    dur: 9.0,  fn: 'scene5',  bg: 'light' },
  { n: 6,  id: 'island-alert',   dur: 10.6, fn: 'scene6',  bg: 'light' },
  { n: 7,  id: 'island-open',    dur: 12.4, fn: 'scene7',  bg: 'light' },
  { n: 8,  id: 'popup-switch',   dur: 13.4, fn: 'scene8',  bg: 'light' },
  { n: 9,  id: 'popup-session',  dur: 9.8,  fn: 'scene9',  bg: 'light' },
  { n: 10, id: 'main-window',    dur: 13.8, fn: 'scene10', bg: 'light' },
  { n: 11, id: 'traffic',        dur: 7.8,  fn: 'scene11', bg: 'dark'  },
  { n: 12, id: 'tunnel',         dur: 3.6,  fn: 'scene12', bg: 'light' },
  { n: 13, id: 'closing',        dur: 3.8,  fn: 'scene13', bg: 'dark'  },
];

export const TOTAL_SECONDS = TIMELINE.reduce((a, s) => a + s.dur, 0) - 0.2 * (TIMELINE.length - 1);
export const TOTAL_FRAMES = Math.round(TOTAL_SECONDS * FPS);

/** Which scene is on screen at film time t, and how far into it we are. */
export function at(t) {
  let start = 0;
  for (let i = 0; i < TIMELINE.length; i++) {
    const s = TIMELINE[i];
    const end = start + s.dur;
    if (t < end || i === TIMELINE.length - 1) return { scene: s, local: t - start, index: i };
    start = end - 0.2;   // the 0.2 s that adjacent scenes share is the transition
  }
}

// ---------------------------------------------------------------- assets
const ASSET_FILES = {
  icon:       ['Sources/AppIcon-1024.png', 'image/png'],
  statusIcon: ['Sources/MenuBarIcon.png', 'image/png'],
  anthropic:  ['Sources/BrandAssets/anthropic-light.png', 'image/png'],
  openai:     ['Sources/BrandAssets/openai-light.png', 'image/png'],
  cursor:     ['Sources/BrandAssets/cursor-light.png', 'image/png'],
};

function loadAssets() {
  const out = {};
  for (const [key, [rel, mime]] of Object.entries(ASSET_FILES)) {
    const p = join(ROOT, rel);
    if (!existsSync(p)) { console.error(`  ! missing asset ${rel}`); continue; }
    out[key] = `data:${mime};base64,${readFileSync(p).toString('base64')}`;
  }
  return out;
}

// ---------------------------------------------------------------- page
/**
 * The page is a blank canvas plus the two modules, inlined. draw(t) must be a
 * pure function of t, so the driver can render the same frame twice and get the
 * same bytes — that property is what makes a re-render trustworthy.
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
    await Promise.all(Object.entries(a).map(([key, src]) => new Promise((res) => {
      const img = new Image();
      img.onload = () => { decoded[key] = img; res(); };
      img.onerror = () => { console.error('asset failed to decode: ' + key); res(); };
      img.src = src;
    })));
    window.setEnv(decoded);
  }, loadAssets());

  const shots = [];
  if (only) {
    const s = TIMELINE.find((x) => x.n === only);
    // The scene's own head start. `draw()` takes film time, so a preview that
    // passed scene-local time would silently render the *previous* scene.
    const offset = TIMELINE.slice(0, TIMELINE.indexOf(s))
      .reduce((a, x) => a + x.dur - 0.2, 0);
    const n = preview ? 12 : Math.round(s.dur * FPS);
    for (let i = 0; i < n; i++) {
      const local = preview ? (i / (n - 1)) * s.dur : i / FPS;
      await page.evaluate((t) => window.draw(t), offset + local);
      const dir = preview ? join(HERE, 'preview') : FRAMES;
      mkdirSync(dir, { recursive: true });
      const file = join(dir, `s${String(s.n).padStart(2, '0')}_${String(i).padStart(4, '0')}.png`);
      await page.screenshot({ path: file, clip: { x: 0, y: 0, width: W, height: H } });
      shots.push(file);
    }
    await browser.close();
    console.log(`${preview ? 'preview' : 'scene'} ${only}: ${shots.length} frames -> ${shots[0]}`);
    return shots;
  }

  const total = TOTAL_FRAMES;
  const t0 = Date.now();
  for (let i = 0; i < total; i++) {
    const t = i / FPS;
    await page.evaluate((tt) => window.draw(tt), t);
    const file = join(FRAMES, `f${String(i).padStart(5, '0')}.png`);
    await page.screenshot({ path: file, clip: { x: 0, y: 0, width: W, height: H } });
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

  console.log('  encoding mp4…');
  ffmpeg(['-framerate', String(FPS), '-i', join(FRAMES, 'f%05d.png'),
          '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-pix_fmt', 'yuv420p',
          '-movflags', '+faststart', '-r', String(FPS), mp4]);

  // The GIF is the README's autoplay. Two passes so the flat card greys do not
  // band, and it is the file that gets reached for on every clone, so it is
  // budgeted: 1280 wide, 12.5 fps, and `max_colors` trimmed — a 20-minute
  // feature's-worth of MP4 quality in a GIF is a README nobody finishes loading.
  console.log('  encoding gif…');
  const pal = join(HERE, 'palette.png');
  const gifFilter = 'fps=10,scale=1040:-1:flags=lanczos';
  ffmpeg(['-i', mp4, '-vf', `${gifFilter},palettegen=max_colors=180:stats_mode=diff`, pal]);
  ffmpeg(['-i', mp4, '-i', pal, '-lavfi',
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
  if (argv.includes('--only') || !onlyEncode) await capture(argv);
  if (!onlyFrames && !argv.includes('--only')) encode();
  if (!onlyEncode && !argv.includes('--only')) {
    console.log(`\n  ${TOTAL_SECONDS.toFixed(1)} s · ${TOTAL_FRAMES} frames · ${W}x${H} @ ${FPS}fps`);
  }
};
main().catch((err) => { console.error(err); process.exit(1); });
