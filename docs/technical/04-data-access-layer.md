# 数据访问层

> ClaudeBar 技术文档 · §4
> 相关：设计文档 [数据模型](../design/03-data-models.md) · [交互流程](../design/06-interactions.md) · 技术文档 [状态中枢](03-provider-store.md)

## `FilePaths` — 路径常量

集中管理所有文件系统路径，分三组：

- **Claude Code**：`~/.claude/settings.json`、`~/.claude/claude-bar-providers.json`（新）、`~/.claude/claude-bar-presets.json`（旧，迁移用）、`~/.claude/projects/`、`~/.claude/sessions/`。
- **Cursor**：`~/.cursor/projects/`、`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`。
- **App Group**：`com.claudebar.app.widget`，快照文件 `claude-bar-widget-data.json`。

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

> **diff 优化（B6）**：2.5s 轮询会反复调用 `writeWidgetSnapshot()`。`WidgetSnapshotWriter.write(_:deduplicatingAgainst:)` 缓存上次 snapshot 的 JSON `Data`，仅当新 `Data != lastSnapshotData` 时才执行四路写入 + `WidgetCenter.shared.reloadAllTimelines()`。Apple 建议仅数据变化时重载 timeline——无 diff 时每 2.5s 无意义重载会浪费磁盘 I/O 与 widget 刷新配额。已删除原 `shared.synchronize()`（现代 macOS 自动同步，已弃用）。

## `SessionMonitor` — Claude Code 会话

**数据源**：`~/.claude/sessions/<pid>.json`，每个文件含 `pid`、`sessionId`、`cwd`、`startedAt`、`status`、`updatedAt` 等字段。

**判活**：`kill(pid_t(pid), 0) == 0`（信号 0 探测进程存在），死进程沉底。

**上下文扫描 `fetchContext`**：读 transcript `projects/<encoded-cwd>/<sessionId>.jsonl` 的**尾部 96KB**（`FileHandle.seekToEnd` 后回退）：
- 只处理含 `"usage"` 且 `"type":"assistant"` 的行。
- `lastContext = input_tokens + cache_read_input_tokens + cache_creation_input_tokens`（最新一条）。
- 从最后一条 `tool_use` 提取活动描述（`describeActivity`：`Bash · build.sh`、`Read · File.swift`、`Agent · Explore` 等）。
- `toolPending`：若最后 `tool_use` 的行号 > 最后 `tool_result` 的行号 → 该工具调用尚未返回 → busy。

**transcript 路径编码**：`/Users/wangxiajun/Project/ClaudeBar` → `projects/-Users-wangxiajun-Project-ClaudeBar`（去前导 `/` 后换 `-`，并加前导 `-`，与 Cursor 编码不同）。

**子 Agent / Workflow `fetchSubagents`**：
- 直属子 Agent：`<sessionDir>/subagents/agent-<id>.meta.json` + 同名 `.jsonl`。
- Workflow：`<sessionDir>/subagents/workflows/<wf_id>/agent-<id>.meta.json`，各 agent 的 transcript 在 `<wf_id>/<fname>.jsonl`。
- 每个 agent 的 `scanAgentActivity` 读尾部 32KB 判定 running/done。

## `CursorSessionMonitor` — Cursor 会话

**数据源**：Cursor 的 `state.vscdb`（SQLite，WAL 模式），表 `composerHeaders`（含 `composerId`、`recency`、`value` JSON、`isArchived`、`isSubagent`）。DB 约 6.5GB，但 `(recency, composerId)` 有索引。

**打开方式**：经共享的 `CursorDB.open()`（`Utils/CursorDB.swift`）——`sqlite3_open_v2` + `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`，`busy_timeout 2000`。WAL 允许并发读，不阻塞 Cursor 的写入。`CursorDB` 同时提供 `textColumn` 文本读取与 `cString` helper，供 `CursorSessionMonitor` 与 `CursorUsageStats` 复用（D2 去重；并消除 B3 的 `map[key]!` force-unwrap）。

**查询**：取 `isArchived=0 AND isSubagent=0` 按 `recency DESC` 最多 80 条，过滤 3 天内活跃（`lastUpdatedAt > cutoff`），取前 14 个展示。

**head 字段解析**：`name`、`createdAt`、`lastUpdatedAt`、`contextUsagePercent`、`agentLocation.status == "active"`（判 busy）、`workspaceIdentifier.uri.fsPath`（或 `draftTarget.environment.uri.fsPath`）取 cwd。

**transcript 扫描**：与 Claude 类似但更简单——Cursor 的 JSONL 有 `{"type":"turn_ended"}` 标记，pending 判定为「最后一条 assistant 行号 > 最后 `turn_ended` 行号」。

**子 Agent**：`fetchSubagents` 查 `isSubagent=1`，按 `subagentInfo.parentComposerId`（或 `rootParentConversationId`）归组到可见的父会话下。

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

## `BalanceFetcher` — DeepSeek 余额

仅当 `baseURL` 的 host 含 `deepseek.com` 时工作（B5：原先用 `baseURL.contains("deepseek")` 字符串包含判定，会误匹配 `https://deepseek-proxy.evil.com/` 等主机；改为基于 `URL(string: baseURL)?.host` 的判定，避免向非预期主机发送 token）。请求 `<base>/user/balance`，Bearer token 鉴权，解析 `balance_infos[0].total_balance` / `currency`。5 秒超时，失败返回 nil（不报错）。`currency` 一并展示（B10：`balanceText = "\(balance) \(currency)"`）。
