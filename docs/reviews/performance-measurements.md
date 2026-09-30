# 性能与并发

> ClaudeBar 技术文档 · §8
> 相关：技术文档 [状态中枢](../technical/03-provider-store.md) · [数据访问层](../technical/04-data-access-layer.md)

| 点 | 策略 |
|----|------|
| 会话轮询 | `Timer.scheduledTimer` 只触发，`refreshSessions` 的扫描在 `Task.detached(priority: .utility)` 中离主线程执行，回主线程仅发布结果。间隔随可见性三档：忙 2.5s / 全空闲 5s / 无可见窗口 8s（`AppConfig.sessionPollInterval` 等，`UIWakePolicy` 驱动）；无可见窗口那档必须留在完成规则的 60 s 新鲜窗口内——轮询被上一轮扫描挤掉时用一次性定时器补跑，不丢拍。**「忙」的口径里 Cursor 那一条带写时钟界**：被中断的轮次不写 `turn_ended`，所以只按行序判定会让一条冻结的 transcript 永远算忙（实测钉住了灵动岛的忙碌徽章、这一档轮询与 1 Hz 采样）；现在还要 transcript 的 mtime 在 10 分钟内（`CursorSessionMonitor.turnLiveWindowMs`），子 Agent 同界。**额度探针不在这一档**：Codex 15 分钟心跳 + 在一个已知 `resetsAt` 落在 15 分钟内时多探一次（`QuotaPollScheduler`，一次性定时器按读数重排）、Cursor 20 分钟（`AppConfig.cursorQuotaPollInterval`），各自观察自己的 store |
| 可见性闸门 | `UIWakePolicy`（主窗口遮挡 / 最小化 / 关闭 + popup 开关）统一驱动：会话间隔、FSEvents 用量重扫、进程采样器、VPN `/connections` 轮询间隔、**以及动画**。挂在界面上的视图读 `surfaceIsVisible` 环境值（`MainWindowView` 注入）；不在界面树里的观察者用 `hasVisibleWindow` |
| 心跳采样 | 每轮 busy/idle 采样追加进 `heartbeats[pid]`，上限 `AppConfig.heartbeatLength`（24，≈ 最近一分钟） |
| 空闲通知 | `ConfirmedCompletionDetector` 只做边沿检测（每轮交付一次），无额外轮询 |
| Cursor DB 查询 | `Task.detached` 后台执行，DB 大但走 `(recency, composerId)` 索引 + LIMIT 80 |
| Cursor 实际扣费 | `CursorLedgerStore` 只在窗口变化 / 手动刷新 / 读数超过 6 h 时才发一次网络请求（单次 1.5–3.6 s），在 detached task 上跑。**用量页从不等待它**：瓦片读的是内存里那份读数（启动时由 `cursor-ledger.json` 反序列化），落地后发通知再重发一次 `rescan: false` 的用量刷新。失败保留旧值。不做历史回填——12×30 天分块实测 306 s 且仍有块失败 |
| transcript 扫描 | 只读尾部 96KB（会话）/ 32KB（子 agent），不全读 |
| 索引扫描 | 目录用 `FileManager.enumerator` 一次取回属性（`contentModificationDate` / `fileSize`），不再对每个命中文件单独 `attributesOfItem`（后者每个文件多走两次 `getxattr`；本机 1250 个 transcript × 每次重扫） |
| 用量统计 | `Task.detached` + 三级过滤 + `concurrentPerform` 并行解析；`UsageStats` 文件缓存带容量上限（4000）与驱逐，防项目树收缩后无限滞留 |
| 主线程 | 所有 `@Published` 更新经 `MainActor.run { [weak self] in }` / 主线程回调 |
| 快照写入 | `WidgetSnapshotWriter` diff 后写四路（B6：仅数据变化时写文件 + `reloadAllTimelines()`，避免每 2.5s 空转） |
| 动画 | **没有常驻的 SwiftUI 时间线**。装饰动效全部走 `NSViewRepresentable` + Core Animation（`DecorativeMotion`、`LucideRotor`/`RotorLayerView`、`UiverseKit` 的 shine/conveyor），渲染服务器插值、不重算 body，并各自再查一次 `window?.occlusionState.contains(.visible)`；调用侧由 `UIWakePolicy` 的 `surfaceIsVisible` + 「减弱动效」双重门控。**按读数调速的那一类（`LucideRotor`）用 `timeOffset` 冻结相位后就地改 `speed`**，所以采样器每 1–2 s 推一次新 rpm 不会重建图层、也不会让扇叶跳回起点；`rpm < 80` 时速率**恰为 0**（扇叶停在原地，图层不消失）。`LucideRotor` 以角速度驱动（没有 `paused:` 参数，也不该有）。`DecorativeMotion.kind == .loadRing` 已随视图删除。全仓现有 **3 处** `TimelineView`。其中一处是 `.animation(...)` 调度、也就是**每帧重新校验 body** 的那一类：`WeatherBackdrop` 的天空（1/30–1/12，按天气分层，只作金属视图不可用时的回落）。问候卡的时钟是 `.periodic(by: 1)`，一秒钟一次，不占显示周期；硬件读数的扫光不再走时间线，改由 `ReadingSweep` 的 `CAGradientLayer` 按 `0.35 + load × 1.35` 周/秒平移（2026-09-29，见下文）。剩下那处 `.periodic` 是灵动岛会话行的「N 分钟前」（30s）。**关掉天气渲染之后这项开销整块消失**：卡片改画 `SkyScene.pinned`——一层按太阳高度插值的晴空，没有云、没有降水底片、没有雾与闪电，也没有玻璃雨滴，`WeatherStore` 这张卡也不再刷新（`Sources/ClaudeBar/Views/Shared/GreetingCard.swift` 的 `liveWeather`）。问候卡的天空本身**不在这张表里**——它是 `MTKView`，自带渲染循环与帧率策略（见 [Greeting atmosphere](../design/greeting-atmosphere.md) §5.7），不经过 SwiftUI 的显示周期。**`.animation` 的 `paused:` 不是省钱的挡板**：paused 为真时确实不跑，但为假时它让整个 hosting view 每个显示周期重跑一次 layout —— 2026-09-28 实测（见 [UI 审计待办](ui-audit-backlog.md) §11）：把它删掉、只留一条画纯色矩形的 30 Hz 时间线，一个 `topBar` 空壳就从中位数 4.0% 涨到 14.7%，两条涨到 17.2%；而把帧率从 30 降到 15 / 8 几乎不动（43.2 / 43.5 / 41.5%）。**新增动画前先确认门控边界**：漏一个就是常驻 display link，每 tick 一次全主线程布局 |
**隐式动画的代价（同上一条是同一类问题，只是藏在 `value:` 里）**：`.animation(_:value:)` 的 `value` 若来自每秒变一次的数据（采样器读数、会话数、到期时间），它**每 tick 都会开启一个新的动画事务**；只要有事务在飞，每个显示周期都会把整个 hosting view 走一遍 layout + display list —— 不是只在插值期间。诊断特征：`sample` 稳态里 `+[NSAnimationContext runAnimationGroup:]` 出现在 `@objc NSHostingView.layout()` **内部**。实测（dashboard，`sample` 5s）：`RollingNumberText` 上的一行 `.animation(.snappy(0.38), value: value)` 让主线程样本里 `runAnimationGroup` 占 31%、`NSHostingView.layout()` 31%、`stepIdle`（display cycle 每帧重排窗口）56%；去掉后分别是 13% / 13% / 3%。**`.numericText` 自己会动，隐式 `.animation` 是多余的**。注意本机 `ps -p PID -o time=` 差值噪声很大（Chrome renderer 常驻半核，app 自身空载在 10–27% 之间摆动），CPU 数字只作旁证，以采样归属为准。新增 `value:` 键前先问：这个值多久变一次？`Tests/inflight-animation-regressions.py` 把这条规则钉在 `RollingNumberText`、`RollingNumberModifier`、`SectionHeader.trailingView` 上，并加上后来清掉的三处同类违反——灵动岛收起态的今日 token（`NotchIslandView.wings`）、灵动岛用量卡 hero（`IslandComponents.hero`）、未挂载的 `MetricTile`（`Tile.swift`，后经 [UI 审计待办](ui-audit-backlog.md) §10 连视图本身删除）；三处都是「1 Hz 读数 + 隐式动画」的同一个形状 |
| 灵动岛常驻 | `IslandOrbit` 的 `repeatForever` 已换成 `DecorativeMotion(kind: .arc)` 的渲染服务器图层：同一启动器、同一 `-g` 树、同一个路径下换 bundle，交替采样得到「在飞事务里的 `NSHostingView.layout()` 占比」中位数 48.8%（旧）→ 31.9%（新），区间不相交，`runAnimationGroup` ≈420 → ≈285。**折叠 + 空闲**状态实测 0.5–0.7%（旧文档记的 0.8%），此时岛内几个 `.animation(_:value:)` 开关不影响读数。面板窗口按 `panelSize`（640×386）无条件给定，曾被认为是每帧代价的第二个乘数 —— 后续用「只改 `panelSize` 的两个 `-O` 构建」分三轮交替 A/B 否掉了：两臂每轮都重叠，小盒（320×80）第一轮反而更高，全部 17.0–31.6% 的散布是机器漂移。所以没有做第二个窗口 / 窗口动画缩放。见 [UI 审计待办](ui-audit-backlog.md) 第 7 条 |
| 无窗口时的开销 | 隐藏主窗口（⌘W，不是「隐藏 App」）后 app 的 idle 从约 25–50% 掉到约 9%：没有窗口时 AppKit 不跑显示周期，SwiftUI 的 layout / display list 全部消失。可见性闸门确实在起作用；剩下的是后台扫描（`sample` 里只剩 `com.claudebar.audioaccessory`、`com.claudebar.proc`、NSURLSession 的叶子） |
| 诊断口径 | **「把一个子视图从页面里删掉再看 CPU」不是有效实验**：删掉 `ResourceStrip`（6 个 tile）后 dashboard 的 idle 反而从 ~46% 变到 ~52–66%，因为只要有动画事务在飞，整棵 `NSHostingView` 每帧照样全量 layout。原先这条还写着「成本 ∝ hosting view 的尺寸」—— 后续用只改 `panelSize` 的两个 `-O` 构建（640×386 vs 320×80）分三轮交替 A/B 否掉了：两臂每轮都重叠，整体散布 17.0–31.6% 全是机器漂移，所以尺寸并不是那个乘数，**在飞的事务才是**（见第 7 条）。有效的量是**主线程样本里挂在哪个帧下的占比**（`NSHostingView.layout()` / `stepIdle` / `CALayer _display`），它在不同构建之间能稳定复现到 1 个百分点，而 CPU 差值在 10–27% 之间乱跳。见 [UI 审计待办](ui-audit-backlog.md) 第 7 条 |
| 磁盘 | 抓包 DB payload 随 `listLimit` 显式级联删除 + 空闲页超阈值 `VACUUM`；媒体目录按孤儿 id 清扫；`core.log` / `vpn.log` 8MB 轮转（`CoreLogWriter`） |
| 文本读取 | 所有「读尾部 N KB」路径（`SessionMonitor` / `CursorSessionMonitor` / `ExternalSessionMonitor`）与 JSONL 存储用 `String(decoding:as:)` 宽容解码：seek 常常落在多字节字符中间，严格 UTF-8 解码会让**整窗**失败（实测 600 份 transcript 中 31 份、291 份 rollout 中 14 份静默返回 0） |

