# 性能与并发

> ClaudeBar 技术文档 · §8
> 相关：技术文档 [状态中枢](03-provider-store.md) · [数据访问层](04-data-access-layer.md)

| 点 | 策略 |
|----|------|
| 会话轮询 | `Timer.scheduledTimer` 只触发，`refreshSessions` 的扫描在 `Task.detached(priority: .utility)` 中离主线程执行，回主线程仅发布结果。间隔随可见性三档：忙 2.5s / 全空闲 5s / 无可见窗口 15s（`AppConfig.sessionPollInterval` 等，`UIWakePolicy` 驱动） |
| 可见性闸门 | `UIWakePolicy`（主窗口遮挡 / 最小化 / 关闭 + popup 开关）统一驱动：会话间隔、FSEvents 用量重扫、进程采样器、VPN `/connections` 轮询间隔、**以及动画**。挂在界面上的视图读 `surfaceIsVisible` 环境值（`MainWindowView` 注入）；不在界面树里的观察者用 `hasVisibleWindow` |
| 心跳采样 | 每轮 busy/idle 采样追加进 `heartbeats[pid]`，上限 `AppConfig.heartbeatLength`（24，≈ 最近一分钟） |
| 空闲通知 | `IdleTransitionDetector` 只做边沿检测（busy→idle 各一次），无额外轮询 |
| Cursor DB 查询 | `Task.detached` 后台执行，DB 大但走 `(recency, composerId)` 索引 + LIMIT 80 |
| transcript 扫描 | 只读尾部 96KB（会话）/ 32KB（子 agent），不全读 |
| 索引扫描 | 目录用 `FileManager.enumerator` 一次取回属性（`contentModificationDate` / `fileSize`），不再对每个命中文件单独 `attributesOfItem`（后者每个文件多走两次 `getxattr`；本机 1250 个 transcript × 每次重扫） |
| 用量统计 | `Task.detached` + 三级过滤 + `concurrentPerform` 并行解析；`UsageStats` 文件缓存带容量上限（4000）与驱逐，防项目树收缩后无限滞留 |
| 主线程 | 所有 `@Published` 更新经 `MainActor.run { [weak self] in }` / 主线程回调 |
| 快照写入 | `WidgetSnapshotWriter` diff 后写四路（B6：仅数据变化时写文件 + `reloadAllTimelines()`，避免每 2.5s 空转） |
| 动画 | **没有常驻的 SwiftUI 时间线**。装饰动效全部走 `NSViewRepresentable` + Core Animation（`DecorativeMotion`、`LucideRotor`/`RotorLayerView`、`UiverseKit` 的 shine/conveyor），渲染服务器插值、不重算 body，并各自再查一次 `window?.occlusionState.contains(.visible)`；调用侧由 `UIWakePolicy` 的 `surfaceIsVisible` + 「减弱动效」双重门控。**按读数调速的那一类（`LucideRotor`）用 `timeOffset` 冻结相位后就地改 `speed`**，所以采样器每 1–2 s 推一次新 rpm 不会重建图层、也不会让扇叶跳回起点；`rpm < 80` 时速率**恰为 0**（扇叶停在原地，图层不消失）。`LucideRotor` 以角速度驱动（没有 `paused:` 参数，也不该有）。`DecorativeMotion.kind == .loadRing` 已随视图删除。全仓只剩两处 `TimelineView`：灵动岛会话行的「N 分钟前」（30s 周期，只包住一行文字），以及 `HardwareIllustration` 的读数扫光（`TimelineView(.animation(minimumInterval: 1/30, paused:))`，仅剩的两个 `TimelineView` 都是这一条的形状：周期长、或者 `paused:` 由读数 / 可见性 / 减弱动效三者按帧判定）。**新增动画前先确认门控边界**：漏一个就是常驻 display link，每 tick 一次全主线程布局 |
**隐式动画的代价（同上一条是同一类问题，只是藏在 `value:` 里）**：`.animation(_:value:)` 的 `value` 若来自每秒变一次的数据（采样器读数、会话数、到期时间），它**每 tick 都会开启一个新的动画事务**；只要有事务在飞，每个显示周期都会把整个 hosting view 走一遍 layout + display list —— 不是只在插值期间。诊断特征：`sample` 稳态里 `+[NSAnimationContext runAnimationGroup:]` 出现在 `@objc NSHostingView.layout()` **内部**。实测（dashboard，`sample` 5s）：`RollingNumberText` 上的一行 `.animation(.snappy(0.38), value: value)` 让主线程样本里 `runAnimationGroup` 占 31%、`NSHostingView.layout()` 31%、`stepIdle`（display cycle 每帧重排窗口）56%；去掉后分别是 13% / 13% / 3%。**`.numericText` 自己会动，隐式 `.animation` 是多余的**。注意本机 `ps -p PID -o time=` 差值噪声很大（Chrome renderer 常驻半核，app 自身空载在 10–27% 之间摆动），CPU 数字只作旁证，以采样归属为准。新增 `value:` 键前先问：这个值多久变一次？`Tests/inflight-animation-regressions.py` 把这条规则钉在 `RollingNumberText` 与 `SectionHeader.trailingView` 上 |
| 灵动岛常驻 | `IslandOrbit` 的 `repeatForever` 已换成 `DecorativeMotion(kind: .arc)` 的渲染服务器图层：同一启动器、同一 `-g` 树、同一个路径下换 bundle，交替采样得到「在飞事务里的 `NSHostingView.layout()` 占比」中位数 48.8%（旧）→ 31.9%（新），区间不相交，`runAnimationGroup` ≈420 → ≈285。**折叠 + 空闲**状态实测 0.5–0.7%（旧文档记的 0.8%），此时岛内几个 `.animation(_:value:)` 开关不影响读数。面板窗口按 `panelSize`（640×386）无条件给定，曾被认为是每帧代价的第二个乘数 —— 后续用「只改 `panelSize` 的两个 `-O` 构建」分三轮交替 A/B 否掉了：两臂每轮都重叠，小盒（320×80）第一轮反而更高，全部 17.0–31.6% 的散布是机器漂移。所以没有做第二个窗口 / 窗口动画缩放。见 [UI 审计待办](17-ui-audit-backlog.md) 第 7 条 |
| 无窗口时的开销 | 隐藏主窗口（⌘W，不是「隐藏 App」）后 app 的 idle 从约 25–50% 掉到约 9%：没有窗口时 AppKit 不跑显示周期，SwiftUI 的 layout / display list 全部消失。可见性闸门确实在起作用；剩下的是后台扫描（`sample` 里只剩 `com.claudebar.audioaccessory`、`com.claudebar.proc`、NSURLSession 的叶子） |
| 诊断口径 | **「把一个子视图从页面里删掉再看 CPU」不是有效实验**：删掉 `ResourceStrip`（6 个 tile）后 dashboard 的 idle 反而从 ~46% 变到 ~52–66%，因为只要有动画事务在飞，整棵 `NSHostingView` 每帧照样全量 layout。原先这条还写着「成本 ∝ hosting view 的尺寸」—— 后续用只改 `panelSize` 的两个 `-O` 构建（640×386 vs 320×80）分三轮交替 A/B 否掉了：两臂每轮都重叠，整体散布 17.0–31.6% 全是机器漂移，所以尺寸并不是那个乘数，**在飞的事务才是**（见第 7 条）。有效的量是**主线程样本里挂在哪个帧下的占比**（`NSHostingView.layout()` / `stepIdle` / `CALayer _display`），它在不同构建之间能稳定复现到 1 个百分点，而 CPU 差值在 10–27% 之间乱跳。见 [UI 审计待办](17-ui-audit-backlog.md) 第 7 条 |
| 磁盘 | 抓包 DB payload 随 `listLimit` 显式级联删除 + 空闲页超阈值 `VACUUM`；媒体目录按孤儿 id 清扫；`core.log` / `vpn.log` 8MB 轮转（`CoreLogWriter`） |
| 文本读取 | 所有「读尾部 N KB」路径（`SessionMonitor` / `CursorSessionMonitor` / `ExternalSessionMonitor`）与 JSONL 存储用 `String(decoding:as:)` 宽容解码：seek 常常落在多字节字符中间，严格 UTF-8 解码会让**整窗**失败（实测 600 份 transcript 中 31 份、291 份 rollout 中 14 份静默返回 0） |
