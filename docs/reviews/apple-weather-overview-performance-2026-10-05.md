# 概览与天气卡片性能审查 · 2026-10-05

本轮以源码基线 `7c20c82` 深查概览页，重点覆盖天气卡的数据刷新、仪表布局、时钟、时间拖动、文字栅格化、Metal 绘制和 Reduce Motion 静态天空。修改三个生产文件，完成四项优化；同时校准 GPU 量具。14 个复核源码入口的哈希、生产探针对照和 Instruments 聚合数据见[测量 JSON](performance-weather-overview-audit-2026-10-05.json)。探针使用合成数据与不可见窗口，没有启动或替换已安装的正式版。

## 苹果依据与本轮修复

苹果建议将昂贵计算移出 SwiftUI body，异步完成并缓存结果；视图更新需要及时完成，才能避免拖延显示帧。[SwiftUI 性能文档](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)。本轮的静态天空原来直接在 body 内等待 GPU、回读图片，符合这个具体问题。单纯把工作包进 Task 仍可能继承主 actor；新的实现明确使用 Dispatch 工作队列。[改善响应性](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)。

`MTKView` 的暂停循环与事件驱动绘制是不同配置；`isPaused` 和 `enableSetNeedsDisplay` 同时为 true 时仍会响应 redraw。因此停用后请求 `needsDisplay`，或接收之前排队的绘制通知，都不能仅靠暂停标志防止 GPU 工作。[MTKView 绘制模式](https://developer.apple.com/documentation/metalkit/mtkview)、[enableSetNeedsDisplay](https://developer.apple.com/documentation/metalkit/mtkview/enablesetneedsdisplay)。

| 生产路径 | 复现的问题 | 修改与验证 |
| --- | --- | --- |
| `AtmosphereMTKView.retime/kick/draw` | 停用仍请求一次 redraw；draw 没有重新判断可见性，暂停、滚动定帧、遮挡或拆卸后仍可能获取 drawable。 | 停用不再请求 redraw；kick 与 draw 检查 active、窗口可见性、held 和 Reduce Motion。六种阻止绘制的状态均不再请求 redraw 或获取 render pass，恢复可见且 active 时仍进入绘制。 |
| `AtmosphereStill/StillCache` | Reduce Motion 在 GeometryReader/body 内同步 snapshot，包含 GPU 完成等待与像素回读。 | 按输入、尺寸、scale 和 active 驱动 task；串行后台队列独占并复用 renderer，主 actor 只发布最新未取消结果。保留上一张有效图，取消排队尺寸，失败允许重试。同步 ImageRenderer 工具路径保留。 |
| `AtmosphereRenderer.finishRasterizing` | 连续调整尺寸时，旧任务完成后先安装旧纹理、通知视图，再处理最新请求，可能短暂闪回旧布局或触发多余重写。 | 只安装仍匹配最新请求的纹理；旧结果直接转入最新任务，不通知视图。生产完成方法的控制夹具在基线确认旧结果会发布，修改后确认不会。 |
| `DashboardView.overviewRows` | 全部会话先格式化、拼接，再截取六条；大量隐藏会话仍执行标题处理。 | Claude 的 alive 筛选使用 lazy，并在 map 前按剩余名额截取三种来源；溢出按钮独立使用完整计数。36 组混合来源与等待状态回归保留排序、字段、计数及负载标识。 |

## 测量结果与适用范围

机器为 Apple M3 Pro，macOS 26.6.2；探针使用匹配的 Command Line Tools Swift 6.3.2，`-O`、arm64/macOS 15。没有修改系统工具链配置。Xcode 27 Instruments 单独用于记录和导出。

| 测量 | 基线 | 修改后 |
| --- | ---: | ---: |
| 六种暂停/隐藏状态，主动调用 kick 与 draw 后的 redraw 请求、render pass 获取 | 每种各 1 次 | 每种均 0 次 |
| 10,000 条合成 Claude 会话的行派生，中位耗时，20 次 | 80.314 ms | 0.048 ms |
| 每次格式化的概览会话数 | 10,000 | 6 |
| Time Profiler：snapshot 主线程 inclusive 采样 | 828 | 0 |
| Time Profiler：snapshot 后台 inclusive 采样 | 0 | 850 |
| 11 种场景 × 两种宽度，固定时刻图片哈希一致 | — | 22 / 22 |

会话基准执行真实 overviewRows 和 SessionTitle.condense，字段由合成模型提供；它只计行派生，未包含完整 body、计数、滚动和 WindowServer 合成。并非整页速度提升倍数。正常会话数较少时，绝对收益也会较小。耗时没有作为 CI 阈值。

宽版同步快照的第一轮中位耗时 **8.333 ms**；最终基线复测 **8.175 ms**。保留的同步预览路径复测 **8.031 ms**。优化把这段等待移出实际卡片的主线程，没有把 GPU 总工作量变成零，也没有将后台总耗时称为页面更新耗时。

Instruments 启动的是同一生产源码的隔离探针，每臂执行 180 次宽度在 1100–1102pt 间变化的静态渲染、间隔 20ms；profile 模式不执行同步预览测量。两次记录正常退出，基线录制 **7.251 秒**、修改后 **6.948 秒**。总采样分别 1,050 / 1,052；主线程分别 902 / 58；缺失 backtrace 分别 7 / 8。snapshot 函数在修改后只出现于后台工作栈。inclusive 样本重叠，Running-thread 采样不等于 GPU 等待时长，也不能换算为真实帧率或能耗。

## GPU、布局与视觉检查

旧量具沿用了旧卡片高度、底部留白和仪表尺寸。本轮直接提取 `GreetingStatusSheet.Metrics`；宽版真实尺寸 **1100 × 474pt**、窄版 **620 × 436pt**，scale 2。小时预报也加入取样区域；METRICS 输出逐场景耗时、帧数和固定时刻图片 SHA-256。用 `--baseline-ref` 编译基线时，同样从基线 Metrics 提取几何，避免将不同布局当成性能变化。

每场景先暖机十帧，再统计 90 帧；两臂按宽度顺序运行。下表是各场景 GPU 中位数的范围：

| 尺寸 | 通道 | 基线 | 修改后 |
| --- | --- | ---: | ---: |
| 1100 × 474pt | 重绘天空并合成 | 0.237–0.417 ms | 0.241–0.510 ms |
| 1100 × 474pt | 只采样天空并合成前景 | 0.174–0.319 ms | 0.175–0.319 ms |
| 620 × 436pt | 重绘天空并合成 | 0.132–0.274 ms | 0.130–0.287 ms |
| 620 × 436pt | 只采样天空并合成前景 | 0.084–0.156 ms | 0.085–0.155 ms |

雷雨 live 路径使用 SystemRandomNumberGenerator 选择云内闪光或落地闪电；两臂的闪电形态不是同输入，本次宽版雷雨天空中位数为 0.417 / 0.510 ms，不能据此判定着色器回归或改善。其他天空和前景基本保持原成本，本轮没有修改着色器。固定时刻 snapshot 使用确定效果，两宽度全部 22 张图片逐像素数据哈希一致；另一个合成雨天验证 live 异步图片与同步预览图片哈希一致。

天气预览工具成功生成宽/窄、自动/手动合成卡片；抽查宽版浅色雨天、窄版深色雷雨，问候、姓名、小时图、日轨、每日预报与底栏未见布局变化。已有 5,300 组布局、墨色选择和太阳事件回归通过。本轮没有执行全场景 contrast 门槛，也未把预览抽查称为全面无障碍验收。

## 其他概览路径的复核

| 路径 | 已有策略与本轮结论 |
| --- | --- |
| 天气请求与预报 | WeatherStore 保持 15 分钟 stale 策略、单个 inflight 和变更后 rerun；GreetingCard 的循环 keyed 于可见性与天气渲染。保留业务刷新，不新增轮询；天气来源、缺失值与时区解析回归通过，没有请求真实服务。 |
| 场景与天文 | SkyScene.make / SkyAstronomy.snapshot 的隔离量具成本很小，太阳事件另有日期/时区/坐标缓存。未增加平行场景缓存。 |
| 时钟与仪表 | 时钟在独立子视图内 1Hz 更新，可见性控制 Timeline；分钟天空更新与小时/每日读数的 Unchanged 键分开。已有布局、日期优先级、DST、极昼极夜和风向回归通过。 |
| 手动时间与文字 | 离开时停止 rewinder/glider；字形轮廓与布局缓存保留。仅修复旧文字栅格化结果的发布，不改变拖动、笔迹或文字样式。 |
| Metal 动效 | 半分辨率云层、15/30Hz 静息档、交互 boost、低功耗/热压力降频及 pending 限流保留；加强最后的绘制入口。实际滚动、长时间 pointer、ProMotion、热压力下的显示帧率仍需单独实机场景。 |
| Canvas 回退 | 保持 surface/视口/Reduce Motion 暂停及低功耗帧率。此次实机有 Metal，没有刻意制造不可用环境，也未测量回退的滚动或热压力成本。 |
| 资源条 | 共享一次帮助文本；Fan/Audio 订阅随出现/离开管理，详情的 ProcessSampler scope 随可见性管理。相关 process-cpu、audio-accessory、interaction-performance 回归通过，没有调用硬件控制。 |
| 能源流 | 可见性与 Reduce Motion 管理原生动画；保留之前的增量几何/颜色缓存和相位。ui-animation-performance 回归通过，没有新增 UI 架构。 |

## 验证与复现

- 全回归 **71 组通过，334.00 秒**；新增天气卡与概览生产逻辑回归通过。
- `make build` / `make release` 成功；两版 bundle、执行文件、Widget、URL scheme、App Group、entitlements 和签名门禁通过，WidgetSnapshot 符号链接保持正确。两种构建均未安装。
- Python 编译和 `git diff --check` 通过。原始 trace、XML、生成源码和日志保存在 gitignored 的 `.build/performance/weather-audit-2026-10-05/`，目录 0700；公开文件只保存合成结果与聚合数据。
- 未退出、重启或替换正式 App；没有操作 VPN/代理/DNS/TUN、硬件、TCC 权限、真实账号或凭据。没有本轮已安装 App 的完整交互前后对照，也没有新内存泄漏、整窗口 FPS、hitch 或能耗测量结论。

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools make test TEST="weather-card-performance dashboard-performance greeting-layout weather-astronomy"
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 Tests/weather-card-performance-regressions.py \
  --probe --baseline-ref 7c20c82 --keep-fixture /tmp/claudebar-weather-before
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 Tests/dashboard-performance-regressions.py --baseline-ref 7c20c82
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 Tools/bench-atmosphere.py --width 1100 --frames 90
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 Tools/bench-atmosphere.py --width 1100 --frames 90 --baseline-ref 7c20c82
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 Tools/render-greeting-preview.py --weather-review
```

baseline 的 probe 模式会打印预期违规，供对照，不作为通过门禁；默认测试严格要求修复后的行为。GPU 工具数据只衡量已渲染帧的成本，后台收益来自避免隐藏帧与主线程等待。
