# 状态中枢 `ProviderStore`

> ClaudeBar 技术文档 · §3
> 相关：设计文档 [交互流程](../design/06-interactions.md) · [数据模型](../design/03-data-models.md) · 技术文档 [数据访问层](04-data-access-layer.md) · [性能与并发](08-performance.md)

`ProviderStore: ObservableObject` 是唯一真值源，持有全部 `@Published` 状态。`init()` 留空，由 AppDelegate 在窗口/状态栏就绪后调用 `refresh()`。`deinit { sessionTimer?.invalidate() }` 释放轮询定时器（B1）。

## Published 状态

| 字段 | 类型 | 含义 |
|------|------|------|
| `providers` | `[Provider]` | 全部 Provider 配置 |
| `activeProviderID` | `UUID?` | 当前激活 Provider |
| `currentEnv` | `EnvConfig?` | 当前 settings.json 的 env |
| `hasSettingsFile` | `Bool` | settings.json 是否存在 |
| `balanceText` / `balanceLoading` | `String?` / `Bool` | DeepSeek 余额（`balanceText` 含币种，B10） |
| `sessions` | `[SessionInfo]` | Claude Code 活跃会话 |
| `cursorSessions` | `[CursorSessionInfo]` | Cursor 活跃会话 |
| `usageStats` / `usageLoading` | `[ModelUsage]` / `Bool` | token 用量 |
| `usagePeriod` / `usageReferenceDate` | `UsagePeriod` / `Date` | 用量周期，变化即重算 |
| `collapsedProviderIDs` | `Set<UUID>` | 折叠的 Provider |
| `expandedSessionPIDs` | `Set<Int>` | 展开的会话（显示子 Agent） |
| `cursorExpanded` | `Set<String>` | 展开的 Cursor 会话 |

## 刷新管线 `refresh()`

```
refresh()
  ├── hasSettingsFile = ...
  ├── currentEnv = SettingsManager.readSettings()       ← 返回 EnvConfig?（B11 简化）
  ├── loadProviders()          ← 含旧格式迁移 + 当前 Provider 探测
  ├── refreshBalance()         ← async, DeepSeek API（balanceText 含币种，B10）
  ├── refreshUsage()           ← Task.detached 扫描 jsonl（weak self，B2）
  ├── refreshSessions()        ← 同步扫 sessions/*.json → refreshCursorSessions()
  ├── startSessionPolling()    ← 2.5s 定时器（deinit 释放，B1）
  └── writeWidgetSnapshot()    ← diff 后推送 Widget（B6）
```

`usagePeriod` 与 `usageReferenceDate` 的 `didSet` 仅在值变化时触发 `refreshUsage()`（B8）。`refreshCursorSessions()` / `refreshUsage()` 的 `Task.detached` 用 `MainActor.run { [weak self] in }` 捕获弱引用，避免强引用 self（B2）。

## `loadProviders()` 的当前态探测

加载 providers.json 后，用 `currentEnv.ANTHROPIC_BASE_URL`（trim `/` 后）匹配出当前激活 Provider，再用 case-insensitive 匹配 `ANTHROPIC_MODEL` 定位其 `activeModelID`，并立即 `saveProviders()` 持久化探测结果。这使得用户在 Claude Code 外手改 settings.json 后，ClaudeBar 能识别当前态。

## `activateModel` 写入流程

```
activateModel(providerID, modelID)
  ├── buildEnv(provider, model)     ← 构造完整 EnvConfig
  ├── SettingsManager.writeSettings(env)   ← 合并写回 settings.json
  ├── activeProviderID = providerID
  ├── currentEnv = env
  ├── providers[idx].activeModelID = modelID
  ├── saveProviders()
  └── refreshBalance()
```

`buildEnv` 把所选 `model.name` 同时写入 `ANTHROPIC_MODEL` 与 8 个 `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL[_NAME]`，确保 Claude Code 内部按 tier 路由时一致。
