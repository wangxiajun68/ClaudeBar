# 数据模型

> ClaudeBar 设计文档 · §3
> 相关：[交互流程](06-interactions.md) · 技术文档 [数据访问层](../technical/04-data-access-layer.md)

## 数据文件一览

| 文件 | 内容 | 读写方 |
|------|------|--------|
| `~/.claude/claude-bar-providers.json` | Claude Code / Provider 列表与激活项（`ProvidersFile`） | `ProviderStore`（写入经 `PrivateFileWriter`） |
| `~/.claude/claude-bar-codex-providers.json` | Codex 供应商列表与激活项（`CodexProvidersFile`） | `CodexProviderStore` |
| `~/.claude/settings.json` | Claude Code 的 `env` 块（`EnvConfig` 镜像） | `SettingsManager` |
| `~/.codex/config.toml` | 激活的 Codex `[model_providers.X]` 表与模型字段 | `CodexConfigWriter` |
| `~/.codex/claude-bar-model-catalog.json` | 写进 `model_catalog_json` 的模型目录 | `CodexModelCatalog` |
| `~/Library/Application Support/ClaudeBar/vpn/subscriptions.json` | VPN 订阅元数据 | `VpnSubscriptionStore` |

## Provider / ModelConfig（`claude-bar-providers.json`）

一个 **Provider** 代表一个 API 服务商，共享 `baseURL` 与 `authToken`，下挂多个 **ModelConfig**：

```json
{
  "providers": [
    {
      "id": "UUID",
      "name": "DeepSeek",
      "authToken": "sk-...",
      "baseURL": "https://api.deepseek.com/anthropic",
      "models": [
        {
          "id": "UUID",
          "name": "deepseek-v4-pro[1M]",
          "contextTokens": "1000000",
          "disableCompact": true,
          "disableExperimentalBetas": true,
          "autoCompactWindow": "",
          "maxConcurrentSubagents": "20",
          "workflowMaxConcurrentAgents": "30"
        }
      ],
      "activeModelID": "UUID",
      "captureEnabled": false,
      "profileID": "UUID",
      "catalogID": "deepseek"
    }
  ],
  "activeProviderID": "UUID"
}
```

顶层对应 Swift 类型 `ProvidersFile { providers, activeProviderID }`；`captureEnabled` 决定该供应商是否经本机代理，`profileID` 把 Claude 侧与 Codex 侧的同一配置关联起来（不含激活状态），`catalogID` 标记条目来自内置供应商目录（目录条目持有各客户端专属的 base URL，自定义主机为 nil）。

## EnvConfig（`settings.json` 的 env 块镜像）

`EnvConfig` 是 Claude Code `settings.json` 中 `env` 字段的 Swift 镜像，包含全部受支持的键：

`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_BASE_URL`、`ANTHROPIC_MODEL`、`CLAUDE_CODE_MAX_CONTEXT_TOKENS`、`DISABLE_COMPACT`、`GITHUB_PERSONAL_ACCESS_TOKEN`、`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`、`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL[_NAME]`、`CLAUDE_CODE_AUTO_COMPACT_WINDOW`、`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`、`CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS`。

切换模型时，`buildEnv()` 会把所选模型的 `name` 同时写入 `ANTHROPIC_MODEL` 与全部 8 个 `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL[_NAME]`，使 Claude Code 内部按 tier 选择时一致指向该模型（见技术文档 [状态中枢](../technical/03-provider-store.md)）。

`EnvConfig` 是普通的合成 `Codable`（字段带默认值但**没有**自定义 `init(from:)`）。读写不走 `JSONDecoder` 解码整份 `settings.json`：`readSettings()` 用 `JSONSerialization` 逐键取值（缺字段默认 `""`），`writeSettings` 把 `EnvConfig` 编码后再解码成 `[String: String]` 取非空值。历史版本曾有自定义 `Decodable`；字段缺失不会抛错这一点由逐键读取保证，而不是解码器的默认值。

