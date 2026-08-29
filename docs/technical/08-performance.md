# 性能与并发

> ClaudeBar 技术文档 · §8
> 相关：技术文档 [状态中枢](03-provider-store.md) · [数据访问层](04-data-access-layer.md)

| 点 | 策略 |
|----|------|
| 会话轮询 | 2.5s `Timer.scheduledTimer`（间隔 `AppConfig.sessionPollInterval`）；定时器只触发，`refreshSessions` 的扫描在 `Task.detached(priority: .utility)` 中离主线程执行，回主线程仅发布结果 |
| 心跳采样 | 每轮 busy/idle 采样追加进 `heartbeats[pid]`，上限 `AppConfig.heartbeatLength`（24，≈ 最近一分钟） |
| 空闲通知 | `IdleTransitionDetector` 只做边沿检测（busy→idle 各一次），无额外轮询 |
| Cursor DB 查询 | `Task.detached` 后台执行，DB 大但走 `(recency, composerId)` 索引 + LIMIT 80 |
| transcript 扫描 | 只读尾部 96KB（会话）/ 32KB（子 agent），不全读 |
| 用量统计 | `Task.detached` + 三级过滤 + `concurrentPerform` 并行解析；`UsageStats` 文件缓存带容量上限（4000）与驱逐，防项目树收缩后无限滞留 |
| 主线程 | 所有 `@Published` 更新经 `MainActor.run { [weak self] in }` / 主线程回调 |
| 快照写入 | `WidgetSnapshotWriter` diff 后写四路（B6：仅数据变化时写文件 + `reloadAllTimelines()`，避免每 2.5s 空转） |
