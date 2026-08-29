# 数据迁移

> ClaudeBar 技术文档 · §6
> 相关：设计文档 [数据模型](../design/03-data-models.md) · 技术文档 [数据访问层](04-data-access-layer.md)

## 旧 Preset → Provider 迁移

`MigrationHelper.migrateIfNeeded()`（在 `Provider.swift`）：
1. 检测 `claude-bar-presets.json`（旧）是否存在且非空。
2. 按 `baseURL`（trim `/`）分组旧 preset。
3. 每组：旧 preset 的 `ANTHROPIC_MODEL` 去重后转为 `ModelConfig`（继承 contextTokens / disableCompact / 等），Provider 名取 URL host 的主域段首字母大写。
4. 返回 `ProvidersFile`，由 `loadProviders` 保存为新格式并**删除旧文件**。

## `Provider.init(from:)` 的旧格式兼容

即便新格式文件，`Provider` 的 `Decodable` 实现也兼容：
- `models`：先试 `[ModelConfig]`，失败再试旧 `[String]`（此时用 provider 级的 `contextTokens`/`disableCompact` 等动态键）。
- `activeModelID`：先试 `UUID`，失败用旧 `activeModel`（String 模型名）匹配。
- `id` / `authToken` / `baseURL`：`decodeIfPresent` 缺失则生成默认。

`EnvConfig.init(from:)` 全字段 `decodeIfPresent`，缺字段默认 `""`，保证向后兼容。

`Preset.init(from:)`：`id` 缺失时生成新 UUID，让无 id 的旧数据存活。
