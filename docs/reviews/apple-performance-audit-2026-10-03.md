# 苹果官方性能文档与模块优化审查 · 2026-10-03

> 后续状态：首次日志载入、MCP 取消与 JSON 路径索引已在 [2026-10-04 第二轮](apple-performance-followup-2026-10-04.md) 实现并单独测量。本报告保留第一轮实现与历史样本；此处的同步 `log_load_ms` 与当前异步载入含义不同。

本轮先网络检索苹果官方性能资料，再检查 ClaudeBar 的调度、观察依赖、计算、解析、持久化和原生绘制入口。保留原有会话迁移工作及期间出现的风扇界面修改；没有安装、启动 release，也没有运行 VPN、写硬件或申请系统权限。

完成了源码入口全量扫描、重点路径复核、生产逻辑合成基准和全量回归。**没有完成所有模块的 Instruments 运行测量，不能据此宣称所有组件已经达到最优性能或恒定 120 FPS。** 文件级覆盖见 [236 个 Swift 路径清单](performance-source-inventory-2026-10-03.md)，含 Widget 快照符号链接；扫描标记只是定位入口，不是运行测量。

## 官方依据

| 苹果资料 | 用于本项目的原则 |
| --- | --- |
| [Improving your app’s performance](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance/) | 以基线、定位、修改、复测形成循环；分别评估响应、内存、磁盘和能耗。 |
| [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) | 离散交互的同步主线程工作以小于 100 ms 为粗略参考；连续交互受 8.3/16.7 ms 显示周期约束，主线程更新尽量小于 5 ms。这些不是所有设备的保证值。 |
| [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance) | 分开定位耗时 body 和过于频繁的更新；避免反复计算相同派生值，限制观察依赖。 |
| [Demystify SwiftUI performance · WWDC23](https://developer.apple.com/videos/play/wwdc2023/10160/) | 保护列表和表格的稳定身份、生命周期与依赖关系。 |
| [Optimize SwiftUI performance with Instruments · WWDC25](https://developer.apple.com/videos/play/wwdc2025/306/) | 用 SwiftUI 更新轨迹与因果图查出真正造成更新的来源，再复测。 |
| [Visualize and optimize Swift concurrency · WWDC22](https://developer.apple.com/videos/play/wwdc2022/110350/) | `Task` 不保证工作离开 MainActor；阻塞等待还可能占用协作线程池。锁和 actor 的占用应短，阻塞 I/O 必要时由 Dispatch 队列承接。 |
| [Optimize CPU performance with Instruments · WWDC25](https://developer.apple.com/videos/play/wwdc2025/308/) | 先避免工作、改算法，再考虑底层微优化；用单调时钟和真实优化编译测量。 |
| [Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes) | 合并小写入，避免高频重写整份序列化文件；SQLite 使用事务、适当索引和 WAL。 |
| [Making changes to reduce memory use](https://developer.apple.com/documentation/xcode/making-changes-to-reduce-memory-use) | 控制缓存和对象保留量；图像按实际尺寸处理；用测量定位内存增长。 |
| [Mac Energy Efficiency Guide · Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html) | 用事件通知替代无效轮询；必要的重复 timer 设置容差；等待使用有业务意义的截止时间。 |
| [NSRegularExpression](https://developer.apple.com/documentation/foundation/nsregularexpression) | 编译后的正则不可变且可跨线程匹配，适合复用固定模式。 |

涉及 iOS 的 Organizer/MetricKit、内存终止和持久化描述没有直接套用为 macOS 行为。本机只有 Command Line Tools，`xcrun --find xctrace` 确认没有 Instruments；未安装新工具或新运行依赖。

## 完成的生产修改

| 模块 | 原成本 | 改动及语义边界 |
| --- | --- | --- |
| `DocumentTable` 初始列宽 | 每列扫描所有 cells，并构造多层中间数组 | 一次遍历统计最长行和代码列；保留 CRLF、中文、emoji、空字符串及原有宽度计算。 |
| `DocumentTable.html` | 每一输出行都过滤全部 cells，规模为行数 × 单元格数 | 一次按行分组索引，再按列输出。原 cell HTML、attributes、表头、合并结构与行列尺寸保留。 |
| `DocumentTableView` | 每个懒加载行簇扫描全部 cells，宽高与位置重复做前缀求和 | 生产模型生成行簇索引及行列前缀坐标；视图仅取该簇 cells。跨行合并仍保持在同一簇，`ForEach` 继续使用 cell UUID，输入、撤销和拖动接口保留。 |
| `ProxyAccessLog` 发布 | 每次请求开始/结束分别安排主队列回调，满环时删除和追加也各自通知 | 100 ms 单飞节流，连续流量每个窗口仍能发布；串行后台 worker 取快照，主线程不等待 proxy lock。快照按顺序上屏并跳过相同内容。延迟窗口新增约 100 ms，记录和 token 统计仍逐请求完成。 |
| `ProxyAccessLog` 清空 | 增量回调可能与清空/新请求交错，旧行或重复行重新出现 | 统一快照发布消除旧增量回调；磁盘追加和清空的入队也由同一状态锁排序。 |
| `ProxyAccessLog` 载入 | 解码全部历史再截 500 行 | 从尾部只解码最后 500 个有效记录，再恢复原序；损坏尾行不隐藏更早的有效行。**仍读取并分割整个文件**，未宣称磁盘读取量也限定为 500 行。 |
| `ModelPricing.canonical` | 每次归一化重复请求正则模式匹配 | 两个固定日期后缀模式编译后复用；保留原先先 `-` 再 `@` 的顺序、ICU Unicode 数字及 `$` 语义，无可增长的 slug 缓存。 |
| `JSONLineCollector` 批量接收 | 每消息删除已消费前缀 | 扫描偏移后只删除一次前缀；保留 1 MiB 防护和完整消息/残留尾段。 |
| `JSONLineCollector` 等待 | 无数据时每 200 ms 重醒，短截止时间也可能等到 200 ms | 用实际剩余预算等待 response/EOF/deadline；不增加周期调度。 |
| 必要定时采样 | 多个普通重复 timer 未设置容差 | 会话轮询、菜单电池、系统速率、Cursor 额度、灵动岛用量与订阅刷新设置 10% 容差。实际速率仍由实际采样时间差计算；不修改动画 tick、交互截止时间、Codex reset 单次调度和充电安全 watchdog。 |

没有批量迁移 `ObservableObject`、移除动效、降低交互刷新率或改变数据库架构。现有字段订阅和原生绘制已覆盖很多历史瓶颈，重复重构缺少收益证据。

## 可复现测量

输入均由夹具生成，临时目录持久化，不读取真实会话、凭据或代理记录。比较基线固定为 `037dc2d`，只从它提取本轮涉及的原函数。两臂均 `swiftc -O -parse-as-library`，每臂独立进程三次，运行顺序交替。Apple M3 Pro / arm64 / Apple Swift 6.3.2。

```bash
make test TEST=module-performance
python3 Tests/module-performance-regressions.py --compare --baseline-ref 037dc2d \
  --output-json docs/reviews/performance-module-measurements-2026-10-03.json
python3 Tools/performance-inventory.py
```

原始三次样本、编译器和夹具信息见 [测量 JSON](performance-module-measurements-2026-10-03.json)。以下表由其中的中位数整理，不把函数耗时当作整页帧率。

| 指标 | 基线中位数 | 优化后中位数 | 变化 |
| --- | ---: | ---: | ---: |
| 表格初始列宽 / ms | 24.53 | 16.74 | 减少 31.8% |
| 表格 HTML 导出 / ms | 1072.08 | 12.34 | 减少 98.8% |
| 完整表格布局遍历 / ms | 1063.80 | 6.46 | 减少 99.4% |
| 18,000 次模型归一化 / ms | 48.22 | 28.23 | 减少 41.4% |
| 5,000 行日志载入 / ms | 350.59 | 61.80 | 减少 82.4% |
| 600 次请求入队 / ms | 3.88 | 3.55 | 减少 8.6% |
| 600 次请求发布通知 / 次 | 1800.00 | 1.00 | 减少 99.9% |
| 连续 60 次请求发布通知 / 次 | 120.00 | 4.00 | 减少 96.7% |
| 2,000 条 JSON-RPC 批量解析 / ms | 4.54 | 3.72 | 减少 18.1% |
| 等待 650 ms 后响应的 semaphore 等待 / 次 | 4.00 | 1.00 | 减少 75.0% |
| 35 ms 请求截止预算的实际等待 / ms | 204.14 | 36.93 | 减少 81.9% |
| 整个合成进程峰值 RSS / MiB | 33.70 | 27.78 | 减少 17.6% |

表格基准为 2,000 × 12，共 24,000 个合成 cells；布局基准遍历**所有行簇**，模拟完整表格遍历，**不是一次可见帧或真实滚动的耗时**。前后 HTML 字节直接比较一致；另保留摘要方便归档。模型名称输出跨臂比较一致。

访问日志基准先装入 5,000 行历史及损坏尾行，环已满，再瞬时执行 600 次 begin/note/finish。旧版每次淘汰、追加和完成触发共三次通知，因此是 1,800 次；从空环启动的 600 次请求此前测到 1,300 次。连续输入为 60 次、每次间隔请求 5 ms，两臂结束时间不同，因为新臂须等最后一个节流窗口提交。发布次数是 Combine 通知数，**不是 SwiftUI 实际 body 次数或绘制帧数**。

峰值 RSS 是 `/usr/bin/time -l` 的整段合成测试进程峰值，含输入、Swift/Foundation 和验证开销；新臂还有合并几何和并发生产者的额外检查。这不是 App 的内存驻留或某个函数的单独内存。定时器容差仅验证已配置，**没有测得整机能耗下降百分比**。

## 逐模块检查结论

| 模块/组件族 | 复核入口和现有实现 | 本轮处置/验证 |
| --- | --- | --- |
| App、主窗口、菜单和 popup | 可见性、生命周期、字段订阅、菜单资源采样 | 保留 `UIWakePolicy` 与 `ProviderState`；菜单电池及系统速率 timer 容差；`ui`、`menubar-strip`、`rendering`、`build-isolation`。 |
| 会话、会话卡、工作流、Agent 树 | 轮询单飞、尾读取、mtime 缓存、派生树缓存、完成/等待判定 | 只加普通轮询容差，保持后台通知新鲜度；`session-scan`、`cursor-turn`、`codex-session`、`workflow-session` 和通知回归。 |
| 用量、图表、模型花费和价格目录 | 后台聚合、范围索引、估算缓存、Canvas、正则归一化 | 固定正则复用；`model-cost`、`usage-analysis`、`usage-index`、`cursor-ledger`、`model-price-source`。 |
| Claude/Codex/Cursor 供应商与额度 | 独立 store、reset 定位、缓存、请求去重 | 保留 reset 的单次精确调度，Cursor 慢心跳容差；`quota-store`、`quota-reset`、`cursor-usage`、`cc-concurrency`、`provider-delete`。 |
| 代理、访问日志、流量检查器、JSON/SSE | 锁、批量发布、内容上限、后台解析、取消、逐请求 token | 改访问日志调度和尾解码；`module-performance`、`performance`、`proxy-usage`、`proxy-upstream`、`agent-protocol-bridge`、`capture-retention`、`interaction-performance`。 |
| 连接器、详情、MCP/CLI 元数据 | 扫描后台化、库存常驻、计数缓存、懒容器、预览取消 | 改共享 JSON-RPC collector；保持运行器边界与外部配置隔离。`connector-batch` 和 collector 合成帧测试；未启动真实 MCP 或 app-server。 |
| 飞书目录、正文、表格、官方嵌入组件 | 分页缓存、身份隔离、子进程传输、Markdown 解析、输入/撤销、WKWebView | 表格分组与布局；`feishu-documents`、`feishu-component`、`module-performance`。不访问真实飞书或更改已有组件工作。 |
| VPN 节点、订阅、域名、连接与速率 | 独立速率观察、平直窗口去重、分页查询、有界环、后台管道解析 | 订阅刷新容差；`vpn-domain-log`、`vpn-format`、`vpn-provider-direct`。没有启动内核或修改网络。 |
| 天气、问候、Metal 天空 | 原生显示调度、可见性/遮挡暂停、热状态、低电量、纹理栅格串行队列 | 保留现有 GPU 实现；天气/天文/问候及原生绘制回归。此次未新增 GPU 前后对照，历史 GPU 结果见旧审查。 |
| CPU、内存、磁盘、联网与配件 | 共享采样订阅者、隐藏暂停、IOKit/蓝牙读取、独立配件状态 | 系统速率容差；`process-cpu`、`audio-accessory`、`connection-panel`、`interaction-performance`。没有调用会弹窗的系统权限。 |
| 充电、风扇和特权工具 | dev 入口闸门、状态机、watchdog、读数与动画生命周期 | 不修改安全监视节奏；`charge-limit`、`fan-rotor`、`machine-mark` 通过模拟/原生绘制验证，不写 SMC。 |
| 灵动岛 | 展开/收起调度、alert 所有权、用量单飞、定时刷新 | 普通用量 timer 容差；`island-session-alert`、`performance`、`inflight-animation`。 |
| 主题、按钮、阴影、字体/图标、列表与布局 | 原生层阴影、稳定路径缓存、可见性播放、懒布局、身份 | 保留已优化实现；`rendering`、`card-shadow`、`provider-icon`、`product-mark`、`widget-tint`、`greeting-layout`、`icon-minimal`。 |
| Widget、偏好、快照与文件安全 | 后台串行写入、忽略时间戳去重、共享身份、私有写入 | 保留现有去重和权限门；`widget-snapshot`、`widget-tint`、`core`、两版包检查。 |
| 迁移、协议转换、媒体和系统启动 | 容量边界、临时路径、进程清理、现有并发/隔离契约 | 保留原有迁移修改；全迁移和桥接回归通过，不发起真实迁移或复制用户凭据。 |
| 构建、压缩资源与打包 | 优化增量编译、输入指纹、对象复用、固定内核、签名顺序 | 未改构建架构；`build-isolation`、`core`，dev/release 都构建并检查签名。不执行 `make package` 或安装。 |

## 验证与实际边界

- `make test`：59 组全部通过，283.35 秒。新增 `module-performance` 已登记在 Makefile，CI 沿用同一清单。
- `make build`、`make release`：都通过，Widget、URL scheme、entitlements、签名和两版身份通过构建门禁。只生成 `.build/dev` / `.build/release` 包。
- release 首次遇到遗留空锁；确认没有构建进程后仅移除空 `.build-lock`，重试成功。没有杀进程。
- 现有警告：release 的 `VpnManager` 管道闭包访问 MainActor store、无 throwing 的 `try?`，以及重复 rpath；测试中的 `CLGeocoder` SDK 弃用警告。未用静默失败掩盖，也未为此迁移无关实现。
- 本地签名身份为现有 `ClaudeBar Dev`，并非发行公证产物。

## 后续需 Instruments 或独立夹具确认的点

1. **全应用交互与功耗**：使用 SwiftUI + Hitches、CPU Profiler、Swift Concurrency、Allocations/Leaks、File Activity 和 Power Profiler，录制深滚、切页、大小表格输入、关闭/遮挡、多窗口、Reduce Motion、低电量和唤醒。特别检查连接器网格、VPN 大节点列表与官方飞书组件。源码扫描和函数基准不能代替这些记录。
2. **日志首次载入**：虽然解码明显变快，`ProxyAccessLog.init` 仍同步读整份文件。若首次挂载 trace 显示阻塞，需要设计异步载入与新请求 ID 的合并顺序；不能直接把 init 改为空列表后让历史覆盖新请求。
3. **MCP / Codex stdio 等待**：共享 collector 不再反复重醒，但调用者的阻塞等待仍应使用并发 trace 验证；MCP 的 detached worker 占用协作线程池及取消到 child 退出的路径值得单独做模拟传输测试。
4. **非 SQLite 的用量后端**：JSON rollup 的按 path 替换仍过滤全表，适合对大目录导入用合成夹具测量后，再决定是否建立 path 索引。默认 SQLite 已有 WAL、事务与日期索引。
5. **发布延迟与几何实机检查**：访问日志的节流窗口应在真实并发流量下验证体验；表格输入、合并行簇、窗口缩放与撤销应录制实际布局和输入焦点，不能仅依赖模型几何一致。

这些是明确记录的验收缺口和后续测量对象；本轮交付没有把它们表述成已经完成的性能改善。
