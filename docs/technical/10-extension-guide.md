# 扩展指南

> ClaudeBar 技术文档 · §10
> 相关：技术文档 [数据访问层](04-data-access-layer.md) · [视图层](05-view-layer.md)

## 新增一个 env 字段
1. `Preset.swift` 的 `EnvConfig` 加属性 + `CodingKeys` + 两个 `init`。
2. `SettingsManager.swift` 的 `readSettings` 加读取、`writeSettings` 加 `preserve` 行。
3. `ProviderStore.buildEnv` 赋值。
4. 若需 UI 编辑，`ProviderEditorView` 的 `EditableModel` + 详情表单加字段。

## 新增一个 Provider 级余额源
1. `BalanceFetcher` 加分支或新建 fetcher。
2. `ProviderStore.refreshBalance` 按 baseURL 分发。

## 新增 Widget 尺寸
1. `ClaudeBarWidget.swift` 的 `supportedFamilies` 加项（如 `.systemMedium`）。
2. `WidgetViews.swift` 按 `@Environment(\.widgetFamily)` 分支布局。

## 新增 Cursor 之外的第二 IDE 监控
1. 新建 `Utils/<Ide>SessionMonitor.swift` + 数据模型。
2. `ProviderStore` 加 `@Published var ideSessions` + `refreshIdeSessions()`。
3. `MenuBarView` 加区段，`writeWidgetSnapshot` 加字段。
4. `WidgetSnapshot` 加对应 summary 类型。
