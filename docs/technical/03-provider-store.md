# 状态中枢 `ProviderStore`

> ClaudeBar 技术文档 · §3
> 相关：设计文档 [交互流程](../design/06-interactions.md) · [数据模型](../design/03-data-models.md) · 技术文档 [数据访问层](04-data-access-layer.md) · [性能与并发](08-performance.md)

`ProviderStore: ObservableObject` 是唯一真值源，持有全部 `@Published` 状态。`init()` 留空，由 AppDelegate 在窗口/状态栏就绪后调用 `refresh()`。`deinit` 释放轮询定时器 `sessionTimer` 与补跑用的 `deferredPollTimer`。视图经 `@ProviderState`（[`ScopedStoreObservation.swift`](../../Sources/ClaudeBar/Models/ScopedStoreObservation.swift)）按字段订阅：外层壳持有 store 引用并经 `\.providerSource` 下发，叶子视图声明自己关心的字段位（`configuration` / `usage` / `sessions` / `heartbeats` / `expansion`），一轮 store 事务合并为一次视图失效（滚动中延迟到停下），隐藏的表面在再次显示时读最新值；`CodexProviderStore` 仍是常规 `@EnvironmentObject`。

## Published 状态

| 字段 | 类型 | 含义 |
|------|------|------|
| `providers` | `[Provider]` | 全部 Provider 配置 |
| `activeProviderID` | `UUID?` | 当前激活 Provider |
| `currentEnv` | `EnvConfig?` | 当前 settings.json 的 env |
| `hasSettingsFile` | `Bool` | settings.json 是否存在 |
| `errorMessage` / `importSummary` | `String?` | 写 settings / 保存供应商失败，导入 Codex 供应商的结果摘要 |
| `balanceText` / `balanceAmounts` / `balanceLoading` | `String?` / `[UUID: String]` / `Bool` | 各家官方余额读数（DeepSeek / Kimi / 硅基流动 / OpenRouter；`balanceText` 含币种）；`balanceAmounts` 按 provider id 存展示金额 |
| `sessions` | `[SessionInfo]` | Claude Code 活跃会话 |
| `expandedSessionPIDs` | `Set<Int>` | 展开的会话。当前 app 目标内既无写入也无读取（会话卡的展开态是各卡自己的 `@State`），只有 `ProviderFields.expansion` 为它保留失效信号 |
| `heartbeats` | `[Int: [Bool]]` | 每会话最近 `AppConfig.heartbeatLength`（24）个 busy/idle 采样，驱动心跳 sparkline |
| `anySessionBusy` | `Bool` | 是否有任一会话 busy（Claude / Cursor / Codex 任一家），驱动主窗口状态胶囊与轮询档位 |
| `cursorSessions` | `[CursorSessionInfo]` | Cursor 活跃会话 |
| `externalSessions` | `[ExternalSessionInfo]` | Codex 线程（含子 agent；「会话」口径的过滤在派生量里） |
| `usageStats` / `usageDays` / `usageWeekDays` / `usageBySource` / `usageLoading` | `[ModelUsage]` / `[DayUsage]` / `[DayUsage]` / `[UsageSource: [ModelUsage]]` / `Bool` | token 用量：周期总表、周期日聚合、所在周的 7 天（popup 固定画周条）、按来源拆分、加载态 |
| `usagePeriod` / `usageReferenceDate` | `UsagePeriod` / `Date` | 用量周期，变化即重算 |
| `usageEstimate` / `usagePublishedInterval` / `todayUsage` | `ModelPricing.Estimate` / `DateInterval?` / `TodayUsage` | 周期估价总额、已发布的周期与今日读数，均 `private(set)`，在 `publishUsage` / `publishPrices` 一次发布 |
| `collapsedProviderIDs` | `Set<UUID>` | 折叠的 Provider。当前无视图读写（仅 `deleteProvider` 清理） |
| `navigationRequest` | `NavigationRequest?` | 跨面页面请求，`private(set)`，见下 |

逐行成本缓存 `usageCostLines`（模型 → 价格行）与 `usageTokensByModel`（来源 → 模型 → tokens）不是 `@Published`，随上面两个发布一起重建。

