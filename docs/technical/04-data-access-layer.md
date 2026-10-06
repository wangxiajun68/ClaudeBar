# 数据访问层

> ClaudeBar 技术文档 · §4
> 相关：设计文档 [数据模型](../design/03-data-models.md) · [交互流程](../design/06-interactions.md) · 技术文档 [状态中枢](03-provider-store.md)

## `FilePaths` — 路径常量

集中管理所有文件系统路径，分四组：

- **Claude Code**：`~/.claude/settings.json`、`~/.claude/claude-bar-providers.json`（当前格式；`FilePaths.presetsFile` 是这一路径的历史命名）、`~/.claude/claude-bar-codex-providers.json`（Codex 供应商）、`~/.claude/projects/`、`~/.claude/sessions/`。
- **Cursor**：`~/.cursor/projects/`、`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`。
- **App Group**：`com.claudebar.app.widget`（dev 为其 bundle ID 加 `.widget`）。
- **VPN**：`~/Library/Application Support/ClaudeBar/vpn/`（`config.yaml`、`subscriptions.json`、`profiles/`、`mihomo`、`core.log`、`vpn.log`）。订阅 token 只出现在此目录。

Claude / Codex / Cursor 的根目录都按 `BuildChannel` 分流：正式版用真实用户目录，开发版落在自身的 `~/Library/Application Support/ClaudeBar Dev/` 下（`.claude`、`.codex`、`.cursor`，以及一份不存在的 `cursor-state.vscdb`，使 Cursor 读取端全部返回空）。

`cursorProjectName(for:)` 复现 Cursor 的 cwd 编码：去前导 `/`，随后把 `[A-Za-z0-9]` 与 `-` 之外的每个字符换成 `-`（下划线、点号都换；Cursor 不加前导 `-`，与 Claude Code 不同）。`cursorTranscriptURL(cwd:composerId:)` 拼出 `agent-transcripts/<composerId>/<composerId>.jsonl`。

## `SettingsManager` — settings.json 读写

**读**：`readSettings()` 用 `JSONSerialization` 解析为 `[String: Any]`，取 `env` 字典构造 `EnvConfig`（缺字段默认 `""`）。返回 `EnvConfig?`；`writeSettings` 需要保留其他顶层字段，内部经 `readDocument()` 自行重读整份 JSON。

**写** `writeSettings(env:)`：先 `readDocument()` 取现有 JSON，`environment(in:)` 取出 `env` 子字典；`EnvConfig` 经 `JSONEncoder` → `JSONDecoder` 折成 `[String: String]` 后，**先按 `managedEnvKeys` 逐键删除旧值，再把非空的新值写回**——空值就是清掉上一个供应商的凭据与开关，不保留旧值；`permissions` 等顶层字段原样保留。随后 `backUpOnce()`（只在第一次写时留一份 `.bak`，已存在则不覆盖），`writeDocument` 用 `JSONSerialization.data(withJSONObject:options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])` 序列化——`.withoutEscapingSlashes` 让 URL 里的 `/` 保持可读——再交给 `PrivateFileWriter.write`（0600 暂存文件 + `rename` 原子替换）。

`restoreOfficial()` 走同一条链：删掉全部 `managedEnvKeys`，`env` 剩空则整个键移除。

## `writeWidgetSnapshot()` — 四路冗余写入 + diff

快照写入逻辑在 `Models/WidgetSnapshotWriter.swift`（`enum WidgetSnapshotWriter`；`ProviderStore.writeWidgetSnapshot()` 只负责构建快照并 `submit`，编码、diff 与写入在串行队列上执行）。因 Widget 沙盒环境的多样性，快照被写到四个位置，按 Widget 读取优先级：

