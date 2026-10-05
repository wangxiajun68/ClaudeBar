# 全模块性能与帧工作复核 · 2026-10-05

本轮从 `a5e9688` 继续审查页面更新、重复绘制和后台统计，修改三个生产文件，修复热图绘制、流量记录缓存及重复 KDE 计算。对正在运行的正式版 1.15.0 做了一轮九页导航的 SwiftUI Instruments 采样；新代码使用合成生产源码探针对照，没有安装到正式版。

[测量、源码哈希与验证 JSON](performance-frame-audit-2026-10-05.json)记录两类证据的范围。[244 个源码入口清单](performance-frame-source-2026-10-05.md)及[逐文件哈希](performance-frame-source-2026-10-05.json)覆盖 Swift、Widget 符号链接、原生辅助工具和构建脚本。入口扫描用于避免遗漏模块，不代表每个文件都已做运行测量。

## 苹果依据与代码修复

苹果建议减少无关的 SwiftUI 更新，将昂贵派生工作移出 body，并让视图更新及时完成。[SwiftUI 性能文档](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)。绘制过程中反复计算不变的数据会增加 CPU 工作，应该准备并复用结果。[渲染效率](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)。后台统计仍消耗共享 CPU；需要在保留正确性的前提下减少计算。[响应性](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)。

| 生产路径 | 原问题 | 修改与验证 |
| --- | --- | --- |
| `UsageHeatmap.contributionGrid` | Canvas 每次绘制逐格做 Calendar 加日、日期分量提取和日期键格式化。七年样本一次 2,557 次，120 次绘制累计 306,840 次。 | 在 GeometryReader 的布局准备阶段生成矩形、强度和 padding 标志；Canvas 只创建路径和填色。保持缺失用量与边缘 padding 的不同颜色。两组图片数据 SHA-256 与基线一致。首次准备成本仍存在。 |
| 热图悬停 | hoveredDate 属于整个 UsageHeatmap，移动到新日期会使父视图重新派生字典、峰值与布局数据。 | 状态移入局部 ViewModifier，只有日期变化才发布；周期或参考日期变化清空 tooltip。保持提示、下钻和无障碍汇总。跨 UTC、纽约 DST、Apia、两种周起始日及紧凑/普通布局的真实点击定位通过；未测量实际 pointer 动作的更新次数。 |
| `TrafficView` 过滤缓存 | 缓存的是 CaptureSummary 值副本；过滤 stamp 不含 state、Token、时长，所以状态变化后缓存仍显示 streaming/pending。列表继续选择 TrafficLiveRow 分支。 | 过滤输入不变时，按已匹配 ID 从最新记录更新值副本，不重复 lowercased 搜索。搜索字段变化仍完整过滤。测试中 120 个过期流式候选降到 0，完成 Token 同步；保持选择、删除后的选择补位和顺序。该计数不是实机观察者或 CPU 测量。 |
| 流量 catalog 回调 | 主队列延迟回调可能在页面拆卸、再次挂载后发布旧一轮更新。 | 捕获 loadGen，执行时同时检查 mounted 与代次。排队后离开的生产回调回归通过；原有 live-stream 回调保护保留。 |
| `UsageAnalysis` KDE | 同一个 Token 总量在 96 个采样位置重复计算相同的反射高斯核。 | 在已排序数据的 ECDF 扫描中记录每个值的出现次数，核值按次数加权。保留带宽、归一化、分位数与所有观测权重。逐点对照冻结的原实现；最大绝对误差 1.11e-15，在相对 1e-12 / 绝对 1e-15 的容差内。 |

没有改变业务刷新间隔、Token 归属、统计样本、动效品质、配置或系统集成入口；没有新增常驻服务或另一套 UI 架构。

## 固定工作量对照

机器为 Apple M3 Pro，macOS 26.6.2；使用匹配的 Command Line Tools Swift 6.3.2，`-O -g`，arm64/macOS 15。基线和修改后各一次进程运行，每组热图绘制 120 次、完整分析 10 次；耗时仅作诊断，没有作为 CI 阈值或随机多轮统计结论。

| 测量 | 基线 | 修改后 |
| --- | ---: | ---: |
| 366 天热图绘制闭包 CPU 中位耗时 | 0.949 ms | 0.040 ms |
| 2,557 天热图绘制闭包 CPU 中位耗时 | 6.677 ms | 0.234 ms |
| 120 次七年绘制的日期键计算次数 | 306,840 | 0 |
| 366 / 2,557 天的额外一次布局准备 | — | 0.993 / 6.806 ms |
| 2,000 天、三种总量的 KDE 部分中位耗时 | 0.842 ms | 0.003 ms |
| 2,000 天、30 种总量的 KDE 部分中位耗时 | 0.856 ms | 0.015 ms |
| 2,000 天、全部不同总量的 KDE 部分中位耗时 | 0.841 ms | 0.909 ms |