## 派生量（`ProviderStore+Derived.swift`）

视图不再各自 reduce，统一读派生属性：会话侧 `aliveSessions`、`busySessionCount`、`aliveCursorSessions`、`activeCursorCount`、`anyClaudeBusy`、`aliveExternalSessions`、`activeExternalCount`、`anyExternalBusy`、`externalSessionTree(kind:)`；用量侧 `totalUsageTokens`、`totalUsageLabel`、`costEstimate`、`costLine(for:)`；以及 `activeProvider`、`activeModel`。

用量页的实扣只有一个出处：`CursorLedgerStore`（`rows` / `windowLabel`），由 `UsageView` 直接读取。它一度在 store 上还有一份 `usageSettlements` 平行副本与 `settlement(for:)` / `settlementCovers(_:)` / `settlementWindowLabel` 三个访问器，但没有任何视图读过——同一个事实的两个出处。

## `AppConfig.swift` — 轮询节奏与共享键

`sessionPollInterval`（2.5s）、`sessionPollIdleInterval`（5s）、`sessionPollHiddenInterval`（8s）、`heartbeatLength`（24）、`quotaPollInterval`（900s，Codex 额度心跳，另有 `quotaResetGrace` / `quotaResetHorizon` / `quotaResetDueWindow` 三个重置瞄准参数）、`cursorQuotaPollInterval`（1200s）等轮询节奏，以及 `widgetSnapshotDefaultsKey`、`widgetBundleID`、`widgetSnapshotFileName` 三个 Widget 快照键（转发 `BuildChannel`，单一出处）都在这里。可见且忙走 2.5s、可见但闲置走 5s、界面隐藏或灵动岛收起走 8s；完成检测的新鲜度预算为 60 s（`ProviderStore.completionFreshness`，私有常量），8 s 档位留有一次漏拍的余量。

## 跨面导航

`navigationRequest: NavigationRequest?`（`@Published private(set)`）与 `requestNavigation(_:)` / `clearNavigation(_:)` 承载「别的面要求主窗口切到某页」的请求；窗口重建后的新订阅者会重放该值，而 `NotificationCenter` 的页面 post 会在窗口尚未装好时丢失。`MainWindowView` 消费后立即清除，请求是 one-shot。

## 刷新管线 `refresh()`

```
refresh()
  ├── hasSettingsFile = ...
  ├── currentEnv = SettingsManager.readSettings()       ← 返回 EnvConfig?
  ├── loadProviders()          ← 读 providers 文件 + 当前 Provider 探测（旧字段兼容在 `Provider.init(from:)`）
  ├── ProviderProfileSync.reconcile(claude:codex:)     ← 经 peer 对齐两侧
  ├── refreshBalance()         ← async, `BalanceFetcher` 支持的官方余额端点（balanceText 含币种）
  ├── peer?.refreshQuota()
  ├── refreshUsage(rescan: true)   ← Task.detached 扫描 jsonl（weak self）
  ├── requestSettlement()      ← 交给 CursorLedgerStore 按当前周期取一次实扣（不等待）
  ├── refreshSessions()        ← detached task 扫描 → 心跳 → 空闲检测 → refreshCursorSessions()
  ├── startSessionPolling()    ← 2.5s / 5s / 8s 定时器（切档时重建；deinit 释放）
  ├── observeVisibility() / ProcessSampler.start() / startUsageWatcher() / observeAppearance()
  ├── writeWidgetSnapshot()
  └── refreshSharedProxy()     ← 经 peer 同步本地代理的 Claude 上游
```

