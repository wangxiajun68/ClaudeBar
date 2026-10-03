# 低负载、滚动与动效性能审查 · 2026-09-30

本轮基于当前工作区，保留开始前的未提交变更。目标是让桌面工具在不可见时停止无消费方的工作，在交互时减少主线程竞争，同时保留现有外观和动效。

## 完成的修复

| 路径 | 问题 | 改动与验证 |
| --- | --- | --- |
| 资源采样 | 隐藏窗口仍保留 hosting view 与采样 scope，`wantsAttribution` 可阻止 timer suspend | `ProcessSampler.applyPeriod` 在无可见窗口时直接暂停；页面 scope 跟随所属 surface 可见性；生产调度方法的夹具验证 suspend/resume 平衡，恢复后保留 1/2 秒档位 |
| 风扇监视 | 隐藏后 2 秒 timer 仍唤醒；没有读数时仍可能触发读取 | 隐藏时撤销 timer，可见且仍有订阅者时恢复并立即刷新；多读者引用计数保留，timer 增加 250 ms tolerance；夹具不调用真实 SMC |
| 滚动门 | 全局布尔值被其他滚动视图 idle/disappear 覆盖；旧 idle/watchdog 可在新手势中释放；disappear 不主动 flush | 每个滚动视图拥有 UUID；只在最后一个 owner 释放后提交，watchdog 可取消且带 generation；期限从本次连续滚动开始计时，阶段转换不重新延长；hover 也服从 4 秒失联期限 |
| 装饰、能源流、读数扫光、风扇旋翼 | 懒容器保留的屏外组件仍可播放；部分原生图层缺少自己的遮挡/拆卸处理 | 增加组件局部 scroll visibility，跨越视口边界才更新；能源流与旋翼自行观察所属窗口遮挡，拆卸时暂停/移除动画；读数扫光脱离窗口时停止；可见时仍用 Core Animation 插值 |
| 问候时钟与天气回退 | 窗口可见但组件已经滚出视口时，周期/动画时间线仍工作 | 组件局部可见性停止时钟 schedule，暂停 Canvas 天气回退；Metal 天空已有 page scroll hold，保留 |
| 原始 JSON/SSE | detached 任务未收到取消；先解码全部事件，再截最后 400 条；先尝试把整段 SSE 当 JSON 解码 | 取消传播到 worker，在行/节点间检查；环形尾缓存；逐行扫描；只解码最终 400 条，实时 assembler 默认仍解码每条事件 |
| Skill Markdown 预览 | 关闭/切换后仍解析、可发布旧结果；纯解析函数带隐式 main actor 隔离 | 取消传播、解析循环检查取消、发布前校验；解析函数显式 `nonisolated`，文件大小上限保留 |

滚动门用于合并已有数据发布。它仍保持原有最长 4 秒延迟预算，未把页面交互、Core Animation 或系统显示刷新率降到数据采样率。

## 逐页检查结论

| 页面/端 | 重点检查 | 本轮结论 |
| --- | --- | --- |
| 概览 | 问候天空/时钟、资源条、能源流、会话摘要 | 修复不可见采样与组件播放；GPU 实测见下；天空纹理栅格化已有后台串行队列 |
| 会话 | 会话网格、展开、agent swarm、负载标签 | 保留懒网格、树缓存、展示上限；使用修复后的滚动门和可见性 scope |
| 用量 | 周期查询、统计图、热图、来源/模型卡 | 聚合已有后台计算与旧结果检查，热图为 Canvas；保留这些实现，未加入每帧重新聚合 |
| 模型/供应商 | 目录搜索、分组宫格、按钮/图标、导入与编辑 | 保留懒分组、图标/路径缓存和原生阴影；异步网络操作与事件驱动动效保留 |
| 流量 | catalog、流式内容、会话解析、原始 JSON、日志 | 既有批量 throttle/后台会话转换保留；修复 JSON/SSE 尾解析与取消 |
| VPN | 节点、订阅、速率、域名明细/汇总/连接 | 速率与节点已有独立观察；日志有界缓冲、后台查询与取消检查保留；未启动内核或做系统网络测试 |
| 设置 | 状态所有权、分类、权限、终端查询 | 父窗口已用 `StateObject` 持有 `SettingsState` 并传入子视图，保持原实现；没有证据支持再重构状态模型 |
| 帮助 | 分类、搜索、滚动、说明弹层 | 保留按输入更新和懒容器，使用修复后的滚动门 |
| 连接器/详情 | 扫描、筛选、详情、Markdown、工具发现 | 网格已有虚拟化、扫描已有后台路径；修复 Markdown 取消与隔离 |
| Popup | 根订阅、KPI、会话/用量面板、toast | 根字段订阅与关闭销毁已有；旋翼生命周期修复，资源监视共享订阅者不互相停止 |
| 灵动岛 | alert/展开/收起、相对时间、原生装饰 | 收起会停止 100 ms 交互 timer；用量刷新单飞；装饰使用改进后的原生组件；30 秒相对时间保留 |
| Widget | 快照写入、去重、timeline | 已有后台串行写入与忽略时间戳去重，保留；身份/签名随两版构建检查 |

