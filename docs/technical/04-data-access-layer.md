# 数据访问层

> ClaudeBar 技术文档 · §4
> 相关：设计文档 [数据模型](../design/03-data-models.md) · [交互流程](../design/06-interactions.md) · 技术文档 [状态中枢](03-provider-store.md)

## `FilePaths` — 路径常量

集中管理所有文件系统路径，分三组：

- **Claude Code**：`~/.claude/settings.json`、`~/.claude/claude-bar-providers.json`（新）、`~/.claude/claude-bar-presets.json`（旧，迁移用）、`~/.claude/projects/`、`~/.claude/sessions/`。
- **Cursor**：`~/.cursor/projects/`、`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`。
- **App Group**：`com.claudebar.app.widget`。
- **VPN**：`~/Library/Application Support/ClaudeBar/vpn/`（`config.yaml`、`subscriptions.json`、`core.log`、`vpn.log`）。订阅 token 只出现在此目录。

`cursorProjectName(for:)` 复现 Cursor 的 cwd 编码：去前导 `/` 后把 `/` 换成 `-`（注意 Cursor **不**加前导 `-`，与 Claude Code 不同）。`cursorTranscriptURL(cwd:composerId:)` 拼出 `agent-transcripts/<composerId>/<composerId>.jsonl`。

## `SettingsManager` — settings.json 读写

**读**：`JSONSerialization` 解析为 `[String: Any]`，取 `env` 字典构造 `EnvConfig`（缺字段默认 `""`）。返回 `EnvConfig?`（B11 简化：原先返回 `(env, raw)` 元组，但 `raw` 通道无调用方使用，已删除；`writeSettings` 内部自行重读文件取 raw）。

**写**：关键在于**不破坏用户手改的配置**：
1. 先 `readSettings()` 取旧 env。
2. `preserve(newValue, existing)`：新值非空用新值，否则保留旧值，都空则空。这避免空字段覆盖用户已有 token。
3. 保留 settings.json 的其他顶层字段（`permissions`、`enabledPlugins` 等）——先读现有 JSON 再替换 `env` 键。
4. `JSONSerialization` 会把 URL 中的 `/` 转义成 `\/`，写回前字符串替换修复，保证 URL 可读。

## `writeWidgetSnapshot()` — 四路冗余写入 + diff（B6）

快照写入逻辑已抽到 `Models/WidgetSnapshotWriter.swift`（`enum WidgetSnapshotWriter`）。因 Widget 沙盒环境的多样性，快照被写到四个位置，按 Widget 读取优先级：

1. **App Group 容器**：`containerURL(forSecurityApplicationGroupIdentifier:)` 下的 `claude-bar-widget-data.json`（首选，沙盒可读）。
2. **`~/.claude/`**：非沙盒回退，便于手工调试。
3. **Widget 沙盒容器**：`~/Library/Containers/com.claudebar.app.widget/Data/claude-bar-widget-data.json`。
4. **UserDefaults (App Group)**：`shared.set(data, forKey: AppConfig.widgetSnapshotDefaultsKey)`。

各路写入均为 best-effort，一路失败不阻塞其他路。

**载荷自描述**：Widget 进程有自己的 `UserDefaults.standard`（App 的 domain 对它是隐形的），也无法导入 `Theme` / `AppPreferences`，因此「这个 token 总量属于哪个周期」「用万/亿还是 K/M/B」「当前是深色还是浅色」都随快照下发（`usagePeriodLabel` / `unitStyle` / `isDark`，均为可选字段，旧快照仍可解码）。三者在 App 侧变化（切周期、改单位、切外观）时会主动重推一次快照，否则要等下一次会话轮询写出的快照发生变化——全空闲时可能永远不写。同一份 `WidgetSnapshot.swift` 通过符号链接被两个 target 编译（`Sources/Widget/WidgetSnapshot.swift`），`build.sh` 会断言该链接仍指向 App 侧同一文件。

> **diff 优化（B6）**：2.5s 轮询会反复调用 `writeWidgetSnapshot()`。`WidgetSnapshotWriter.write(_:deduplicatingAgainst:)` 缓存上次 snapshot 的 JSON `Data`，仅当新 `Data != lastSnapshotData` 时才执行四路写入 + `WidgetCenter.shared.reloadAllTimelines()`。Apple 建议仅数据变化时重载 timeline——无 diff 时每 2.5s 无意义重载会浪费磁盘 I/O 与 widget 刷新配额。已删除原 `shared.synchronize()`（现代 macOS 自动同步，已弃用）。

## `SessionMonitor` — Claude Code 会话

