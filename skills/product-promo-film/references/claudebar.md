# ClaudeBar 编辑适配

以下为已接受的空间宣传片基线。先从当前仓库核对这些文件；版本更新可能改变尺寸、时间和脚本参数，不把本参考当成比源码更高的事实来源。不要依赖固定绝对项目路径。

## 源文件职责

| 文件 | 职责 |
| --- | --- |
| `docs/promo/prompt.md` | 产品叙事、镜头、素材区域、时间轴与制作规格 |
| `docs/promo/DESIGN.md` | 宣传片视觉规则及设计验收 |
| `Tools/promo/scenes.mjs` | CSS 3D 场景、空间姿态、滚动与按时间计算的动画 |
| `Tools/promo/page.mjs` | 场景 HTML/CSS 与脚本装配 |
| `Tools/promo/driver.mjs` | 时间轴、所需素材、截图、动效检查与 MP4/GIF 编码 |
| `Tools/promo/film.mjs` | 输出宽高与 FPS 常量 |
| `Tools/render-promo-film.py` | 依赖检查、生产素材刷新与驱动入口 |
| `Tools/promo/key-island.py` | 连通背景抠图，保留岛内浅色正文 |
| `Tests/promo-key-regressions.py` | 浅/深背景下的抠图回归 |
| `Tools/serve-promo.py` | 支持字节 Range 的本地播放器服务 |

原 Canvas 绘制模块 `weather.mjs` 已废弃删除。不要恢复 `.build/promo/` 中的历史复制模块；执行 `Tools/promo/` 中维护的源文件。

## 基线与素材

基线为 1920×1080 / 30fps / 66秒 / 1980帧，静音。章节：天气 0–10，Popup 10–22，灵动岛 22–33，桌面 33–46，工作视图 46–58，收束 58–66 秒。用户认可的方向是天气卡片带入、连续空间旅程、真实产品 UI、丰富动效与可读的停稳画面。

生产素材来自 `render-greeting-preview.py`、`render-popup-preview.py`、`render-island-preview.py` 和 `render-mainwindow-preview.py`。渲染器可能使用生产 Swift 源码切片及固定数据，不等同完整应用运行；查看脚本明确未渲染的硬件子视图，不把演示 fixture 当成真实数据。

当前驱动需要晴/云/雨/夜浅色天气、浅色 Popup、浅色常驻/提醒/展开岛、浅色概览/会话/用量窗口及深色流量窗口。裁切矩形以制作说明与当前图像尺寸为准。UI 改版后重新检查素材尺寸、Popup 分层边界及滚动范围。

## 工作命令（从仓库根目录执行）

```bash
python3 Tools/render-promo-film.py --check
# --check 检查工具/模块存在性，不安装依赖，不证明素材齐全。
python3 Tools/render-promo-film.py --storyboard
# 刷新生产素材并准备 playwright-core，生成章内样张及介绍图。
node Tools/promo/driver.mjs --motion-check
python3 Tests/promo-key-regressions.py
# 视觉检查样张及动作后，再做全量渲染/编码。
python3 Tools/render-promo-film.py --reuse-surfaces
python3 Tools/serve-promo.py
```

帧捕获需要 Node、playwright-core 与 Google Chrome，编码需要 ffmpeg；抠图测试需要 Pillow。实际依赖以脚本为准。`--storyboard` 会覆盖当前介绍图，属于制作输出操作。只有确认素材已经对应当前源码时才能使用 `--reuse-surfaces`。

本地章节播放器：`http://127.0.0.1:8808/docs/promo/film.html`。端口已有服务时复用并核对，不重复启动。

可独立生成帧与编码：

```bash
python3 Tools/render-promo-film.py --frames --reuse-surfaces
python3 Tools/render-promo-film.py --encode
```

局部修复命令示例：

```bash
node Tools/promo/driver.mjs --range 21.9:36,57.5:66 --frames
node Tools/promo/driver.mjs --encode
```

局部模式不会清空帧目录，只在已有完整、同一版本时间轴的 `fXXXXX.png` 序列上使用。缓存已清理或无法证明帧基线一致时，全量重建。片长、FPS、时间轴或全局素材改变时，也全量重建；跨章元素要包含其整个影响范围。

## 输出联动

输出位于 `docs/promo/`：MP4、GIF、poster/overview/sessions/usage PNG、`film.html`、`captions.zh.vtt` 和制作说明。改时间轴时同步 driver、播放器章节、字幕、GIF 截取区间、截图时间点及中英文 README 的片长。GIF 默认为20秒精选、800px宽/6fps/128色；依据实际体积调整，不用低帧 GIF 判断全片30fps品质。

中间帧、调试稿、palette、teaser 位于 `.build/promo/`，可以在交付完成后清理。保留当前依赖和抠图资产以便复查；生产 UI 预览脚本属于可复用工具，不因生成本次视频而删除。2026-09-30 已清理历史帧缓存，不能假定完整序列仍存在。

编码验收可使用技能自带的 `scripts/inspect_video.py`，传入影片路径及 `--width 1920 --height 1080 --fps 30 --duration 66 --frames 1980 --codec h264 --pixel-format yuv420p --count-frames --decode`。规格改变时使用新值。该工具只检查文件和解码，不修改影片，也不替代视觉播放。

GitHub README 当前使用视频附件播放器，GIF 只是可选独立产物。更新成片时也要重新上传播放附件并同步双语 README，不能只替换仓库 MP4。附件上传和压缩命令以 `docs/promo/prompt.md` 的“GitHub README 视频播放”为准；通过网页编辑器上传即可，不必创建 Issue。当前本机 gh 2.98 没有 `--attach`，使用 CLI 上传前先检查实际版本的帮助。