## 2026-09-29：审查后的整体修复（已编译、回归通过，**尚未实测**）

这一轮来自一次不带构建的源码审查，改的都是「主线程在一帧里被迫做的事」。**没有跑 A/B**：下列每一项的收益都还是推断，落地后请用 `Tools/` 里的帧间隔口径复测，再把数字补到这里。

| 项 | 问题 | 改动 |
| --- | --- | --- |
| `ProcessSampler` | `coreLoad` / `gpuRenderers` 是未取整的浮点，`host != host` 几乎每次采样都成立，整条资源条和电力流每个 tick 整体失效 | 每格读数拆到 `CellLoad`、发布前量化；`SiliconCells` 只观察 `cells`；提交经 `ScrollHoverGate.afterScroll` |
| 滚动期间的失效 | 采样、`ProviderState`、流量实时流都在滚动中写 `@Published` | `ScrollHoverGate.afterScroll(key, block)`：滚动中按 key 合并推迟，滚动结束（最多 4 s）后一次性落下 |
| 天空 | 悬停时 120 Hz、空闲 30 Hz | 静止按天气 15 / 30 Hz；只有指针在主窗口内移动时升到 60 Hz，停止后回落 |
| 换页 | 旧页淡出 + 新页淡入 + 位移，两页同时存在约 180 ms；连接器页每次从空清单起步；供应商页在挂载帧里改 `balanceLoading`；外壳订阅 `.configuration`，余额刷新会重建页面 | 旧页 `removal: .identity`、新页只淡入无位移；`ConnectorManager.shared` 常驻、重扫只发布变化；余额刷新推迟 250 ms；外壳不再订阅任何字段 |
| 流量页 | 10 Hz 的 `livePreview` 让整张列表失效 | 拆到 `CaptureLivePreview`；只有进行中的行（`TrafficLiveRow`）观察它，其余行 `Equatable` |
| 按钮 / 卡片阴影 | 非 destructive 按钮也挂一个不透明度为 0 的 `LayerShadow`（一个 `NSView` + 两层 `CALayer`）；参数不变的 `updateNSView` 仍重建 `CGPath` | 只给 destructive 挂；`ShadowHostView` 记录上次参数，相同则跳过 |
| 小组件快照 | 变化时 4 处原子写盘发生在主线程 | 快照仍在主线程构建（读模型），编码、去重、写盘转到串行 utility 队列 |

