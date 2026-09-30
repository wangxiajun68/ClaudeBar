// MOTION THESIS: start inside the weather, pull out into the card, unfold the
// popup into its three information planes, compress it into the notch, then
// reveal the desktop. Real source textures travel through one perspective world.
// Continuity: shared planes survive chapter boundaries. Feedback: unfolding,
// alert expansion and scrolling are editorial demonstrations, not recorded input.
// Budget: deterministic CSS 3D transforms, bounded blur, 36 rain lines; no loops
// driven by wall time and no external motion runtime.

const motionNodes = {};
let motionAssets = {};
const motionClamp = v => Math.max(0, Math.min(1, v));
const motionEase = v => 1 - Math.pow(1 - motionClamp(v), 4);
const progress = (t, a, b) => motionEase((t - a) / (b - a));
const smooth = (t, a, b) => { const p = motionClamp((t - a) / (b - a)); return p * p * (3 - 2 * p); };
const between = (a, b, p) => a + (b - a) * p;
const motionGate = (t, a, b, c, d) => progress(t, a, b) * (1 - smooth(t, c, d));
const MOTION_SKY = { x: 48, y: 48, w: 2200, h: 948 };

function texture(name, crop = null, radius = 28) {
  const img = motionAssets[name];
  if (!img) throw new Error(`Missing film texture: ${name}`);
  if (!crop && radius === 0) return img.src;
  const s = crop ?? { x: 0, y: 0, w: img.width, h: img.height };
  if (s.x < 0 || s.y < 0 || s.x + s.w > img.width || s.y + s.h > img.height)
    throw new Error(`Crop exceeds ${name}: ${JSON.stringify(s)}`);
  const c = document.createElement('canvas'); c.width = s.w; c.height = s.h;
  const g = c.getContext('2d'); g.beginPath(); g.roundRect(0, 0, s.w, s.h, radius); g.clip();
  g.drawImage(img, s.x, s.y, s.w, s.h, 0, 0, s.w, s.h);
  return c.toDataURL('image/png');
}
function addPlane(id, src, className = '') {
  const el = document.createElement('div'); el.className = `plane ${className}`;
  const img = document.createElement('img'); img.src = src; img.alt = ''; el.append(img);
  document.getElementById('space').append(el); motionNodes[id] = el;
  return el;
}
function pose(id, p) {
  const el = motionNodes[id];
  const { x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, w = 1000, h = 430,
    scale = 1, alpha = 1, blur = 0 } = p;
  const a = motionClamp(alpha);
  el.style.display = a < 0.001 ? 'none' : 'block';
  el.style.opacity = a;
  el.style.width = `${w}px`; el.style.height = `${h}px`;
  el.style.transform = `translate(-50%,-50%) translate3d(${x}px,${y}px,${z}px) rotateX(${rx}deg) rotateY(${ry}deg) rotateZ(${rz}deg) scale(${scale})`;
  el.style.filter = blur > 0.1 ? `blur(${blur}px)` : 'none';
}
function windowPlane(id, name, dark = false) {
  const el = document.createElement('div'); el.className = `plane window ${dark ? 'dark' : ''}`;
  el.innerHTML = '<div class="windowbar"><span class="lights"><i></i><i></i><i></i></span><strong>ClaudeBar</strong><nav>概览　 会话　 模型　 用量　 流量　 VPN</nav><span>⌘K</span></div><div class="viewport"><img alt=""></div>';
  el.querySelector('img').src = motionAssets[name].src;
  document.getElementById('space').append(el); motionNodes[id] = el;
  return el;
}
function scrollWindow(id, amount) {
  const el = motionNodes[id]; const img = el.querySelector('.viewport img');
  const width = parseFloat(el.style.width) || 1120;
  const viewportH = (parseFloat(el.style.height) || 720) - 56;
  const naturalH = img.naturalHeight / img.naturalWidth * width;
  img.style.transform = `translateY(${-Math.max(0, naturalH - viewportH) * motionClamp(amount)}px)`;
}
export function setupFilm(assets) {
  motionAssets = assets;
  const space = document.getElementById('space'); space.replaceChildren();
  for (const sky of ['sun', 'cloud', 'rain', 'night']) {
    const el = addPlane(`sky-${sky}`, texture(`greeting-light-${sky}`, MOTION_SKY, 50), 'weather');
    const rain = document.createElement('div'); rain.className = 'rain';
    for (let i = 0; i < 36; i++) { const drop = document.createElement('i'); rain.append(drop); }
    el.append(rain);
  }
  addPlane('popup', texture('popup-light', null, 50), 'popup');
  const parts = [{ y: 0, h: 384 }, { y: 398, h: 710 }, { y: 1120, h: 592 }];
  parts.forEach((part, i) => addPlane(`popup-${i}`, texture('popup-light', { x: 0, y: part.y, w: 920, h: part.h }, 30), 'popup-part'));
  addPlane('island-rest', texture('island-collapsed-light', null, 0), 'island');
  addPlane('island-alert', texture('island-alert-light', null, 0), 'island');
  addPlane('island-open', texture('island-expanded-light', null, 0), 'island');
  windowPlane('desktop', 'window-overview-light');
  windowPlane('sessions', 'window-sessions-light');
  windowPlane('usage', 'window-usage-light');
  windowPlane('traffic', 'window-traffic-dark', true);
  addPlane('icon', texture('icon', null, 180), 'icon');
  // A physical screen rim locates the notch, rather than leaving a black tile
  // floating without context. Its interior is a designed presentation backdrop.
  const monitor = document.createElement('div'); monitor.className = 'plane monitor';
  monitor.innerHTML = '<div class="desktop-wallpaper"></div><div class="notch"></div><div class="desktop-menubar"><span>ClaudeBar　 文件　 窗口</span><span>周三　 10:17</span></div><div class="dock"><i>CB</i><i>CC</i><i>Co</i><i>Cu</i></div>';
  space.prepend(monitor); motionNodes.monitor = monitor;
  const labels = document.getElementById('layer-labels');
  labels.innerHTML = '<span>模型与额度</span><span>正在进行的会话</span><span>用量与快捷操作</span>';
  document.querySelectorAll('.brand-icon').forEach(img => { img.src = assets.icon.src; });
  return Promise.all([...document.querySelectorAll('#space img')].map(img => img.decode()));
}
function weatherPose(t) {
  const pull = smooth(t, 0.4, 4.3);
  const leave = smooth(t, 8.9, 12.5);
  return {
    x: between(0, -630, leave), y: between(-24, -12, leave),
    z: between(760, -30, pull) - leave * 600,
    rx: between(0, 7, pull) + leave * 9,
    ry: between(0, -11, pull) + leave * 31,
    rz: -1.8 * pull, w: 1460, h: 1460 * 948 / 2200,
    alpha: 1 - smooth(t, 11.1, 12.7), blur: leave * 3,
  };
}
function renderWeather(t) {
  const keys = ['sun', 'cloud', 'rain', 'night'];
  const phase = motionClamp((t - 4.0) / 5.3) * 3;
  const index = Math.min(3, Math.floor(phase));
  const mix = smooth(phase - index, 0.15, 0.85);
  const p = weatherPose(t);
  keys.forEach((key, i) => {
    let alpha = i === index ? 1 : i === index + 1 ? mix : 0;
    // Opaque lower image avoids a dark dip during the dissolve.
    pose(`sky-${key}`, { ...p, alpha: alpha * p.alpha, z: p.z + i * 0.15 });
    const rain = motionNodes[`sky-${key}`].querySelector('.rain');
    rain.style.opacity = key === 'rain' ? 0.75 : 0;
    rain.querySelectorAll('i').forEach((el, k) => {
      const x = ((k * 173 + t * (12 + k % 4)) % 1470) - 10;
      const y = ((k * 79 + t * (225 + k % 7 * 26)) % 710) - 60;
      el.style.transform = `translate(${x}px,${y}px) rotate(-13deg)`;
      el.style.height = `${18 + k % 5 * 8}px`;
      el.style.opacity = 0.15 + (k % 4) * 0.13;
    });
  });
}
function renderPopup(t) {
  const enter = progress(t, 8.9, 11.6);
  const separate = smooth(t, 14.0, 16.6) * (1 - smooth(t, 19.0, 21.1));
  const exit = smooth(t, 21.3, 24.8);
  const splitAlpha = motionGate(t, 13.9, 14.3, 20.7, 21.1);
  const x = between(840, 386, enter) - exit * 310;
  const y = between(190, -3, enter) - exit * 420;
  const z = between(-550, 25, enter) - exit * 150;
  const turn = between(-64, -11, enter) + exit * 16;
  const alpha = progress(t, 9, 10.1) * (1 - smooth(t, 23, 24.9));
  const scale = between(0.72, 1, enter) * between(1, 0.2, exit);
  const w = 428, h = 428 * 1712 / 920;
  pose('popup', { x, y, z, ry: turn, rx: 5, rz: 0.8, w, h, scale, alpha: alpha * (1 - splitAlpha) });
  const parts = [{ y: -308.9, h: 178.6 }, { y: -48.9, h: 330.3 }, { y: 259.2, h: 275.4 }];
  parts.forEach((part, i) => {
    pose(`popup-${i}`, { x: x + (i - 1) * separate * 74,
      y: y + part.y * between(1, .86, separate) + (i - 1) * separate * 28,
      z: z + separate * (120 - i * 60), ry: turn - separate * (8 - i * 7),
      rx: 5 + separate * (i - 1) * 4, rz: 0.8, w, h: part.h,
      alpha: alpha * splitAlpha, scale: scale * between(1, .86, separate) });
  });
  const labels = document.getElementById('layer-labels');
  labels.style.opacity = separate * alpha;
  labels.style.transform = `translateY(${(1 - separate) * 20}px)`;
}
function renderIsland(t) {
  const entry = progress(t, 22.0, 23.8);
  const alert = smooth(t, 25.2, 26.4);
  const open = smooth(t, 28.2, 29.8);
  const merge = smooth(t, 31.3, 34.4);
  const a = progress(t, 21.9, 22.8) * (1 - smooth(t, 35, 36));
  const p = {
    x: between(76, 0, entry), y: between(-400, -35, entry) - merge * 319,
    z: between(-180, 90, entry) - merge * 105,
    ry: between(16, -8, entry) * (1 - merge), rx: 6 * (1 - merge),
    w: between(between(700, 900, alert), 900, open) * between(1, 0.37, merge),
    h: between(between(103, 220, alert), 575, open) * between(1, 0.37, merge),
  };
  pose('island-rest', { ...p, alpha: a * (1 - alert) });
  pose('island-alert', { ...p, alpha: a * alert * (1 - open) });
  pose('island-open', { ...p, alpha: a * open });
  const halo = document.getElementById('island-halo');
  halo.style.opacity = a * (0.17 + 0.2 * Math.sin(t * 1.4) ** 2) * (1 - merge);
}
function renderDesktop(t) {
  const enter = progress(t, 31.3, 34.5);
  const inspect = smooth(t, 36.0, 37.8);
  const scroll = smooth(t, 37.6, 43.1);
  const exit = smooth(t, 44.9, 47.0);
  pose('monitor', {
    x: 0, y: -45, z: between(-420, -130, enter),
    ry: between(-17, 0, enter), rx: between(10, 0, enter),
    w: 1520, h: 860, alpha: progress(t, 31.2, 32.5) * (1 - smooth(t, 35.5, 37.8)),
  });
  const win = { x: between(0, -75, inspect) - exit * 1300,
    y: between(40, -14, inspect), z: between(-180, 0, enter) + inspect * 80,
    rx: between(7, 0, enter) + inspect * 2, ry: between(-12, 0, enter) + inspect * 8,
    w: 1120, h: 720, alpha: progress(t, 32.1, 34.0) * (1 - exit),
    blur: exit * 2 };
  pose('desktop', win); scrollWindow('desktop', scroll);
}
function renderGallery(t) {
  const phases = [
    { id: 'sessions', a: 45, b: 47, c: 49, d: 51, scroll: 0 },
    { id: 'usage', a: 49, b: 51, c: 53, d: 55, scroll: smooth(t, 51, 54) },
    { id: 'traffic', a: 53, b: 55, c: 57, d: 59.2, scroll: 0 },
  ];
  phases.forEach(({ id, a, b, c, d, scroll }) => {
    const arrive = progress(t, a, b), leave = smooth(t, c, d);
    pose(id, { x: between(1420, 0, arrive) - leave * 1420,
      y: -5 + (1 - arrive) * 80, z: between(-420, 90, arrive) - leave * 260,
      ry: between(-35, 0, arrive) + leave * 26, rx: 3,
      w: 1120, h: 720, alpha: motionGate(t, a, a + 0.9, c + 0.4, d), blur: (1 - arrive + leave) * 2 });
    scrollWindow(id, scroll);
  });
}
function renderClosing(t) {
  const gather = progress(t, 57.5, 60.5), quiet = smooth(t, 61.4, 63.2);
  if (t >= 57.5) {
    pose('sky-sun', { x: -440, y: -130, z: -200, rx: 10, ry: 20, rz: -4,
      w: 940, h: 405, alpha: gather * (1 - quiet), blur: quiet * 6 });
    pose('popup', { x: 610, y: -10, z: 20, rx: 4, ry: -20, rz: 3,
      w: 300, h: 558, alpha: gather * (1 - quiet), blur: quiet * 6 });
    pose('desktop', { x: -110, y: 150, z: -130, rx: 6, ry: 5, w: 830, h: 534,
      alpha: gather * (1 - quiet), blur: quiet * 6 });
    scrollWindow('desktop', .45);
    pose('island-open', { x: -420, y: 208, z: 160, rx: 4, ry: 8, w: 388, h: 248,
      alpha: gather * (1 - quiet), blur: quiet * 6 });
  }
  pose('icon', { x: 0, y: -130, z: between(-150, 120, quiet), ry: between(-24, 0, quiet),
    rx: between(10, 0, quiet), w: 112, h: 112, alpha: progress(t, 61.4, 63.2) });
  const lockup = document.getElementById('end-lockup');
  lockup.style.opacity = progress(t, 62.0, 63.4);
  lockup.style.transform = `translateY(${(1 - progress(t, 62, 63.4)) * 28}px)`;
}
function renderCopy(t) {
  let current = 0;
  for (let i = 0; i < CUT_DATA.length; i++) if (t >= CUT_DATA[i].start) current = i;
  const s = CUT_DATA[current];
  const local = t - s.start;
  const alpha = progress(local, current === 0 ? 2.7 : 0.4, current === 0 ? 4 : 1.5)
    * (current === CUT_DATA.length - 1 ? 1 - smooth(local, 3, 4) : 1 - smooth(local, s.dur - 1, s.dur - 0.15));
  const copy = document.getElementById('copy');
  copy.className = `copy ${s.id === 'popup' ? 'left' : 'bottom'}`;
  document.getElementById('headline').textContent = s.title;
  let subtitle = s.subtitle;
  if (s.id === 'workspace') subtitle = t < 50 ? '会话：看清上下文、工具与运行状态。' : t < 54 ? '用量：来源、构成与费用分开看。' : '流量：查看对话与工具调用，追踪一次请求。';
  document.getElementById('subline').textContent = subtitle;
  copy.style.opacity = alpha;
  copy.style.transform = `translateY(${(1 - alpha) * 24}px)`;
  copy.style.filter = `blur(${(1 - alpha) * 5}px)`;
}
export function renderFilm(t) {
  if (!Number.isFinite(t)) throw new Error('Film time must be finite');
  t = Math.max(0, t);
  document.getElementById('film-stage').style.setProperty('--ambient', `${0.45 + 0.15 * Math.sin(t * 0.18)}`);
  const atmosphere = document.getElementById('atmosphere');
  atmosphere.style.transform = `translate3d(${Math.sin(t * 0.12) * 100}px,${Math.cos(t * 0.1) * 50}px,0) scale(1.2)`;
  document.getElementById('ground').style.transform = `translateX(-50%) rotateX(68deg) rotateZ(${between(-8, 8, smooth(t, 0, 60))}deg)`;
  document.getElementById('brand').style.opacity = progress(t, 2.8, 4.5);
  for (const el of Object.values(motionNodes)) el.style.display = 'none';
  renderWeather(t); renderPopup(t); renderIsland(t); renderDesktop(t); renderGallery(t); renderClosing(t); renderCopy(t);
  return `cinematic @ ${t.toFixed(3)}`;
}
