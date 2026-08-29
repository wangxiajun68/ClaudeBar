# 数据模型

> ClaudeBar 设计文档 · §3
> 相关：[交互流程](06-interactions.md) · 技术文档 [数据访问层](../technical/04-data-access-layer.md)

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
          "autoCompactWindow": ""
        }
      ],
      "activeModelID": "UUID"
    }
  ],
  "activeProviderID": "UUID"
}
```

顶层对应 Swift 类型 `ProvidersFile { providers, activeProviderID }`。

## EnvConfig（`settings.json` 的 env 块镜像）

`EnvConfig` 是 Claude Code `settings.json` 中 `env` 字段的 Swift 镜像，包含全部受支持的键：

`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_BASE_URL`、`ANTHROPIC_MODEL`、`CLAUDE_CODE_MAX_CONTEXT_TOKENS`、`DISABLE_COMPACT`、`GITHUB_PERSONAL_ACCESS_TOKEN`、`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`、`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL[_NAME]`、`CLAUDE_CODE_AUTO_COMPACT_WINDOW`。

切换模型时，`buildEnv()` 会把所选模型的 `name` 同时写入 `ANTHROPIC_MODEL` 与全部 8 个 `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL[_NAME]`，使 Claude Code 内部按 tier 选择时一致指向该模型（见技术文档 [状态中枢](../technical/03-provider-store.md)）。

## 旧格式兼容（`Provider.init(from:)`）

`Provider` 的 `Decodable` 实现兼容早期手写的 providers 文件：

- `models`：先试 `[ModelConfig]`，失败再试旧 `[String]`（此时读 provider 级的 `contextTokens`/`disableCompact`/`disableExperimentalBetas`/`autoCompactWindow` 动态键套到每个模型上）。
- `activeModelID`：先试 `UUID`，失败用旧 `activeModel`（String 模型名）匹配。
- `id` / `authToken` / `baseURL`：`decodeIfPresent` 缺失则取默认（id 自动生成 UUID）。

`EnvConfig.init(from:)` 全字段 `decodeIfPresent`，缺字段默认 `""`，保证向后兼容。

> 历史版本（≤1.4）的扁平 `Preset` 列表与 `claude-bar-presets.json` 自动迁移逻辑（`MigrationHelper`）已随代码清理移除；现仅保留上述 provider 文件内的旧字段解码兼容。

## WidgetSnapshot（主 app → Widget 的快照）

主 app 每次刷新都把面板状态序列化为 `WidgetSnapshot`，经 `WidgetSnapshotWriter` 写入 **四个** 冗余位置以保证沙盒 Widget 一定能读到（见技术文档 [§4.3](../technical/04-data-access-layer.md#writewidgetsnapshot--四路冗余写入--diffb6)）：

```json
{
  "todayTotalTokens": 38690638,
  "modelBreakdown": [{"model": "kimi-k2.6", "totalTokens": 30000000}],
  "activeProviderName": "Kimi Local",
  "activeModelName": "kimi-k2.6",
  "balanceText": "42.50 CNY",
  "totalSessionCount": 2,
  "busySessionCount": 1,
  "sessions": [/* SessionSummary, 最多 5 条 */],
  "cursorSessions": [/* CursorSessionSummary, 最多 5 条 */],
  "updatedAt": "2026-08-01T12:00:00Z"
}
```
