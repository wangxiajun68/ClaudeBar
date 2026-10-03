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
| `errorMessage` | `String?` | 写 settings 失败等错误信息 |
| `balanceText` / `balanceLoading` | `String?` / `Bool` | 各家官方余额读数（DeepSeek / Kimi / 硅基流动 / OpenRouter；`balanceText` 含币种，B10） |
| `sessions` / `expandedSessionPIDs` | `[SessionInfo]` / `Set<Int>` | Claude Code 活跃会话 / 展开的会话（显示子 Agent） |
| `heartbeats` | `[Int: [Bool]]` | 每会话最近 `AppConfig.heartbeatLength`（24）个 busy/idle 采样，驱动心跳 sparkline |
| `anySessionBusy` | `Bool` | 是否有任一会话 busy（驱动菜单栏图标脉冲） |
| `cursorSessions` | `[CursorSessionInfo]` | Cursor 活跃会话（展开态与 Claude 共用 `expandedSessionPIDs`） |
| `usageStats` / `usageLoading` | `[ModelUsage]` / `Bool` | token 用量 |
| `usagePeriod` / `usageReferenceDate` | `UsagePeriod` / `Date` | 用量周期，变化即重算 |
| `collapsedProviderIDs` | `Set<UUID>` | 折叠的 Provider |

## 派生量（`ProviderStore+Derived.swift`）

视图不再各自 reduce，统一读派生属性：`aliveSessions`、`busySessionCount`、`aliveCursorSessions`、`activeCursorCount`、`anyClaudeBusy`、`totalUsageTokens`、`totalUsageLabel`、`maxUsageTokens`、`activeProvider`、`activeModel`。

用量页的实扣只有一个出处：`CursorLedgerStore`（`rows` / `windowLabel`），由 `UsageView` 直接读取。它一度在 store 上还有一份 `usageSettlements` 平行副本与 `settlement(for:)` / `settlementCovers(_:)` / `settlementWindowLabel` 三个访问器，但没有任何视图读过——同一个事实的两个出处。

## 非路径配置（`AppConfig.swift`）

`sessionPollInterval`（2.5s）、`sessionPollIdleInterval`（5s）、`sessionPollHiddenInterval`（8s）、`heartbeatLength`（24）、`widgetSnapshotDefaultsKey`、`widgetBundleID`、`widgetSnapshotFileName`——轮询节奏与 Widget 快照键名的单点定义。可见且忙走 2.5s、可见但闲置走 5s、界面隐藏或灵动岛收起走 8s。

## 刷新管线 `refresh()`

```
refresh()
  ├── hasSettingsFile = ...
  ├── currentEnv = SettingsManager.readSettings()       ← 返回 EnvConfig?（B11 简化）
  ├── loadProviders()          ← 读 providers 文件 + 当前 Provider 探测（旧字段兼容在 `Provider.init(from:)`）
  ├── ProviderProfileSync.reconcile(claude:codex:)     ← 经 peer 对齐两侧
  ├── refreshBalance()         ← async, `BalanceFetcher` 支持的官方余额端点（balanceText 含币种，B10）
  ├── peer?.refreshQuota()
  ├── refreshUsage(rescan: true)   ← Task.detached 扫描 jsonl（weak self，B2）
  ├── requestSettlement()      ← 交给 CursorLedgerStore 按当前周期取一次实扣
  ├── refreshSessions()        ← detached task 扫描 → 心跳 → 空闲检测 → refreshCursorSessions()
  ├── startSessionPolling()    ← 2.5s 定时器（deinit 释放，B1）
  ├── observeVisibility() / startUsageWatcher() / observeAppearance()
  └── writeWidgetSnapshot()    ← diff 后推送 Widget（B6）
```