必要的后台功能没有按 UI 生命周期停用：会话完成/等待通知、运行中的代理服务与正式版 VPN 故障切换仍需要服务自己的消费方。资源遥测、装饰播放和解析预览属于可停止的 UI 工作。

## 可复现的测量

### SSE：生产解析函数，合成数据，不读用户流量

命令：`.venv/bin/python Tests/interaction-performance-regressions.py --compare`。

输入为 30,000 个 SSE 事件，每个包含 512 字节字符串。使用 `swiftc -O`；旧版 JSON 解析取自本轮修改前相同的 HEAD 文件。每臂独立进程 3 次，均返回最后 400 条并报告 29,600 条截断。

| 指标 | 原实现 | 优化后 |
| --- | --- | --- |
| 解析耗时 3 次 | 322 / 305 / 305 ms | 80 / 72 / 74 ms |
| 中位耗时 | 305 ms | 74 ms（约下降 76%） |
| 进程峰值 RSS 3 次 | 113.2 / 113.8 / 113.8 MiB | 63.5 / 63.5 / 63.4 MiB |

RSS 包括输入构造与 Swift/Foundation 运行时，不是解析器单独占用。保留尾事件为 O(400)，但原始输入字符串仍需存在；单个事件大小不受事件数量上限约束。Foundation 单次 JSON 解码不能在内部取消，取消检查位于其前后及节点/行之间。

### Metal 天空：现有引擎，不是本轮 FPS 提升数据

命令：`python3 Tools/bench-atmosphere.py --frames 120`。

Apple M3 Pro，1100×474 pt 卡片，2200×948 px，11 种日间/夜间/降水场景。每场景预热 10 帧，再计 120 帧；指标为各场景中位数。

| 指标 | 各场景范围 |
| --- | --- |
| GPU：同时刷新云层的帧 | 0.24–0.40 ms |
| GPU：仅合成前景的帧 | 0.17–0.30 ms |
| CPU：帧编码 | 8.2–12.7 µs |
| 问候纹理栅格化 | 6.868 ms，生产 live 路径已有后台 raster queue |
| 首次字体/文案布局样本 | 5.922 ms；缓存布局接近量具的显示精度下限 |

这组结果没有支持重写 Metal 引擎或加入新渲染依赖的依据。量具为离屏提交并逐帧等待 GPU，不能代表窗口合成竞争、滚动 hitch 或持续功耗。

## 回归与交付验证

新增 `interaction-performance` 组登记在 `Makefile`，CI 继续使用同一清单。生产函数/图层夹具覆盖：

- 隐藏时资源 timer 暂停，重复暂停不失衡；恢复到正常采样档位。
- 风扇多读者、隐藏/恢复、最后读者离开，不访问 SMC。
- 1000 次数据发布合并为最后一次；多 owner、旧 idle、新手势、丢失 idle 期限。
- SSE 空流、400 条边界、环形回绕、CRLF、多行事件、中文/emoji/字符串内 Unicode 换行字符、末尾 DONE、JSON 数组上限与文本回退。
- 默认 assembler 保留逐事件解码；Inspector 尾事件仍有完整 JSON 节点。
- JSON 与 Markdown worker 取消；Markdown 基本文案/代码块不变。
- 原生能源流/旋翼遮挡、detach、恢复时相位连续；1000 次相同更新不重建能源图层。

`fan-rotor`、`rendering`、`machine-mark` 与 `inflight-animation` 继续验证像素、图层稳定性及高频读数不持有连续 SwiftUI 动画事务（2026-10-02 又新增 `widget-tint`、`icon-minimal`）。