1. **App Group 容器**：`containerURL(forSecurityApplicationGroupIdentifier:)` 下的 `claude-bar-widget-data.json`（首选，沙盒可读）；容器取不到时回退到 `~/.claude/`。
2. **`~/.claude/`**：仅当它与第 1 路的路径不同才写一次，便于手工调试。
3. **Widget 沙盒容器**：`~/Library/Containers/<widgetBundleID>/Data/claude-bar-widget-data.json`。
4. **UserDefaults (App Group)**：`shared.set(data, forKey: BuildChannel.widgetSnapshotDefaultsKey)`。

各路写入均为 best-effort，一路失败不阻塞其他路。写入前有一道闸：`BuildChannel.promptsForSystemPermissions` 且用户权限 `.widgetData` 允许，否则直接返回上次的 diff key——写其他 App 容器会触发系统弹窗，开发版不请求这种持久 TCC 授权。

**载荷自描述**：Widget 进程有自己的 `UserDefaults.standard`（App 的 domain 对它是隐形的），也无法导入 `Theme` / `AppPreferences`，因此「这个 token 总量属于哪个周期」「用万/亿还是 K/M/B」「当前是深色还是浅色」都随快照下发（`usagePeriodLabel` / `unitStyle` / `isDark`，均为可选字段，旧快照仍可解码）。三者在 App 侧变化（切周期、改单位、切外观）时会主动重推一次快照，否则要等下一次会话轮询写出的快照发生变化——全空闲时可能永远不写。同一份 `WidgetSnapshot.swift` 通过符号链接被两个 target 编译（`Sources/Widget/WidgetSnapshot.swift`），`build.sh` 会断言该链接仍指向 App 侧同一文件。

> **diff 优化**：2.5s 轮询会反复调用 `writeWidgetSnapshot()`。`WidgetSnapshotWriter.write(_:deduplicatingAgainst:)` 缓存上次 snapshot 的规范化 JSON `Data`（`updatedAt` 置零后按 `.sortedKeys` 编码，否则每次构建的时间戳都会让比较失配），仅当新 key 与上次不同时才执行四路写入 + `WidgetCenter.shared.reloadAllTimelines()`。Apple 建议仅数据变化时重载 timeline——无 diff 时每 2.5s 无意义重载会浪费磁盘 I/O 与 widget 刷新配额。已删除原 `shared.synchronize()`（现代 macOS 自动同步，已弃用）；用户开启 `.widgetData` 权限时走 `force` 分支清掉 diff key，重推一次未变的载荷。

## `SessionMonitor` — Claude Code 会话

**数据源**：`~/.claude/sessions/<pid>.json`，每个文件含 `pid`、`sessionId`、`cwd`、`startedAt`、`status`、`updatedAt` 等字段。

**判活**：`kill(pid, 0) == 0`（信号 0 探测进程存在），死进程沉底。`pid` 必须是合法的 `pid_t` 且大于 0 才参与探测：`pid_t` 是 32 位，超出范围的值会在转换时直接 trap（整个 App 崩在每轮扫描上），而 `kill(0, 0)` / `kill(-1, 0)` 会成功——它们面向的是进程组，把伪造的 `"pid": 0` 读成活着。二者都按「这条记录不可用」跳过。

**上下文扫描 `fetchContext`**：读 transcript `projects/<encoded-cwd>/<sessionId>.jsonl` 的**尾部 96KB**（`FileHandle.seekToEnd` 后回退）：
- 只处理含 `"usage"` 且 `"type":"assistant"` 的行。
- `lastContext = input_tokens + cache_read_input_tokens + cache_creation_input_tokens`（最新一条）。
- 从最后一条 `tool_use` 提取活动描述（`describeActivity`：`Bash · build.sh`、`Read · File.swift`、`Agent · Explore` 等）。
- `toolPending` **按 `tool_use` 的 id 记**，不按行号：最新一条带工具的 assistant 记录就是当前这批调用，某次调用在被后续 `tool_result` 的 `tool_use_id` 点名之前一直算未完成。行号规则（最后 `tool_use` 行号 > 最后 `tool_result` 行号）只对「一次一个工具」成立——本机 125 份 transcript 里有 91 份存在一条记录带多个 `tool_use`，而 42,084 条 `tool_result` 记录**没有一条**带多个结果块（Claude Code 每次调用写一条结果记录），所以批次里第一个结果一落地，行号规则就判定「没有待办」，剩下的工具明明还在跑。块里没有 id 的旧格式回落到行号规则。`scanAgentActivity` 用同一条判据。

