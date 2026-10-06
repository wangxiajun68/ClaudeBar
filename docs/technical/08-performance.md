# 性能与并发

> ClaudeBar 技术文档 · §8
> 相关：[状态中枢](03-provider-store.md) · [数据访问层](04-data-access-layer.md)

本模块定义采样、数据发布、滚动和动效的负载边界。业务状态见 [ProviderStore](03-provider-store.md)，天气引擎见 [天气与天空渲染](18-weather-and-atmosphere.md)。历史实验与机器读数见 [测量证据](../reviews/README.md)，不作为当前性能承诺。

## 可见性与采样生命周期

`UIWakePolicy` 汇总主窗口遮挡、最小化、关闭、popup 与灵动岛展开状态；视图通过 `surfaceIsVisible` 读取所属 surface 的可见性，视图树之外的读者用 `hasVisibleWindow`。组件还需检查局部滚动可见性，不能把 `onDisappear` 当作屏外检测：懒容器可能保留视图实例。

| 模块 | 消费方与调度边界 |
| --- | --- |
| 会话扫描 | `ProviderStore.startSessionPolling` 按可见性与忙闲选择档位（`AppConfig` 的 2.5 / 5 / 8 秒），扫描本身在后台任务执行。完成检测保留必要新鲜度（`completionFreshness` 60 秒）；漏拍由一次性补跑处理（`deferredPollRetry` 1.5 秒） |
| 额度 | `QuotaPollScheduler` 为 Codex 按 15 分钟心跳（`AppConfig.quotaPollInterval`）与已知重置时间安排请求，重置确认带 5 秒宽限；Cursor 额度按 `cursorQuotaPollInterval`（20 分钟）；都不跟随每次会话扫描重复查询 |
| 进程归因 | `ProcessSampler.applyPeriod` 在无可见窗口时暂停 timer；有归属需求时 live 1 秒、仅页面 scope 2 秒，无归属前台 6 秒、后台 12 秒，有归属但应用不在前台为 6 秒；页面 scope 跟随所属 surface，恢复时保留采样档位，suspend/resume 必须配对 |
| 风扇监视 | `FanMonitor` 保留读者引用计数；隐藏时撤销 timer，可见且有订阅者时立即刷新并恢复，2 秒 timer 使用 0.25 秒 tolerance 合并唤醒 |
| 用量扫描 | FSEvents 防抖合并（0.4 秒）后才重扫；解析与聚合在后台，索引按 mtime + size 增量复用，页面读取内存快照 |
| Widget | `WidgetSnapshotWriter` 仅在内容变化时写入与请求 timeline reload |

无消费方的装饰与硬件读取应停止；仍承担完成检测、业务连接或提醒职责的任务按各自契约降频。开发版的系统集成限制始终在副作用入口执行，不为测量绕过。

## 后台任务与数据发布

文件、网络、数据库查询、子进程等待和大文本解析离开主线程。UI 状态在 main actor 发布；切换对象或关闭预览时取消旧工作，并在发布前检查任务所有权，防止旧结果覆盖新状态。

`Task.detached` 的取消需显式传播到 worker。`DocumentMarkup`（Skill Markdown 与飞书文档的解析）和 `JSONTree` 的扫描循环检查取消；SSE 预览逐行扫描，以环形尾缓存保留最后 400 个事件（`JSONTree.sseCap`），只解码需要展示的部分。实时 SSE assembler 仍处理完整事件流。

会话监控读取受限尾部而非整份 transcript（会话上下文 96 KB、子代理 32 KB，Codex rollout 512 KB 窗口）；用量索引的目录遍历用带属性的 enumerator，按目录批量取回修改时间与文件大小而不是逐文件 stat。尾部窗口使用宽容 UTF-8 解码，因为 seek 可能落在多字节字符中间。文件缓存以 mtime + size 等输入签名判断能否复用，Codex rollout 快照另按时间窗清理。

资源读数通过字段级订阅和发布前量化减少无意义失效。批量统计在后台聚合，主线程只提交已经准备好的展示数据；不要在 `body`、每帧 Canvas 或 hover 回调重新聚合历史。

连接器库存同时只运行一轮后台扫描；扫描期间的新请求合并为最新项目路径，保留待处理的 CLI 发现需求。每个调用者等待同一个 runner 完成，过期项目结果不发布，已经完成的 CLI 结果可用于下一轮。单页任务取消不取消共享库存工作；同一路径在修改后仍重新扫描，不用持久缓存掩盖变更。

迁移历史（`MigrationStorage.records`）在每个有大小限制的文件读取前后检查取消，发布时（`SessionMigrationModel.refresh`）检查刷新代次和内容变化。飞书编辑器目录复用后台解析得到的原始 UTF-16 范围；点击先确认缓存文本和草稿身份仍匹配，不在主线程重新扫描整份文档。缓存保留到下一次解析，未证明内存下降；当前正在执行的同步文件读取也不会被取消检查强行打断。测量与边界见 [模块调度审查](../reviews/apple-module-scheduling-performance-2026-10-05.md)。

访问日志构造不读磁盘；`ProxyLogView` 出现时调用 `loadListIfNeeded`。读取队列以 64 KiB 块倒读 JSONL，找到最近 500 个有效记录便停止；UTF-8 跨块片段先拼接再解码。代理的首次请求通过 `prepareForRequests` 挂起等待同一加载队列，完成后才分配递增 ID，后续请求只检查锁保护的状态。读盘期间不持有请求状态锁，清空把历史标为已消费，载入结果不能恢复已清空记录。UI 快照仍按 100 ms 窗口合批发布，`entries` 由 MainActor 隔离。