**审查后判断为不值得动的**：`rollingNumber`（已按 `surfaceIsVisible` / `rolls` 门控）、`SystemThroughput`（一次 `getifaddrs`，微秒级）、`ConnectorsView` / 用量分组的过滤排序（只随数据或搜索词变化，规模几十项）。VPN 页的观察范围收窄有意没做，因为该文件当时有未提交的改动。

## 2026-09-29：概览离开显示周期

概览上还有两条 `.animation` 时间线。§11 量过：一条只画纯色矩形的时间线就让 `topBar` 空壳从 4.0% 涨到 14.7%，把帧率从 30 降到 8 几乎不动——成本是「时间线活着」，不是它一秒钟画几次。降帧率保不住效果，删掉时间线又会让扫光和秒点停掉。这两条都改成渲染服务器或一秒钟一次的周期，画面不变。

- **资源条扫光**（CPU / GPU / 内存 / 硬盘，忙的时候最多四条 30 Hz 时间线）。柱体仍由 `Canvas` 在采样变化时画一次；斜向高光是 `ReadingSweep`，每个忙柱一条渐变，裁在柱的圆角里，按原来的速率平移。负载跨采样时用 `timeOffset` 保住相位，不跳回起点。负载 < 4%、减弱动效、表面不可见或窗口被遮挡时速率为 0，高光不画，恢复时从柱的前缘重新开始。柱体上有 `.transaction { animation = nil }`，所以 1 Hz 读数不会打开隐式事务。`Tests/machine-mark-regressions.py` 改成断言文件里没有 `TimelineView`、扫光是 `CABasicAnimation`。
- **问候时钟**从 `.animation(minimumInterval: 1)` 改成 `.periodic(by: 1)`。秒点仍然每秒亮灭一次，分钟仍走 `.numericText`。天空在被拖动、或卡片所在表面不可见时，不建时间线。
- **滚动时的悬停**。指针扫过概览的瓦片会逐个翻转 `hovered`，每一次都是一次布局（设置页旧瓦片墙深滚时量过：指针在瓦片上 86 fps，停在空白槽里 102 fps）。`ScrollHoverGate` 在滚动的 tracking / 减速 / 动画阶段丢掉 enter/exit，停下后补发一次 `mouseMoved`，让指针底下那一张补上悬停。闸门本身不是可观察状态，避免在滚动最需要主线程的那一帧重算整页。

## 2026-09-29：其余页面只排屏幕上的内容

连接器清单是上一轮量过的最重页面（深滚约 68 fps，p50 16.4 ms，和指针在不在卡片上无关）。两处结构和那组数字对得上。每张卡都挂着 `rotation3DEffect`，角度为 0 也留在树上，滚动时整份网格逐帧重新光栅化。网格又套在普通 `VStack` 里，`ScrollView` 按理想高度问它，懒网格会把全部卡片排出来。模型目录是同一种嵌套，分组更少，上一轮约 88 fps。

- `DepthTiltModifier` 只在这张卡被悬停、且没有减弱动效时才装上 3D 和一次扫光。抬起仍由 `.tile()` 负责。扫光在出现时就开始，因为覆盖层是连同悬停一起创建的。
- 有卡片时，`LazyVGrid` 是 `ScrollView` 的直接内容，标题、筛选和提示放在 `Section` 的 header 里，横向内边距只加一次。空列表和扫描中仍是普通栈。
- 模型目录的分组从 `VStack` 改成 `LazyVStack`，滚出屏幕的分类不再构建。组内网格仍是该分类的那几张卡。
- `scrollHoverGate()` 接到会话、连接器、用量、流量、VPN、设置、帮助和模型目录的滚动上。概览仍自己写滚动阶段，因为它还要同时停住天空；两边都走 `ScrollHoverGate.set`。

这一节没有新的帧间隔。上面的 68 fps / 88 fps 是 2026-09-26 的 `SCStream` 读数，这次没有重跑。VPN 节点马赛克仍是分组里的一整块网格（上一轮约 114 fps），设置页是短表单，流量列表本来就是 `LazyVStack`，都没有再拆结构。