**transcript 路径编码**：`/Users/wangxiajun/Project/ClaudeBar` → `projects/-Users-wangxiajun-Project-ClaudeBar`。规则是 Claude Code 自己的 `cwd.replace(/[^a-zA-Z0-9]/g, "-")`：**除 `[A-Za-z0-9]` 外的每个字符**都换成 `-`（不只是 `/`），前导 `/` 变成前导 `-`——含点号的路径（`…/helix/.helix/agents/…` → `…-helix--helix-…`）靠这条才对得上，与 Cursor 编码不同。超过 200 字符的 slug 客户端会再缀一段哈希，本应用无法镜像，`SessionMonitor.locateTranscript` 按 `<sessionId>.jsonl` 全树兜底（每个 session 只扫一次并缓存）。

**标题 `firstHumanPrompt`**：读 transcript 头部找第一条人类 prompt（Claude Code 没有标题字段）。**起始 16KB，找不到就继续往后读**（上限 512KB），并且只解析已经收到换行的完整行——固定窗口下，一条**起于窗口内、止于窗口外**的 prompt 会以截断形态到达、`JSONSerialization` 失败、被静默跳过，于是整条会话没有标题，所有卡片都回退成目录名。`user` 流里绝大多数记录不是人打的字，必须按顺序排除：

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

**打开方式**：经共享的 `CursorDB.open()`（`Utils/CursorDB.swift`）——存在性检查 + `sqlite3_open_v2` + `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`，`busy_timeout 2000`。WAL 允许并发读，不阻塞 Cursor 的写入。`CursorDB` 同时提供 `textColumn` 文本读取与 `cString` helper，供 `CursorSessionMonitor`、`CursorUsageFetcher` 与 `CursorLedgerStore` 复用。

**查询**：读取 `isArchived=0 AND isSubagent=0` 且 `recency` 或 `checkpointAt` 在最近 3 天内的 header，先解析运行状态再按忙碌优先排序；列表通常保留 14 个，但全部运行会话必须保留（`max(14, 忙会话数)` 截取）。查询只读 `composerHeaders` 这一张索引表，不读 `cursorDiskKV` 的消息正文。

**head 字段解析**：`name`、`lastUpdatedAt`、`contextUsagePercent`、`unfinishedRunAt`、`conversationCheckpointLastUpdatedAt`；`workspaceIdentifier.uri.fsPath`（或 `draftTarget.environment.uri.fsPath`）取 cwd。`agentLocation.status == "active"` 是可能残留的绑定标记，只用于提交后 120 秒的启动宽限，不能代表整轮运行状态。

**运行判断**：主会话和子 Agent 共用 `CursorTranscriptScan.inFlight`。

- JSONL 的最后一条 user 或 assistant 消息出现在最后一个 `turn_ended` 之后，且文件 mtime 在 10 分钟内，说明轮次尚未结束。用户提交即进入 pending，覆盖等待首个回复的阶段。
- `unfinishedRunAt > 0` 且 `max(unfinishedRunAt, checkpointAt)` 在 10 分钟内，也说明轮次可能仍在运行。Cursor 实测会持续写 SQLite checkpoint，但 JSONL 长时间停在用户消息；仅检查 JSONL 会漏掉这些长任务。
- 当前轮次的 `turn_ended`（成功或错误）优先结束运行状态。文件早于 `unfinishedRunAt` 的旧结束标记不能结束新轮次，也不能发布旧答案的 completion ID。
- 两种写入都停止超过 10 分钟时，残留 pending/unfinished 不再算忙。这个窗口是启发式边界：真实任务如果两种数据源都静默超过 10 分钟，仍可能漏报。

