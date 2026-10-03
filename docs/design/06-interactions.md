# 关键交互流程

> ClaudeBar 设计文档 · §6
> 相关：[数据模型](03-data-models.md) · 技术文档 [状态中枢](../technical/03-provider-store.md) · [数据访问层](../technical/04-data-access-layer.md)

## 切换 Provider / Model

1. 用户点击 popup 的模型行，或在目录瓦片上选好模型后按「激活」→ `ProviderStore.activateModel(providerID:modelID:)`。
2. `buildEnv()` 用所选 Provider + Model 构造完整 `EnvConfig`。
3. `SettingsManager.writeSettings(env:)` 读现有 JSON，按 `managedEnvKeys` 删掉旧值、再把非空的 `EnvConfig` 值写回（空值即清除，不保留），`permissions` 等顶层字段原样保留，`PrivateFileWriter` 0600 暂存 + `rename` 写回 `~/.claude/settings.json`；URL 的可读斜杠靠 `JSONSerialization` 的 `.withoutEscapingSlashes`，不是写后替换（机制见技术文档 [§4](../technical/04-data-access-layer.md)）。
4. 更新 `activeProviderID` / `activeModelID`，持久化 `claude-bar-providers.json`（`FilePaths.presetsFile`），刷新余额。
5. popup 页头显示 `FeedbackToast`（Claude 侧文案 `CC · <模型名>`，Codex 侧 `Codex · <模型名>`；由 `PanelState.feedbackToken` 驱动 `.task(id:)`，2 秒后淡出）。
6. Claude Code 与 Codex 独立激活：切换一侧只写该侧配置。共享代理会刷新上游状态，但不会选择另一侧的供应商或模型。

> **设计取舍（`managedEnvKeys` 的清除语义，B4）**：`writeSettings` 先删掉全部 `managedEnvKeys`、只把非空的新值写回，所以切换 Provider 时上一个 Provider 的 token / 模型变量会被清掉，而用户手填的**非托管**变量原样保留。已经过时的旧说法是「空值不覆盖旧值、旧 token 会残留」——现在的方向相反：托管的空值就是删除。若以后要保留某一项手填值，应把它移出 `managedEnvKeys`，而不是恢复「空值不覆盖」的语义。

## 会话监控（2.5s 轮询 + 心跳 + 空闲通知）

1. `ProviderStore.refresh()` → `startSessionPolling()` 启动 2.5s 定时器（间隔定义在 `AppConfig.sessionPollInterval`）；定时器只触发，扫描在 detached task 中离主线程执行。
2. `SessionMonitor.fetchActive()`：扫描 `~/.claude/sessions/*.json`，解析 PID/cwd/status，用 `kill(pid, 0)` 判活，按 recency 排序。
3. 对每个活跃会话 `fetchContext()`：读其 transcript `*.jsonl` 的**尾部 ~96KB**，取最后一条 assistant 消息的 `input + cache_read + cache_creation` 作为当前上下文 token，并从最近的 `tool_use` 推断当前活动；若 `tool_use` 后无 `tool_result` 则标记 `toolPending = true`（busy）。
4. `fetchSubagents()`：扫描会话目录的 `subagents/*.meta.json` 与 `subagents/workflows/<id>/`，聚合子 Agent 与 Workflow。
5. 每轮把 busy/idle 采样追加进 `heartbeats[pid]`（长度 `AppConfig.heartbeatLength`，默认 2.5s×24 ≈ 最近一分钟），驱动瓦片上的 `HeartbeatSparkline`。
6. `ConfirmedCompletionDetector` 判定「这一轮真的交付了答案」：该会话的轮次键变了 + 它自己的文件刚写过（60 s 内）+ 当前不忙（三条同见 [§03-provider-store](../technical/03-provider-store.md)）。命中且 `AppPreferences.idleNotifyEnabled` 开启时，经 `NotificationService` 发系统通知（"最终答复已就绪"，附 Resume 动作）；点按通知经 `.resumeSession` 通知回 AppDelegate 用 `TerminalLauncher` 恢复会话。Cursor / Codex 同一条规则，只是轮次键取各自的本机字段（Cursor 用 transcript 字节偏移 `turn-<offset>`、Codex 用 `task_complete.turn_id`，文案随各自客户端）。
7. `CursorSessionMonitor.fetchActive()` 在后台线程读 Cursor 的 `state.vscdb`（SQLite，只读，WAL 安全），按 `recency` **或 `checkpointAt`** 取最近 3 天内活跃的非归档 composer，**先判运行状态再按忙碌优先排序**（列表通常保留 14 个，但运行中的会话不受这个数量限制），再扫描其 transcript 与 checkpoint 补充活动状态——**「有轮次在飞」的判据是两条写时钟取其一**：JSONL 的最后一条 user **或** assistant 行在最后一个 `turn_ended` 之后（`toolPending`）且文件 mtime 在 10 分钟内，或者存在未完成的 run（`unfinishedRunAt > 0`）且 `max(unfinishedRunAt, checkpointAt)` 在 10 分钟内（中断的轮次不写 `turn_ended`，只按行序判定会让一条冻结的文件永远算忙；而 Cursor 会持续写 checkpoint 却可能很久不导出 JSONL，只看 JSONL 会把长任务判成闲置；带有终态标记且标记晚于 `unfinishedRunAt` 的 transcript 直接收尾）。细节见 [Cursor 监控排查](../technical/cursor-session-monitor-investigation.md)。
8. 全部结果回主线程后 `writeWidgetSnapshot()` 同步给 Widget。

