# 关键交互流程

> ClaudeBar 设计文档 · §6（原 §5）
> 相关：[数据模型](03-data-models.md) · 技术文档 [状态中枢](../technical/03-provider-store.md) · [数据访问层](../technical/04-data-access-layer.md)

## 切换 Provider / Model

1. 用户点击模型行 → `ProviderStore.activateModel(providerID:modelID:)`。
2. `buildEnv()` 用所选 Provider + Model 构造完整 `EnvConfig`。
3. `SettingsManager.writeSettings(env:)` 读旧 env，用 `preserve()` 合并（空值不覆盖已有值），保留 `permissions` 等顶层字段，写回 `~/.claude/settings.json`（并修复 JSONSerialization 转义的 `\/`）。
4. 更新 `activeProviderID` / `activeModelID`，持久化 `providers.json`，刷新余额。
5. 面板显示 "checkmark ✓ DeepSeek / deepseek-v4-pro" 反馈 toast（2 秒后淡出）。

> **设计取舍（`preserve()` 不清空字段，B4）**：`writeSettings` 的 `preserve(newValue, existing)` 在新值为空且旧值非空时保留旧值，目的是"空预设不冲掉用户手填的 settings"。副作用是：从一个有 token 的 Provider 切到另一个未配置 token 的 Provider 时，旧 token 会残留在 `settings.json`。当前通过 `buildEnv()` 在切换时显式写入新 Provider 的 token 来覆盖此风险（激活的 Provider 总是把它的 token 写进去）。若未来需要"切换 Provider 必清旧 token"，需单独引入显式清除逻辑，而非改 `preserve()` 语义（那会破坏手填配置不被冲掉的承诺）。

## 会话监控（2.5s 轮询）

1. `ProviderStore.refresh()` → `startSessionPolling()` 启动 2.5s 定时器。
2. `SessionMonitor.fetchActive()`：扫描 `~/.claude/sessions/*.json`，解析 PID/cwd/status，用 `kill(pid, 0)` 判活，按 recency 排序。
3. 对每个活跃会话 `fetchContext()`：读其 transcript `*.jsonl` 的**尾部 ~96KB**，取最后一条 assistant 消息的 `input + cache_read + cache_creation` 作为当前上下文 token，并从最近的 `tool_use` 推断当前活动；若 `tool_use` 后无 `tool_result` 则标记 `toolPending = true`（busy）。
4. `fetchSubagents()`：扫描会话目录的 `subagents/*.meta.json` 与 `subagents/workflows/<id>/`，聚合子 Agent 与 Workflow。
5. `CursorSessionMonitor.fetchActive()` 在后台线程读 Cursor 的 `state.vscdb`（SQLite，只读，WAL 安全），按 `recency` 取最近 80 个非归档 composer，过滤 3 天内活跃的，再扫描其 transcript 尾部补充活动状态。
6. 全部结果回主线程后 `writeWidgetSnapshot()` 同步给 Widget。

## 用量统计

1. `UsageStats.fetch(in: interval)` 扫描 `~/.claude/projects/**/*.jsonl`。
2. **三级过滤优化**：① 文件 mtime 早于区间起点则跳过；② 行首 ISO 日期字符串粗筛（±1 天 slack 容错时区）；③ 精确解析时间戳并 `interval.contains`。
3. 用 `DispatchQueue.concurrentPerform` 并行解析各文件，合并为按模型聚合的 `ModelUsage`（input/output/cacheRead/cacheCreation）。
4. 追加 `CursorUsageStats.fetch()` 的全量 Cursor token，按总量降序排序。

## 编辑 Provider（独立窗口 / 主窗口页面）

点击菜单栏 popup 底部 "编辑供应商" 图标 → 打开 `ProviderEditorView` 独立 `NSWindow`（760×520，可缩放，位置持久化）。主窗口供应商页（`ProvidersView`）同样嵌入 `ProviderEditorView`，与 popup 底部按钮共用同一编辑视图。左侧 Provider 列表（增/删/复制），右侧 master-detail：Provider 配置（名/Key/URL）+ 模型列表（增/删/设默认/编辑各字段）。保存时若该 Provider 当前激活，则重新 `activateModel` 应用变更。

## Widget 联动

- Widget 点击通过 `widgetURL("claudebar://")` 触发；主 app 的 `AppDelegate.application(_:open:)` 收到该 URL 后调用 `showPanel()` 弹出菜单栏面板。
- 主 app 每次状态变化构建 `WidgetSnapshot`，与上次快照 diff——**仅在数据变化时**才写 4 路文件并调 `WidgetCenter.shared.reloadAllTimelines()`（避免每 2.5s 无意义重载，见技术文档 [§4.3](../technical/04-data-access-layer.md#writewidgetsnapshot--四路冗余写入--diffb6)）；Widget 自身 30s 也会主动刷新。
