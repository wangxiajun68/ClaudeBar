# Cursor 会话监控漏报排查（2026-09-28）

## 已确认的主要原因

本机 ClaudeBar 项目的 Cursor 会话 `1b62e4b7-b248-4a76-a5e0-a5546a6d85d5` 在运行时被监控判为 idle。

只读对照采样时：

| 信号 | 观测 |
| --- | --- |
| head `lastUpdatedAt` / `unfinishedRunAt` | 距读取约 21 分钟，是本轮提交时间 |
| JSONL | 停在本轮用户消息，未持续输出 assistant |
| SQLite `checkpointAt` | 距读取约 30 秒，排查期间多次前进 |
| `composerData` 最近消息 header | 出现新的工具调用，含 `shellStatus: running` |
| 原监控结果 | 7 个近期会话，0 个运行中 |
| 修正后生产监控结果 | 7 个近期会话，1 个运行中，恢复上述会话 |

原代码仅把 120 秒内的 `unfinishedRunAt` 当作运行信号；超过两分钟后依赖 JSONL 的 assistant 消息与 mtime。因此，Cursor 正在更新数据库、但 JSONL 暂停导出的长轮次会被降为 idle。灵动岛直接消费这个状态，漏报发生在监控层。

`agentLocation.status` 在已完成的旧会话里也保留 `active`。另一次采样中，正在产生工具调用的 composerData 顶层 `status` 仍为 `aborted`。两者都不能单独作为实时运行依据。

## 同时修正的漏报条件

1. **先截断再判运行**：原查询只读 80 个 header，先截取 14 个才扫描 transcript。现在查询最近的 header 集合，先判断运行、再排序；运行会话不受展示数量限制。这是回归测试复现的问题，并非本次实机主因（当时仅有 7 个近期会话）。
2. **等待首个回复**：原 pending 只认 assistant。现在 user 消息也开启轮次。
3. **旧结束标记压掉新轮次**：新提交尚未出现在 JSONL 时，旧成功标记不能结束新轮次，也不能发出旧答案的完成通知。
4. **错误结束未清理运行状态**：当前轮次的成功与错误结束标记都结束运行。
5. **完成时间错误**：长任务完成后的新鲜度改用实际活动/文件写入时间，避免按提交时间判断而漏通知。
6. **子 Agent 路径与父级关系**：本机子 Agent 文件实际在父会话 `subagents/` 目录；原代码按独立主会话路径读取。现在优先使用实际路径，支持挂到可见根会话，保留原路径兼容。主会话和子 Agent 共用写入时钟判断。

## 验证

`python3 Tests/cursor-turn-regressions.py` 通过 Swift 解释器直接运行完整生产 `CursorSessionMonitor`、`CursorDB` 和路径逻辑。只将 home 目录重定向到临时文件夹，SQLite 与 JSONL 都是合成数据，不修改用户数据库。

25 项检查全部通过，覆盖：checkpoint 更新但 JSONL 滞后或缺失、首 token 等待、8 分钟静默工具、过期中断、成功与错误终止、旧答案与新提交、归档、80 条以外的运行会话、超过 14 个并发会话、3 天以前提交但 checkpoint 仍活跃的任务，以及子 Agent 路径、根父级、checkpoint 与过期行为。

实机只读对照运行了修改前与修改后的生产监控代码。单次耗时分别为 33 ms 和 19 ms；这是一次采样，不是性能基准。

## 剩余边界与待验证项

- 已确认下游 `ProviderStore → IslandLiveModel → NotchIslandView` 根据发布的 `status/toolPending` 显示状态；列表本身可滚动，不会再截断为前几个会话。
- 现有轮询间隔：界面可见时忙碌 2.5 秒、闲置 5 秒；界面隐藏或灵动岛收起时 8 秒。因此状态变化仍有轮询延迟。
- 为避免崩溃或中断会话永久显示运行，保留 10 分钟写入过期边界。真实任务若 SQLite 和 JSONL 都停止写入超过该窗口，仍可能被判闲置；单靠当前持久化信号无法可靠区分这种情况与已中断任务。
- 按用户要求，没有执行应用 build、安装或重启。独立监控回归已验证；新应用的灵动岛端到端显示需在用户允许 build 后验证。
