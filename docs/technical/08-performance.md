# 性能与并发

> ClaudeBar 技术文档 · §8
> 相关：技术文档 [状态中枢](03-provider-store.md) · [数据访问层](04-data-access-layer.md)

| 点 | 策略 |
|----|------|
| 会话轮询 | `Timer.scheduledTimer` 只触发，`refreshSessions` 的扫描在 `Task.detached(priority: .utility)` 中离主线程执行，回主线程仅发布结果。间隔随可见性三档：忙 2.5s / 全空闲 5s / 无可见窗口 15s（`AppConfig.sessionPollInterval` 等，`UIWakePolicy` 驱动） |
| 可见性闸门 | `UIWakePolicy`（主窗口遮挡 / 最小化 / 关闭 + popup 开关）统一驱动：会话间隔、FSEvents 用量重扫、进程采样器、VPN `/connections` 轮询间隔、**以及动画**。`shouldAnimate` 是 TimelineView 的门控值 |
| 心跳采样 | 每轮 busy/idle 采样追加进 `heartbeats[pid]`，上限 `AppConfig.heartbeatLength`（24，≈ 最近一分钟） |
| 空闲通知 | `IdleTransitionDetector` 只做边沿检测（busy→idle 各一次），无额外轮询 |
| Cursor DB 查询 | `Task.detached` 后台执行，DB 大但走 `(recency, composerId)` 索引 + LIMIT 80 |
| transcript 扫描 | 只读尾部 96KB（会话）/ 32KB（子 agent），不全读 |
| 索引扫描 | 目录用 `FileManager.enumerator` 一次取回属性（`contentModificationDate` / `fileSize`），不再对每个命中文件单独 `attributesOfItem`（后者每个文件多走两次 `getxattr`；本机 1250 个 transcript × 每次重扫） |
| 用量统计 | `Task.detached` + 三级过滤 + `concurrentPerform` 并行解析；`UsageStats` 文件缓存带容量上限（4000）与驱逐，防项目树收缩后无限滞留 |
| 主线程 | 所有 `@Published` 更新经 `MainActor.run { [weak self] in }` / 主线程回调 |
| 快照写入 | `WidgetSnapshotWriter` diff 后写四路（B6：仅数据变化时写文件 + `reloadAllTimelines()`，避免每 2.5s 空转） |
| 动画 | 只有 `TimelineView` 是常驻成本。全部四处（`SoftRotor` / `AuroraSparkline` / `ScanLine` / `SourceStack`）都带 `paused:`，且门控值来自「真的有人看得到吗」（`UIWakePolicy.hasVisibleWindow`）而非调用方随手传的 flag。**新增动画前先确认 `paused` 边界**：漏一个就是 12–20 Hz 常驻 display link，每 tick 一次全主线程布局 |
| 磁盘 | 抓包 DB payload 随 `listLimit` 显式级联删除 + 空闲页超阈值 `VACUUM`；媒体目录按孤儿 id 清扫；`core.log` / `vpn.log` 8MB 轮转（`CoreLogWriter`） |
| 文本读取 | 所有「读尾部 N KB」路径（`SessionMonitor` / `CursorSessionMonitor` / `ExternalSessionMonitor`）与 JSONL 存储用 `String(decoding:as:)` 宽容解码：seek 常常落在多字节字符中间，严格 UTF-8 解码会让**整窗**失败（实测 600 份 transcript 中 31 份、291 份 rollout 中 14 份静默返回 0） |
