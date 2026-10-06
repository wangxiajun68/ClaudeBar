# 数据迁移与格式兼容

> ClaudeBar 技术文档 · §6
> 相关：设计文档 [数据模型](../design/03-data-models.md) · 技术文档 [数据访问层](04-data-access-layer.md)

## 现状

当前的数据格式是 Claude 侧的 `claude-bar-providers.json`（`ProvidersFile`）与 Codex 侧的 `claude-bar-codex-providers.json`（`CodexProvidersFile`），分别由 `ProviderStore` / `CodexProviderStore` 读写。历史版本的扁平 `Preset` 列表（`claude-bar-presets.json`）与其自动迁移器 `MigrationHelper` 已从代码中移除；`FilePaths` 也不再保留旧文件路径。若存在更早版本的残留文件，ClaudeBar 不再读取或迁移。

## `Provider.init(from:)` 的旧字段兼容

即便新格式文件，`Provider` 的 `Decodable` 实现也兼容早期手写内容：

- `models`：先试 `[ModelConfig]`，失败再试旧 `[String]`（此时用 provider 级的 `contextTokens`/`disableCompact`/`disableExperimentalBetas`/`autoCompactWindow` 动态键填充每个模型）。
- `activeModelID`：先试 `UUID`，失败用旧 `activeModel`（String 模型名）匹配。
- `id` / `authToken` / `baseURL` / `captureEnabled`：`decodeIfPresent` 缺失则取默认（id 生成新 UUID）；`name` 是唯一必填字段。

`EnvConfig`（`Models/Preset.swift`）是普通合成 `Codable`，且全仓没有从 `settings.json` 解出 `EnvConfig` 的 `JSONDecoder` 路径：读取走 `readSettings()` 的逐键构造（缺键得 `""`），`writeSettings` 内的一次 `JSONEncoder` → `JSONDecoder` 往返只作用在内存里刚编码出的完整字典上。因此上一条兼容路径完全由 `Provider` 承担，与 `EnvConfig` 无关。

## 若需重新引入迁移

1. 在 `Models/Provider.swift`（或独立文件）重建旧格式类型与 `MigrationHelper.migrateIfNeeded()`（历史实现把每个 `Preset` 归组成一个 `Provider` 的模型行，并在成功后删除旧文件）。
2. `FilePaths` 加回旧文件路径（历史名为 `oldPresetsFile`）。
3. `ProviderStore.loadProviders()` 开头调用迁移并 `saveProviders()`（保存新格式后删除旧文件）。