## 用量统计

1. `ProviderStore.refreshUsage(rescan:)` 在 detached task 上跑：先发布索引里的缓存结果（有缓存时立刻可读），再 `UsageIndex.updateIndex()`，最后再查一遍索引并发布最终值。
2. `UsageIndex` 是持久化索引，不做现扫：每个 transcript 只解析一次，按 (文件, 天, 模型) 落成汇总行（SQLite `usage-index.db`，或 JSON 后端 `logs/usage-files.json` + `usage-rollup.jsonl`），查询即一次 `GROUP BY`。增量维护按 mtime + size 跳过未变文件、只从字节 `offset` 解析追加块——细节见技术文档 [§4](../technical/04-data-access-layer.md)。
3. 查询 `UsageIndex.fetch` / `fetchBySource` / `fetchDaily` / `fetchDailyModels` / `fetchSession` 聚合 `ModelUsage`（input/output/cacheRead/cacheCreation）与按日 `DayUsage`；第三方（代理）流量由 `ProxyUsageStore` 的独立汇总并入，见技术文档 §4。

## 编辑 Provider（独立窗口 / 主窗口页面）

点击菜单栏 popup 底部 "管理模型" 图标 → 主窗口切到「模型」页，并**在同一个通知里带上目的地**（`Notification.showMainWindow(page:editor:)` 的 `userInfo`）。窗口可能是这一刻才被建出来的，而新的 `NSHostingView` 要等第一次 display pass（约 50 ms）才订阅 `NotificationCenter`；先 post 再补一条分页通知会丢掉分页，所以目的地随同一条通知发布，或经 `ProviderStore.navigationRequest` 转发（见 [technical/05](../technical/05-view-layer.md)）。

主窗口「模型」页是供应商目录（`ProviderDirectoryHost` + `ProviderCatalogBrowser`）：`PageHeaderCard` 页带（标题「模型」+ 副标题 + 「导入 Codex/Claude」与「自定义」）+ 当前连接条（含「仅显示已配置」开关）+ 客户端分段开关 / 分类筛选 / 搜索 + 按分类分组的网格。选中一项后用 `ProviderConnectionEditor` 弹窗编辑——名称 / Key / 接口地址 / 模型列表 / 每个模型的上下文窗口与压缩阈值 / Codex 协议与推理强度——保存时若该 Provider 当前激活，则重新 `activateModel` 应用变更。目录页即列表，弹窗不再套第二列导航。

源码里曾另有一套 master-detail 编辑器（`ProviderEditorView` / `CodexProviderEditorView` + `ProviderEditorModel`），没有挂载点，已删除；它独有的四个 per-model 字段先折进了 `ProviderConnectionEditor`，见 [审查证据](../reviews/ui-audit-backlog.md) §3。

## Widget 联动

- Widget 点击通过 `widgetURL("claudebar://")` 触发；主 app 的 `AppDelegate.application(_:open:)` 收到该 URL 后调用 `showPanel()` 弹出菜单栏面板。
- 主 app 每次状态变化构建 `WidgetSnapshot`，经 `WidgetSnapshotWriter` 与上次快照 diff——**仅在数据变化时**才写 4 路文件并调 `WidgetCenter.shared.reloadAllTimelines()`（避免每 2.5s 无意义重载，见技术文档 [§4.3](../technical/04-data-access-layer.md#writewidgetsnapshot--四路冗余写入--diffb6)）；Widget 自身 30s 也会主动刷新。