- `usagePeriod` 与 `usageReferenceDate` 的 `didSet` 仅在值变化时触发 `refreshUsage()`（B8）。
- **Cursor 的实际扣费走两个入口**：`ProviderStore.refresh()` 与用量页的周期切换（`selectPeriod` / `shiftUsage`）调 `requestSettlement()`，它按当前周期算出窗口交给 `CursorLedgerStore`（年 / 全部由账本退化为账单周期并标记）；账本读回来后发 `.cursorLedgerDidChange`，`startUsageWatcher` 里注册的观察者以 `refreshUsage(rescan: false)` 响应——**磁盘上什么都没变，只有钱变了**，所以不重走 transcript。用量页的瓦片读的一直是内存里那份读数，网络往返从不挡渲染。
- `refreshSessions()` 的扫描在 `Task.detached(priority: .utility)` 中离主线程执行，回主线程发布结果、追加心跳采样、跑 `ConfirmedCompletionDetector`；**只有「新的一轮真的交付了答案」才通知**，规则是三条同时成立：该会话的**轮次键（turn key）变了**、该会话自己的文件**刚刚写过**（60 s 内）、当前不是忙状态。轮次键三家各取本地权威字段：Claude 用「轮次+步数计数 + 最终答复 uuid」（计数来自 transcript 尾窗，`ProviderStore.enrich` 里做单调夹紧，避免窗口滑动把键推回旧值）、Codex 用 `task_complete.turn_id`、Cursor 用 `turn-<字节偏移>`。这样被中断 / 杀掉的一轮（键没动）、起始前就存在的答案（首次见到只做基线）、以及没有任何人在看时结束的一轮（不新鲜）都不会播报；反过来，短于轮询间隔的一轮、以及忙→闲边沿之后才落盘的答案也能报出来。**Cursor 的「忙」另有一条写时钟界**：它中断时不写收尾的 `turn_ended`，只按行序判定会让一条冻结的 transcript 永远算忙（`CursorSessionMonitor.turnLiveWindowMs`，10 分钟），这条界只影响忙碌判定、不影响轮次键。
- `refreshCursorSessions()` / `refreshUsage()` 的 `Task.detached` 用 `MainActor.run { [weak self] in }` 捕获弱引用，避免强引用 self（B2）。

## 空闲通知

- `AppPreferences`（`Models/AppPreferences.swift`）：`@Published var idleNotifyEnabled`（UserDefaults 持久化，**默认关**——与截图热键一起在「权限与隐私」里逐项 opt-in，见设计 §01），开启时向系统请求通知授权。
- `NotificationService`（`Utils/NotificationService.swift`）：封装 UNUserNotificationCenter——授权、注册 `IDLE_SESSION` 与 `NEEDS_INPUT` 两个 category（前者含 "在终端恢复" 动作，后者用于停在用户身上的会话）、`notifyIdle(session:)` / `notifyIdle(cursor:)` / `notifyIdle(external:)` 构建「Claude / Cursor / <客户端> 已完成」+「<项目> · 最终答复已就绪」的通知。
- 点按通知或 Resume 动作 → post `.resumeSession`（`userInfo` 携带 `agent` / `sessionId` / `cwd` / `pid` / `inDesktop`）→ `AppDelegate` 按 agent 分派到 `TerminalLauncher` 的 Claude / Codex / Cursor 入口。

## `loadProviders()` 的当前态探测

加载 providers 文件（`FilePaths.presetsFile`，即 `claude-bar-providers.json`）后，若 `currentEnv` 的 `ANTHROPIC_BASE_URL` 指向回环代理但当前供应商并没有开启「流量记录」，会把该供应商的原始地址重新激活写回；否则用 baseURL（trim `/` 后）匹配出当前激活 Provider，再用 case-insensitive 匹配 `ANTHROPIC_MODEL` 定位其 `activeModelID`，并立即 `saveProviders()` 持久化探测结果。这使得用户在 Claude Code 外手改 settings.json 后，ClaudeBar 能识别当前态。

## `activateModel` 写入流程

```
activateModel(providerID, modelID)
  ├── guard 找到 provider + model，否则直接返回
  ├── buildEnv(from: provider, model:)  ← 构造完整 EnvConfig
  ├── SettingsManager.writeSettings(env)   ← 合并写回 settings.json
  │     └── 抛错时：currentEnv = readSettings()，errorMessage = "写入设置失败：…"，中止（不激活）
  ├── activeProviderID = providerID
  ├── currentEnv = env
  ├── providers[idx].activeModelID = modelID
  ├── saveProviders()
  ├── refreshBalance()
  └── refreshSharedProxy()
```

`buildEnv` 把所选 `model.name` 同时写入 `ANTHROPIC_MODEL` 与 8 个 `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL[_NAME]`，确保 Claude Code 内部按 tier 路由时一致。
