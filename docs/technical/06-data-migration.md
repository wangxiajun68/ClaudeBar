# 数据迁移与格式兼容

> ClaudeBar 技术文档 · §6
> 相关：设计文档 [数据模型](../design/03-data-models.md) · 技术文档 [数据访问层](04-data-access-layer.md)

## 现状

当前唯一的数据格式是 `claude-bar-providers.json`（`ProvidersFile`）。历史版本的扁平 `Preset` 列表（`claude-bar-presets.json`）与其自动迁移器 `MigrationHelper` 已从代码中移除；`FilePaths` 也不再保留旧文件路径。若存在更早版本的残留文件，ClaudeBar 不再读取或迁移。

## `Provider.init(from:)` 的旧字段兼容

即便新格式文件，`Provider` 的 `Decodable` 实现也兼容早期手写内容：

- `models`：先试 `[ModelConfig]`，失败再试旧 `[String]`（此时用 provider 级的 `contextTokens`/`disableCompact`/`disableExperimentalBetas`/`autoCompactWindow` 动态键填充每个模型）。
- `activeModelID`：先试 `UUID`，失败用旧 `activeModel`（String 模型名）匹配。
- `id` / `authToken` / `baseURL`：`decodeIfPresent` 缺失则取默认（id 生成新 UUID）。

`EnvConfig.init(from:)` 全字段 `decodeIfPresent`，缺字段默认 `""`，保证向后兼容。

## 若需重新引入迁移

1. 在 `Models/Provider.swift`（或独立文件）重建 `Preset`/`PresetsFile` 类型与 `MigrationHelper.migrateIfNeeded()`。
2. `FilePaths` 加回旧文件路径。
3. `ProviderStore.loadProviders()` 开头调用迁移并 `saveProviders()`（保存新格式后删除旧文件）。