## 2026-09-29：天气卡改成三张缓存的画面

雨雪看起来卡，不是因为有一套 CPU 粒子。雨丝和雪花原先是片元着色器里的哈希，和体积云写在同一次绘制里。云才是贵的：每个有云的像素做 5 次噪声，再沿光照走 4 步、每步 3 次噪声。把雨单独拆出去、再把雨提到显示器刷新率，总的 GPU 时间不降反升，玻璃窗台也跟着每一帧重模糊。那是在原来的结构上挪帧率。

整张卡做成一段视频也放不进去。问候语画在远雨和近雨之间，云影要落到字上，倾角跟风走，时刻和视差是连续的。一段循环视频是一张扁平的图。

现在这张卡是三张缓存的画面，合成一次：

- **云层**（渐变、天体、卷云、体积云、雾）画到半分辨率，也就是卡片的点分辨率，一张 `rgba16Float`。30 Hz 更新，低电量或热压力 15 Hz。闪电照亮云底的那一下，云层跟着走。半分辨率是因为云是低频的，双线性放大就是它本来的柔边。
- **雨雪是烘焙一次的平铺底片**，之后只按风速滚动采样。底片里的雨丝已经拉长，所以 30 Hz 播出来是连续的，不必为了雨把整张卡提到 120 Hz。密度用亮度门控：小雨先露出最亮的几条，雨变大再铺满。
- **合成**把云层、底片、闪电通道、问候语和玻璃雨滴叠在一起。滴和涟漪的折射是挪云层的采样点。静止时整张卡 30 Hz；笔、淡变、视差、拖动时刻才跟显示器刷新率，而且那些帧不再重走云。

同一台 M3 Pro、2200×948（`Tools/bench-atmosphere.py`）：大雨含云层的一帧 0.40 ms，只合成的一帧 0.31 ms；雪 0.32 / 0.23 ms；雷暴 0.41 / 0.31 ms；晴天云层帧 0.25–0.39 ms。静止的大雨大约 30 × 0.40 ms = 12 ms GPU/秒。没有新的合成器帧间隔。

## 2026-09-26：帧率审计（新口径：实测帧间隔）

上一轮之后的问题不再是「有没有常驻 display link」，而是「每次交互到底掉了几帧」。所以这一轮先把**量具**换成能直接回答这个问题的：

- `SCStream` 挂到主窗口上，统计**合成器真正提交**的帧（`SCFrameStatus.complete/started`，`.idle` 不计），拿 PTS 差值算 p50/p90/p99 与 >20 ms 的次数。这比上一版的 `SCScreenshotManager` 轮询可靠得多——那个 API 串行且上限约 23 Hz，它报出的「帧间隔」其实是探针自己的轮询周期（同一台机器上，一个最小 SwiftUI 动画窗口经它测出 120 fps，ClaudeBar 只测出 60，那个 60 是 poll 上限而不是 app 的表现）。
- 同一台机器上先测参照系：最小 SwiftUI app 121 fps（窗口自身动画每帧重绘）、SourceTree 120 fps（**静止**窗口，合成器补零帧）→ 静止窗口本身是 120 Hz 满帧。ClaudeBar 静止时只有 57–70 fps，说明**窗口并非静止**：有东西在按 60 Hz 重绘。
  > **这条参照系后来被自己的对照推翻了，见下面「静止窗口在 SCStream 上不可判别」**：静止窗口在 SCStream 上只拿到约 49–50 fps，SourceTree 那次 120 是它自己在动（标题栏动画 / 滚动条淡出）。所以「57–70 说明窗口在重绘」这个推论不成立——57–70 与 49–50 的差别**部分**来自真实重绘，但「静止 = 120」这个前提是错的。留着这条是因为它当时推导出的方向（继续找每显示周期的重绘）最后是对的。
- `sample` 用 1 ms 间隔重采样，并改成**按叶子栈归属**（每个叶子的权重累加到它整条祖先链上的 app 帧），不再按顶层计数——顶层的 `CFRunLoopServiceMachPort` 是刻意的等待，按它排序会把「什么都没做」排在第一。

本轮修复（每一条都先复现、再改、再 A/B）：