- `usagePeriod` 与 `usageReferenceDate` 的 `didSet` 仅在值变化时触发 `refreshUsage(rescan: false)`。
- **Cursor 的实际扣费走两个入口**：`ProviderStore.refresh()` 与用量页的周期切换（`selectPeriod` / `shiftUsage`）调 `requestSettlement()`，它按当前周期算出窗口交给 `CursorLedgerStore`（年 / 全部由账本退化为账单周期并标记）；账本读回来后发 `.cursorLedgerDidChange`，`startUsageWatcher` 里注册的观察者以 `refreshUsage(rescan: false)` 响应——磁盘上什么都没变，只有钱变了，所以不重走 transcript。用量页的瓦片读的一直是内存里那份读数，网络往返从不挡渲染。
- `refreshSessions()` 的扫描在 `Task.detached(priority: .utility)` 中离主线程执行，回主线程发布结果、追加心跳采样、跑 `ConfirmedCompletionDetector`；只有「新的一轮真的交付了答案」才通知，规则是三条同时成立：该会话的轮次键（turn key）变了、该会话自己的文件刚刚写过（60 s 内）、当前不是忙状态。轮次键三家各取本地权威字段：Claude 用「轮次+步数计数 + 最终答复 uuid」（计数来自 transcript 尾窗，`ProviderStore.enrich` 里做单调夹紧，避免窗口滑动把键推回旧值）、Codex 用 `task_complete.turn_id`、Cursor 用 `turn-<字节偏移>`。这样被中断 / 杀掉的一轮（键没动）、起始前就存在的答案（首次见到只做基线）、以及没有任何人在看时结束的一轮（不新鲜）都不会播报；反过来，短于轮询间隔的一轮、以及忙→闲边沿之后才落盘的答案也能报出来。**Cursor 的「忙」另有一条写时钟界**：它中断时不写收尾的 `turn_ended`，只按行序判定会让一条冻结的 transcript 永远算忙（`CursorSessionMonitor.turnLiveWindowMs`，10 分钟），这条界只影响忙碌判定，不影响轮次键。
- 三个扫描（Claude / Cursor / Codex）各有主线程 gate，同一扫描单飞；上一次没跑完就补跑一次（`deferredPollRetry`，1.5 s），不丢轮询。扫描结果先比后赋，未变化不发布。`refreshCursorSessions()` / `refreshUsage()` 的 `Task.detached` 用 `MainActor.run { [weak self] in }` 捕获弱引用，避免强引用 self。
- `refreshCursorSessions()` 受 `PermissionGate.allows(.cursorData)` 闸门控制；`.permissionDidChange` 与 `.persistenceModeDidChange` 都会触发对应重扫。

## 空闲通知

- `AppPreferences`（`Models/AppPreferences.swift`）：`@Published var idleNotifyEnabled`（UserDefaults 持久化，**默认关**——与截图热键一起在「权限与隐私」里逐项 opt-in，见设计 §01），开启时向系统请求通知授权（dev 构建的请求被 `BuildChannel.promptsForSystemPermissions` 拦下）。
- `NotificationService`（`Utils/NotificationService.swift`）：封装 UNUserNotificationCenter——授权、注册 `IDLE_SESSION` 与 `NEEDS_INPUT` 两个 category（前者含「在终端继续」动作，后者含「去确认」，用于停在用户身上的会话）、`notifyIdle(session:)` / `notifyIdle(cursor:)` / `notifyIdle(external:)` 构建「Claude / Cursor / <客户端> 已完成」+「<项目> · 最终答复已就绪」的通知。`notifyNeedsInput(session:)` / `notifyNeedsInput(cursor:)` 是另一条路径：刘海条本身无法承载（关闭或已展开）时，`NotchIslandController` 用它兜底提醒会话停在用户身上。
- 点按通知或 Resume 动作 → post `.resumeSession`（`userInfo` 携带 `agent` / `sessionId` / `cwd` / `pid` / `inDesktop`）→ `AppDelegate` 按 agent 分派到 `TerminalLauncher` 的 Claude / Codex / Cursor 入口。banner 用 `session-<pid>` / `cursor-<composerId>` 等标识替换同会话的旧通知。

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

`buildEnv` 把所选 `model.name` 同时写入 `ANTHROPIC_MODEL` 与 8 个 `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL[_NAME]`，另带 `CLAUDE_CODE_MAX_CONTEXT_TOKENS`、`DISABLE_COMPACT`、`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`、`CLAUDE_CODE_AUTO_COMPACT_WINDOW` 与两个并发上限（`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` / `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS`），确保 Claude Code 内部按 tier 路由时一致。该供应商开启「流量记录」时，base URL 与 token 换成回环代理地址与代理 token（真实 key 由代理上游注入）。
