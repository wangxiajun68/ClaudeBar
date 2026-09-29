// Builds the page the driver renders in. Kept out of driver.mjs so the exact
// source can be inspected and syntax-checked without launching a browser.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * The page is one classic script, so the three modules are flattened into it:
 * an `import …` line is dropped whole, and an `export ` *keyword* is deleted
 * while the declaration it prefixes stays. Deleting the whole line instead is
 * how `export const INK = {` becomes a dangling object literal — a syntax error
 * the browser reports as a mysterious "Unexpected token" far from its cause.
 */
export function stripModules(src) {
  const lines = src.split('\n');
  const out = [];
  let dropping = false;
  for (const line of lines) {
    // An import is dropped whole — including the multi-line destructuring form
    // (`const { A, B } = F;` spans three lines), which is why this tracks a
    // brace/paren balance instead of testing each line on its own.
    if (dropping) {
      if (/[;}\]]\s*$/.test(line) && !/[{\(]\s*$/.test(line)) dropping = false;
      continue;
    }
    if (/^\s*import\b/.test(line)) {
      if (!/[;}\]]\s*$/.test(line)) dropping = true;
      continue;
    }
    if (/^\s*const\s*\{[^}]*\}\s*=\s*(F|Wx)\s*;?\s*$/.test(line)) continue;
    if (/^\s*const\s*\{[^}]*$/.test(line)) { dropping = true; continue; }
    // The scenes re-alias the weather namespace by hand (`const WX_drawSky =
    // Wx.drawSky, …`). In the flattened script there is no `Wx`, so those lines
    // are rewritten to bind the names directly — the functions are already in
    // scope from the module above, and the scenes import the same ones.
    const alias = line.match(/^\s*const\s+(WX_\w+)\s*=\s*Wx\.(\w+)\s*[,;]/);
    if (alias) {
      // A line can carry several pairs; split on the commas between them.
      const pairs = line.replace(/^\s*const\s+/, '').replace(/;\s*$/, '').split(/,\s*/);
      const bound = pairs.map((pair) => {
        const m = pair.match(/^(WX_\w+)\s*=\s*Wx\.(\w+)$/);
        return m ? `const ${m[1]} = ${m[2]};` : null;
      }).filter(Boolean);
      if (bound.length) out.push('  ' + bound.join(' '));
      continue;
    }
    if (/^\s*const\s+WX_\w+\s*=/.test(line)) continue;
    out.push(line.replace(/^(\s*)export\s+/, '$1'));
  }
  return out.join('\n');
}

/** Every top-level binding the flattened script declares, for collision checks. */
export function topLevelNames(script) {
  const seen = new Map();
  script.split('\n').forEach((l, i) => {
    const m = l.match(/^(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)/);
    if (m) seen.set(m[1], [...(seen.get(m[1]) ?? []), i + 1]);
  });
  return seen;
}

export function pageSource({ here, width, height, timeline }) {
  const film = stripModules(readFileSync(join(here, 'film.mjs'), 'utf8'));
  const mod = stripModules(readFileSync(join(here, 'weather.mjs'), 'utf8'));
  const scenes = stripModules(readFileSync(join(here, 'scenes.mjs'), 'utf8'));

  // The three files are flattened into one scope, so a name declared twice is a
  // hard failure rather than a silent shadow. Checked here, where the message
  // can name the file pair, instead of leaving it to the browser.
  const combined = `${film}\n${mod}\n${scenes}`;
  const dupes = [...topLevelNames(combined)].filter(([, lines]) => lines.length > 1);
  if (dupes.length) {
    throw new Error('flattened modules redeclare: ' +
      dupes.map(([n, l]) => `${n} (lines ${l.join(', ')})`).join('; '));
  }

  const cut = JSON.stringify(timeline.map((s) => [s.fn, s.dur]));

  return `<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;background:#000;overflow:hidden}
  canvas{display:block}
</style></head><body>
<canvas id="c" width="${width}" height="${height}"></canvas>
<script>
${combined}

const win = typeof globalThis !== 'undefined' ? globalThis : this;
let ENV = { assets: {} };
win.setEnv = (a) => { ENV = { assets: a }; };
const CUT = ${cut};
win.draw = (t) => {
  const g = document.getElementById('c').getContext('2d');
  g.setTransform(1, 0, 0, 1, 0, 0);
  g.clearRect(0, 0, W, H);
  let start = 0, chosen = CUT[CUT.length - 1], local = t;
  for (let i = 0; i < CUT.length; i++) {
    const end = start + CUT[i][1];
    if (t < end || i === CUT.length - 1) { chosen = CUT[i]; local = t - start; break; }
    start = end - 0.2;
  }
  const fn = { scene1, scene2, scene3, scene4, scene5, scene6, scene7, scene8,
               scene9, scene10, scene11, scene12, scene13 }[chosen[0]];
  if (typeof fn !== 'function') throw new Error('no scene named ' + chosen[0]);
  fn(g, local, ENV);
  return chosen[0] + ' @ ' + local.toFixed(2);
};
</script></body></html>`;
}
