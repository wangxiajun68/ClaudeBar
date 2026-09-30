import { readFileSync } from 'node:fs';
import { join } from 'node:path';
export function pageSource({ here, width, height, timeline }) {
  const scenes = readFileSync(join(here, 'scenes.mjs'), 'utf8').replace(/^export /gm, '');
  let start = 0;
  const cut = timeline.map(s => { const v = { ...s, start }; start += s.dur; return v; });
  return `<!doctype html><html><head><meta charset="utf-8"><style>
*{box-sizing:border-box}html,body{margin:0;width:${width}px;height:${height}px;overflow:hidden;background:#090e15;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;-webkit-font-smoothing:antialiased}
#film-stage{position:relative;width:${width}px;height:${height}px;overflow:hidden;isolation:isolate;background:radial-gradient(ellipse at 50% 20%,#223a4b 0,#101c2b 40%,#080d15 85%);--ambient:.6}
#atmosphere{position:absolute;inset:-100px;background:radial-gradient(ellipse at 23% 15%,#467f9750,transparent 52%),radial-gradient(ellipse at 85% 65%,#99816d35,transparent 50%);opacity:var(--ambient)}
#ground{position:absolute;left:50%;top:700px;width:2300px;height:1200px;transform-origin:top;background-image:linear-gradient(#7b9eb510 1px,transparent 1px),linear-gradient(90deg,#7b9eb510 1px,transparent 1px);background-size:110px 110px;mask-image:radial-gradient(ellipse at center,#000,transparent 66%)}
#space{position:absolute;inset:0;perspective:1600px;perspective-origin:50% 46%;transform-style:preserve-3d}
.plane{position:absolute;left:50%;top:46%;transform-style:preserve-3d;backface-visibility:hidden;will-change:transform,opacity;display:none;border-radius:24px;box-shadow:0 45px 90px #0008,0 3px 10px #0004}
.plane>img{position:relative;z-index:1;transform:translateZ(1px);display:block;width:100%;height:100%;object-fit:contain;border-radius:inherit}
.plane:before{z-index:-1;content:"";position:absolute;inset:0;border:1px solid #eafaff40;border-radius:inherit;transform:translateZ(-3px);background:transparent}
.plane:after{content:"";position:absolute;inset:0;border:1px solid #ffffff25;border-radius:inherit;pointer-events:none;background:linear-gradient(135deg,#ffffff0e,transparent 35%,#ffffff08 75%,transparent)}
.weather{border-radius:34px;box-shadow:0 65px 140px #0009,0 0 0 1px #c8eaff35}.weather:before{background:transparent}.rain{position:absolute;inset:0;overflow:hidden;border-radius:inherit;pointer-events:none}.rain i{position:absolute;top:0;left:0;width:1px;background:linear-gradient(transparent,#fff);box-shadow:0 0 2px #fff4}
.popup,.popup-part{border-radius:22px}.popup:before,.popup-part:before{background:transparent}
.island{box-shadow:0 35px 65px #0007;border-radius:24px}.island:before{background:transparent}.island:after{border-color:#ccf6ff20}
.window{overflow:hidden;border-radius:18px;background:#eef3f8}.windowbar{height:56px;display:flex;align-items:center;gap:20px;padding:0 24px;background:#eef3f8;color:#25323c;border-bottom:1px solid #cad5df;font-size:16px}.windowbar nav{margin:auto;font-size:14px}.windowbar>span:last-child{font-size:13px;opacity:.6}.lights{display:flex;gap:8px}.lights i{width:11px;height:11px;border-radius:50%;background:#ff6158}.lights i:nth-child(2){background:#ffbe2e}.lights i:nth-child(3){background:#2acb42}.viewport{position:absolute;top:56px;bottom:0;width:100%;overflow:hidden}.viewport img{display:block;width:100%;max-width:none;transform-origin:top left}.window.dark{background:#16181c}.window.dark .windowbar{background:#20252b;color:#eee;border-color:#343c45}
.monitor{border:8px solid #16191f;box-shadow:0 50px 140px #000b,0 0 0 2px #92b0c535;overflow:hidden;border-radius:30px;background:#203547}.desktop-wallpaper{position:absolute;inset:0;background:radial-gradient(ellipse at 20% 30%,#54857f,transparent 45%),radial-gradient(ellipse at 80% 80%,#375a87,transparent 50%),linear-gradient(130deg,#203b42,#1b283d)}.desktop-menubar{display:flex;justify-content:space-between;padding:12px 24px;color:#e4eef4;font-size:18px;background:#10232b50}.notch{position:absolute;top:0;left:calc(50% - 110px);height:45px;width:220px;border-radius:0 0 16px 16px;background:#050607}.dock{position:absolute;bottom:22px;left:50%;transform:translateX(-50%);padding:10px;display:flex;gap:12px;border:1px solid #ffffff30;border-radius:18px;background:#ffffff20}.dock i{font-style:normal;font-size:16px;width:44px;height:44px;display:grid;place-items:center;border-radius:10px;background:#e7f0f0cc;color:#263642}
#brand{position:absolute;top:64px;left:88px;display:flex;align-items:center;gap:12px;color:#eef5f9;font-size:22px;font-weight:600;z-index:3}.brand-icon{width:34px;height:34px;border-radius:8px}#edition{position:absolute;right:88px;top:76px;color:#b0c3ce;font-size:17px;letter-spacing:.03em}
.copy{position:absolute;z-index:5;color:#f2f7fa;pointer-events:none}.copy h1{white-space:pre-line;font-size:58px;line-height:1.15;letter-spacing:-.025em;margin:0 0 20px;font-weight:600}.copy p{font-size:25px;line-height:1.5;color:#b9cbd7;margin:0}.copy.bottom{left:110px;right:110px;top:901px;text-align:center}.copy.left{left:125px;top:390px;width:530px}.copy.left h1{font-size:76px;line-height:1.2;max-width:530px}.copy.left p{max-width:490px;font-size:27px}
#layer-labels{position:absolute;left:124px;top:740px;color:#93bdcf;font-size:22px;display:flex;gap:22px;flex-direction:column;z-index:6}
#island-halo{position:absolute;width:1050px;height:480px;border-radius:50%;background:radial-gradient(ellipse,#5c8e9e90,transparent 65%);left:435px;top:270px;filter:blur(35px);opacity:0;pointer-events:none}
#end-lockup{position:absolute;left:0;right:0;top:575px;text-align:center;color:#f4f7fa;opacity:0;z-index:6}#end-lockup h1{font-size:82px;letter-spacing:-.04em;margin:0 0 20px}#end-lockup p{font-size:30px;color:#b9cbd7;margin:0 0 30px}#end-lockup a{display:block;font-size:23px;color:#d5e9f4}#end-lockup small{display:block;margin-top:22px;color:#91a8b8;font-size:18px}
.icon{border-radius:26px}
</style></head><body><div id="film-stage"><div id="atmosphere"></div><div id="ground"></div><div id="island-halo"></div><div id="space"></div><div id="brand"><img class="brand-icon" alt="">ClaudeBar</div><div id="edition">macOS · AI 工作台</div><div id="copy" class="copy bottom"><h1 id="headline"></h1><p id="subline"></p></div><div id="layer-labels"></div><div id="end-lockup"><h1>ClaudeBar</h1><p>让工作流，住进你的 Mac。</p><a>github.com/wangxiajun68/ClaudeBar</a><small>macOS 15+ · Apple Silicon · MIT 开源</small></div></div><script>
const CUT_DATA = ${JSON.stringify(cut)};
${scenes}
window.setEnv = setupFilm;
window.draw = renderFilm;
</script></body></html>`;
}