**时间语义**：返回的 `lastUpdatedAt` 是最新活动时间，运行期间结合 checkpoint 与 transcript mtime；有当前结束标记时使用 transcript 的时间，不让后续 metadata 写入刷新旧答案的完成时间。原始 head 的 `lastUpdatedAt` 是提交时间，用它给长任务的完成通知判新鲜度会漏通知。

**账号凭据**：同一张 `ItemTable` 里有 `cursorAuth/accessToken` 行，`CursorDB.readCredentials()` 只读这一个键；JWT 的 `sub` 从 payload 段就地解出，供 `CursorUsageFetcher` 拼 `cursor.com/api/*` 的 cookie（Connect RPC 用裸 JWT）。**每次探测都重读**——Cursor 会在运行中原地轮换 access token，缓存一小时的 token 会开始 401；读的是只读 WAL 句柄上一条按主键的 SELECT，成本可忽略。token 是 424 字节的 JWT，必须走 `textColumn` 而不是 `cString`（后者在第一个 NUL 截断，交出去的是坏 token）。

**子 Agent**：`fetchSubagents` 查最近的 `isSubagent=1` header，按 `subagentInfo.parentComposerId` 归组；直属父级是另一个 helper 时，回退到可见的 `rootParentConversationId`。transcript 优先读 `agent-transcripts/<rootId>/subagents/<childId>.jsonl`，再兼容旧的独立 composer 路径。运行状态使用与主会话相同的 checkpoint / transcript 判据。

本次实机漏报证据与验证范围见 [Cursor 会话监控排查](cursor-session-monitor-investigation.md)。

## `UsageIndex` — token 用量索引

**数据源**：Claude Code 的 `~/.claude/projects/**/*.jsonl`（assistant 消息 `message.usage`）与 Codex 的 `sessions` 及 `archived_sessions`（每轮 `last_token_usage`）。第三方（代理）流量不在这里，见下文 `ProxyUsageStore`。

**不再现扫**。旧实现是每次查询用 mtime 预筛 + UTC 日期粗筛 + `concurrentPerform` 并行解析整个项目树；现在每个 transcript 只解析一次，落成 (file, day, model) 汇总行，查询退化为一次 `GROUP BY`。两个后端二选一（设置 → 开启数据库），互不迁移：SQLite `usage-index.db`，或 JSON 的 `logs/usage-files.json` + `usage-rollup.jsonl`。`rollup` 按用户本地时区的日期键记录 `calls` / `input` / `output` / `cache_read` / `cache_create`。

**增量维护 `updateIndex()`**：`collectTranscripts()` 用 `FileManager.enumerator`（`.skipsPackageDescendants`）一次目录列举取回 mtime/size，逐文件与索引中的记录比较——

- mtime + size 都没变：整个跳过。
- 只追加：从记录的字节 `offset` 起只解析新块（Codex），新行 upsert-with-add；`offset` 停在上一个完整换行，未终止的半行留给下次。
- 变小或改写：从 0 全量重解析并替换该文件的 rollup，旧数据不会残留；`headHash`（文件头 256 字节的 FNV-1a）用来识别「size 相同但首部已被改写」。
- 文件消失（含 `archived_sessions` 归档后）：连 rollup 一起删除。

**查询与更新的分工**：`fetch` / `fetchBySource` / `fetchDaily` / `fetchDailyModels` / `fetchSession` / `fetchOfficialCodex` 只查索引，都不走 transcript；`ProviderStore` 先发布缓存结果，再 `updateIndex()`，再发布最终值（`hasCachedData` / `needsInitialBuild` 只用来决定是否显示 spinner）。schema 版本由 `PRAGMA user_version` 管理（当前 11，`migrateIfNeeded`；v7/v8/v10 各重建过一次 Codex 行，v11 重建过 Claude 行）。JSON 后端用 `FileRec.parserVersion` 表达同一件事。