最终执行 `make test`、`make build`、`make release`。构建只输出 dev/release 包，不安装或启动正式版；包身份、Widget、URL scheme、entitlements 与签名由构建门禁校验。本次审查时本地正式版构建还是 ad-hoc 签名；此后本地构建（两个版本）改为使用 `ClaudeBar Dev` 自签身份以稳定 TCC，不再是审查时的签名形态，也不是发行公证产物。

## 验收边界

本轮是全视图文件静态扫描、重点路径代码复核、生产切片回归和离屏 CPU/GPU 测量。**没有完成全页面 60/120 Hz 实机滚动、动画 hitch、整机能耗或全应用空闲 CPU 的前后对照**；本机只有 Command Line Tools，`xctrace` 不可用。不能把这些结果表述成“所有页面恒定 120 FPS”或“已测得空闲 CPU 为零”。

组件可见性修复通过 SDK 编译和原生层夹具验证；SwiftUI 的视口回调在实际多窗口、快速滚动和 Reduce Motion 场景下的触发时机仍需实机帧测。历史性能文档里的 FPS 是此前构建数据，不作为本轮测量引用。

## 组件静态扫描清单

以下是该轮审查时按 `git ls-tree` 记下的 96 个文件中的 95 个；2026-10-02 删除 `Shared/ConnectivityProbeButton.swift` 后本表同步删行（其组件仍在别处使用，本表已不再逐文件枚举）。标记只列出命中的持续调度、后台任务、原生桥接和观察订阅入口；空标记不代表组件运行耗时已被证明为零。所有文件都检查了这些入口及滚动/状态更新信号，重点命中路径的结果见上文。此后新增的视图（飞书文档与表格编辑、会话状态视图等）未再逐个补入本表。