| # | 路径 | 现象（实测） | 修复 |
|---|------|--------------|------|
| 1.1 | `Tile.swift` `EqualRowGrid.updateCache` | 会话轮询一改数据就 `removeAll` 整个测量缓存，`sessionOverview` 那格每 2.5 s 重排一次，看似是白花的钱 | **试过清掉这个 `removeAll`，被测试和测量双双否掉**：`Tests/ui-regressions.py` 的 `Cache must invalidate when content changes` 直接断言失败（缓存键只描述列布局，内容变高后行高会留下旧值），而 1 ms 采样显示这条路径只值 ~0.25 ms/秒。回滚，并把「为什么必须清」写进代码注释 |
| 1.2 | `HardwareDetailPanel.ConnectionRing` | 12 Hz `Timer` 写 `@State phase` + `.animation(.linear(0.1), value: phase)`：事务几乎 100% 在飞；且 timer 存成局部 `let`，**弹出框关闭后从不 invalidate**，一直改一个已经没有 view 的 `@State` | 换成 `DecorativeMotion(kind: .arc/.pulse)`（Core Animation 图层，带遮挡观察者），`tick()` 与 `phase` 删除。**后来四只环整体被三段式检查器取代**（环在量一个位置，而这里要回答的是「走哪条路、过哪道门、挂了什么」），`.pulse` 那一路保留给了本机代理的呼吸点，`.arc` 仍由灵动岛用量卡在用；两版面板都没有留下每帧在跑的东西 |
| 1.3 | `NotchIslandView.IslandPaceRing` | `pace` 是今日/昨日比，每一次用量索引重扫都会变（FSEvents 突发可到秒级多次）；`.animation(.snappy, value:)` 挂在**永远在屏**、且 `UIWakePolicy` 明确不算可见的收起态面板上，且没走减弱动效 | 删除该修饰符（`Shape.trim(to:)` 本身是 `Animatable`） |
| 1.4 | `LucideRotor` 轮缘量规 | `.animation(value: rpm)`：SMC 大多数 2 s 轮询都会给出不同的 RPM，风扇转速稳定时也每 tick 开一次事务 | 动画键改为 `gauge`——读数量化到 1.5 % 的最小可见步长，未跨步就不开事务；`withAnimation` 只在这个量化值上。旋翼角速度仍读实时 `rpm` |
| 1.5 | `ProxyCaptureStore.init` | 首次挂载流量页时在**主线程**上开 SQLite、recover orphans、prune、读 120 行列表；`sample` 里这条链路占整个切换的叶子样本约四分之一（探针自身符号被 strip，只能按比例看） | `init` 变空，列表改由 `loadListIfNeeded()` 在后台队列读、幂等、`TrafficView.onAppear` 触发；`publishList` 合并读取期间新产生的记录（否则按 id 的实时更新会丢行）；`reloadPersistence` 同样移到后台 |
| 1.6 | `SessionCardView` | `.animation(Theme.Animation.smooth, value: agentTotals.running)`：`running` 来自 `ProviderStore.$sessions`（忙 2.5 s / 闲 5 s），而这张卡在计数变化时没有任何可插值的东西（胶囊是纯 `Text`，数字走 `RollingNumberText` 自己的 roll） | 删除 |
| 1.7 | `LucideHardwareGeometry.path(for:)` | CPU 轮廓 30+ 条路径指令，由每帧运行的 `Canvas` 构造，dashboard 上同时 4 个 | 按 `Kind` 缓存（`@MainActor` 静态字典，几何是常量的纯函数） |
| 1.8 | `HardwareIllustration` 扫光相位 | `phase(level:at: date)` 用绝对时钟（`timeIntervalSinceReferenceDate`），两张同读数的 tile 相位不同，`paused:` 恢复后会落在扫光中途 | 相位改为「出现以来的秒数」（`@State sweepStart`），`paused:` 恢复即从扫光起点开始 |
| 1.9 | `HardwareIllustration.drawReading` | 每帧 `cells.map(clamp)` 分配数组 | 改为就地取整，去掉每帧分配 |

`Tests/inflight-animation-regressions.py` 新增三条守卫（`SessionCardView`、`IslandPaceRing`、`LucideRotor` 的量化写入），每条都用「重新引入 bug」的负控验证过——其中 `LucideRotor` 的第一版断言写成了「文件里出现 `gaugeValue`」，把写入改回 `rpm` 仍然通过，改成断言 `let next = gaugeValue` 后才真正拦住。


| 项 | 现象 | 为何不动 |
|----|------|----------|
| 页面切换 20–35 次 >20 ms 帧 | 每 2 s 一次点击，8 页轮换 | A/B 过 `transition(.identity)`（完全去掉页面淡入淡出）与 `.opacity` 两种改法：`>20ms` 24→25→24，无差别。所谓「切换卡顿」的实际归属是**每 2 s 发生一次的 `EqualRowGrid` 尚未动画**（已修，见上 1.1）与**目标页首次挂载**，不是过渡动画本身。为了 0 可测收益去掉动效不符合「保证动效效果」的要求 |
| **卡片阴影**（本轮最终定位到的那一层） | 见下节 | 已修：`TileSurface` 的 `.shadow` 改为图层阴影。下面的表格同时记录了**哪些表面不值得改**（面板、chip），那几条是负结果，别重复尝试 |
| `HardwareIllustration` 的 30 Hz `TimelineView` + `Canvas` | 4 个 tile 同时每帧构造路径 | **已修（2026-09-29）**：A/B `animates()` 恒 false 曾把这条读成「不值得动」——滚动 82–87 fps → 83–91 fps，区间重叠。但那次量的是**滚动帧率**，而这条调度的代价在**空闲显示周期**上（见本节开头 2026-09-29 两节与 [UI 审计待办](ui-audit-backlog.md) §11）：时间线活着时每个显示周期都重排整个 hosting view。现在扫光是 `ReadingSweep` 的 `CAGradientLayer`，`TimelineView` 从这条路径上消失 |
| `SankeyWaveLayer` 每 tick 重建 `CGPath` | `PowerFlowCard` 的波浪带，1 Hz | 属 1 Hz 而非每帧；`waves != self.waves` 的守卫在构造之后，是真实浪费但要重排 `SweepClock` 的接口，本轮未动 |
| `TrafficView` 整页观察 `catalog` | `livePreview` 按 0.1 s 节流发布 | 该页的连接检查器确实要实时内容。**真正的修法是把 `livePreview` 拆成按行的子视图各自观察**，那是视图重构而不是性能补丁；本轮只修掉它在挂载路径上的同步 SQLite（见上 1.5） |
| `VPNView` 的 O(nodes) 派生在 `body` 里 | `proxiesByName` / `livePath` 每次 body 重建 | 订阅体量大时才是问题；需把派生值上移到 `VpnManager` 作为存储态，改动面大，未做 |

量具与脚本留在 `/tmp`（`FrameProbe.swift` / `cbsample.py` / `build-variant.sh` / `ab2.sh` / `axclick.swift`）：
`build-variant.sh <name> <srcdir>` 造带符号的 `-O -g` 探针包，`ab2.sh <A> <B> <轮数> park|scroll|switch <秒> [页]`
交替两臂跑。注意**两个 app 实例同时跑会互相污染**（另一个实例的窗口同样在提交帧，也会抢主线程），A/B 必须一次只跑一个。

**两个量具坑，都会把结论带偏**：

