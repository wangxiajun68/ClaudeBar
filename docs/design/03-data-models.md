# 数据模型

> ClaudeBar 设计文档 · §3
> 相关：[交互流程](06-interactions.md) · 技术文档 [数据访问层](../technical/04-data-access-layer.md)

## Provider / ModelConfig（新格式，`claude-bar-providers.json`）

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

## EnvConfig（`settings.json` 的 env 块镜像）

`EnvConfig` 是 Claude Code `settings.json` 中 `env` 字段的 Swift 镜像，包含全部受支持的键：

`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_BASE_URL`、`ANTHROPIC_MODEL`、`CLAUDE_CODE_MAX_CONTEXT_TOKENS`、`DISABLE_COMPACT`、`GITHUB_PERSONAL_ACCESS_TOKEN`、`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`、`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL[_NAME]`、`CLAUDE_CODE_AUTO_COMPACT_WINDOW`。

切换模型时，`buildEnv()` 会把所选模型的 `name` 同时写入 `ANTHROPIC_MODEL` 与全部四个 `ANTHROPIC_DEFAULT_*_MODEL[_NAME]`，使 Claude Code 内部按 tier 选择时一致指向该模型。**设计取舍**：这是"强制单一模型"的有意行为——把所选模型名写入全部 4 个 tier（OPUS/SONNET/HAIKU/FABLE）的 DEFAULT_MODEL，确保无论 Claude Code 内部按哪个 tier 路由，都落到用户选定的模型。代价是失去了"不同 tier 用不同模型"的能力，但 ClaudeBar 的产品定位是单一切换器，此取舍可接受。

## 旧格式迁移（`claude-bar-presets.json`）

旧版的扁平 `Preset` 列表（每个 preset 各自带 baseURL/authToken/model）在首次加载时由 `MigrationHelper.migrateIfNeeded()` 自动转换：按 `baseURL` 分组归并为 Provider，每个旧 preset 退化为该 Provider 下的一个 ModelConfig，迁移后删除旧文件。

## WidgetSnapshot（主 app → Widget 的快照）

主 app 每次刷新都把面板状态序列化为 `WidgetSnapshot`，写入 **四个** 冗余位置以保证沙盒 Widget 一定能读到（见技术文档 [§4.3](../technical/04-data-access-layer.md#writewidgetsnapshot--四路冗余写入--diffb6)）：

```json
{
  "todayTotalTokens": 38690638,
  "modelBreakdown": [{"model": "kimi-k2.6", "totalTokens": 30000000}],
  "activeProviderName": "Kimi Local",
  "activeModelName": "kimi-k2.6",
  "balanceText": "42.50",
  "totalSessionCount": 2,
  "busySessionCount": 1,
  "sessions": [/* SessionSummary, 最多 5 条 */],
  "cursorSessions": [/* CursorSessionSummary, 最多 5 条 */],
  "updatedAt": "2026-08-01T12:00:00Z"
}
```