**数据源**：`~/.claude/sessions/<pid>.json`，每个文件含 `pid`、`sessionId`、`cwd`、`startedAt`、`status`、`updatedAt` 等字段。

**判活**：`kill(pid_t(pid), 0) == 0`（信号 0 探测进程存在），死进程沉底。

**上下文扫描 `fetchContext`**：读 transcript `projects/<encoded-cwd>/<sessionId>.jsonl` 的**尾部 96KB**（`FileHandle.seekToEnd` 后回退）：
- 只处理含 `"usage"` 且 `"type":"assistant"` 的行。
- `lastContext = input_tokens + cache_read_input_tokens + cache_creation_input_tokens`（最新一条）。
- 从最后一条 `tool_use` 提取活动描述（`describeActivity`：`Bash · build.sh`、`Read · File.swift`、`Agent · Explore` 等）。
- `toolPending`：若最后 `tool_use` 的行号 > 最后 `tool_result` 的行号 → 该工具调用尚未返回 → busy。

**transcript 路径编码**：`/Users/wangxiajun/Project/ClaudeBar` → `projects/-Users-wangxiajun-Project-ClaudeBar`。规则是 Claude Code 自己的 `cwd.replace(/[^a-zA-Z0-9]/g, "-")`：**除 `[A-Za-z0-9]` 外的每个字符**都换成 `-`（不只是 `/`），前导 `/` 变成前导 `-`——含点号的路径（`…/helix/.helix/agents/…` → `…-helix--helix-…`）靠这条才对得上，与 Cursor 编码不同。超过 200 字符的 slug 客户端会再缀一段哈希，本应用无法镜像，`SessionMonitor.locateTranscript` 按 `<sessionId>.jsonl` 全树兜底（每个 session 只扫一次并缓存）。

**标题 `firstHumanPrompt`**：读 transcript **头部 16KB** 找第一条人类 prompt（Claude Code 没有标题字段）。`user` 流里绝大多数记录不是人打的字，必须按顺序排除：

- `isMeta == true` —— 注入的 `<local-command-caveat>` 提示
- `isSidechain == true` —— 子 agent 流量
- `origin.kind != "human"` —— `/effort`、`/clear` 等斜杠命令管道（`origin` 缺失即此类）

实测本机 40 份 transcript：**35 份**能拿到干净首条 prompt，其余（只跑过 `/clear`、或只有 `<history>` 注入）回退目录名。标题统一由 `SessionTitle` 派生，见 [07 文件索引](09-file-index.md)。

**子 Agent / Workflow `fetchSubagents`**：
- 直属子 Agent：`<sessionDir>/subagents/agent-<id>.meta.json` + 同名 `.jsonl`。
- Workflow：`<sessionDir>/subagents/workflows/<wf_id>/agent-<id>.meta.json`，各 agent 的 transcript 在 `<wf_id>/<fname>.jsonl`。
- 每个 agent 的 `scanAgentActivity` 读尾部 32KB 判定 running/done。

## `CursorSessionMonitor` — Cursor 会话

**数据源**：Cursor 的 `state.vscdb`（SQLite，WAL 模式），表 `composerHeaders`（含 `composerId`、`recency`、`value` JSON、`isArchived`、`isSubagent`）。DB 约 6.5GB，但 `(recency, composerId)` 有索引。

**打开方式**：经共享的 `CursorDB.open()`（`Utils/CursorDB.swift`）——`sqlite3_open_v2` + `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`，`busy_timeout 2000`。WAL 允许并发读，不阻塞 Cursor 的写入。`CursorDB` 同时提供 `textColumn` 文本读取与 `cString` helper，供 `CursorSessionMonitor` 与 `CursorUsageStats` 复用（D2 去重；并消除 B3 的 `map[key]!` force-unwrap）。

**查询**：读取 `isArchived=0 AND isSubagent=0` 且 `recency` 或 `checkpointAt` 在最近 3 天的 header。先解析运行状态再按忙碌优先排序，列表通常保留 14 个，但全部运行会话必须保留。取消查询前 80 条的硬截断，避免较早提交的长任务被新会话挤掉。查询只扫描小型 `composerHeaders` 索引表，不读取大型 `cursorDiskKV` 消息正文。

**head 字段解析**：`name`、`lastUpdatedAt`、`contextUsagePercent`、`unfinishedRunAt`、`conversationCheckpointLastUpdatedAt`；`workspaceIdentifier.uri.fsPath`（或 `draftTarget.environment.uri.fsPath`）取 cwd。`agentLocation.status == "active"` 是可能残留的绑定标记，只用于提交后 120 秒的启动宽限，不能代表整轮运行状态。