**两个来源语义**：Claude 的同一个 `message.id` 会分多次追加（partial → final），索引按 `message.id` 最后一次为准，并且**整个语料只记一次**（见下）；Codex 的 `token_count` 是累计快照，按事件去重、并用 `turn_context` 的模型 slug 归属到具体模型。

**`message.id` 全局唯一归属（`UsageClaims`）**：`message.id` 只在一次*对话*内唯一。会话被 `--resume`／fork 成新 transcript 时，Claude Code 会把父会话的 assistant 记录逐字复制进新文件——同一个 id、同一个 `message.uuid`、同样的 usage 出现在两份文件里（本机实测 417 个 id 跨文件重复，两天内 1.03 亿 token 被记了两遍）。原先的去重只在**单个文件内**做 last-wins，看不到这一点，两份都会被计入。

现在每个 id 只有一个归属文件：`updateIndex()` 开头 `UsageClaims.begin(owners:)` 把不属于本轮候选文件的归属全部释放（文件被删即归还），解析时已归属他处的 id 直接不计入本文件，本文件不再打印的 id 归还。Claude 文件的 rollup 每次都是**整份替换**，所以丢掉一条就等于不写它，不会留下旧行。账本落在 `logs/usage-claims.jsonl`（追加写，死行超过半数时整份重写）：丢了或读不了只意味着下次解析找不到归属、按老办法认领，不会凭空多记。

**格式化**：`UsageStats.formatTokens` → `38.7M` / `318K` / `942`；`UsageStats` 现在只剩周期区间、标签与格式化函数，没有扫描逻辑。

## `ProxyUsageStore` — 第三方（代理）用量

代理请求的 token 只落在 `ProxyCaptureStore` 的抓包行上，而抓包行按最近 120 条滚动（见下），不能当账本。`ProxyUsageStore` 因此是第三方流量的持久 (day, model) 汇总：`record(model:at:input:output:cacheRead:cacheWrite:)` 在每次代理请求结束时累加，`input` 是扣除了缓存命中后的新输入（`TokenTotals` 先把上游 prompt 数里的命中折出去），查询走 `fetch(startDay:endDay:)`。后端与 `UsageIndex` 同为 SQLite（`proxy-usage.db`）或 JSONL（`logs/usage-third-party.jsonl`）。`UsageIndex.fetch` 会把它的结果并入模型汇总，所以用量环的第三方切片是真实的 token 份额，而不是从被截断的列表上估的。**这份汇总不裁剪**——它就是要留住比抓包窗口更长的历史。

## 抓包留存 — `ProxyCaptureStore` / `CaptureJSONStore`

「流量」页的抓包记录是滚动窗口，不是完整账本：

- **列表上限 `listLimit = 120`**：两个后端都保留最近 120 条；SQLite 侧 `pruneLocked()` 先按 `capture_id NOT IN (最新 120)` 显式删除 payload 行，再删 capture 行（不依赖 `ON DELETE CASCADE`——`foreign_keys` is per-connection，实测关掉时 payload 会永远留下）。
- **空闲页回收**：`PRAGMA freelist_count` 超过 `vacuumThresholdPages = 8_192`（4096 字节页 → 约 32 MB）才 `VACUUM`，因为 VACUUM 是整文件重写。
- **孤儿媒体清扫**：每 `300` 秒一次 `sweepOrphanMedia()`，`logs/captures/<id>/` 中既无对应行、mtime 又早于 `-86_400` 秒的目录才删除——间隔内刚创建的目录会被留下。
- `CaptureJSONStore` 在 `prune()` 里做同样的 120 条截断；`ProxyCaptureStore.loadListIfNeeded()` 把列表读放在后台队列、幂等，只在首次挂载流量页时触发。

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