热图探针执行真实 Canvas 闭包中的路径/颜色代码，计时阶段不做 GPU 提交或图片栅格化。布局准备只计一次，真实父视图输入或尺寸变化仍会再次准备；不能把 0.234ms 当作整页 body 或首帧耗时。新数组会保留准备数据，未证明内存降低。另用 CGContext 执行原闭包的完整填色，比对固定尺寸图片；不是整个窗口的视觉验收。

完整统计仍约 38–40ms，以日期解析等工作为主。三种总量样本完整耗时为 38.294 / 38.622ms，没有观察到有意义的整段提速。全部不同的值不会节省核计算，反而存在加权及新数组的成本；本轮保留这个测量，不把局部核函数的收益推广到完整统计或页面帧率。

Time Profiler 另执行同样的两组热图，每组固定 1,500 次绘制。主线程 sampled CPU 权重从 **11,250ms 降到 448ms**；Foundation inclusive 从 9,734ms 到 18ms。基线 self 热点包括 CFString 格式化和 Calendar 分量；修改后主要是路径、内存和 SwiftUI 值操作。两臂均包含启动、布局准备和每组一次图片栅格化，录制时机器还有其他工作。inclusive 值有重叠，不可相加；采样不是精确函数耗时、实际 FPS 或能耗。

## 正式版 Instruments 观察

附加正在运行的 `/Applications/ClaudeBar.app`，版本 1.15.0，执行文件 SHA-256 为 `fadf4b9451e647a381a4520d6663ae82b3fdef4481d41c3c7a6d0f9a4731069e`。SwiftUI 模板录制 90.870 秒，进行一次会话、模型、连接器、用量、流量、VPN、设置、帮助、概览导航；有滚动区域时滚动一次，最后恢复概览顶部。其余时间主要在概览。没有展开所有详情、所有设置分类或每种动效状态。

- 观测到 **135 种项目视图、4,387 次项目 body 更新**；累计 body duration 100.752ms，有 9 次超过 1ms。嵌套更新可能重叠，不能视为互斥 CPU 总时间。
- `SessionActionChips` 更新 117 次，中位 0.004ms、p95 0.035ms，最大一次 17.325ms；`TrafficView` 4 次，最大 7.781ms；`ConnectorsView` 3 次，最大 4.326ms；`VPNView` 7 次，最大 4.087ms。最长事件主要是一次较慢更新，需要重复冷/暖切换归因，不能仅凭单次冷初始化重写界面。
- hitches 表有 367 行，p50 8.333ms、p95 30.832ms、最大 416.666ms；115 行标记潜在昂贵应用更新。保留原表口径，没有将事件行数、frame lifetime 或任意 duration 换算为 FPS、掉帧率或 hitch ratio。[Apple hitch 定义](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)。
- sampled CPU 权重约 40,919.9ms，主线程 26,204.3ms。项目第一帧归因中约 25,003.4ms 只有 main，13,251.8ms 是地址，183.8ms 有业务符号。正式版构建会 strip，不能用这些地址推断具体业务函数。框架 self 以 AttributeGraph 更新为首；还需要带符号、可复现动作的独立录制。

SwiftUI Cause Graph 与 100μs 采样本身有开销，后台业务和其他 App 继续运行；这是一次探索性测量，不是常态 CPU 基线。部分概览子树没有以对应源码类型名出现在汇总，不能据此认定成本为零。正式版数据与新代码的合成对照是两种证据；尚无安装新代码后的整窗口前后帧率对照。

## 全模块复核范围

以下把本轮入口检查、已有优化和未测场景放在同一清单；不重复将前轮结果记为本轮测量。此前的逐模块审查见[全模块报告](apple-remaining-performance-audit-2026-10-04.md)、[正式版测量](apple-release-performance-audit-2026-10-04.md)、[原生详情](apple-native-detail-performance-2026-10-05.md)和[天气概览](apple-weather-overview-performance-2026-10-05.md)。