MCP stdio 发现的 semaphore 等待由 Dispatch 队列承接，调用任务通过 checked continuation 挂起。取消标记与进程启动/停止分别用短状态锁和进程锁保护；取消先唤醒 collector，再由独立队列停止本次发现的子进程。每条路径只恢复一次 continuation，保留逐请求预算、分页限制与禁止安装型运行器的边界。

日期查询由 SQLite 的范围索引完成，`rollup(day)` 上的索引把窄窗口查询收敛到索引扫描，宽窗口交给一次全表 `GROUP BY`；不再有 Swift 侧的日期到键索引。`UsageIndex.fetchSessionFamilies` 将每个文件一次性路由到查询家族，Codex 用迭代父链与共享祖先链接复用归属，环共享查询结果，不为每个节点复制完整祖先集合。匹配的祖先及模型输出仍有成本；测量与边界见 [核心算法审查](../reviews/apple-core-algorithms-performance-2026-10-05.md)。

## 滚动更新与布局

`ScrollHoverGate` 用每个滚动视图的 UUID 记录 ownership；只有最后一个 owner 释放后才 flush 延迟发布。watchdog 可取消并带 generation，连续滚动的最长延迟预算为 4 秒，阶段转换不能重新延长期限。视图拆卸也必须释放 ownership。

滚动时合并采样和实时数据发布，并抑制经过卡片的 hover 翻转；停止后补发 mouseMoved 恢复指针下的悬停。门控只延迟数据更新，不降低页面的显示刷新率。概览通过 `PageScrollActivity` 持有天空静帧，滚动时由系统合成平移。

连接器网格以 `LazyVGrid` 作为滚动内容，模型目录分组使用 `LazyVStack`。避免普通栈的理想高度测量使懒容器提前布局所有项。连接器卡上的 3D 倾斜已删除：`rotation3DEffect` 角度为 0 也留在树上会把整张卡提升为合成层，滚动时整份网格逐帧重新光栅化。

## 动效与图层

持续装饰优先通过 `NSViewRepresentable` 和 Core Animation 图层插值，例如 `DecorativeMotion`、`ReadingSweep`、`LucideRotor` 和能源流。它们必须同时响应 surface 可见性、局部视口、window occlusion、Reduce Motion 与拆卸；脱离窗口后不能保留播放回调。

旋翼和扫光改变速度时用 `timeOffset` 保持相位，不因每次读数重建动画。低负载、低 RPM 和减弱动效时冻结或隐藏装饰。问候时钟用秒级 periodic schedule；Metal 不可用的天气 Canvas 使用受限 animation schedule，屏外暂停。

能源流的 `SankeyWaveView` 按路径、外观、几何与播放速度分别更新。速度变化只重定时共享时钟；路径变化不重建渐变色和位置节点；目的节点、明暗、尺寸或行程变化才重新准备对应图层属性。新流带须初始化全部属性，拆卸须停止播放。组件 CPU 样本和静态像素对照见 [UI 与动效审查](../reviews/apple-ui-performance-2026-10-04.md)，不代表整窗口 FPS。

给持续变化的采样值绑定 `.animation(_:value:)` 可能使整个 hosting view 长期处于动画事务中。`RollingNumberText` 等读数叶子保留自己的数字转场，避免附加宽泛的隐式动画。修改动效应测量 hosting layout / display 的归属，而不是仅观察单个视图代码是否简单。

`LayerShadow` 用单个 `CALayer` 加显式 `shadowPath` 绘制阴影，替代 SwiftUI `.shadow`；按钮板面上曾有的 `.compositingGroup()` + 两层 `.shadow()` 组合（卡面本身只有一层 `.shadow`，不带 `.compositingGroup()`）随改写移除，第二层阴影的 `under*` 参数集也随最后一处调用删除。图层尺寸与路径按实际边界更新，静态外观不引入常驻计时器。

## 验证入口与测量契约

回归登记在 Makefile，由 `make test` 统一运行；日常按模块使用 `make test TEST=performance`、`module-performance`、`backend-performance`、`access-log-tail`、`ui-animation-performance`、`interaction-performance`、`rendering`、`inflight-animation`、`card-shadow` 或 `fan-rotor`。测试运行生产函数或状态机，使用临时输入和模拟传输，不启动 VPN、不写硬件、不操作真实用户进程；MCP 夹具验证自身模拟子进程的退出。

天气 GPU 编码与文字栅格化用 `python3 Tools/bench-atmosphere.py --frames 120 --contrast` 验证。工具把生产着色器与排版器（`SkyScene`、`AtmosphereShader`、`AtmosphereRenderer`、`GreetingScript`）编进一个临时探针（`-O`），逐场景报告天空帧与前帧的 GPU 中位数、编码 CPU 中位数，并单列一次性成本（场景构建、问候语排版与栅格化）；`--contrast` 额外渲染三个相位时刻，按区域检查信息文字的对比度中位数（低于 3:1 直接中止）。

整窗口流畅度需要在相同优化构建、窗口尺寸、数据规模和显示器条件下测量帧间隔、p50/p90、长帧与 hitch。空闲负载需区分可见静止、完全隐藏和局部屏外，结合 CPU、GPU、唤醒与能耗。用相同脚本交替执行对照，保留环境与采样归属；单次 CPU 读数、微基准或源码扫描不能替代实际页面帧率验收。
