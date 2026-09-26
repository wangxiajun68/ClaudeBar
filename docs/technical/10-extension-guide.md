# 扩展指南

> ClaudeBar 技术文档 · §10
> 相关：技术文档 [数据访问层](04-data-access-layer.md) · [视图层](05-view-layer.md)

## 新增一个 env 字段
1. `Preset.swift` 的 `EnvConfig` 加属性 + `CodingKeys` + 两个 `init`。
2. `SettingsManager.swift` 的 `readSettings` 加读取、`writeSettings` 加 `preserve` 行。
3. `ProviderStore.buildEnv` 赋值。
4. 若需 UI 编辑，加在用户真正会打开的编辑器上：`ProviderConnectionModel`（`Views/Shared/ProviderConnectionEditor.swift`）+ `ProviderConnectionDraft` 的读写、`ProvidersView.connectionDraft` / `saveConnection` 的往返。**只改这条路** —— 源码里曾有一套同名近似的 `ProviderEditorModel` / `ProviderEditorView`（无挂载点），已删除，见 [17](17-ui-audit-backlog.md) §3。

## 新增一个 Provider 级余额源
1. `BalanceFetcher` 加分支或新建 fetcher。
2. `ProviderStore.refreshBalance` 按 baseURL host 分发。

## 新增 Widget 尺寸
1. `ClaudeBarWidget.swift` 的 `supportedFamilies` 加项（如 `.systemMedium`）。
2. `WidgetViews.swift` 按 `@Environment(\.widgetFamily)` 分支布局。

## 新增 Cursor 之外的第二 IDE 监控
1. 新建 `Utils/<Ide>SessionMonitor.swift` + 数据模型。
2. `ProviderStore` 加 `@Published var ideSessions` + `refreshIdeSessions()`（照 `refreshCursorSessions` 的 detached-task 模式）。
3. popup 加 `Views/Popup/` 区段、主窗口 `SessionsView` 加 section，`writeWidgetSnapshot` 加字段。
4. `WidgetSnapshot` 加对应 summary 类型（`Widget/WidgetSnapshot.swift` 同步）。

## 新增 VPN 探测站点或切换策略

见 [11-vpn.md](11-vpn.md)。探测列表在 `VpnNetProbe`；failover 阈值在 `VpnManager.tickFailover`。不要把订阅 URL 写进仓库。

## 新增一类空闲通知
1. `NotificationService` 加 `notifyIdle(...)` 变体与 category（如需独立动作）。
2. `ProviderStore` 为该来源加一个 `IdleTransitionDetector<ID>` 实例并在刷新回调里 `detect`。
3. `AppDelegate` 的 `.resumeSession` 处理器补对应恢复逻辑。