## 旧格式兼容（`Provider.init(from:)`）

`Provider` 的 `Decodable` 实现兼容早期手写的 providers 文件：

- `models`：先试 `[ModelConfig]`，失败再试旧 `[String]`（此时读 provider 级的 `contextTokens`/`disableCompact`/`disableExperimentalBetas`/`autoCompactWindow` 动态键套到每个模型上）。
- `activeModelID`：先试 `UUID`，失败用旧 `activeModel`（String 模型名）匹配。
- `id` / `authToken` / `baseURL`：`decodeIfPresent` 缺失则取默认（id 自动生成 UUID）。

> 历史版本的扁平 `Preset` 列表与 `claude-bar-presets.json` 自动迁移逻辑（`MigrationHelper`）已在 1.8.0 移除；现仅保留上述 provider 文件内的旧字段解码兼容。

## WidgetSnapshot（主 app → Widget 的快照）

主 app 在会话轮询与用量/外观变化时把面板状态序列化为 `WidgetSnapshot`，经 `WidgetSnapshotWriter` 写入 **四个** 冗余位置以保证沙盒 Widget 一定能读到（见技术文档 [§4.3](../technical/04-data-access-layer.md#writewidgetsnapshot--四路冗余写入--diffb6)）：

```json
{
  "todayTotalTokens": 38690638,
  "usagePeriodLabel": "9月",
  "unitStyle": "chinese",
  "isDark": true,
  "modelBreakdown": [{"model": "kimi-k2.6", "totalTokens": 30000000}],
  "activeProviderName": "Kimi Local",
  "activeModelName": "kimi-k2.6",
  "balanceText": "42.50 CNY",
  "totalSessionCount": 2,
  "busySessionCount": 1,
  "sessions": [/* SessionSummary, 最多 5 条 */],
  "cursorSessions": [/* CursorSessionSummary, 最多 5 条 */],
  "externalSessions": [/* ExternalSessionSummary（Codex 等），最多 5 条、只含主会话不含子代理 */],
  "updatedAt": "2026-08-01T12:00:00Z"
}
```

`todayTotalTokens` 是 `usagePeriodLabel` 所述区间的总量（默认当前月，popup 可回翻），不一定是今天。`usagePeriodLabel` / `unitStyle` / `isDark` 与三条 summary 里的 `waiting` 都是可选字段，旧快照缺了也能解码；`externalSessions` 在解码器里对缺失取空数组（见 `WidgetSnapshot` 的手写 `init(from:)`）。

## Codex 供应商与模型（`claude-bar-codex-providers.json`）

Codex 侧是独立类型：`CodexProvider`（`apiKey` / `baseURL` / `wireAPI` / `requiresOpenAIAuth` / `preserveOfficialLogin` / `disableResponseStorage` / `models` / `activeModelID` / `captureEnabled` / `profileID` / `catalogID`）；`CodexModelConfig`（`name` / `reasoningEffort` / `contextWindow` / `autoCompactTokenLimit`）。顶层为 `CodexProvidersFile { providers, activeProviderID, activeKey }`，`activeKey` 是写进 `~/.codex/config.toml` 的 `[model_providers.X]` 表名（默认 `custom`）。激活 Codex 供应商时写入 `~/.codex/config.toml` 与模型目录 `~/.codex/claude-bar-model-catalog.json`，并按 `preserveOfficialLogin` 维护 `~/.codex/auth.json`（见 `CodexConfigWriter`）。写入 `config.toml` 的 `wire_api` 恒为 `"responses"`——Chat 上游由本机代理桥接，不写进这个文件。

## VPN 订阅（本机）

订阅元数据在 `~/Library/Application Support/ClaudeBar/vpn/subscriptions.json`，由 `VpnSubscriptionStore` 读写；订阅 YAML 在 `vpn/profiles/`，运行时配置在 `vpn/config.yaml`。**不要**把该文件或订阅 token 提交到 Git。
