# 性能与并发

> ClaudeBar 技术文档 · §8
> 相关：技术文档 [状态中枢](03-provider-store.md) · [数据访问层](04-data-access-layer.md)

| 点 | 策略 |
|----|------|
| 会话轮询 | 2.5s `Timer.scheduledTimer`，`refreshSessions` 同步快路径（只读 sessions/*.json 小文件） |
| Cursor DB 查询 | `Task.detached(priority: .utility)` 后台执行，DB 大但走索引 + LIMIT |
| transcript 扫描 | 只读尾部 96KB（会话）/ 32KB（子 agent），不全读 |
| 用量统计 | `Task.detached` + 三级过滤 + `concurrentPerform` 并行解析 |
| 主线程 | 所有 `@Published` 更新经 `MainActor.run { [weak self] in }` / 主线程回调 |
| 快照写入 | diff 后写四路（B6：仅数据变化时写文件 + `reloadAllTimelines()`，避免每 2.5s 空转） |