**运行判断**：主会话和子 Agent 共用 `CursorTranscriptScan.inFlight`。

- JSONL 的最后一条 user 或 assistant 消息出现在最后一个 `turn_ended` 之后，且文件 mtime 在 10 分钟内，说明轮次尚未结束。用户提交即进入 pending，覆盖等待首个回复的阶段。
- `unfinishedRunAt > 0` 且 `max(unfinishedRunAt, checkpointAt)` 在 10 分钟内，也说明轮次可能仍在运行。Cursor 实测会持续写 SQLite checkpoint，但 JSONL 长时间停在用户消息；仅检查 JSONL 会漏掉这些长任务。
- 当前轮次的 `turn_ended`（成功或错误）优先结束运行状态。文件早于 `unfinishedRunAt` 的旧结束标记不能结束新轮次，也不能发布旧答案的 completion ID。
- 两种写入都停止超过 10 分钟时，残留 pending/unfinished 不再算忙。这个窗口是启发式边界：真实任务如果两种数据源都静默超过 10 分钟，仍可能漏报。

**时间语义**：返回的 `lastUpdatedAt` 是最新活动时间，运行期间结合 checkpoint 与 transcript mtime；有当前结束标记时使用 transcript 的时间，不让后续 metadata 写入刷新旧答案的完成时间。原始 head 的 `lastUpdatedAt` 是提交时间，用它给长任务的完成通知判新鲜度会漏通知。

**账号凭据**：同一张 `ItemTable` 里还有 `cursorAuth/*` 行（accessToken / cachedEmail / stripeMembershipType / stripeSubscriptionStatus），供 `CursorUsageFetcher` 调用额度接口。**每次探测都重读**——Cursor 会在运行中原地轮换 access token，缓存一小时的 token 会开始 401；读的是只读 WAL 句柄上一条按主键的 SELECT，成本可忽略。token 是 424 字节的 JWT，必须走 `textColumn` 而不是 `cString`（后者在第一个 NUL 截断，交出去的是坏 token）。

**子 Agent**：`fetchSubagents` 查最近的 `isSubagent=1` header，按 `subagentInfo.parentComposerId` 归组；直属父级是另一个 helper 时，回退到可见的 `rootParentConversationId`。transcript 优先读 `agent-transcripts/<rootId>/subagents/<childId>.jsonl`，再兼容旧的独立 composer 路径。运行状态使用与主会话相同的 checkpoint / transcript 判据。

本次实机漏报证据与验证范围见 [Cursor 会话监控排查](cursor-session-monitor-investigation.md)。

## `UsageStats` — token 用量扫描

**数据源**：`~/.claude/projects/**/*.jsonl` 的 assistant 消息 `message.usage`。

**三级过滤**（性能关键，`~/.claude/projects` 可达数千文件、数百 MB）：
1. **文件 mtime 预筛**：`contentModificationDate < interval.start` 直接跳过整个文件（消息按时间追加，mtime = 最后写入）。
2. **UTC 日期字符串粗筛**：ISO 时间戳零填充，前 10 字符字典序 == 时间序。取 `[interval.start-1d, interval.end+1d]`（±1 天 slack 容时区），行首日期不在窗口则跳过，避免 JSON 解析。
3. **精确解析**：`ISO8601DateFormatter`（线程安全，`DateFormatter` 不是）解析后 `interval.contains`。

**并行**：`DispatchQueue.concurrentPerform(iterations: n)` 每文件独立解析为 `[String: ModelUsage]`，再合并。`ModelUsage` 累加 `calls`、`inputTokens`、`outputTokens`、`cacheReadTokens`、`cacheCreationTokens`，`totalTokens = 三者输入 + 输出`。

**格式化**：`formatTokens` → `38.7M` / `318K` / `942`。

## `CursorUsageStats` — Cursor 历史 token

**数据源**：同一 `state.vscdb` 的 `cursorDiskKV` 表，键 `bubbleId:<composerId>:<bubbleId>`，值 JSON 的 `tokenCount.inputTokens/outputTokens`。

**限制**（经验证）：Cursor 自 ~2026-03 起停止写 token 计数，故近期月无数据；无 per-bubble model 字段。按设计决策，聚合为单条 `ModelUsage(model: "Cursor")`，作为全量值追加到所有周期。

**这条路已经废弃。** 本次实测抽查 `bubbleId:*` 最近 2 万条，`tokenCount` **全部为 0**；
`~/.cursor/ai-tracking/ai-code-tracking.db` 的 `ai_code_hashes` 只有 model 与行数、**没有 token**。
Cursor 侧的 token 事实**只能联网拿**，local-first 在这里不成立。

