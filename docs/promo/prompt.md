# ClaudeBar 产品影片

当前版本：2026-10-16，1.17 发布素材。52 秒、1920×1080、30fps、1560 帧，静音 H.264 / yuv420p / faststart。相较旧版 66 秒影片，压缩天气与概览停留，增加网关、网络、文档和 CLI；整体保留连续空间转场。

## 时间轴与动效

| 时间 | 内容 | 动作与停稳 |
| --- | --- | --- |
| 0–4s | 天气 | 天空特写拉出完整卡片，晴云雨夜交叠，末段向左后方退出 |
| 4–10s | Popup | 侧后旋入，完整停稳，模型 / 会话 / 用量沿深度轴展开，合拢至顶栏 |
| 10–16s | 灵动岛 | 常驻 → 完成提醒 → 展开详情，随后向显示器顶边归位 |
| 16–21s | 桌面概览 | 显示器拉远，窗口浮起，滚动浏览天气、仪表与能源 |
| 21–29s | 会话 / 用量 / 请求 | 约 2.67 秒一个视图，沿同一轨道进入、停稳和退出；用量页面纵向浏览 |
| 29–37s | 模型网关 | 前四秒展示路由关系，后四秒展示真实视图渲染的队列航道；界面在可阅读的正面停稳 |
| 37–46s | 网络 / 文档 / CLI | 每项三秒：VPN 历史分析、文档正文、终端观测；短入场、正面停留、同向退出 |
| 46–52s | 收束 | 多个界面在空间汇集，退到后景，再落定图标、项目名与仓库地址 |

分镜信息由 `Tools/promo/driver.mjs` 的 TIMELINE 执行，字幕和播放器按上表同步。旧镜头姿态通过 `shotTime` 映射到当前章节秒数；它只复用运动曲线，输出时钟仍是当前 52 秒时间轴。没有实时钟、随机输入或无限动画。

每章抽查入场、早期、停稳、晚期与退出；章界检查前后一帧。视频中的分层、桌面边框和镜头是宣传编排，不表示产品具备爆炸分层等操作。

## 视觉

深蓝石墨背景、偏蓝环境光和透视地面；真实 UI 保持原生颜色。CSS 3D 使用 1600px 透视及 50% / 46% 的投影中心，以旋转、深度、遮挡和差速建立空间关系。标题固定在独立留白带，正文停稳时接近正面；不依靠持续摇晃制造运动。

完整视图不得拉伸或越界。长页面放入符合比例的窗口视口，通过滚动呈现；CLI 按原图比例限制高度。Popup 完整展示后再分层，不叠压正文。纹理全部解码后捕获完整 DOM 画面。

## 素材与真实性

| 素材 | 来源 |
| --- | --- |
| 天气 | `Tools/render-greeting-preview.py`，生产视图与固定数据；裁切去掉 48px 外边距，卡片 2200×948px |
| Popup | `Tools/render-popup-preview.py`，920×1712px；三层源区 y=0/h=384、398/710、1120/592 |
| 灵动岛 | `Tools/render-island-preview.py`，生产视图；`key-island.py` 仅清除连通的外部背景 |
| 概览 / 会话 / 用量 / 请求 | `Tools/render-mainwindow-preview.py`，生产视图及隔离 store；不执行真实迁移或后台服务 |
| 模型网关 | `Tools/render-model-gateway-preview.py`，固定请求状态的路由与队列；不是实际网络录制 |
| VPN 历史分析 | `Tools/render-vpn-preview.py`，生产原生视图与临时目录样本，不启动内核 |
| 文档正文 | `Tools/render-feishu-preview.py`，生产 Markdown 阅读 / 编辑表面；不是云端文档组件登录过程 |
| CLI | 仓库既有 `docs/assets/cli-matrix-preview.png` 合成演示图，未访问真实终端账户数据 |
| README 示例 | `Tools/promo/readme-surfaces.py`，复制 Popup，组合刘海屏与外接屏的最新原生预览 |

以上渲染是源码切片与固定样本的视图展示，不等于整应用运行。模型、额度、费用、文档和请求正文均为演示内容；不读取正式配置、密钥或私人会话。

## 重建

```bash
python3 Tools/render-promo-film.py --check
python3 Tools/render-promo-film.py --storyboard
node Tools/promo/driver.mjs --motion-check
python3 Tests/promo-key-regressions.py
python3 Tools/render-promo-film.py --reuse-surfaces
python3 Tools/serve-promo.py
```

需要 Node、固定版本的 playwright-core、Google Chrome、Swift 工具链、Pillow 和 ffmpeg。依赖与中间帧位于 `.build/promo/`，生产脚本位于 `Tools/`。下载命令使用当前任务指定代理；工具不修改系统代理。

先刷新素材和检查分镜，再全量捕获 1560 帧并编码。仅在本轮素材已刷新后使用 `--reuse-surfaces`。时间轴或全局素材改变必须重建全序列；不能把旧 1980 帧缓存混入本版。

输出包括 MP4、20 秒 / 800px / 6fps 的 GIF、poster / overview / sessions / usage / gateway PNG、Popup / island 示例、中文字幕和章节播放器。GIF 只作轻量预览，不用它判断成片帧率。

完整解码检查：

```bash
python3 skills/product-promo-film/scripts/inspect_video.py docs/promo/claudebar.mp4 --width 1920 --height 1080 --fps 30 --duration 52 --frames 1560 --codec h264 --pixel-format yuv420p --count-frames --decode
```

## GitHub README 视频播放

双语 README 使用单独成段的 GitHub 视频附件 URL，原生播放器提供点击播放；仓库 MP4 用于高清下载。更新成片时生成小于 10MB 的 H.264 播放版并重新上传附件，同时替换两版 README 链接，不能沿用旧片地址。

```bash
ffmpeg -i docs/promo/claudebar.mp4 -c:v libx264 -preset fast -crf 26 -pix_fmt yuv420p -movflags +faststart -an .build/promo/readme.mp4
```

可通过 GitHub Markdown 编辑器上传附件，不必创建 Issue 或提交临时网页编辑。播放器位于 `http://127.0.0.1:8808/docs/promo/film.html`；验证桌面 / 手机布局、字幕、章节和字节 Range。实际检查结果记录在 DESIGN.md，未做的检查不得标记完成。

本仓库的可复用制作技能见 [product-promo-film](../../skills/product-promo-film/SKILL.md)。