1. **点错页 = 量到静止窗口。** 上一版的 `oneclick` 用一张写死的像素偏移表（`[314,385,…]`，为 1120pt 宽的窗口量的）点顶栏；窗口后来是 1248pt 宽，每一次点击都落在两个 tab 的缝里。`park` / `switch` 因此在**什么都没切换**的情况下测了一整轮「静止的概览页」——而静止窗口与满帧窗口的数字长得很像（见下一条），所以它不会报错，只会给出一个安静的错误答案。现在导航走 `axclick` / `frameprobe` 的 AX 分支：读应用自己的可访问性树，按 tab 暴露的 label（`概览`/`会话`/…）`AXPress`，并且探针会打印 `pressFails=`，非 0 就是没点中。
2. **静止窗口在 SCStream 上不可判别。** 本机先做了对照（`shadowprobe`）：三个完全一样的静态卡片，一个带 SwiftUI `.shadow`、一个带图层阴影、一个不带，**三者都是 ~49 fps**——静止窗口只拿到约 50 帧/秒的非 idle 提交，三臂在噪声里。给同一个卡片加一个每帧移动的圆点后，三者都变成 ~120。也就是说「影子贵不贵」这个问题，只有在窗口**正在重绘**时才测得出，静止窗口上的任何 A/B 都只是在量合成器自己的节奏。概览页恰好是每显示周期都在重绘的（就是上一节那个在飞事务），所以它能判别——这也是为什么它恰好停在 60：app 每个显示周期都提交，但每两个周期才完成一次。

### 2026-09-26（续）：定位到 `.shadow`，并用独立两臂重测

**先更正上一节。** 上面「四个否证实验都是零结果」那张表**不能作为证据**：它们跑在 `/tmp/arms.sh` 上，而那个脚本的每个开关都是 `environment["X"] != nil` 判空——`env X=0` 是**开**。写 off 臂时把变量设成 0 而不是**不设**，就让 off 臂等于 on 臂，四行零结果全是这么来的（`arms.sh` 头部后来补了这条规则）。要复现一个「关掉它」的对照，off 臂必须**完全不带**这个环境变量。下面改用**两棵真实的源码树**各打一个 `-O -g` 探针包，不再用带开关的单构建。

**结论：页面上最贵的一件事是 `.shadow()`，而且贵得离谱。** 概览页静止 6 s、SCStream 计入的合成帧、两臂交替、一次只跑一个 app：

| 臂 | `TileSurface` 的投影 | 帧数（6 s，中位，n=6） |
|---|---|---|
| `sbase` | `.shadow(color:radius:y:)`（原样） | **383**（min 371 / max 388） |
| `slayer` | `LayerShadow`（CALayer + `shadowPath`） | **741**（min 727 / max 752） |

区间**完全不相交**，1.9 倍，p50 从 16.8 ms 回到 8.3 ms（`p99` 19 → 9–16）。同一对臂在另外四种条件下同向：`模式`页 462 → 693；`连接器` 605 → 726。

**用户要的那两件事（切换、滑动），按 fps 和卡顿次数列在这里**——它们不是「平均帧率上升」，是 `>20 ms` 的帧基本消失：

| 负载 | | 帧数 | fps | p50 | p99 | >20 ms |
|---|---|---|---|---|---|---|
| `scroll`（会话页来回滚 8 s） | 修复前 | 628 | 77.9 | **14.0 ms** | 18.7 | 1 |
| | 修复后 | 1019 | **119.2** | **8.3 ms** | 9.6 | **0** |
| `switch`（8 页每 2 s 切一次，16 s） | 修复前 | 1499 | 89.5 | 8.5 ms | 18.8 | 4 |
| | 修复后 | 1920 | **112.4** | 8.3 ms | 17.5 | **0** |

滚动那一行是这两条里更说明问题的：修复前 p50 是 14.0 ms（71 Hz 的中位节奏，也就是**每一帧都在 60–72 Hz 之间拖**），修复后 p50 8.3 ms 就是本机 ProMotion 的原生节拍。修复前 `hist` 里 334 帧落在 12–17 ms 带、176 帧落在 17–25 ms 带；修复后 1609 帧落在 8–12 ms 带，17 ms 以外一共 31 帧。

视觉不变：圆角、radius 5/9、y 1/4、opacity 0.04/0.07、底下的 `cardSurface` 填充都照旧，阴影仍然由 `cardSurface` 画出剪影。用「同一构建连拍 4 张取中位数」的办法把两臂各拍一组再相减：两张中位数图之间 94.95 % 的像素逐位相同，**最大差 1 个色阶、中位数 0**（同一臂自己前后两张的中位数图也有 0.95 % 的像素在动，是真实时钟驱动的元素），阴影在卡片下沿的衰减剖面（+1/+3/+5/+7 px 行均值）两臂逐点一致。所谓「4.9 % 的像素有变化」里绝大部分是时间噪声，不是渲染差异。

**悬停动效也逐项验过**（`hoverprobe`：把指针停在卡片上，前后各拍一张）。静息态卡片下沿在 y=545、悬停态在 y=541 —— 抬起 4 图像像素 = 2pt，和 `.offset(y: lift && hovered ? -2 : 0)` 一致；下沿以下的第一行亮度 181.2 → 177.8，再往下的衰减整条变暗（239.6/243.2/248.0 → 234.9/238.4/243.0），和 `.shadow` 的 0.04→0.07、radius 5→9 对上。也就是说换成图层阴影之后，**抬起、加深、边缘与底色冲洗四件事都还在**，只是投影改由渲染服务器栅格化。

**原因**：`.shadow(...)` 是 display-list 里的一个 filter。它不是「一次栅格化」——只要卡片子树被访问，它就每显示周期重跑一次，并把该子树变成合成单元。`CALayer` + 显式 `shadowPath` 交给渲染服务器，栅格化一次，视图图里不再有这条。和 `DecorativeMotion` 是同一条规则：**它是画，不是状态，就该由渲染服务器拥有**。诊断特征也对得上：`sample` 的叶子归属里 `CALayer _display` / `NSDisplayCycle` 两臂都在跑，而降下来的正是「每周期能不能做完」这一件事。

**不是所有 `.shadow` 都值这个价——代价跟被投影的子树走。** 三条负结果，用同一套两臂对照测的，都**不要**去改：