## `CursorLedger` / `CursorLedgerStore` — Cursor 的真实用量与金额

Cursor 在 `api2.cursor.sh` 的 `DashboardService` 上暴露了两个未公开 RPC，**用本机
`state.vscdb` 里已存的同一个裸 JWT 即可调用**，不新增任何凭据：

| RPC | 返回 |
|---|---|
| `GetAggregatedUsageEvents` `{startDate,endDate}` | 按模型的 token 四桶 + `totalCents` |
| `GetFilteredUsageEvents` `{startDate,endDate,page,pageSize}` | 逐次调用流水（含 `conversationId`） |

**金额是真的**：流水里 `tokenUsage.totalCents == chargedCents`（9,895 条逐条核对）——
这是 Cursor 实际扣掉的数额，不是刊例价折算。这使 Cursor 成为本应用第二个真金额来源
（另一个是 OpenRouter），见 [15 模型花费](15-model-cost.md)。

**四条形状约束，每条都由实测驱动**：

- **token 字段是字符串**（`"inputTokens":"914"`），`totalCents` 是浮点。用 `as? Int` 会把整份
  聚合读成 0——那渲染出来是「这个月没用量」，不是报错。走 `CursorUsageFetcher.number`。
- **`tokenUsage` 可能整个缺失**（非 token 调用：`isTokenBasedCall=false`、`chargedCents=0`）。
  那是真实的零值行，不是解析失败。
- **窗口上限约 90 天，且非确定性失败**：>90 天的请求返回 `{"code":"internal"}` 且无数据，
  且不按宽度稳定复现（实测 90d 失败、91d 成功、92d 失败）。12×30 天分块回填耗时 **306 s
  且仍有 1 块失败**（每块已重试 3 次）→ **不做历史回填**，只做周期级取数，每块带重试，
  **任何一块最终失败就整体返回 nil**，绝不返回残缺和。
- **聚合不含 `grok-bot-*`**：本轮窗口聚合 $53.51 vs 流水 $57.72，差额全部是
  `grok-bot-automation` / `grok-bot-default`。两个接口口径不同，流水才是完整的。

**名字归一**：Cursor 按 effort 档位命名（`claude-opus-5-5-medium`），本地客户端记的是基础名
（`claude-opus-5-5`）。`ModelPricing.canonical` 因此剥掉尾部的 effort / 速度档
（`-low/-medium/-high/-xhigh/-fast/-thinking`，**循环剥**，因为实测出现过
`claude-4.6-sonnet-medium-thinking` 这种叠加），两者才会落到同一行。归一同时作用于定价查表，
方向安全：查表本就是「最长 slug 优先的前缀匹配」，剥掉只会落向基础档，且价目表里没有任何
slug 以这些词结尾（`Tests/model-cost-regressions.py` 断言这一条）。

**周期与窗口**：金额接口接受的是**窗口**，不是「今天 / 月 / 年」。`CursorLedgerStore` 用
`UsageStats.interval(for:reference:)` 得出窗口；`年` / `全部` 超出上限时**退化为账单周期**
（`GetCurrentPeriodUsage` 的两个边界，已在读），并置 `truncated`——UI 必须说明它覆盖的是
一个账期而不是屏幕上的周期。窗口与页面周期不一致时**显示旧值并标明窗口**，而不是隐藏。

**取数节奏**：窗口变化 / 手动刷新 / `fetchedAt` 超过 6 h 才发请求，在 detached task 上跑，
用量页永远先用已有快照（含启动时从 `cursor-ledger.json` 反序列化的上一次读数）渲染。
失败**保留旧值**、只记 `note`。落地后发 `.cursorLedgerDidChange`，`ProviderStore` 以
`refreshUsage(rescan: false)` 响应——磁盘上什么都没变，只有钱变了。

## `BalanceFetcher` — DeepSeek 余额

仅当 `baseURL` 的 host 含 `deepseek.com` 时工作（B5：原先用 `baseURL.contains("deepseek")` 字符串包含判定，会误匹配 `https://deepseek-proxy.evil.com/` 等主机；改为基于 `URL(string: baseURL)?.host` 的判定，避免向非预期主机发送 token）。请求 `<base>/user/balance`，Bearer token 鉴权，解析 `balance_infos[0].total_balance` / `currency`。5 秒超时，失败返回 nil（不报错）。`currency` 一并展示（B10：`balanceText = "\(balance) \(currency)"`）。