| 模块 | 本轮复核与沿用策略 | 运行测量边界 |
| --- | --- | --- |
| 主窗口/导航 | 九页真实导航；保留按页面挂载、scoped observation 和滚动 hover gate。 | 没有全窗口尺寸/外观组合或连续快速切页对照。 |
| 概览/天气 | 复核上一轮后台静态天空、过期纹理丢弃、可见性绘制闸和六条会话提前截取。 | 本轮主要静止/短滚动；天气场景 GPU 与像素对照属于上一轮。 |
| 资源、音频、风扇、能源流 | 复核可见性订阅、详情 ProcessSampler scope 和原生层复用；相关全回归通过。 | 没有操作硬件，未做长期资源轮询与能耗测量。 |
| 会话/子代理/迁移 | LazyVStack、缓存树派生、受限回溯和等待状态保护保留；复核首次操作控件构建。 | 真实导航只覆盖当前清单；未执行迁移、终端恢复或千会话滚动。 |
| 模型/供应商 | 保留后台模型库存、空查询快路径、批次查询合并；导航看到首次构建成本。 | 未编辑凭据、发真实模型请求或验证巨大配置清单的整页 FPS。 |
| 连接器/插件/MCP/本地 CLI | 复核单次过滤输入、缓存计数、扫描后台化和插件预览后台读取。 | 当前目录的浏览观测；未修改外部连接器或执行启停 CLI。 |
| Markdown/飞书组件 | 复核 512KB 限制、后台解析、取消、搜索 debounce 与已准备预览；组件回归通过。 | 本轮未联网操作飞书，也未打开每种文档/表格详情。 |
| 用量/价格/配额 | 本轮修改热图与 KDE；后台库存、归属、索引缓存和取消保护保留。同步价格缓存读取是初始化路径，未凭扫描标记改写。 | 合成数据覆盖大历史；真实用量页只做导航/滚动，未测所有时间窗和拖动。 |
| 流量/会话转录/日志 | 本轮修复缓存副本与 catalog 生命周期；后台转录、有限队尾读取、10Hz live 合并保留。 | 没有产生真实请求或重放账号流量；回归直接执行生产回调。 |
| VPN/订阅/探测 | 复核 capped history 图、后台等待、探测代次和全回归中的隔离策略。 | 只浏览页面；未切换 VPN、代理、DNS、TUN 或触发正式控制测试。 |
| 设置/权限/登录项 | 六分类源码与显式副作用入口边界保留；正式导航只显示当前分类。 | 未修改设置、请求权限或操作登录项；不是六分类全部交互测量。 |
| 帮助 | 静态目录、已缓存查询、LazyVStack 保留；当前内容量小，没有未经测量增加章节缓存。 | 真实导航一次；未逐篇搜索/阅读测量。 |
| 菜单栏/弹窗/灵动岛/提醒 | scoped invalidation、去重、翼栏周期条件与原生动画生命周期回归通过。 | 本轮没有展开所有弹窗或触发真实提醒；不能继承主窗口 FPS 结论。 |
| 共享控件/Theme/原生绘制 | 热图局部状态；DecorativeMotion 保持层和尺寸/颜色缓存。七种原生效果各 1,000 次稳定更新、隐藏/拆卸停止动画的生产回归通过。 | 隔离生命周期验证不是每个动效的实际显示帧率矩阵。 |
| Widget/持久化/版本/构建/辅助工具 | 源码入口与 72 组回归覆盖快照兼容、JSON/SQLite、文件权限、版本身份和副作用闸；不调整安全 watchdog 节奏。 | 无 Widget 系统时间线压力、真实辅助工具控制或长时间泄漏测量。 |

## 验证与复现

- 全回归 **72 组通过，356.60 秒**；定向 frame-work-performance、usage-analysis、remaining-lifecycle、rendering 四组通过，22.47 秒。
- 最后补充流量排序、终止错误与拆卸后再挂载的回归，frame-work-performance 再次通过，10.38 秒；生产代码保持全回归与双构建时的版本。
- dev / release 构建通过，宿主/Widget 身份、URL scheme、App Group、entitlements 与签名门禁通过；WidgetSnapshot 符号链接保持正确。仅构建，未安装。
- Python 编译和 `git diff --check` 通过。测试执行生产算法/回调，用冻结原算法校验统计结果，没有启动 App、真实 VPN 或写硬件。
- 原 trace、源码探针和日志只保存在 gitignored 的 `.build/performance/frame-audit-2026-10-05/`，目录 0700。导出元数据的进程环境字段已移除；公开报告只保留合成输入结果、视图名和聚合数值。可重新导出的巨大临时 XML 在汇总后清理。
- 正式版 PID 与执行文件哈希保持原值，最后停留概览顶部。本轮没有安装、重启或退出正式版；没有修改用户配置、凭据、系统权限或网络控制。

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools make test TEST="frame-work-performance usage-analysis remaining-lifecycle rendering"
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 Tests/frame-work-performance-regressions.py \
  --baseline-ref a5e9688 --probe --output-json /tmp/claudebar-frame-before.json
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 Tests/frame-work-performance-regressions.py \
  --output-json /tmp/claudebar-frame-after.json
```