| 表面 | 阴影底下是什么 | 改成图层阴影后 |
|---|---|---|
| `TileSurface`（卡片） | `DepthLens` 的同心环 + 边框 + 悬停态 | 383 → 741，**+93 %** |
| `PanelCardModifier`（面板，19 处） | 两个圆角矩形 | 384 → 386，无变化 |
| 按钮/chip（`InstrumentControls` / `UiverseKit`） | 2–3 个胶囊 + 渐变 | 738 → 736，无变化 —— **但这只是在概览页**，见下面「最大的一处」：换成按钮密集的模型页就是 1260 → 2019 |

所以「把 `.shadow` 换成图层」不是一条可以全局套用的规则：面板和 chip 的子树本来就便宜，换成图层只是在渲染服务器上多挂一层，没有任何可换回的东西。**改之前先量那张表面**，用上面的 `ab2.sh`。

**仍然没有查清的静息开销**：概览页现在到 120 了，但 `模型` / `连接器` / `设置` 页静止时还是 87–115 fps，`VPN` 页在 70–105 之间抖。又排掉了两条候选（同样是两棵真实源码树、交替两臂）：

| 候选 | 做法 | 结果 |
|---|---|---|
| 卡片角上的 `DepthLens` 同心环（每张卡一个 `Canvas`） | 把 `DepthLens` 的 `Canvas` 循环清零（帧还在，环不画） | 概览 733 → 734、设置 542 → 568，**无变化** |
| 命令面板的 `shadowCard`（双层 `.shadow`，`CommandPalette.swift:89`） | 删掉两层阴影 | 746 → 755，**无变化**——面板默认是关的，这条本来也不该有影响，测它是为了确认它不在静息路径上 |

所以剩下的开销仍然不在「某个具体的绘制」上；`sample` 的叶子归属在「设置」页几乎全是 `mach_msg`（99.5 %），而「概览」页是 31 % ——也就是说这两页的 99 fps 与 120 fps 之间的差别，是**主线程之外**的东西在抢提交时机，不在主线程的视图遍历里，用主线程采样看不到。下一步要换的量具是仪表化的合成时机（`CA::Transaction` 的 commit 时长分布），而不是继续加 `sample`。这段是负结果，别再重复。

### 2026-09-26（再续）：深滚两屏，暴露了「滚动」的真正短板

**上一节的 `scroll` 数字偏乐观，因为那个探针只滚了一屏。** `scroll` 原来是「向上 60 tick 再返回」，页面比窗口高，所以这一趟只碰到了最上面一屏——最便宜的那段。改成「60 上 + 60 下 + 110 上 + 110 下」（10 s，覆盖到目录网格的后面几行、设置页的下半段）之后，另外三页的真相出来了：

| 页 | 浅滚（旧口径） | **深滚（新口径）** | 深滚 p50 | >20 ms |
|---|---|---|---|---|
| 概览 | 116 fps | **118 fps** | 8.3 ms | 1 |
| 会话 | 119 | **119** | 8.3 ms | 0 |
| 用量 | 116 | 119 | 8.3 ms | 0 |
| 流量 | 120 | 119 | 8.3 ms | 1 |
| 模型 | 77 | **72**（修复前 60） | **16.1 ms** | **73 / 10 s** |
| VPN | 84 | **92**（修复前 68） | 8.5 ms | 7 |
| 设置 | 87 | **61–85**（修复前 60） | 16.6 ms | **39 / 10 s** |

修复对这两页仍然有效（`sbase` 深滚 736 帧 / 60.5 fps，`sfinal` 1005 帧 / 84.8 fps；模型页 60 → 72），但**它们没有到「丝滑」**，而这是目标里明确点名的「滑动」。诊断：滚动中的主线程采样里 `NSView _layoutSubtree` 292 %、`CA::Transaction` 242 %、`stepIdle` 115 %、`AG::Subgraph` 88 %、`NSHostingView` 57 %、`runAnimationGroup` 5 % —— 是**每帧都在重跑整棵 hosting view 的布局**，不是某个动画在飞（那项只占 5 %）。

又排掉一个候选：设置瓦片的 `GlyphWell`/`InstrumentGlyph` 是 `Canvas`，设置页有 23 个，看着很可疑；把它的 `Canvas` 短路（不画任何路径）后深滚 773 → 820 帧、1007 → 1026 帧，**无变化**。所以也不是「每帧重画那些小 canvas」。这条测的是那次改版**之前**的设置页瓦片墙（`SettingTile`，已随设置页重做删除，见 [设置页](../design/surfaces/settings.md)），结论仍然有效：它测的是小 `Canvas` 的成本，与被删的视图无关。

一个必须一起读的口径坑：`ab2.sh` 的两次独立运行会差到 ±20 %（设置页深滚同一构建量到过 773 / 1007；主线程忙碌占比从 33 % 到 70 %），因为**合成器的提交节奏跟窗口前景焦点和机器负载走**。所以上面那些「有变化」的结论必须靠 `>20 ms` 的次数和 `p50` 一起判，不能只看帧数。

**再深一层：60 → 87 是稳定的，再往上没有找到。** 把扫程加到「60+60+110+110+200+200 tick」（19 s，滚到设置页最底部）再量同一对臂：`sbase` 1146 帧 / 60.2 fps（`p50` 16.7 ms，`>20ms` 16 次），`sfinal` 1649 帧 / **86.9 fps**（`p50` 8.9 ms，`>20ms` 2 次）。同一构建在不同轮次里量到 61–102 fps 都是有的，所以**别拿单轮数字下结论**，但 `p50` 16.7 → 8.9 这个方向在每一轮里都在。

**滚动中最贵的一件事是悬停抖动，而且它不在卡片的投影里。** 让探针只在两种指针位置上滚同一页（设置，深滚）：

| 指针位置 | 帧数 | fps | p50 | p90 | `>20 ms` | 8–12 ms 带 |
|---|---|---|---|---|---|---|
| 停在窗口中央（默认，指针每帧扫过不同的 tile） | 1001 | 86.5 | 8.8 ms | 17.2 ms | 0 | 544 |
| 停在窗口右侧空白槽里（不碰任何 tile） | 1267 | **102.5** | 8.5 ms | **15.7 ms** | 1 | **916** |