| 文件（相对于 Views） | 静态检查标记 |
| --- | --- |
| `Island/IslandComponents.swift` | 持续调度 |
| `Island/IslandShape.swift` | 输入/事件更新路径 |
| `Island/NotchIslandView.swift` | 观察订阅 |
| `MainWindowView.swift` | 原生桥接 |
| `MenuBarView.swift` | 异步任务 |
| `Pages/ConnectorDetailSheet.swift` | 异步任务 |
| `Pages/ConnectorsView.swift` | 观察订阅 |
| `Pages/CursorTokenUsageCard.swift` | 异步任务、观察订阅 |
| `Pages/DashboardView.swift` | 输入/事件更新路径 |
| `Pages/HelpView.swift` | 输入/事件更新路径 |
| `Pages/ProvidersView.swift` | 观察订阅 |
| `Pages/ProxyLogView.swift` | 观察订阅 |
| `Pages/SessionsView.swift` | 输入/事件更新路径 |
| `Pages/SettingsView.swift` | 观察订阅 |
| `Pages/TrafficView.swift` | 异步任务、观察订阅 |
| `Pages/UsageView.swift` | 观察订阅 |
| `Pages/VPNSubscriptionSection.swift` | 观察订阅 |
| `Pages/VPNView.swift` | 观察订阅 |
| `Pages/VpnDomainLogSection.swift` | 异步任务、观察订阅 |
| `Popup/PanelHeader.swift` | 观察订阅 |
| `Popup/PanelState.swift` | 输入/事件更新路径 |
| `Popup/SessionsPanel.swift` | 输入/事件更新路径 |
| `Popup/UsagePanel.swift` | 输入/事件更新路径 |
| `Shared/APIKeyField.swift` | 输入/事件更新路径 |
| `Shared/AgentSwarmView.swift` | 输入/事件更新路径 |
| `Shared/Atmosphere/AtmosphereRenderer.swift` | 输入/事件更新路径 |
| `Shared/Atmosphere/AtmosphereShader.swift` | 输入/事件更新路径 |
| `Shared/Atmosphere/AtmosphereView.swift` | 原生桥接 |
| `Shared/Atmosphere/GreetingScript.swift` | 输入/事件更新路径 |
| `Shared/Atmosphere/SkyScene.swift` | 输入/事件更新路径 |
| `Shared/BatteryChargeControls.swift` | 输入/事件更新路径 |
| `Shared/BrandMark.swift` | 输入/事件更新路径 |
| `Shared/CodeBlock.swift` | 输入/事件更新路径 |
| `Shared/CodexModelMark.swift` | 输入/事件更新路径 |
| `Shared/CodexQuotaGauges.swift` | 输入/事件更新路径 |
| `Shared/CommandPalette.swift` | 输入/事件更新路径 |
| `Shared/ConnectionCard.swift` | 输入/事件更新路径 |
| `Shared/ContextBar.swift` | 输入/事件更新路径 |
| `Shared/CursorSessionCardView.swift` | 输入/事件更新路径 |
| `Shared/DecorativeMotion.swift` | 原生桥接 |
| `Shared/DiskUsagePanel.swift` | 输入/事件更新路径 |
| `Shared/ExchangeRateTile.swift` | 观察订阅 |
| `Shared/ExternalSessionCardView.swift` | 输入/事件更新路径 |
| `Shared/FanInternalsPanel.swift` | 输入/事件更新路径 |
| `Shared/FeedbackToast.swift` | 输入/事件更新路径 |
| `Shared/GlassCard.swift` | 输入/事件更新路径 |
| `Shared/GreetingCard.swift` | 持续调度、异步任务、观察订阅 |
| `Shared/GreetingInstruments.swift` | 输入/事件更新路径 |
| `Shared/HardwareDetailPanel.swift` | 异步任务、观察订阅 |
| `Shared/HardwareIllustration.swift` | 原生桥接 |
| `Shared/HeartbeatSparkline.swift` | 输入/事件更新路径 |
| `Shared/HelpCatalog.swift` | 输入/事件更新路径 |
| `Shared/InstrumentControls.swift` | 异步任务 |
| `Shared/InstrumentGlyph.swift` | 输入/事件更新路径 |
| `Shared/InstrumentSearchField.swift` | 输入/事件更新路径 |
| `Shared/InstrumentWidgets.swift` | 输入/事件更新路径 |
| `Shared/Interaction.swift` | 输入/事件更新路径 |
| `Shared/JSONTreeView.swift` | 异步任务、观察订阅 |
| `Shared/LucideHardwareGeometry.swift` | 输入/事件更新路径 |
| `Shared/LucideHardwarePaths.swift` | 输入/事件更新路径 |
| `Shared/LucideRotor.swift` | 原生桥接 |
| `Shared/MachineKpiStrip.swift` | 输入/事件更新路径 |
| `Shared/MemoryDetailPanel.swift` | 异步任务 |
| `Shared/ModelImportSheet.swift` | 输入/事件更新路径 |
| `Shared/ModelPriceCard.swift` | 观察订阅 |
| `Shared/PermissionsSection.swift` | 观察订阅 |
| `Shared/PlainDumpView.swift` | 原生桥接 |
| `Shared/PowerFlowCard.swift` | 原生桥接 |
| `Shared/ProductBrandMark.swift` | 输入/事件更新路径 |
| `Shared/ProviderConnectionEditor.swift` | 输入/事件更新路径 |
| `Shared/ProviderControls.swift` | 输入/事件更新路径 |
| `Shared/ProviderDirectory.swift` | 输入/事件更新路径 |
| `Shared/ProviderModelFetchButton.swift` | 输入/事件更新路径 |
| `Shared/ProviderQuickSetup.swift` | 输入/事件更新路径 |
| `Shared/ProxyCurlExample.swift` | 输入/事件更新路径 |
| `Shared/ProxyUpstreamPickers.swift` | 观察订阅 |
| `Shared/ResourceStrip.swift` | 输入/事件更新路径 |
| `Shared/SectionHeader.swift` | 输入/事件更新路径 |
| `Shared/SessionCardView.swift` | 输入/事件更新路径 |
| `Shared/SettingsControls.swift` | 输入/事件更新路径 |
| `Shared/SignatureGlyph.swift` | 输入/事件更新路径 |
| `Shared/SkillMarkdownPreview.swift` | 异步任务 |
| `Shared/SourceRing.swift` | 输入/事件更新路径 |
| `Shared/StandbyEmptyState.swift` | 输入/事件更新路径 |
| `Shared/Tile.swift` | 原生桥接 |
| `Shared/UiverseKit.swift` | 输入/事件更新路径 |
| `Shared/UiverseSurfaces.swift` | 输入/事件更新路径 |
| `Shared/UsageAnalytics.swift` | 异步任务 |
| `Shared/UsageHeatmap.swift` | 输入/事件更新路径 |
| `Shared/UsageModelCard.swift` | 观察订阅 |
| `Shared/UsageViz.swift` | 输入/事件更新路径 |
| `Shared/VPNSurface.swift` | 输入/事件更新路径 |
| `Shared/VpnTopChrome.swift` | 观察订阅 |
| `Shared/WeatherBackdrop.swift` | 持续调度 |
| `Shared/WeatherReadingSky.swift` | 输入/事件更新路径 |