也就是说：滚动时指针每经过一个 `SettingTile` 就翻转一次它的 `hovered` `@State`，而 `.hoverTile()` 的 `.contentShape` + `.onHover` + `.tile(...)` 每个都是每帧重新求值的东西。这解释了为什么 `sample` 里 `NSView _layoutSubtree` 会到 292 %——**每一次 hover 翻转都是一次布局**，不是「某个动画在飞」（`runAnimationGroup` 只占 5 %）。这条是对**旧设置页**（瓦片墙）量的，那张墙已随设置页重做整片删除（新页面一组一张中性面板、行内不放悬停表面，见 [设置页](../design/surfaces/settings.md)），所以这一页不再有这条成本；保留在这里是因为**结论本身**仍然成立——`.hoverTile()` 的每一处调用点都带来同样的每帧求值，滚动网格里尤其要当心。

**但这条只解释了设置页，不解释模型页和连接器页。** 同样把指针停进空白槽再滚「模型」（64.8 → 67.8 fps）和「连接器」（68.8 → 69.1 fps）几乎不动——这两页的成本跟指针无关。而且这两页的 `p50` 是 16.4–16.5 ms、`p90` 17.7–18.4 ms、`>20 ms` 只有 1 次：**不是抖动，是稳稳地按 60 Hz 走**。这和上一节「概览页修复前停在 60」是同一个签名（每个显示周期都提交、每两个周期才完成一次），但它和指针无关、和卡片表面无关、和网格容器无关，本轮没有定位。

**然后找到了这一轮最大的一处：`InstrumentButton` 的板面阴影。** 同一个病，但在「应用里重复次数最多的那个组件」上——`ProviderDirectory` 每张卡就带 8 个按钮。它原来是一条 `.compositingGroup()` + 两层 `.shadow()`（黑色一层 + `tint.opacity(0.18)` 一层，参考图里 `:after` 与 `:before` 的关系）。改成 `LayerShadow`（`shadowPath` + 兄弟图层承载第二层）之后：

| 页（深滚 16 s） | `.shadow` | 图层阴影 | p50 | `>20 ms` |
|---|---|---|---|---|
| 模型（provider 目录） | 1260 帧 / 66.6 fps | **2019 帧 / 108.6 fps** | 16.5 → **8.4 ms** | **73 → 0** |
| VPN | 1760 / 92.5 | **2181 / 114.8** | 8.5 → **8.3 ms** | 8 → **1** |
| 设置 | 1672 / 88.1 | **1834 / 96.3** | 8.7 → 8.5 ms | 0 → 0 |

视觉：模型页整页 99.18 % 的像素逐位相同，最大差 **9 个色阶**（0–255）、平均 0.013——就是抗锯齿边缘重新栅格化。两层阴影的半径、偏移、透明度和颜色都照旧，只是其中一层改由兄弟图层承载（一个 `CALayer` 只能带一层阴影）。

**这一步推翻了前面那句「面板/chip 的阴影不值得改」。** 那张表里 chip 那行（738 → 736，无变化）测的是**概览页静止**——概览页上几乎没有 `InstrumentButton`，所以那个实验证明的是「概览页没有这种按钮」，不是「按钮阴影不贵」。**代价是每按钮的，而按钮按页面的个数算**：同样的改动在模型页值 +63 %，在概览页值 0。

**剩下没有解决的**：连接器页深滚 1270 → 1288（无变化）、设置页只到 96 仍未到 120，两页都是 `p50` 16.4 ms、`p90` 17.7 ms、`>20 ms` 只有 2–4 次——**又是那个「稳稳地按 60 Hz」的签名**，和指针无关、和卡片表面无关、和按钮阴影无关。这一条没有定位，也不该再靠猜着删东西去试（这一轮已经试掉七个候选，六个是零）。

**这一轮交付后的全页深滚实测**（16 s，三趟扫程，发版构建）：

| 页 | 修复前 | **修复后** | p50 | p90 | `>20 ms` |
|---|---|---|---|---|---|
| 概览 | 60 | **119.8** | 8.3 | 8.7 | 0 |
| 会话 | 78 | **119.7** | 8.3 | 8.7 | 0 |
| 用量 | — | **114.6** | 8.3 | 9.0 | 0 |
| 流量 | — | **119.7** | 8.3 | 8.7 | 0 |
| VPN | 68 | **114.5** | 8.3 | 8.9 | 0 |
| 模型 | 60 | **87.9** | 8.8 | 16.9 | 0 |
| 设置 | 60 | **95.3** | 8.5 | 16.9 | 2 |
| 连接器 | 60 | **68.2** | 16.4 | 17.7 | 4 |

八页里**五页到 114–120 fps**，一页（VPN）当轮是最低到 92 的页之一、这一轮 114.5，说明它已经在 108–115 之间；**设置 95、模型 88 还在 100 以下，连接器 68 基本没动**。`p50` 这一列是最干净的判据：凡是到位的页都是 **8.3 ms**（本机 ProMotion 的原生节拍），没到位的两页是 8.8 / 16.4 ms——**连接器页仍是「每帧都在晚」**，不是抖动。

切换（8 页每 2 s 一次，16 s）在全部构建上都是 112–116 fps、`>20 ms` 0–2。

**已经排掉的，别重复**：`DepthLens` 的 `Canvas`（733 → 734、542 → 568，无变化）、`InstrumentGlyph` 的 `Canvas`（773 → 820、1007 → 1026，无变化）、把设置页的 `EqualRowGrid` 换成 `LazyVGrid`（1011 → 1029、844 → 814，无变化）、`TileSurface` 的 `clipShape`（1033 → 1010、828 → 828，无变化）、命令面板的 `shadowCard`（746 → 755，无变化）、面板的 `.shadow`（384 → 386）。**卡片本身已经不再是瓶颈**——上面这一串里每一张卡片表面的改动都是零，剩下的成本是这样卡的**个数 × 它们被指针扫过的次数**。

